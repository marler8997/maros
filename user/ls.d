import mar.array : aequals;
import mar.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.print : formatHex;
import mar.filesys : linux_dirent, getdents, LinuxDirentRange;
import mar.file : FileD, open, close, OpenFlags, OpenAccess, OpenCreateFlags,
                   stat_t, fstatat, formatMode, AT_SYMLINK_NOFOLLOW, isLink, readlinkat;
import mar.stdio : stdout, stderr;
import mar.process : exit;

import log;

import mar.start;
mixin(startMixin);

__gshared bool long_ = false;

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argc--;
    argv++;
    {
        uint originalArgc = argc;
        argc = 0;
        for (uint i = 0; i < originalArgc; i++)
        {
            auto arg = argv[i];
            if (arg[0] != '-')
                argv[argc++] = arg;
            else if (aequals(arg, lit!"-l"))
                long_ = true;
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
    }

    if (argc == 0)
        ls(litPtr!"", litPtr!".");
    else
    {
        foreach (i; 0 .. argc)
        {
            auto pathname = argv[i];
            stdout.write(pathname, ":\n");
            ls(litPtr!"  ", argv[i]);
        }
    }
    return 0;
}

void ls(cstring prefix, cstring pathname)
{
    auto fd = open(pathname, OpenFlags(OpenAccess.readOnly, OpenCreateFlags.dir));
    if (!fd.isValid)
    {
        logError("open \"", pathname , "\" failed ", fd);
        exit(1);
    }
    scope(exit) close(fd);
    //logInfo("open returned ", fd);

    for (;;)
    {
        ubyte[2048] buffer = void;
        auto entries = cast(linux_dirent*)buffer.ptr;
        auto result = getdents(fd, entries, buffer.length);
        if (result.numval <= 0)
        {
            if (result.failed)
                logError("getdents failed, it returned ", result.numval);
            break;
        }
        printDirEntries(prefix, fd, entries, result.val);
    }
}

bool isCurrentOrParentDir(cstring name)
{
    return name[0] == '.' &&
        (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'));
}

void printDirEntries(cstring prefix, FileD dirFd, linux_dirent* entries, ptrdiff_t size)
{
    foreach (entry; LinuxDirentRange(size, entries))
    {
        if (isCurrentOrParentDir(entry.nameCString))
            continue;

        if (!long_)
        {
            stdout.write(prefix, entry.nameCString, "\n");
            continue;
        }

        stat_t fileStatus = void;
        {
            auto result = fstatat(dirFd, entry.nameCString, &fileStatus, AT_SYMLINK_NOFOLLOW);
            if (result.failed)
            {
                logError("stat \"", entry.nameCString, "\" failed, returned ",
                    result.numval);
                continue;
            }
        }
        stdout.write(prefix,
            fileStatus.st_mode.formatMode, " ",
            entry.nameCString);
        if (fileStatus.st_mode.isLink)
        {
            stdout.write(" -> ");
            // TODO: do not use a static size for this
            char[100] buffer;
            auto result = readlinkat(dirFd, entry.nameCString, buffer);
            if (result.failed)
            {
                stdout.write("? (error: readlinkat failed, returned ",
                    result.numval, " )");
            }
            else
            {
                stdout.write(buffer[0 .. result.val]);
            }
        }
        stdout.write("\n");
    }
}
