// msh = Maros Shell
import mar.array : aequals, acopy, amove;
import mar.sentinel : SentinelPtr, SentinelArray, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.mem : malloc, tryRealloc;
static import mar.linux.file;
import mar.linux.file : FileD, open, OpenFlags, OpenAccess, read;
import mar.input : LineReader, DefaultFileLineReaderHooks;
import mar.env : getenv;
import mar.findprog;
import mar.linux.process : exit, fork, execve, waitid, idtype_t, WEXITED;
import mar.linux.signals : siginfo_t;
import mar.linux.ttyioctl : isatty;

import log;

__gshared SentinelPtr!cstring savedEnvp;
__gshared cstring pathEnv;
__gshared bool interactiveMode;
__gshared int lastExitCode = 0;
__gshared uint lineNumber;

import mar.start;
mixin(startMixin);

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    savedEnvp = envp;

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
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1; // fail
            }
        }
    }

    FileD inFile;
    if (argc == 0)
    {
        inFile = mar.linux.file.stdin;
    }
    else if (argc == 1)
    {
        auto filename = argv[0];
        inFile = open(filename, OpenFlags(OpenAccess.readOnly));
        if (!inFile.isValid)
        {
            logError("open '", filename, "' failed, returned ", inFile.numval);
            return 1; // fail
        }
    }


    pathEnv = getenv(envp, "PATH");

    interactiveMode = isatty(inFile);

    {
        enum InitialBufferSize = 1024;
        auto result = malloc(InitialBufferSize);
        if (result is null)
        {
            logError("malloc(", InitialBufferSize, ") failed");
            exit(1);
        }
        inBuffer = (cast(char*)result)[0 .. InitialBufferSize];
    }
    for (;;)
    {
        if (interactiveMode)
        {
            import mar.file : stdout;
            stdout.write(lastExitCode, "> ");
        }
        runNextCommands(inFile);
    }
    return 0;
}

__gshared char[] inBuffer;
__gshared size_t nextLineStart;
__gshared size_t inDataLimit;

void increaseBufferSize(size_t newSize)
in { assert(nextLineStart == 0, "codebuf"); } do
{
    char *newBuffer;
    if (tryRealloc(inBuffer.ptr, newSize))
        newBuffer = inBuffer.ptr;
    else
    {
        newBuffer = cast(char*)malloc(newSize);
        if (!newBuffer)
        {
            logError("out of memory");
            exit(1);
        }
        acopy(newBuffer, inBuffer.ptr, inDataLimit);
    }
    inBuffer = newBuffer[0 .. newSize];
}

bool processInBuffer()
{
    bool ranOneCommand = false;
    for (auto i = nextLineStart;; i++)
    {
        if (i >= inDataLimit)
            return ranOneCommand;
        if (inBuffer[i] == '\n')
        {
            inBuffer[i] = '\0';
            auto line = inBuffer[nextLineStart .. i];
            nextLineStart = i + 1;
            ranOneCommand = true;
            handleCommand(line.assumeSentinel);
        }
    }
}

void runNextCommands(FileD inFile)
{
    for (;;)
    {
        if (processInBuffer())
            return;

        if (nextLineStart > 0)
        {
            auto dataSize = inDataLimit - nextLineStart;
            amove(inBuffer.ptr, inBuffer.ptr + nextLineStart, dataSize);
            nextLineStart = 0;
            inDataLimit = dataSize;
        }
        else if (inDataLimit == inBuffer.length)
            increaseBufferSize(inBuffer.length * 2);

        assert(nextLineStart == 0, "code bug");
        assert(inDataLimit < inBuffer.length, "code bug");
        {
            //import mar.file; stdout.write("[DEBUG] read...\n");
            auto result = read(inFile, inBuffer[inDataLimit.. $]);
            if (result.numval <= 0)
            {
                if (result.failed)
                {
                    logError("read failed, returned ", result.numval);
                    exit(1);
                }
                handleTheRest();
            }
            inDataLimit += result.val;
        }
    }
}

// TODO: test this
void handleTheRest()
{
    if (inDataLimit > 0)
    {
        // make sure it ends in null
        if (inDataLimit == inBuffer.length)
            increaseBufferSize(inBuffer.length + 1);
        inBuffer[inDataLimit] = '\0';
        handleCommand(inBuffer[0 .. inDataLimit].assumeSentinel);
    }
    exit(0);
}

