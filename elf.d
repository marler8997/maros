module elf;

import std.algorithm : skipOver;
import std.string : lineSplitter, strip, indexOf, startsWith;

import mar.flag;
import mar.passfail;
import mar.enforce;
import mar.arraybuilder;
import mar.sentinel;
import mar.c;
import mar.print;
import mar.file : pipe, PipeFds, fileExists;
import mar.io;
import mar.process : ProcBuilder;

import common;

struct ReadElfLibrary
{
    static auto nullValue() { return ReadElfLibrary(null); }

    string file;
    bool isNull() const { return file is null; }
}
struct ReadElfInstaller
{
    cstring readElfProgram;
    const(char)[] targetRoot;
    ReadElfLibrary[string] installed;

    passfail install(SentinelArray!(const(char)) elfFile)
    {
        import mar.mem : free;

        auto procBuilder = ProcBuilder.forExeFile(readElfProgram);
        procBuilder.tryPut(lit!"-d").enforce;
        procBuilder.tryPut(elfFile).enforce;

        auto output = runGetStdout(procBuilder, Yes.printStdoutOnError);
        scope(exit) free(output.ptr);

        foreach (line; lineSplitter(output))
        {
            enum LibraryPrefix = "Shared library: [";
            enum RPathPrefix = "Library rpath: [";

            //stdout.writeln("readelf: ", line);

            auto prefixIndex = line.indexOf(LibraryPrefix);
            if (prefixIndex == -1)
            {
                auto rpathIndex = line.indexOf(RPathPrefix);
                if (rpathIndex != -1)
                {
                    stdout.writeln("readelf: ", line);
                    // TODO: Handle RPATH ( 0x000000000000000f (RPATH)              Library rpath: [/lib/crda] )
                    stderr.writeln("Error: RPATH not implemented");
                    return passfail.fail;
                }
                continue;
            }

            //stdout.writeln("readelf: ", line);
            auto libraryName = line[prefixIndex + LibraryPrefix.length .. $];
            auto endIndex = libraryName.indexOf(']');
            enforce(endIndex != -1, "invalid line format, found prefix '", LibraryPrefix, "' with no ending ']'");
            libraryName = libraryName[0 .. endIndex];

            auto existing = installed.get(cast(string)libraryName, ReadElfLibrary.nullValue);
            if (!existing.isNull)
            {
                stdout.writeln("library '", libraryName, "' already installed");
                continue;
            }
            installLibrary(libraryName.idup);
        }
        return passfail.pass;
    }
    // assumption: library has not already been installed
    private void installLibrary(string library)
    {
        stdout.writeln("[WARNING] installLibrary not impl");
    }

    private string resolveLibrary(const(char)[] library)
    {
        assert(0);
    }
}

struct LddLibrary
{
    static auto nullValue() { return LddLibrary(typeof(file).nullValue); }

    SentinelArray!(immutable(char)) file;
    bool isNull() const { return file.isNull; }
}
struct LddElfInstaller
{
    cstring lddProgram;
    const(char)[] targetRoot;

    ArrayBuilder!(SentinelArray!(const(char))) queue;
    LddLibrary[string] installed;

    auto peel(T)(T* next)
    {
        auto spaceIndex = (*next).indexOf(' ');
        if (spaceIndex == -1)
        {
            stderr.writeln("Error: invalid line, no space in '", (*next), "'");
            return null;
        }
        auto result = (*next)[0 .. spaceIndex];
        *next = (*next)[spaceIndex + 1 .. $];
        return result;
    }

    passfail installDeps()
    {
        for (;;)
        {
            if (queue.data.length == 0)
                break;
            auto next = queue.pop();
            auto result = installDirectDeps(next);
            if (result.failed)
                return result;
        }
        return passfail.pass;
    }
    passfail installDirectDeps(SentinelArray!(const(char)) elfFile)
    {
        import mar.mem : free;

        auto procBuilder = ProcBuilder.forExeFile(lddProgram);
        procBuilder.tryPut(elfFile).enforce;

        auto output = runGetStdout(procBuilder, Yes.printStdoutOnError);
        scope(exit) free(output.ptr);

        foreach (line; lineSplitter(output))
        {
            line = line.strip();
            //stdout.writeln("ldd: ", line);
            if (line == "statically linked")
                continue;

            auto next = line;
            auto name = peel(&next);
            if (name is null)
                return passfail.fail; // error already logged
            assert(name.length > 0, "codebug: whitespace should have been skipped by the strip function");

            //stdout.writeln("  name = '", name, "'");
            if (name[0] == '/')
            {
                auto result = installLibrary(name);
                if (result.failed)
                    return result;
                continue;
            }
            assert(name.indexOf('/') == -1, "unexpected output from ldd");
            if (name == "linux-vdso.so.1")
            {
                // skip this special library
                // it is automatically loaded by the kernel and does not exist
                // as a file on the filesystem
                continue;
            }
            if (!skipOver(next, "=> "))
            {
                stderr.writeln("Error: invalid line, expected next part to be '=> ' but is '", next, "'");
                return passfail.fail;
            }
            auto realName = peel(&next);
            if (realName is null)
                return passfail.fail; // error already logged
            if (realName.length == 0)
            {
                 stderr.writeln("Error: ldd was not able to resolve '", name, "'");
                 return passfail.fail;
            }
            //stdout.writeln("  realname = '", realName, "'");
            assert(realName[0] == '/', "unexpected output from ldd");
            {
                auto result = installLibrary(realName);
                if (result.failed)
                    return result;
            }
        }
        return passfail.pass;
    }

    private passfail installLibrary(const(char)[] libraryTempName)
    {
        auto existing = installed.get(cast(string)libraryTempName, LddLibrary.nullValue);
        if (!existing.isNull)
        {
            //stdout.writeln("library '", libraryTempName, "' already installed");
            return passfail.pass;
        }
        auto libraryStringName = sprintMallocSentinel(libraryTempName).asImmutable;
        if (!fileExists(libraryStringName.ptr))
        {
            stderr.writeln("Error: library '%s' does not exist", libraryStringName);
        }
        if (installFile(libraryStringName.array, targetRoot, null).failed)
            return passfail.fail;

        installed[libraryStringName.array] = LddLibrary(libraryStringName);
        queue.tryPut(libraryStringName).enforce; // install deps later
        return passfail.pass;
    }
}

passfail installElfWithReadelf(cstring readElfProgram, SentinelArray!(const(char)) elfFile, string destDir, const(char)[] targetRoot)
{
    stdout.writeln("installElf (with readelf) '", elfFile, "' to '", targetRoot, "'");
    auto result = installFile(elfFile.array, targetRoot, destDir);
    auto installer = ReadElfInstaller(readElfProgram, targetRoot);
    return installer.install(elfFile);
}

passfail installElfWithLdd(cstring lddProgram, SentinelArray!(const(char)) elfFile, string destDir, const(char)[] targetRoot)
{
    stdout.writeln("installElf (with ldd) '", elfFile, "' to '", targetRoot, "'");
    auto result = installFile(elfFile.array, targetRoot, destDir);
    auto installer = LddElfInstaller(lddProgram, targetRoot);
    installer.queue.tryPut(elfFile).enforce;
    return installer.installDeps();
}
