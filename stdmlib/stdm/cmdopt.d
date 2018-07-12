module maros.cmdopt;

import stdm.c : cstring;

/**
Get the value of a command line option argument and increments
the counter.
On errors, prints a message to stderr and exits.
*/
auto getOptArg(T)(T args, uint* i)
{
    import stdm.file : print, stderr;
    import stdm.process : exit;

    (*i)++;
    auto arg = args[*i];
    if (arg == arg.nullValue)
    {
        print(stderr, "Error: option \"", args[(*i)-1], "\" requires an argument\n");
        exit(1);        
    }
    return arg;
}