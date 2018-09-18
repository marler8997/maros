module common;

import mar.passfail;
import mar.flag;
import mar.enforce;
import mar.process : ProcBuilder;
import mar.linux.cthunk : mode_t;
import mar.linux.file.perm;

auto tryExec(string command, string filter = null)
{
    import std.exception : assumeUnique;
    import std.array : appender;
    import std.string : lineSplitter;
    import std.algorithm : canFind;
    import std.stdio;
    import std.process : executeShell;
    import std.typecons : Yes;
    if (filter)
        writefln("[EXEC-FILTERED] %s | filter '%s'", command, filter);
    else
        writeln("[EXEC] ", command);

    auto result = executeShell(command);
    if (result.output.length > 0)
    {
        if (filter)
        {
            auto filtered = appender!(char[])();
            bool started = false;
            foreach (line; result.output.lineSplitter!(Yes.keepTerminator))
            {
                if (line.canFind(filter))
                {
                    if (!started)
                    {
                        writeln("--------------------------------------------------------------------------------");
                        started = true;
                    }
                    write(line);
                    filtered.put(line);
                }
            }
            if (started)
                writeln("--------------------------------------------------------------------------------");
            result.output = filtered.data.assumeUnique;
        }
        else
        {
            writeln("--------------------------------------------------------------------------------");
            write(result.output);
            if (result.output[$-1] != '\n')
                writeln();
            writeln("--------------------------------------------------------------------------------");
        }
    }
    return result;
}
string exec(string command, string filter = null)
{
    import std.format : format;
    auto result = tryExec(command, filter);
    enforce(result.status == 0, format("last command exited with code %s", result.status));
    return result.output;
}

void run(string command)
{
    import std.stdio;
    import std.process : spawnShell, wait;
    writeln("[RUN] ", command);
    writeln("--------------------------------------------------------------------------------");
    //
    // TODO: what to do with environment variables?
    //
    auto pid = spawnShell(command);
    auto result = wait(pid);
    writeln("--------------------------------------------------------------------------------");
    enforce(result == 0, "last command exited with ", result);
}

version (Posix)
{
    import mar.sentinel : SentinelPtr;
    import mar.c : cstring;
    extern (C) extern __gshared SentinelPtr!cstring environ;
}
else static assert(0, "environ pointer for this platform not implemented");

void printRun(ProcBuilder procBuilder)
{
    import mar.io : stdout;
    stdout.writeln("[RUN] ", procBuilder);
}

void run(ProcBuilder procBuilder)
{
    import mar.io;
    import mar.process : wait;

    printRun(procBuilder);
    stdout.writeln("--------------------------------------------------------------------------------");
    auto proc = procBuilder.startWithClean(environ);
    enforce(proc, "failed to start process: ", Result.val);
    auto result = wait(proc.val);
    enforce(result, "failed to wait for process, returned ", Result.val);
    enforce(result.val == 0, "last command exited with ", result.val);
}

char[] runGetStdout(ProcBuilder procBuilder, Flag!"printStdoutOnError" printStdoutOnError)
{
    import mar.sentinel : assumeSentinel;
    import mar.file : pipe, PipeFds, dup2, close;
    import mar.input : readAllMalloc;
    import mar.io : stdout;
    import mar.linux.process : fork, execve, wait;

    PipeFds pipeFds;
    pipe(&pipeFds)
        .enforce("pipe failed, returned ", Result.val);
    //stdout.writeln("[DEBUG] Pipe: read=", pipeFds.read, ", write=", pipeFds.write);

    printRun(procBuilder);
    procBuilder.tryPut(cstring.nullValue).enforce;
    auto pidResult = fork();
    if (pidResult.val == 0)
    {
        {
            auto result = dup2(pipeFds.write, stdout);
            enforce(result == stdout, "dup2 failed, returned ", result);
        }
        close(pipeFds.read);
        close(pipeFds.write);
        auto result = execve(procBuilder.args.data[0], procBuilder.args.data.ptr.assumeSentinel, environ);
        // TODO: how do we handle this error in the new process?
        //exit( (result.numval == 0) ? 1 : result.numval);
        enforce(false, "execve failed");
    }

    procBuilder.free();
    pidResult.enforce("fork failed, returned ", Result.val);
    close(pipeFds.write);
    auto output = readAllMalloc(pipeFds.read, 4096);
    close(pipeFds.read);

    auto result = wait(pidResult.val);
    enforce(result, "wait failed, returned ", Result.val);
    if (result.val != 0)
    {
        if (printStdoutOnError)
        {
            stdout.write(output.val);
        }
        enforce(0, "last command exited with ", result.val);
    }
    return output.val;
}

alias formatFile = formatQuotedIfSpaces;

@property auto formatDir(const(char)[] dir)
{
    if (dir.length == 0)
        dir = ".";
    return formatQuotedIfSpaces(dir);
}

