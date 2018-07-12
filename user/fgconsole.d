import stdm.conv : tryTo;
import stdm.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import stdm.c : cstring;
import stdm.filesys : getcwd;
import stdm.file : print, stdout, open, close, OpenFlags, OpenAccess, OpenCreateFlags;
import stdm.linux.ioctl;
import stdm.linux.vt;

import log;
import tty;

import stdm.start : startMixin;
mixin(startMixin!());

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argc--;
    argv++;
    if (argc != 0)
    {
        logError("expected 0 arguments but got ", argc);
        return 1;
    }

    auto ttyFd = open(defaultTty.ptr, OpenFlags(OpenAccess.readWrite));
    // don't need to close, process will close it
    if (!ttyFd.isValid)
    {
        logError("failed to open ", defaultTty.array, ", open returned ", ttyFd.numval);
        return 1;
    }
    vt_stat state;
    {
        auto result = ioctl(ttyFd, VT_GETSTATE, &state);
        if (result.failed)
        {
            logError("VT_GETSTATE failed, returned ", result.numval);
            return 1;
        }
    }
    print(stdout, state.v_active, "\n");
    return 0;
}
