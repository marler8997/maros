import mar.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.print : formatHex;
import mar.filesys : getcwd;
import mar.file : stdout;

import log;

import mar.start;
mixin(startMixin);

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argc--;
    argv++;
    // TODO: replace this with a function that can handle long path names
    char[1000] path;
    //stdout.write("getcwd(", (cast(void*)path.ptr).formatHex, ", ", path.length, ")\n");
    auto result = getcwd(path.ptr, path.length);
    //stdout.write("returned ", (cast(void*)result.raw).formatHex, "\n");
    if (result.failed)
    {
        logError("getcwd(size=", path.length, ") failed e=", result.numval);
        return 1;
    }
    stdout.write(path.ptr.assumeSentinel, "\n");
    return 0;
}
