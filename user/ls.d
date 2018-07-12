import stdm.array : aequals;
import stdm.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import stdm.c : cstring;
import stdm.format : formatHex;
import stdm.filesys : linux_dirent, getdents, LinuxDirentRange;
import stdm.file : FileD, stdout, stderr, print, open, close, OpenFlags, OpenAccess, OpenCreateFlags,
                   stat_t, fstatat, formatMode, AT_SYMLINK_NOFOLLOW, isLink, readlinkat;
import stdm.process : exit;

import log;

import stdm.start : startMixin;
mixin(startMixin!());

__gshared bool long_ = false;

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argc--;
    argv++;
    {
        uint originalArgc = argc;
        argc = 0;
        for (uint i = 0; i < originalArgc; i++)
        {
            auto arg = argv[i];
            if (arg[0] != '-')
                argv[argc++] = arg;
            else if (aequals(arg, lit!"-l"))
                long_ = true;
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
    }

    if (argc == 0)
        ls(litPtr!"", litPtr!".");
    else
    {
        foreach (i; 0 .. argc)
        {
            auto pathname = argv[i];
            print(stdout, pathname, ":\n");
            ls(litPtr!"  ", argv[i]);
        }
    }
    return 0;
}

void ls(cstring prefix, cstring pathname)
{
    auto fd = open(pathname, OpenFlags(OpenAccess.readOnly, OpenCreateFlags.dir));
    if (!fd.isValid)
    {
        logError("open \"", pathname , "\" failed ", fd);
        exit(1);
    }
    scope(exit) close(fd);
    //logInfo("open returned ", fd);

    for (;;)
    {
        ubyte[2048] buffer = void;
        auto entries = cast(linux_dirent*)buffer.ptr;
        auto result = getdents(fd, entries, buffer.length);
        if (result.numval <= 0)
        {
            if (result.failed)
                logError("getdents failed, it returned ", result.numval);
            break;
        }
        printDirEntries(prefix, fd, entries, result.val);
    }
}

bool isCurrentOrParentDir(cstring name)
{
    return name[0] == '.' &&
        (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'));
}

void printDirEntries(cstring prefix, FileD dirFd, linux_dirent* entries, ptrdiff_t size)
{
    import stdm.file : print;

    foreach (entry; LinuxDirentRange(size, entries))
    {
        if (isCurrentOrParentDir(entry.nameCString))
            continue;

        if (!long_)
        {
            print(stdout, prefix, entry.nameCString, "\n");
            continue;
        }

        stat_t fileStatus = void;
        {
            auto result = fstatat(dirFd, entry.nameCString, &fileStatus, AT_SYMLINK_NOFOLLOW);
            if (result.failed)
            {
                logError("stat \"", entry.nameCString, "\" failed, returned ",
                    result.numval);
                continue;
            }
        }
        print(stdout, prefix,
            fileStatus.st_mode.formatMode, " ",
            entry.nameCString);
        if (fileStatus.st_mode.isLink)
        {
            print(stdout, " -> ");
            // TODO: do not use a static size for this
            char[100] buffer;
            auto result = readlinkat(dirFd, entry.nameCString, buffer);
            if (result.failed)
            {
                print(stdout, "? (error: readlinkat failed, returned ",
                    result.numval, " )");
            }
            else
            {
                print(stdout, buffer[0 .. result.val]);
            }
        }
        print(stdout, "\n");
    }
}
