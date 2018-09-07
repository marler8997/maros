module common;

import mar.process : ProcBuilder;

void enforce(T)(T cond, lazy string msg)
{
    import std.stdio : writeln;
    import mar.process : exit;
    if (!cond)
    {
        writeln("Error: ", msg);
        exit(1);
    }
}

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
    import mar.process : exit;
    writeln("[RUN] ", command);
    writeln("--------------------------------------------------------------------------------");
    //
    // TODO: what to do with environment variables?
    //
    auto pid = spawnShell(command);
    auto result = wait(pid);
    writeln("--------------------------------------------------------------------------------");
    if (result != 0)
    {
        writefln("Error: last command exited with %s", result);
        exit(1);
    }
}

version (Posix)
{
    import mar.sentinel : SentinelPtr;
    import mar.c : cstring;
    extern (C) extern __gshared SentinelPtr!cstring environ;
}
else static assert(0, "environ pointer for this platform not implemented");

void run(ProcBuilder procBuilder)
{
    import mar.file : stdout, stderr;
    import mar.process : exit, wait;
    stdout.write("[RUN] ", procBuilder, "\n");
    stdout.write("--------------------------------------------------------------------------------\n");
    auto proc = procBuilder.startWithClean(environ);
    if (proc.failed)
    {
        stderr.write("Error: failed to start process: ", proc, "\n");
        exit(1);
    }
    auto result = wait(proc.val);
    if (result.failed)
    {
        stderr.write("Error: failed to wait for process: ", result, "\n");
        exit(1);
    }
    if (result.val != 0)
    {
        stderr.write("Error: last command exited with ", result.val, "\n");
        exit(1);
    }
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
    import std.path;
    if (!path.isAbsolute)
        path = buildNormalizedPath(base, path);
    else
        path = buildNormalizedPath(path);

    const abs = absolutePath(path);
    const rel = relativePath(path);
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
