import mar.conv : tryTo;
import mar.array : aequals;
import mar.sentinel : SentinelPtr, assumeSentinel, lit;
import mar.c : cstring;
import mar.print : sprint;
import mar.file : FileD, stdin, stdout, stderr, open, close, OpenFlags, OpenAccess, dup2;
import mar.env : getenv;
import mar.findprog;
import mar.cmdopt;
import mar.linux.ioctl : ioctl;
import mar.linux.vt : VT_OPENQRY;
import mar.linux.process : exit, fork, setsid, execve;

import log;
import tty;

import mar.start;
mixin(startMixin);

void usage()
{
    stdout.write("Usage: openvt [-c vtnum] [--] command\n");
    stdout.write("Options:\n");
    stdout.write("  -t     file system type\n");
    stdout.write("  --allow-non-empty-target\n");
}
// TODO: what to do about envp?
extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    cstring vtNumString;

    argc--;
    argv++;
    {
        uint originalArgc = argc;
        argc = 0;
        uint i = 0;
        for (; i < originalArgc; i++)
        {
            auto arg = argv[i];
            if (arg[0] != '-')
                break;

            if (aequals(arg, lit!"-c"))
                vtNumString = getOptArg(argv, &i);
            else if (aequals(arg, lit!"--"))
            {
                i++;
                break;
            }
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
        for (; i < originalArgc; i++)
            argv[argc++] = argv[i];
    }

    if (argc == 0)
    {
        usage();
        return 1;
    }

    uint vtNum;
    if (!vtNumString.isNull)
    {
        if (tryTo(vtNumString, &vtNum).failed)
        {
            logError("invalid vt number \"", vtNumString, "\"");
            return 1;
        }
    }

    cstring programFile;
    if (!usePath(argv[0]))
        programFile = argv[0];
    else
    {
        programFile = findProgram(getenv(envp, "PATH"), argv[0].walkToArray.array);
        if (programFile.isNull)
        {
            logError("cannot find program \"", argv[0], "\"");
            return 1;
        }
    }
    argv[0] = programFile;

    auto ttyControlFd = open(defaultTty.ptr, OpenFlags(OpenAccess.readWrite));
    if (!ttyControlFd.isValid)
    {
        logError("failed to open ", defaultTty.array, ", open returned ", ttyControlFd.numval);
        return 1;
    }
    // no need to close ttyControlFd, will be closed when process exits

    if (vtNumString.isNull)
    {
        // find an open vt
        auto result = ioctl(ttyControlFd, VT_OPENQRY, &vtNum);
        if (result.failed)
        {
            logError("VT_OPENQRY failed, returned ", result.numval);
            exit(1);
        }
        stdout.write("found open vt ", vtNum, "\n");
    }

    // TODO: is this size good?
    char[20] vtFileBuffer;
    auto vtFileLength = sprint(vtFileBuffer, "/dev/tty", vtNum, '\0');
    auto vtFile = vtFileBuffer[0 .. vtFileLength - 1].assumeSentinel;

    stdout.write("running program \"", argv[0], "\" on ", vtFile, "\n");

    auto pidResult = fork();
    if (pidResult.val == 0)
    {
        close(ttyControlFd);
        auto sessionID = setsid();
        if (sessionID.failed)
        {
            logError("setsid failed, returned ", sessionID.numval);
            exit(1);
        }
        //close(stderr);
        //close(stdout);
        //close(stdin);
        // open the new tty
        auto ttyFd = open(vtFile.ptr, OpenFlags(OpenAccess.readWrite));
        if (!ttyFd.isValid)
        {
            logError("open \"", vtFile.array, "\" failed, returned ", ttyFd.numval);
            exit(1);
        }
        enforceDup2(ttyFd, stdin);
        enforceDup2(ttyFd, stdout);
        enforceDup2(ttyFd, stderr);
        auto result = execve(argv[0], argv, envp);
        logError("execve returned ", result.numval);
        exit(1);
    }

    if (pidResult.failed)
    {
        logError("fork failed");
        exit(1);
    }
    stdout.write("pid=", pidResult.val, "\n");
    return 1;
}

void enforceDup2(FileD oldfd, FileD newfd)
{
    auto result = dup2(oldfd, newfd);
    if (result != newfd)
    {
        logError("dup failed, returned ", result.numval);
        exit(1);
    }
}
