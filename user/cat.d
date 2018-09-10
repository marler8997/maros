import mar.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.file : FileD, open, close, write, OpenFlags, OpenAccess, read;
import mar.io : stdout, stdin;
import mar.process : exit;

import log;

import mar.start;
mixin(startMixin);

__gshared ubyte[4096] buffer;

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argc--;
    argv++;

    if (argc == 0)
        cat(stdin);
    else
    {
        foreach (i; 0 .. argc)
        {
            auto pathname = argv[i];
            auto fd = open(pathname, OpenFlags(OpenAccess.readOnly));
            if (!fd.isValid)
            {
                logError("open \"", pathname, "\" returned ", fd.numval);
                return 1;
            }
            cat(fd);
            close(fd);
        }
    }
    return 0;
}

void cat(FileD fd)
{
    for (;;)
    {
        auto readResult = read(fd, buffer);
        if (readResult.numval <= 0)
        {
            if (readResult.numval < 0)
            {
                logError("read failed, returned ", readResult.numval);
                exit(1);
            }
            return;
        }
        auto writeResult = write(stdout, buffer[0 .. readResult.val]);
        if (writeResult.val != readResult.val)
        {
            logError("write(", readResult.val, ") failed, returned ", writeResult.val);
            exit(1);
        }
    }
}
