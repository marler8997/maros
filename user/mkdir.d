import mar.array : aequals;
import mar.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.file : S_IRWXU, S_IRWXG, S_IRWXO;
import mar.io : stdout;
import mar.filesys : mkdir;

import log;

import mar.start;
mixin(startMixin);

__gshared bool parentsMode = false;

void usage()
{
    stdout.write("Usage: mkdir [-options] <dirs...>\n");
    stdout.write("  -p, --parents     no error if existing, make parent directories as needed\n");
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
            else if (aequals(arg, lit!"-p") || aequals(arg, lit!"--parents"))
                parentsMode = true;
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
    foreach (dirname; argv[0 .. argc])
    {
        if (parentsMode)
        {
            logError("-p not implemented");
            return 1;
        }
        else
        {
            auto result = mkdir(dirname, S_IRWXU | S_IRWXG | S_IRWXO);
            if (result.failed)
            {
                logError("mkdir '", dirname, "' failed, returned ", result.numval);
                return 1;
            }
        }
    }
    return 0;
}