bool isspace(char c)
{
    return c == ' ';
}

char[] peel(SentinelPtr!(char)* linePtr)
{
    char c;

    // skip whitespace
    for (; ; (*linePtr)++)
    {
        c = (*linePtr)[0];
        if (!isspace(c))
            break;
    }
    auto start = (*linePtr);
    if (c != '\0')
    {
        for (;;)
        {
            (*linePtr)++;
            c = (*linePtr)[0];
            if (isspace(c) || c == '\0')
                break;
        }
    }
    return start.raw[0 .. (*linePtr).raw - start.raw];
}

// return exit code
void handleCommand(SentinelArray!char lineArray)
{
    lineNumber++;

    ubyte[500] __tempBuffer;
    // temporary stub for alloc
    ubyte* allocStub(size_t size)
    {
        return (size <= __tempBuffer.length) ?
            __tempBuffer.ptr : null;
    }

    //import mar.file; stdout.write("[DEBUG] handleCommand: ", lineArray, "\n");

    auto linePtr = lineArray.ptr;
    for (;; linePtr++)
    {
        auto c = linePtr[0];
        if (!isspace(c))
            break;
    }
    if (linePtr[0] == '#')
        return;

    //
    // count arguments
    //
    uint argc = 0;
    {
        auto next = linePtr;
        for (;;)
        {
            auto cmd = peel(&next);
            if (cmd.length == 0)
                break;
            //import mar.file; stdout.write("[DEBUG] arg '", cmd, "'\n");
            argc++;
        }
    }
    if (argc == 0)
    {
        return; // empty line
    }
    //import mar.file; stdout.write("[DEBUG] got ", argc, " args\n");

    auto argv = cast(cstring*)allocStub(cstring.sizeof * (argc + 1));
    if (argv is null)
    {
        logError("failed to allocate memory");
        exit(1);
    }
    {
        auto next = linePtr;
        foreach (index; 0 .. argc)
        {
            auto cmd = peel(&next);
            cmd.ptr[cmd.length] = '\0';
            argv[index] = cmd.ptr.assumeSentinel;
            next++; // skip past the new '\0' character
        }
        argv[argc] = cstring.nullValue;
    }

    auto command = argv[0];

    // check if it is a special command
    if (aequals(command, "cd"))
        cd(argc, argv.assumeSentinel);
    else
    {
        if (usePath(command))
        {
            auto result = findProgram(pathEnv, command.walkToArray.array);
            if (result.isNull)
            {
                if (!interactiveMode)
                {
                    logError("(line ", lineNumber, ") cannot find program \"", command, "\"");
                    exit(1);
                }
                logError("cannot find program \"", command, "\"");
                lastExitCode = 1;
                return;
            }
            argv[0] = result;
        }

        // TODO: use clone instead (taken from strace bash)
        //clone(child_stack=0, flags=CLONE_CHILD_CLEARTID|CLONE_CHILD_SETTID|SIGCHLD, child_tidptr=0x7f1db307c9d0) = 16481
        auto pidResult = fork();
        if (pidResult.failed)
        {
            logError("fork failed, returned ", pidResult.numval);
            exit(1);
        }
        if (pidResult.val == 0)
        {
            auto result = execve(argv[0], argv.assumeSentinel, savedEnvp);
            logError("execve returned ", result.numval);
            exit(1);
        }

        siginfo_t info;
        //stdout.write("[DEBUG] waiting for ", pid, "...\n");
        auto result = waitid(idtype_t.pid, pidResult.val, &info, WEXITED, null);
        if (result.failed)
        {
            logError("waitid failed, returned ", result.numval);
            //exit(result);
            exit(1);
        }
        lastExitCode = info.si_status;
        if (!interactiveMode)
        {
            if (lastExitCode)
            {
                logError("(line ", lineNumber, ") program \"", argv[0], "\" exited with error code ", lastExitCode);
                exit(lastExitCode);
            }
        }
    }
}

void cd(uint argc, SentinelPtr!cstring argv)
{
    import mar.filesys : chdir;

    argc--;
    argv++;
    if (argc == 0)
    {
        logError("cd requires a path");
        return;
    }

    // TODO: parse options
    if (argc > 1)
    {
        logError("too many arguments");
        return;
    }
    auto path = argv[0];
    auto result = chdir(path);
    if (result.failed)
    {
        logError("chdir failed, returned ", result.numval);
        return;
    }
}
