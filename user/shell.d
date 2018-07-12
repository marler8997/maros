import stdm.array : aequals;
import stdm.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import stdm.c : cstring;
import stdm.linux.process : exit, vfork, fork, execve, waitid, idtype_t, WEXITED;
import stdm.linux.signals : siginfo_t;

import log;
import findprog;

__gshared SentinelPtr!cstring savedEnvp;
__gshared char[] inputBuffer;
__gshared size_t inputDataLength;

// TODO: implement expanding input buffer
__gshared char[1025] tempInitialBufferUntilMallocIsWorking;

import stdm.start : startMixin;
mixin(startMixin!());

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    savedEnvp = envp;

    import stdm.file : stdout, print;

    inputBuffer = tempInitialBufferUntilMallocIsWorking;
    // inputBuffer = malloc(1024); (except not malloc, a type-safe variant)

    for (;;)
    {
        print(stdout, "# ");
        auto lineLength = readln();
        handleCommand(inputBuffer[0 .. lineLength]);

        // shift any remaining data back to the beginning
        inputDataLength -= (lineLength + 1);
        // todo: use memove variant (coming soon)
        for (ushort i = 0; i < inputDataLength; i++)
        {
            inputBuffer[i] = inputBuffer[lineLength + 1 + i];
        }
    }
}

// returns: index of newline
size_t readln()
{
    import stdm.file : stdin, stderr, print, read;

    for (;;)
    {
        auto lastReadLength = read(stdin, inputBuffer[inputDataLength .. $]);
        if (lastReadLength.numval <= 0)
        {
            if (lastReadLength.failed)
            {
                logError("read(stdin) failed, returned ", lastReadLength.numval);
                exit(1);
            }
            exit(0);
        }
        auto index = inputDataLength;
        inputDataLength += lastReadLength.val;

        // find the newline
        for (;;)
        {
            if (inputBuffer[index] == '\n')
            {
                inputBuffer[index] = '\0';
                return index;
            }

            index++;
            if (index >= inputDataLength)
            {
                break;
            }
        }

        if (inputDataLength >= inputBuffer.length)
        {
            // TODO: increase buffer size (i.e. realloc)
            logError("command too long, resizing buffer not implemented");
            exit(1);
        }
    }
}

char[] peel(char** linePtr)
{
    char c;
    for (; ; (*linePtr)++)
    {
        c = (*linePtr)[0];
        if (c != ' ')
            break;
    }
    char* start = (*linePtr);
    if (c != '\0')
    {
        for (;;)
        {
            (*linePtr)++;
            c = (*linePtr)[0];
            if (c == ' ' || c == '\0')
                break;
        }
    }
    return start[0 .. (*linePtr) - start];
}

void handleCommand(char[] line)
{
    import stdm.file : print, stderr;

    ubyte[500] __tempBuffer;
    // temporary stub for alloc
    ubyte* allocStub(size_t size)
    {
        return (size <= __tempBuffer.length) ?
            __tempBuffer.ptr : null;
    }

    //import stdm.file; print(stdout, "[DEBUG] handleCommand: ", line, "\n");

    //
    // count arguments
    //
    uint argc = 0;
    {
        auto next = line.ptr;
        for (;;)
        {
            auto cmd = peel(&next);
            if (cmd.length == 0)
                break;
            //import stdm.file; print(stdout, "[DEBUG] arg '", cmd, "'\n");
            argc++;
        }
    }
    if (argc == 0)
    {
        return; // empty line
    }
    //import stdm.file; print(stdout, "[DEBUG] got ", argc, " args\n");

    auto argv = cast(cstring*)allocStub(cstring.sizeof * (argc + 1));
    if (argv is null)
    {
        logError("failed to allocate memory");
        exit(1);
    }
    {
        auto next = line.ptr;
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
    {
        cd(argc, argv.assumeSentinel);
    }
    else
    {
        //
        // Find the program to handle this command
        //
        char[200] programFileBuffer; // todo: shouldn't use a statically sized buffer here
        cstring programFile = getCommandProgram(command, programFileBuffer);
        if (programFile.isNull)
        {
            logError("cannot find program \"", command, "\"");
            return;
        }
        argv[0] = programFile;

        //auto pid = vfork();
        auto pidResult = fork();
        if (pidResult.failed)
        {
            logError("fork failed, returned ", pidResult.numval);
            exit(1);
        }
        if (pidResult.val == 0)
        {
            auto result = execve(programFile, argv.assumeSentinel, savedEnvp);
            logError("execve returned ", result.numval);
            exit(1);
        }

        siginfo_t info;
        //print(stdout, "[DEBUG] waiting for ", pid, "...\n");
        auto result = waitid(idtype_t.pid, pidResult.val, &info, WEXITED, null);
        if (result.failed)
        {
            logError("waitid failed, returned ", result.numval);
            //exit(result);
            exit(1);
        }
        //print(stdout, "child process status is 0x", status.formatHex, "\n");
    }
}

void cd(uint argc, SentinelPtr!cstring argv)
{
    import stdm.filesys : chdir;

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
