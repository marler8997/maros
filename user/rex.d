/**
rex will execute a program in a restricted context

Special directories
--------------------------------------------------------------------------------
/var/rex/<pid>  : the root mount for process <pid>
/rex            : if this directory exists, then you are currently running
                : in a rex container.
/rex/prog       : this is the program that the rex container started with

*/
import mar.flag;
import mar.array : acopy, aequals, endsWith;
import mar.sentinel : SentinelPtr, SentinelArray, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.print : sprint, sprintMallocSentinel, formatHex;
import mar.file : open, close, read, isDir, fileExists, lseek,
    OpenFlags, OpenAccess, OpenCreateFlags, ModeFlags, SeekFrom;
import mar.io : stdout;
import mar.filesys : mkdir, rmdir, chdir, link, chroot, mount, umount2, MS_BIND;
import mar.mem : malloc, free;
import mar.env : getenv;
import mar.findprog;
import mar.linux.syscall : sys_getuid, sys_setuid;
import mar.linux.mmap : MemoryMap, mmap, munmap, PROT_READ, PROT_WRITE, MAP_PRIVATE;
import mar.linux.process : pid_t, exit, execve, unshare, getpid, fork, waitid, idtype_t, WEXITED;
import mar.linux.signals : siginfo_t;
import mar.linux.capability;

import log;

import mar.start;
mixin(startMixin);

__gshared cstring argv0;
__gshared SentinelPtr!cstring globalEnvp;

enum OpTag
{
    mkdir,
    link,
}
struct Op
{
    OpTag tag;
    union
    {
        cstring str;
    }
    private this(OpTag tag, cstring str) { this.tag = tag; this.str = str; }
    static Op mkdir(cstring dir) { return Op(OpTag.mkdir, dir); }
    static Op link(cstring dir) { return Op(OpTag.link, dir); }
}
struct Settings
{
    cstring program;
    bool noDefaultMounts;
    Builder!Op ops;
}

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argv0 = argv[0];
    globalEnvp = envp;
    argc--;
    argv++;
    if (argc == 0)
    {
        stdout.write("Usage: rex [-options] <program|rex-config> <args>...\n");
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
                i++;
                break;
            }
            else if (aequals(arg, lit!"--fork"))
                fork = true;
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
        for (; i < originalArgc; i++)
        {
           argv[argc++] = argv[i];
        }
    }

    if (argc < 1)
    {
        logError("not enough non-option arguments");
        return 1; // fail
    }

    Settings settings;
    {
        auto mainFile = argv[0];
        // TODO: there may be other ways to check that it is a rex file
        if (mainFile.walkToArray.endsWith(".rex"))
        {
            auto parser = ConfigParser(mainFile, &settings);
            parser.load();
            if (settings.program.isNull)
            {
                logError("config is missing the 'program' directive");
                return 1;
            }
        }
        else
        {
            if (!usePath(mainFile))
                settings.program = mainFile;
            else
            {
                settings.program = findProgram(getenv(envp, "PATH"), mainFile.walkToArray.array);
                if (settings.program.isNull)
                {
                    logError("cannot find program \"", mainFile, "\"");
                    return 1; // fail
                }
            }
        }
    }

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
        stdout.write("CAPABILITIES:\n");
        stdout.write(" effective 0x", data.effective.formatHex, "\n");
        stdout.write(" permitted 0x", data.permitted.formatHex, "\n");
        stdout.write(" inheritable 0x", data.inheritable.formatHex, "\n");
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
        import mar.linux.process;
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
    setupRootfs(&settings);

    //debugPrintMounts();

    argv[0] = litPtr!"/rex/prog";
    auto childArgv = (&argv[0]).assumeSentinel;
    {
        auto result = execve(childArgv[0], childArgv, envp);
        logError("execve failed, returned ", result.numval);
        return 1;
    }
}

struct Builder(T)
{
   T* ptr;
   size_t length;
   T[] data() const { return (cast(T*)ptr)[0 .. length]; }
   void put(T item)
   {
       auto newPtr = cast(T*)malloc(T.sizeof * length + 1);
       if (length > 0)
       {
           acopy(newPtr, ptr, length * T.sizeof);
       }
       newPtr[length] = item;
       free(ptr);
       ptr = newPtr;
       length++;
   }
}

struct ConfigParser
{
    cstring filename;
    Settings* settings;
    uint lineNumber;
    void load()
    {
        auto fd = open(filename, OpenFlags(OpenAccess.readOnly));
        if (!fd.isValid)
        {
            logError("open(\"", filename, "\") failed, returned ", fd.numval);
            exit(1);
        }

        auto fileSize = lseek(fd, 0, SeekFrom.end);
        if (fileSize.failed)
        {
            logError("lseek(\"", filename, "\") failed, returned ", fileSize.numval);
            exit(1);
        }

        auto map = MemoryMap(mmap(null, fileSize.val, PROT_READ | PROT_WRITE,
            MAP_PRIVATE, fd, 0), fileSize.val);
        if (map.failed)
        {
            logError("mmap(\"", filename, "\") failed, returned ", map.numval);
            exit(1);
        }
        close(fd); // we can close the file now

        size_t lineStart = 0;
        size_t next = 0;
        lineNumber = 1;
        for (;;)
        {
            if (next == fileSize.val)
            {
                parseConfigLine(map.array!char[lineStart .. next]);
                break;
            }
            auto c = map.array!char[next++];
            if (c == '\n')
            {
                parseConfigLine(map.array!char[lineStart .. next - 1]);
                lineStart = next;
                lineNumber++;
            }
        }
    }
    void parseConfigLine(const(char)[] line)
    {
        stdout.write("got line '", line, "'\n");
        parseConfigLine(line.ptr, line.ptr + line.length);
    }
    void parseConfigLine(const(char)* next, const(char)* limit)
    {
        next = skipWhitespace(next, limit);
        if (next >= limit)
            return; // blank line
        if (next[0] == '#')
        {
            stdout.write("  got comment\n");
            return;
        }
        if (tryConsume(&next, limit, "program "))
        {
            //auto value = copyToSentinelString(next, limit);
            auto value = next[0 .. limit-next];
            //stdout.write("  [DEBUG] program value is '", value, "'\n");
            settings.program = getFileRelativeTo(filename.walkToArray.array, value).ptr;
            //stdout.write("  got program '", program, "'\n");
        }
        else if (tryConsume(&next, limit, "noDefaultMounts"))
        {
            settings.noDefaultMounts = true;
        }
        else if (tryConsume(&next, limit, "link "))
        {
            auto link = copyToSentinelString(next, limit);
            stdout.write("  got link '", link, "'\n");
            settings.ops.put(Op.link(link.ptr));
        }
        else if (tryConsume(&next, limit, "mkdir "))
        {
            auto dir = copyToSentinelString(next, limit);
            stdout.write("  got mkdir '", dir, "'\n");
            settings.ops.put(Op.mkdir(dir.ptr));
        }
        else
        {
            logError(filename, "(", lineNumber, ") unknown directive '", next[0 .. limit-next], "'");
            exit(1);
        }
    }
}

