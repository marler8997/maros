import stdm.array : aequals;
import stdm.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import stdm.format : sprint, formatHex;
import stdm.ctypes : mode_t;
import stdm.c : cstring;
// todo: don't import file, instead use logFunctions
import stdm.linux.file;
import stdm.linux.filesys;
import stdm.linux.process : exit, pid_t, vfork, fork, setsid, execve,
    waitid, idtype_t, WEXITED;
import stdm.linux.signals : siginfo_t;
import stdm.linux.syscall : SyscallValueResult;
import stdm.linux.ioctl : ioctl;
import stdm.linux.vt : VT_OPENQRY, VT_ACTIVATE, VT_WAITACTIVE;

import log;
import util : dumpProgramInput;
import tty;

import stdm.start : startMixin;
mixin(startMixin!());

__gshared SentinelPtr!cstring savedEnvp;

// TODO: use logging functions logError/logInfo
// TODO: wrap low level functions by logging calls to them using logInfo

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    print(stdout, "init process started with ", argc, " arguments:\n");
    savedEnvp = envp;
    dumpProgramInput(argv, envp);

    //
    // TODO: check that the filesystem does not have any more than
    //       we expect
    //
    print(stdout, "checking filesystem...(not implemented)\n");

    //
    // TODO: mount filesystems like /proc and /sys
    //
    static immutable mountProg = litPtr!"/sbin/mount";
    enforceDir(litPtr!"/proc",
        ModeFlags.readUser  | ModeFlags.execUser  |
        ModeFlags.readGroup | ModeFlags.execGroup |
        ModeFlags.readOther | ModeFlags.execOther );
    enforceDir(litPtr!"/sys",
        ModeFlags.readUser  | ModeFlags.execUser  |
        ModeFlags.readGroup | ModeFlags.execGroup |
        ModeFlags.readOther | ModeFlags.execOther );

    // TODO: check if /proc and /sys are already mounted?
    {
        // Note: have to assign the array literal to a static variable
        //       otherwise it will require GC which does not work with betterC
        static immutable mountProcArgs = [
            mountProg,
            litPtr!"-t", litPtr!"proc",
            litPtr!"proc",
            litPtr!"/proc",
            SentinelPtr!(immutable(char)).nullValue].assumeSentinel;
        auto pid = run(mountProg, mountProcArgs.ptr.withConstPtr,
            SentinelPtr!cstring.nullValue);
        waitEnforceSuccess(pid);
    }
    {
        // Note: have to assign the array literal to a static variable
        //       otherwise it will require GC which does not work with betterC
        static immutable mountSysArgs = [
            mountProg,
            litPtr!"-t", litPtr!"sysfs",
            litPtr!"sysfs",
            litPtr!"/sys",
            SentinelPtr!(immutable(char)).nullValue].assumeSentinel;
        auto pid = run(mountProg, mountSysArgs.ptr.withConstPtr,
            SentinelPtr!cstring.nullValue);
        waitEnforceSuccess(pid);
    }

    //
    // TODO: read the kernel command line from /proc/cmdline
    //       and change behavior based on that
    //
    // TODO: also, read configuration from somewhere on the
    //       disk.  Maybe /etc/init.txt?
    //

    // start the shell
    for (size_t count = 1; ;count++)
    {
        SyscallValueResult!pid_t shellPid;
        {
            auto ttyControlFd = open(defaultTty.ptr, OpenFlags(OpenAccess.readWrite));
            if (!ttyControlFd.isValid)
            {
                logError("failed to open ", defaultTty.array, ", open returned ", ttyControlFd.numval);
                return 1;
            }
            char[20] vtFileBuffer;
            auto vtNum = findOpenVt(ttyControlFd);
            auto vtFileLength = sprint(vtFileBuffer, "/dev/tty", vtNum, '\0');
            auto vtFile = vtFileBuffer[0 .. vtFileLength - 1].assumeSentinel;

            // Note: have to assign the array literal to a static variable
            //       otherwise it will require GC which does not work with betterC
            static immutable shellProg = litPtr!"/sbin/shell";
            static immutable shellArgs = [
            shellProg,
            SentinelPtr!(immutable(char)).nullValue].assumeSentinel;

            shellPid = fork();
            if (shellPid.val == 0)
            {
                close(ttyControlFd);
                auto sessionID = setsid();
                if (sessionID.failed)
                {
                    logError("setsid failed, returned ", sessionID.numval);
                    exit(1);
                }
                //close(stderr);
                //close(stdout);
                //close(stdin);
                // open the new tty
                auto ttyFd = open(vtFile.ptr, OpenFlags(OpenAccess.readWrite));
                if (!ttyFd.isValid)
                {
                    logError("open \"", vtFile.array, "\" failed, returned ", ttyFd.numval);
                    exit(1);
                }
                enforceDup2(ttyFd, stdin);
                enforceDup2(ttyFd, stdout);
                enforceDup2(ttyFd, stderr);
                auto result = execve(shellProg, shellArgs.ptr.withConstPtr, savedEnvp);
                logError("execve returned ", result.numval);
                exit(1);
            }

            if (shellPid.failed)
            {
                logError("fork failed, returned ", shellPid.numval);
                exit(1);
            }
            print(stdout, "started shell, pid=", shellPid.val, "\n");
            chvt(ttyControlFd, vtNum);
            close(ttyControlFd);
        }
        auto result = wait(shellPid.val);
        if (count >= 10)
        {
            logError("the shell has exited (code ", result, ") ", count, " times, giving up");
            exit(1);
        }
        logError("shell exited with code ", result,
            " starting it again (count=", count, ")");
    }

    return 1;
}

