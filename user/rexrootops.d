/**
This tool contains all the operations that the rex program must do as root.

For example, only the root user can create the /var/rex directory, however,
we don't want to have to run the full rex program as root.
*/
import stdm.array : aequals;
import stdm.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import stdm.c : cstring;
import stdm.format : formatHex, sprint;
import stdm.file : open, print, stdout, isDir, ModeFlags, OpenFlags, OpenAccess, OpenCreateFlags;
import stdm.filesys : umask, mkdir, rmdir, umount2, linux_dirent, getdents, LinuxDirentRange;
import stdm.process : exit;

import log;

import stdm.start : startMixin;
mixin(startMixin!());

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argc--;
    argv++;
    if (argc == 0)
    {
        print(stdout, "Usage: rexrootops <operation>\n"
            ~ "Operations:\n"
            ~ "  setup   Setup the rex environment (i.e. create '/var/rex')\n"
            ~ "  clean   Clean up the rex environment (i.e. remove '/var/rex')\n");
        return 1;
    }
    {
        uint originalArgc = argc;
        argc = 0;
        uint i = 0;
        for (; i < originalArgc; i++)
        {
            auto arg = argv[i];
            if (arg[0] != '-')
            {
                argv[argc++] = arg;
                if (argc == 2)
                {
                    i++;
                    break;
                }
            }
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
    }
    if (argc != 1)
    {
        logError("expected 1 argument, but got ", argc);
        return 1;
    }
    auto op = argv[0];

    if (aequals(op, lit!"setup"))
        return setup();
    if (aequals(op, lit!"clean"))
        return clean();

    logError("unknown operation '", op, "'");
    return 1;
}

enum mkdirFlags = ModeFlags.execUser | ModeFlags.readUser  | ModeFlags.writeUser |
                ModeFlags.execGroup | ModeFlags.readGroup  | ModeFlags.writeGroup |
                ModeFlags.execOther | ModeFlags.readOther  | ModeFlags.writeOther;

int setup()
{
    if (isDir(litPtr!"/var/rex"))
    {
        print(stdout, "/var/rex already exists\n");
    }
    else
    {
        print(stdout, "creating /var/rex...\n");
        // remove umask so we can set the directory permission to whatever we want
        umask(0);
        {
            auto result = mkdir(litPtr!"/var/rex", mkdirFlags);
            if (result.failed)
            {
                logError("mkdir(\"/var/rex\") failed, returned ", result.numval);
                return 1; // fail
            }
        }
    }
    return 0; // success
}


// temporary function to cleanup all the rex processes
int clean()
{
    auto rexDirFd = open(litPtr!"/var/rex", OpenFlags(OpenAccess.readOnly, OpenCreateFlags.dir));
    if (!rexDirFd.isValid)
    {
        if (rexDirFd.numval == -2)
        {
            print(stdout, "/var/rex does not exist, nothing to clean\n");
            return 0;
        }
        logError("open(\"/var/rex\") failed, returned ", rexDirFd.numval);
        return 1;
    }
    for (;;)
    {
        ubyte[2048] buffer = void;
        auto entries = cast(linux_dirent*)buffer.ptr;
        auto result = getdents(rexDirFd, entries, buffer.length);
        if (result.numval <= 0)
        {
            if (result.failed)
                logError("getdents failed, it returned ", result.numval);
            break;
        }
        clean(entries, result.val);
    }
    {
        print(stdout, "rmdir(\"/var/rex\")\n");
        auto result = rmdir(litPtr!"/var/rex");
        if (result.failed)
        {
            logError("rmdir(\"/var/rex\") failed, returned ", result.numval);
            return 1;
        }
    }
    return 1;
}
bool isCurrentOrParentDir(cstring name)
{
    return name[0] == '.' &&
        (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'));
}
void clean(linux_dirent* entries, ptrdiff_t size)
{
    foreach (entry; LinuxDirentRange(size, entries))
    {
        if (isCurrentOrParentDir(entry.nameCString))
            continue;

        print(stdout, "cleaning /var/rex/", entry.nameCString, "\n");

        static void doUnmount(cstring pid, const(char)[] dir)
        {
            char[60] nameBuffer;
            auto nameLength = sprint(nameBuffer, "/var/rex/", pid, "/", dir, '\0') - 1;
            auto name = nameBuffer[0 .. nameLength].assumeSentinel;
            if (isDir(name.ptr))
            {
                print(stdout, "unmounting '", name, "'...\n");
                auto umountResult = umount2(name.ptr, 0);
                auto rmdirResult = rmdir(name.ptr);
                if (rmdirResult.failed)
                {
                    if (umountResult.failed)
                        logError("umount2(\"", name, "\") failed, returned ", umountResult.numval);
                    else
                        logError("rmdir(\"", name, "\") failed, returned ", rmdirResult.numval);
                    exit(1);
                }
            }
        }
        doUnmount(entry.nameCString, "dev");
        doUnmount(entry.nameCString, "proc");
        doUnmount(entry.nameCString, "sys");
    }
}