// returns a formatter that will print the given string.  it will print
// it surrounded with quotes if the string contains any spaces.
@property auto formatQuotedIfSpaces(T...)(T args) if (T.length > 0)
{
    struct Formatter
    {
        T args;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            import std.string : indexOf;
            bool useQuotes = false;
            foreach (arg; args)
            {
                if (arg.indexOf(' ') >= 0)
                {
                    useQuotes = true;
                    break;
                }
            }

            if (useQuotes)
                sink("\"");
            foreach (arg; args)
            {
                sink(arg);
            }
            if (useQuotes)
                sink("\"");
        }
    }
    return Formatter(args);
}
/*
DOESN'T WORK CORRECTLY
string sourceRelativeShortPath(string fileFullPath = dirName(__FILE_FULL_PATH__))(string path)
{
    return shortPath(path, fileFullPath);
}
*/
string shortPath(string path, string base)
{
    //import mar.io;stdout.writeln("[DEBUG] shortPath: path '", path, "' base '", base, "'");
    import std.path;
    if (path.isAbsolute)
        return buildNormalizedPath(path);

    path = buildNormalizedPath(base, path);

    const abs = buildNormalizedPath(absolutePath(path));
    const rel = buildNormalizedPath(relativePath(path));
    return (rel.length < abs.length) ? rel : abs;
}

static struct MappedFile
{
    import std.format : format;

    import mar.flag;
    import mar.c : cstring;
    import mar.ctypes : off_t;
    import mar.mmap : MemoryMap, createMemoryMap;
    import mar.file : FileD;
    version (linux)
    {
        import mar.linux.file : open, OpenFlags, OpenAccess, close;
    }
    else version (Windows)
    {

    }

    private FileD fd;
    private MemoryMap memoryMap;
    static MappedFile openAndMap(cstring filename, off_t offset, size_t length, Flag!"writeable" writeable)
    {
        MappedFile result;
        result.fd = open(filename, OpenFlags(writeable ? OpenAccess.readWrite : OpenAccess.readOnly));
        enforce(result.fd.isValid, format("failed to open '%s' (e=?)", filename/*, errno*/));
        result.memoryMap = createMemoryMap(null, length, writeable, result.fd, offset);
        enforce(result.memoryMap.passed, format("failed to memory map file (e=%s)", result.memoryMap.numval));
        return result;
    }
    auto ptr() const { return memoryMap.ptr; }
    ~this()
    {
        unmapAndClose();
    }
    void unmapAndClose()
    {
        if (fd.isValid)
        {
            memoryMap.unmap();
            close(fd);
            this.fd.setInvalid();
        }
    }
}

passfail mkdirIfDoesNotExist(const(char)[] dir, mode_t mode = S_IRWXU | S_IRWXG | (S_IROTH | S_IXOTH))
{
    import mar.c : tempCString;
    import mar.file : isDir;
    import mar.io;
    import mar.filesys : mkdir;

    mixin tempCString!("dirCStr", "dir");
    if (!isDir(dirCStr.str))
    {
        stdout.writeln("mkdir '", dir, "'");
        auto result = mkdir(dirCStr.str, mode);
        if (result.failed)
        {
            stderr.writeln("mkdir '", dir, "' failed, returned ", result.numval);
            return passfail.fail;
        }
    }
    // TODO: should we check that the mode is correct?
    return passfail.pass;
}

auto trimFront(inout(char)[] str, char trimChar)
{
    size_t offset = 0;
    for (; offset < str.length && str[offset] == trimChar; offset++)
    { }
    return str[offset .. $];
}
auto trimBack(inout(char)[] str, char trimChar)
{
    size_t offset = str.length;
    for(; offset > 0;)
    {
        offset--;
        if (str[offset] != trimChar)
        {
            offset++;
            break;
        }
    }
    return str[0 .. offset];
}
auto trimBoth(inout(char)[] str, char trimChar)
{
    return str.trimFront(trimChar).trimBack(trimChar);
}

passfail installFile(const(char)[] file, const(char)[] targetRoot, const(char)[] targetOverride)
{
    import mar.qual;
    import mar.mem : free;
    import mar.print : sprintMallocNoSentinel;
    import mar.path : baseName;

    targetRoot = targetRoot.trimBack('/');

    char[] targetFile;
    if (targetOverride.length == 0)
    {
        auto fileTrimmedRoot = file.trimFront('/');
        targetFile = sprintMallocNoSentinel(targetRoot, '/', fileTrimmedRoot);
    }
    else
    {
        if (targetOverride[$ - 1] == '/')
            targetFile = sprintMallocNoSentinel(targetRoot, '/', targetOverride.trimFront('/'), baseName(file));
        else
            targetFile = sprintMallocNoSentinel(targetRoot, '/', targetOverride.trimFront('/'));
    }
    auto result = installFile(file, targetFile, targetRoot.length + 1);
    free(targetFile.ptr);
    return result;
}

passfail installFile(const(char)[] source, const(char)[] dest, size_t mkdirStartIndex)
{
    import mar.print : sprintMallocSentinel;
    import mar.path : SubPathIterator, dirName;

    foreach (dir; SubPathIterator(dirName(dest), mkdirStartIndex))
    {
        //stdout.writeln("[DEBUG] SubPath '", dir, "'");
        auto result = mkdirIfDoesNotExist(dir);
        if (result.failed)
            return passfail.fail;
    }

    // TODO: this is just a quick hack to get it working
    //       mar should create a copy function
    import std.file : exists;
    if (exists(dest))
    {
        import mar.io;
        stdout.writeln("already installed '", dest, "'");
    }
    else
    {
        import std.format : format;
        run(format("cp %s %s", source, dest));
    }
    return passfail.pass;
}
