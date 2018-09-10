module util;

void dumpProgramInput(T,U)(T argv, U envp)
{
    import mar.io : stderr, stdout;

/*
    {
        // TODO: replace call to getcwd (see filesys.d getcwd2)
        char[100] buffer;
        auto result = getcwd(buffer.ptr, buffer.length);
        if (result.isNull)
        {
            stderr.write("Error: getcwd failed\n");
            exit(1);
        }
        stdout.write("result is 0x", (cast(void*)result).formatHex, "\n");
        pragma(msg, typeof(result));
        stdout.write("cwd \"", result, "\"\n");
    }
    */
    if (argv)
    {
        for(size_t i = 0; ;i++)
        {
            auto arg = argv[i];
            if (!arg) break;
            stdout.write("arg", i, " \"", arg, "\"\n");
        }
    }
    if (envp)
    {
        for(size_t i = 0; ;i++)
        {
            auto env = envp[i];
            if (!env) break;
            stdout.write("env \"", env, "\"\n");
        }
    }
}

