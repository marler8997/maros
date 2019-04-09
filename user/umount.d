import mar.flag;
import mar.array : aequals;
import mar.sentinel : SentinelPtr, assumeSentinel, lit;
import mar.c : cstring;
import mar.stdio : stdout;
import mar.linux.filesys : umount2;
import mar.cmdopt;

import log;

import mar.start;
mixin(startMixin);

void usage()
{
    stdout.write("Usage: umount [-options] dir\n");
    stdout.write("Options:\n");
}
extern (C) int main(uint argc, SentinelPtr!(SentinelPtr!char) argv, SentinelPtr!(SentinelPtr!char) envp)
{
    SentinelPtr!char fstypes;
    bool allowNonEmptyTarget = false;

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
                return 1;
            }
        }
    }

    if (argc == 0)
    {
        usage();
        return 1;
    }
    if (argc > 1)
    {
        logError("too many command-line arguments");
        return 1;
    }
    auto dir = argv[0];
    auto result = umount2(dir, 0);
    if (result.failed)
    {
        logError("umount '", dir, "' failed, returned ", result.numval);
        return 1;
    }
    return 0;
}
