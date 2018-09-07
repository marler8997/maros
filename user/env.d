import mar.array : aequals;
import mar.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.file : stdout;
import mar.process : exit;

import log;

import mar.start;
mixin(startMixin);

void usage()
{
    stdout.writeln("Usage: env [NAME=VALUE] [COMMAND]");
    stdout.writeln("Set each NAME to VALUE in the environment and run COMMAND or print environment\n");
    stdout.writeln("Options:");
    stdout.writeln("  -i, --ignore-environment  Start with empty environment");
    stdout.writeln("  -u, --unset=NAME          Remove variable from environment");
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
            else if (aequals(arg, lit!"-i") || aequals(arg, lit!"--ignore-environment"))
            {
                logError("-i not impl");
                exit(1);
            }
            else if (aequals(arg, lit!"-u") || aequals(arg, lit!"--unset"))
            {
                logError("-u not impl");
                exit(1);
            }
            else if (aequals(arg, lit!"-h") || aequals(arg, lit!"--help"))
            {
                usage();
                return 1;
            }
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
    }

    if (argc > 0)
    {
        logError("run command not impl");
        exit(1);
    }

    for (size_t i = 0; ; i++)
    {
        auto env = envp[i];
        if (env.isNull)
            break;
        stdout.writeln(env);
    }

    return 0;
}
