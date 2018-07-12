module stdm.process;

import stdm.sentinel : SentinelPtr;
import stdm.c : cstring;

void exit(int exitCode)
{
    version (linux)
    {
        import stdm.linux.process : exit;
        exit(exitCode);
    }
    else version (Windows)
    {
        assert(0, "exit not implemented on windows");
    }
    else static assert(0, "unsupported platform");
}
