import mar.array : aequals;
import mar.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.print : formatHex;
import mar.mem : malloc;
import mar.stdio : stdout;
import mar.linux.file : open, OpenFlags, OpenAccess, close, read, stat_t, fstat;
import mar.linux.syscall : sys_init_module, sys_finit_module;
import log;

import mar.start;
mixin(startMixin);

__gshared bool long_ = false;

void usage()
{
    stdout.write("Usage: insmod <file> [args...]\n");
}

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
    {
        usage();
        return 1;
    }

    auto filename = argv[0];

    if (argc > 1)
    {
        logError("module options not implemented");
        return 1;
    }

    cstring params = litPtr!"";

    auto fd = open(filename, OpenFlags(OpenAccess.readOnly));
    if (!fd.isValid)
    {
        stdout.write("failed to open file '", filename, "', result=", fd.numval);
        return 1;
    }
    {
        auto result = sys_finit_module(fd, params, 0);
        if (result.failed)
        {
            logError("finit_module failed, returned ", result.numval);
            return 1;
        }
    }

    return 0;
}
