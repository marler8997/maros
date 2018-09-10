import mar.flag;
import mar.array : aequals;
import mar.sentinel : SentinelPtr, assumeSentinel, lit;
import mar.c : cstring;
import mar.process : exit;
import mar.linux.file : open, close, OpenFlags, OpenAccess, OpenCreateFlags;
import mar.io : stdout;
import mar.linux.filesys : mount, linux_dirent, getdents, LinuxDirentRange;
import mar.cmdopt;

import log;

import mar.start;
mixin(startMixin);

void usage()
{
    stdout.write("Usage: mount [-options] source target\n");
    stdout.write("Options:\n");
    stdout.write("  -t     file system type\n");
    stdout.write("  --allow-non-empty-target\n");
}
extern (C) int main(uint argc, SentinelPtr!(SentinelPtr!char) argv, SentinelPtr!(SentinelPtr!char) envp)
{
    SentinelPtr!char fstypes;
    bool allowNonEmptyTarget = false;

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
            else if (aequals(arg, lit!"-t"))
                fstypes = getOptArg(argv, &i);
            else if (aequals(arg, lit!"--allow-non-empty-target"))
                allowNonEmptyTarget = true;
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
    }

    if (argc != 2)
    {
        logError("expected 2 non-option command line arguments but got ", argc);
        return 1;
    }
    auto source = argv[0];
    auto target = argv[1];

    if (!allowNonEmptyTarget)
    {
        enforceEmptyTarget(target);
    }

    if (fstypes.isNull)
    {
        logError("no -t is not implemented");
        return 1;
    }

    foreach (type; FsTypeIteratorDestructive(fstypes))
    {
        //stdout.write("fstype \"", type, "\"\n");
        auto result = tryMount(source, target, type);
        if (result == Yes.passed)
        {
            //stdout.write("[DEBUG] mount was success!\n");
            return 0;
        }
    }
    // error message should already be printed
    return 1;
}

Flag!"passed" tryMount(cstring source, cstring target, cstring type)
{
    auto result = mount(source, target, type, 0, null);
    if (result.passed)
        return Yes.passed;
    logError("failed to mount as type \"", type, "\", mount returned ", result.numval);
    return No.passed;
}

void enforceEmptyTarget(cstring target)
{
    logInfo("checking if target dir is empty");
    auto fd = open(target, OpenFlags(OpenAccess.readOnly, OpenCreateFlags.dir));
    if (fd.isValid)
    {
        scope(exit) close(fd);
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
            foreach (entry; LinuxDirentRange(result.val, entries))
            {
                if (!aequals(entry.nameCString, ".") &&
                    !aequals(entry.nameCString, ".."))
                {
                    logError("target dir is not empty");
                    exit(1);
                }
            }
        }
    }
}

struct FsTypeIteratorDestructive
{
    SentinelPtr!char next;
    SentinelPtr!char _front;
    this(SentinelPtr!char next)
    {
        this.next = next;
        popFront();
    }
    bool empty() const { return _front is SentinelPtr!char.nullValue; }
    auto front() { return _front; }
    void popFront()
    {
        if (next[0] == '\0')
        {
            _front = SentinelPtr!char.nullValue;
        }
        else
        {
            _front = next;
            for (;;)
            {
                if (next[0] == ',')
                {
                    next.raw[0] = '\0';
                    next = (next.raw + 1).assumeSentinel; //next++;
                    return;
                }
                next = (next.raw + 1).assumeSentinel; //next++;
                if (next[0] == '\0')
                {
                    return;
                }
            }
        }
    }
}