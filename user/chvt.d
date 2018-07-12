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

    if (argc == 0)
    {
        print(stdout, "Usage: chvt <terminal_number>\n");
        return 1;
    }
    if (argc != 1)
    {
        logError("expected 1 argument but got ", argc);
        return 1;
    }

    uint num;
    {
        const numString = argv[0];
        if (numString.tryTo(&num).failed)
        {
            logError("not a valid number \"", numString, "\"");
            return 1;
        }
    }

    auto ttyFd = open(defaultTty.ptr, OpenFlags(OpenAccess.readWrite));
    // don't need to close, process will close it
    if (!ttyFd.isValid)
    {
        logError("failed to open ", defaultTty.array, ", open returned ", ttyFd.numval);
        return 1;
    }
    if (ioctl(ttyFd, VT_ACTIVATE, num).failed)
    {
        logError("VT_ACTIVATE failed");
        return 1;
    }
    if (ioctl(ttyFd, VT_WAITACTIVE, num).failed)
    {
        logError("VT_WAITACTIVE failed");
        return 1;
    }
    return 0;
}
