module util;

void dumpProgramInput(T,U)(T argv, U envp)
{
    import stdm.file : print, stderr, stdout;

/*
    {
        // TODO: replace call to getcwd (see filesys.d getcwd2)
        char[100] buffer;
        auto result = getcwd(buffer.ptr, buffer.length);
        if (result.isNull)
        {
            print(stderr, "Error: getcwd failed\n");
            exit(1);
        }
        print(stdout, "result is 0x", (cast(void*)result).formatHex, "\n");
        pragma(msg, typeof(result));
        print(stdout, "cwd \"", result, "\"\n");
    }
    */
    if (argv)
    {
        for(size_t i = 0; ;i++)
        {
            auto arg = argv[i];
            if (!arg) break;
            print(stdout, "arg", i, " \"", arg, "\"\n");
        }
    }
    if (envp)
    {
        for(size_t i = 0; ;i++)
        {
            auto env = envp[i];
            if (!env) break;
            print(stdout, "env \"", env, "\"\n");
        }
    }
}