void enforceDup2(FileD oldfd, FileD newfd)
{
    auto result = dup2(oldfd, newfd);
    if (result != newfd)
    {
        logError("dup failed, returned ", result.numval);
        exit(1);
    }
}

// switch the display to the new tty
void chvt(FileD ttyControlFd, uint vtNum)
{
    if (ioctl(ttyControlFd, VT_ACTIVATE, vtNum).failed)
    {
        logError("VT_ACTIVATE failed");
        exit(1);
    }
    if (ioctl(ttyControlFd, VT_WAITACTIVE, vtNum).failed)
    {
        logError("VT_WAITACTIVE failed");
        exit(1);
    }
}

uint findOpenVt(FileD ttyControlFd)
{
    uint vtNum;
    {
        auto result = ioctl(ttyControlFd, VT_OPENQRY, &vtNum);
        if (result.failed)
        {
            logError("VT_OPENQRY failed, returned ", result.numval);
            exit(1);
        }
    }
    print(stdout, "vt ", vtNum, " is open\n");
    return vtNum;
}


/**
Makes sure the the directory exists with the given `mode`.  Creates
it if it does not exist.
*/
void enforceDir(cstring pathname, mode_t mode)
{
    // get the current state of the pathname
    auto currentMode = tryGetFileMode(pathname);
    if (currentMode.failed)
    {
        print(stdout, "mkdir \"", pathname, "\" mode=0x", mode.formatHex, "\n");
        auto result = mkdir(pathname, mode);
        if (result.failed)
        {
            logError("mkdir failed, returned ", result.numval);
            exit(1);
        }
    }
    else
    {
    /*
        currently not really working as I expect...need to look into this
        if (currentMode.val != mode)
        {
            logError("expected path \"", pathname, "\" mode to be 0x",
                mode.formatHex, " but it is 0x", currentMode.numval.formatHex);
            exit(1);
        }
        */
    }
}

//!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// TODO: maybe move these functions to a common module
//!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
pid_t run(cstring filename, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    print(stdout, "running \"", filename, "\" with the following input:\n");
    dumpProgramInput(argv, envp);
    //auto pid = vfork();
    auto pidResult = fork();
    if (pidResult.failed)
    {
        logError("fork failed, returned ", pidResult.numval);
        exit(1);
    }
    if (pidResult.val == 0)
    {
        auto result = execve(filename, argv, envp);
        logError("execve returned ", result.numval);
        exit(1);
    }
    return pidResult.val;
}

auto wait(pid_t pid)
{
    siginfo_t info;
    //print(stdout, "[DEBUG] waiting for ", pid, "...\n");
    auto result = waitid(idtype_t.pid, pid, &info, WEXITED, null);
    if (result.failed)
    {
        logError("waitid failed, returned ", result.numval);
        //exit(result);
        exit(1);
    }
    //print(stdout, "child process status is 0x", status.formatHex, "\n");
    return info.si_status;
}

void waitEnforceSuccess(pid_t pid)
{
    auto result = wait(pid);
    if (result != 0)
    {
        logError("last program failed (exit code is ", result, " )");
        exit(1);
    }
}