SentinelArray!char getFileRelativeTo(Flag!"useDotSlashForCwd" useDotSlashForCwd = No.useDotSlashForCwd)
    (const(char)[] relativeFile, const(char)[] file)
{
    //stdout.write("[DEBUG] relativeFile '", relativeFile, "', file '", file, "'\n");
    if (file.length >= 1 && file[0] == '/')
        return file.copyToSentinelString;
    for (size_t i = relativeFile.length; ;)
    {
        if (i == 0)
        {
            static if (useDotSlashForCwd)
                return sprintMallocSentinel("./", file);
            else
                return file.copyToSentinelString;
        }
        i--;
        if (relativeFile[i] == '/')
            return sprintMallocSentinel(relativeFile[0 .. i + 1], file);
    }
}

SentinelArray!char copyToSentinelString(const(char)* ptr, const(char)* limit)
{
    return copyToSentinelString(ptr[0 .. limit - ptr]);
}
SentinelArray!char copyToSentinelString(const(char)[] str)
{
    auto buf = cast(char*)malloc(str.length + 1);
    if (!buf)
    {
        logError("malloc failed");
        exit(1);
    }
    acopy(buf, str.ptr, str.length);
    buf[str.length] = '\0';
    return buf[0 .. str.length].assumeSentinel;
}

bool tryConsume(const(char)** str, const(char)* limit, const(char)[] thing)
{
    if ((limit - *str) >= thing.length && aequals(*str, thing))
    {
        *str = *str + thing.length;
        return true;
    }
    return false;
}
inout(char)* skipWhitespace(inout(char)* str, const(char)* limit)
{
    for (; str < limit; str++)
    {
        char c = str[0];
        if (c != ' ' && c != '\t' && c != '\r')
            break;
    }
    return str;
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
    stdout.write("[DEBUG] link '", buffer.ptr.assumeSentinel, "' -> '", oldName, "'\n");
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

void setupRootfs(Settings* settings)
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
    stdout.write("[DEBUG] pid is ", pid.val, "\n");
    char[50] pidPathBuffer;
    auto pidPathLength = sprint(pidPathBuffer, "/var/rex/", pid.val, '\0') - 1;
    auto pidPath = pidPathBuffer[0 .. pidPathLength].assumeSentinel;
    stdout.write("[DEBUG] pidPath is '", pidPath, "'\n");
    mkPidPath(pidPath.ptr);
    doMkdir!60("/var/rex/", pid.val, "/rex");
    {
        auto result = link!70(settings.program, "/var/rex/", pid.val, "/rex/prog");
        if (result.failed)
        {
            logError("link to '", settings.program, "' failed, returned ", result.numval);
            exit(1);
        }
    }

    static void doDir(T)(T pidPath, cstring dir, Flag!"alsoMount" alsoMount)
    {
        char[60] targetBuffer = void;
        auto targetLength = sprint(targetBuffer, pidPath, dir, '\0') - 1;
        auto target = targetBuffer[0 .. targetLength].assumeSentinel;
        {
            auto result = mkdir(target.ptr, mkdirFlags);
            if (result.failed)
            {
                logError("mkdir(\"", target, "\") failed, returned ", result.numval);
                exit(1);
            }
        }
        if (alsoMount)
        {
            auto result = mount(dir, target.ptr, cstring.nullValue, MS_BIND, null);
            if (result.failed)
            {
                logError("bind mount '", dir, "' to '", target, "' failed, returned ", result.numval);
                exit(1);
            }
        }
    }
    if (!settings.noDefaultMounts)
    {
        doDir(pidPath, litPtr!"/proc", Yes.alsoMount);
        doDir(pidPath, litPtr!"/sys", Yes.alsoMount);
    }

    foreach (op; settings.ops.data)
    {
        final switch (op.tag)
        {
        case OpTag.mkdir:
            stdout.write("[DEBUG] making dir '", op.str, "'\n");
            doDir(pidPath, op.str, No.alsoMount);
            break;
        case OpTag.link:
            stdout.write("[DEBUG] making link '", op.str, "'\n");
            doDir(pidPath, op.str, Yes.alsoMount);
            break;
        }
    }

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

    stdout.write("got ", totalRead, " bytes from /proc/mounts\n");
    stdout.write("--------------------------------------------------------------------------------\n");
    stdout.write(buffer[0 .. totalRead]);
    stdout.write("--------------------------------------------------------------------------------\n");
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
