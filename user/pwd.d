import stdm.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import stdm.c : cstring;
import stdm.filesys : getcwd;
import stdm.file : print, stdout;

import log;

import stdm.start : startMixin;
mixin(startMixin!());

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argc--;
    argv++;
    // TODO: replace this with a function that can handle long path names
    char[1000] path;
    import stdm.format : formatHex;
    //print(stdout, "getcwd(", (cast(void*)path.ptr).formatHex, ", ", path.length, ")\n");
    auto result = getcwd(path.ptr, path.length);
    //print(stdout, "returned ", (cast(void*)result.raw).formatHex, "\n");
    if (result.failed)
    {
        logError("getcwd(size=", path.length, ") failed e=", result.numval);
        return 1;
    }
    print(stdout, path.ptr.assumeSentinel, "\n");
    return 0;
}
