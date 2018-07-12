/**
rex will execute a program in a restricted context

Special directories
--------------------------------------------------------------------------------
/var/rex/<pid>  : the root mount for process <pid>
/rex            : if this directory exists, then you are currently running
                : in a rex container.
/rex/prog       : this is the program that the rex container started with

*/
import stdm.array : aequals;
import stdm.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import stdm.c : cstring;
import stdm.format : sprint, formatHex;
import stdm.file : print, stdout, open, close, read, isDir,
    OpenFlags, OpenAccess, OpenCreateFlags, ModeFlags;
import stdm.filesys : mkdir, rmdir, chdir, link, chroot, mount, umount2, MS_BIND;
import stdm.linux.syscall : sys_getuid, sys_setuid;
import stdm.linux.process : pid_t, exit, execve, unshare, getpid, fork, waitid, idtype_t, WEXITED;
import stdm.linux.signals : siginfo_t;
import stdm.linux.capability;

import log;
import findprog : getCommandProgram;

import stdm.start : startMixin;
mixin(startMixin!());

__gshared cstring argv0;
__gshared SentinelPtr!cstring globalEnvp;

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argv0 = argv[0];
    globalEnvp = envp;
    argc--;
    argv++;
    if (argc == 0)
    {
        print(stdout, "Usage: rex [-options] <config> <program> <args>\n");
        return 1;
    }
    bool fork = false;
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
            else if (aequals(arg, lit!"--fork"))
                fork = true;
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
        print(stdout, "i=", i, "\n");
        for (; i < originalArgc; i++)
        {
            argv[argc++] = argv[i];
        }
    }

    if (argc < 2)
    {
        logError("not enough non-option arguments");
        return 1; // fail
    }
    auto configFile = argv[0];
    auto command = argv[1];

    //
    // Find the program to handle this command
    //
    char[200] programFileBuffer; // todo: shouldn't use a statically sized buffer here
    cstring programFile = getCommandProgram(command, programFileBuffer);
    if (programFile.isNull)
    {
        logError("cannot find program \"", command, "\"");
        return 1; // fail
    }
    /*
    auto args = argv[2 .. argc];
    print(stdout, "config file '", configFile, "'\n");
    print(stdout, "program     '", program, "'\n");
    print(stdout, args.length, " args:\n");
    foreach (i; 0 .. args.length)
    {
        print(stdout, i, ": '", args[i], "'\n");
    }
    */

    // todo: load config file


    //
    // request CAP_SYS_ADMIN so we can unshare(CLONE_NEWNS)
    //
    {
        __user_cap_header_struct header;
        __user_cap_data_struct data;
        header.version_ = _LINUX_CAPABILITY_VERSION_3;
        header.pid = 0;
        auto result = capget(&header, &data);
        if (result.failed)
        {
            logError("capget failed, returned ", result.numval);
            exit(1);
        }
        print(stdout, "CAPABILITIES:\n");
        print(stdout, " effective 0x", data.effective.formatHex, "\n");
        print(stdout, " permitted 0x", data.permitted.formatHex, "\n");
        print(stdout, " inheritable 0x", data.inheritable.formatHex, "\n");
        if ((CAP_TO_MASK(CAP_SYS_ADMIN) & data.effective) == 0)
        {
            logError("missing the CAP_SYS_ADMIN capability, have you run 'setcap cap_sys_admin+ep rex`?");
            exit(1);
        }
        if ((CAP_TO_MASK(CAP_SYS_CHROOT) & data.effective) == 0)
        {
            logError("missing the CAP_SYS_CHROOT capability, have you run 'setcap cap_sys_chroot+ep rex`?");
            exit(1);
        }
    }

    // put the process in it's own namespace
    {
        import stdm.linux.process;
        auto result = unshare(0
            //| CLONE_FILES
            | CLONE_FS
            | CLONE_NEWNS
            );
        if (result.failed)
        {
            logError("unshare failed, returned ", result.numval);
            return 1;
        }
    }

    //
    // setup rootfs
    //
    setupRootfs(programFile);

    debugPrintMounts();

    argv[1] = litPtr!"/rex/prog";
    auto childArgv = (&argv[1]).assumeSentinel;
    {
        auto result = execve(childArgv[0], childArgv, envp);
        logError("execve failed, returned ", result.numval);
        return 1;
    }
}

enum mkdirFlags = ModeFlags.execUser | ModeFlags.readUser  | ModeFlags.writeUser |
                  ModeFlags.execGroup | ModeFlags.readGroup  | ModeFlags.writeGroup |
                  ModeFlags.execOther | ModeFlags.readOther  | ModeFlags.writeOther;

void doMkdir(cstring path)
{
    if (!isDir(path))
    {
        auto result = mkdir(path, mkdirFlags);
        if (!isDir(path))
        {
            logError("mkdir(\"", path, "\") failed, returned ", result.numval);
            exit(1);
        }
    }
}
void doMkdir(size_t bufferSize, T...)(T args)
{
    char[bufferSize] buffer;
    auto length = sprint(buffer, args, '\0') - 1;
    doMkdir(buffer.ptr.assumeSentinel);
}

void mkPidPath(cstring pidPath)
{
    if (isDir(pidPath)) {
        logError("pid path '", pidPath, "' already exists, this case is not handled yet");
        exit(1);
    }
    {
        auto result = mkdir(pidPath, mkdirFlags);
        if (!isDir(pidPath))
        {
            logError("mkdir(\"", pidPath, "\") failed, returned ", result.numval);
            exit(1);
        }
    }
}

