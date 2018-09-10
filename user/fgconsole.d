import mar.conv : tryTo;
import mar.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.filesys : getcwd;
import mar.file : open, close, OpenFlags, OpenAccess, OpenCreateFlags;
import mar.io : stdout;
import mar.linux.ioctl;
import mar.linux.vt;

import log;
import tty;

import mar.start;
mixin(startMixin);

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
    stdout.write(state.v_active, "\n");
    return 0;
}