auto link(size_t bufferSize, T...)(cstring oldName, T newNameArgs)
{
    char[bufferSize] buffer;
    auto length = sprint(buffer, newNameArgs, '\0') - 1;
    print(stdout, "[DEBUG] link '", buffer.ptr.assumeSentinel, "' -> '", oldName, "'\n");
    return link(oldName, buffer.ptr.assumeSentinel);
}

void runRexRootOpsSetup()
{
    auto pidResult = fork();
    if (pidResult.failed)
    {
        logError("fork failed, returned ", pidResult.numval);
        exit(1);
    }
    if (pidResult.val == 0)
    {
        char[100] progBuffer;
        auto progLength = sprint(progBuffer, argv0, "rootops", '\0') - 1;
        auto prog = progBuffer[0 .. progLength].assumeSentinel;

        cstring[3] args;
        args[0] = prog.ptr;
        args[1] = litPtr!"setup";
        args[2] = cstring.nullValue;

        auto result = execve(args[0], args.assumeSentinel.ptr, globalEnvp);
        logError("execve returned ", result.numval);
        exit(1);
    }

    siginfo_t info;
    auto result = waitid(idtype_t.pid, pidResult.val, &info, WEXITED, null);
    if (result.failed)
    {
        logError("waitid failed, returned ", result.numval);
        exit(1);
    }
    if (info.si_status != 0)
    {
        logError("rexrootops failed, exited with ", info.si_status);
        exit(1);
    }
}

void setupRootfs(cstring programFile)
{
    if (!isDir(litPtr!"/var/rex"))
    {
        // need to run 'rexrootops setup'.
        // this needs to be done by the root user which
        // is why it's in another executable
        runRexRootOpsSetup();
        if (!isDir(litPtr!"/var"))
        {
            logError("failed to create /var/rex, the directory where rex creates temporary filesystems");
            exit(1);
        }
    }

    auto pid = getpid();
    if (pid.failed)
    {
        logError("getpid failed, returned ", pid.numval);
        exit(1);
    }
    print(stdout, "[DEBUG] pid is ", pid.val, "\n");
    char[50] pidPathBuffer;
    auto pidPathLength = sprint(pidPathBuffer, "/var/rex/", pid.val, '\0') - 1;
    auto pidPath = pidPathBuffer[0 .. pidPathLength].assumeSentinel;
    print(stdout, "[DEBUG] pidPath is '", pidPath, "'\n");
    mkPidPath(pidPath.ptr);
    doMkdir!60("/var/rex/", pid.val, "/rex");
    {
        auto result = link!70(programFile, "/var/rex/", pid.val, "/rex/prog");
        if (result.failed)
        {
            logError("link to '", programFile, "' failed, returned ", result.numval);
            exit(1);
        }
    }

    // setup /proc, /sys and /dev
    static void do_mount(T)(T pidPath, cstring mountDir)
    {
        char[60] targetBuffer = void;
        auto targetLength = sprint(targetBuffer, pidPath, mountDir, '\0') - 1;
        auto target = targetBuffer[0 .. targetLength].assumeSentinel;
        {
            auto result = mkdir(target.ptr, mkdirFlags);
            if (result.failed)
            {
                logError("mkdir(\"", target, "\") failed, returned ", result.numval);
                exit(1);
            }
        }
        auto result = mount(mountDir, target.ptr, cstring.nullValue, MS_BIND, null);
        if (result.failed)
        {
            logError("bind mount '", mountDir, "' to '", target, "' failed, returned ", result.numval);
            exit(1);
        }
    }
    do_mount(pidPath, litPtr!"/proc");
    do_mount(pidPath, litPtr!"/sys");
    do_mount(pidPath, litPtr!"/dev");

    {
        auto result = chdir(pidPath.ptr);
        if (result.failed)
        {
            logError("chdir(\"", pidPath, "\") failed, returned ", result.numval);
            exit(1);
        }
    }
    {
        auto result = chroot(litPtr!".");
        if (result.failed)
        {
            logError("chroot(\"", pidPath, "\") failed, returned ", result.numval);
            exit(1);
        }
    }

}

void debugPrintMounts()
{
    auto mounts = open(litPtr!"/proc/mounts", OpenFlags(OpenAccess.readOnly));
    if (!mounts.isValid)
    {
        logError("open /proc/mounts failed ", mounts);
        exit(1);
    }
    scope(exit) close(mounts);
    //logInfo("open returned ", mounts);

    char[4096] buffer; // TODO: use malloc
    size_t totalRead = 0;
    for (;;) {
        auto result = read(mounts, buffer[totalRead .. $]);
        if (result.failed) {
            logError("read /proc/mounts failed, returned ", result.numval);
            exit(1);
        }
        if (result.val == 0) {
            break;
        }
        totalRead += result.val;
        if (totalRead == buffer.length) {
            logError("mounts output was too large, not implemented");
            exit(1);
        }
    }

    print(stdout, "got ", totalRead, " bytes from /proc/mounts\n");
    print(stdout, "--------------------------------------------------------------------------------\n");
    print(stdout, buffer[0 .. totalRead]);
    print(stdout, "--------------------------------------------------------------------------------\n");
    /*
    col| description
    ------------------------------------------------------------
     1 | the 'device' that is mounted
     2 | the 'mount point'
     3 | the 'file-system' type
     4 | options (i.e. "ro" (read-only), "rw" (read-write))
     5 | "0": dummy value designed to match format used in /etc/mtab
     6 | "0": dummy value designed to match format used in /etc/mtab
    */
    // TODO: unmount everything, or mount a new root
}
