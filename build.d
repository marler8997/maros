#!/usr/bin/env rund
//!importPath mar/src
//!debug
//!debugSymbols
//!version NoExit

import core.stdc.errno;
import core.stdc.stdlib : exit, alloca;
import core.stdc.string : memcpy, memset;

import std.array : join;
import std.string : lineSplitter, strip, stripLeft, startsWith, endsWith, indexOf;
import std.conv : to, ConvException;
import std.format : format, formattedWrite;
import std.algorithm : skipOver, canFind, map;
import std.datetime : SysTime;
import std.path : isAbsolute, absolutePath, buildNormalizedPath;
import std.file : exists, readText, rmdir, timeLastModified;
import std.process : executeShell, environment;

import mar.flag;
import mar.enforce;
import mar.endian;
import mar.array : acopy;
import mar.sentinel : SentinelArray, makeSentinel, verifySentinel, lit;
import mar.print : formatHex, sprintMallocSentinel;
import mar.c;
import mar.ctypes : off_t, mode_t;
import mar.conv : tryParseEnum;
import mar.typecons : Nullable;
import mar.file : getFileSize, tryGetFileMode, fileExists, open, close,
    OpenFlags, OpenAccess, OpenCreateFlags,
    S_IXOTH,
    S_IWOTH,
    S_IROTH,
    S_IRWXO,
    S_IXGRP,
    S_IWGRP,
    S_IRGRP,
    S_IRWXG,
    S_IXUSR,
    S_IWUSR,
    S_IRUSR,
    S_IRWXU;
import mar.filesys : mkdir;
static import mar.path;
import mar.findprog : findProgram, usePath;
import mar.process : ProcBuilder;
import mar.cmdopt;
import mbr = mar.disk.mbr;
// TODO: replace this linux-specific import
//import mar.linux.file : open, close;
import mar.linux.capability : CAP_TO_MASK, CAP_SYS_ADMIN, CAP_SYS_CHROOT;

import common;
import compile;
import elf;

void log(T...)(T args)
{
    import mar.io;
    stdout.writeln("[BUILD] ", args);
}
void logError(T...)(T args)
{
    import mar.io;
    stdout.writeln("Error: ", args);
}

enum DefaultDirMode = S_IRWXU | S_IRWXG | S_IROTH;

//
// TODO: prefix all information from this tool with [BUILD] so
//       it is easy to distinguish between output from this tool
//       and output from other tools.
//       do this by not importing std.stdio globally
//

struct CommandList
{
    Command[] commands;
    string desc;
}
immutable commandLists = [
    immutable CommandList(buildCommands,
        "Build Commands"),
    immutable CommandList(diskSetupCommands,
        "Disk Setup Commands (in the same order as they would be invoked)"),
    immutable CommandList(utilityCommands,
        "Some Generic Utility Commands"),
];

string marosRelativeShortPath(string path)
{
    return shortPath(path, mar.path.dirName(__FILE_FULL_PATH__));
}

/**
Makes sure the the directory exists with the given `mode`.  Creates
it if it does not exist.
*/
void logMkdir(string pathname, mode_t mode = DefaultDirMode)
{
    mixin tempCString!("pathnameCStr", "pathname");

    // get the current state of the pathnameCStr
    auto currentMode = tryGetFileMode(pathnameCStr.str);
    if (currentMode.failed)
    {
        log("mkdir \"", pathnameCStr.str, "\" mode=0x", mode.formatHex);
        auto result = mkdir(pathnameCStr.str, mode);
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
        if (currentMode.value != mode)
        {
            stderr.write("Error: expected path \"", pathnameCStr, "\" mode to be 0x",
                mode.formatHex, " but it is 0x", currentMode.value.formatHex, "\n");
            exit(1);
        }
        */
    }
}
void logCopy(From, To)(From from, To to, Flag!"asRoot" asRoot)
{
    import std.file : copy;
    exec(format("%scp %s %s", asRoot ? "sudo " : "", from.formatFile, to.formatFile));
}

void usage()
{
    import std.stdio : writeln, writefln;
    writeln ("build.d [-C <dir>] <command>");
    foreach (ref commandList; commandLists)
    {
        writeln();
        writeln(commandList.desc);
        foreach (ref cmd; commandList.commands)
        {
            writefln(" %-20s %s", cmd.name, cmd.description);
        }
    }
}

int main(string[] args)
{
    try
    {
        return tryMain(args);
    }
    catch(EnforceException) { return 1; }
}
int tryMain(string[] args)
{
    args = args[1 .. $];
    string configOption;
    {
        auto newArgsLength = 0;
        scope (exit) args = args[0 .. newArgsLength];
        for (uint i = 0; i < args.length; i++)
        {
            auto arg = args[i];
            if (arg[0] != '-')
                args[newArgsLength++] = arg;
            // TODO: implement -C
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
    }
    if (args.length == 0)
    {
        usage();
        return 1;
    }

    import std.stdio;

    const commandToInvoke = args[0];
    args = args[1 .. $];
    foreach (ref commandList; commandLists)
    {
        for (size_t cmdIndex; cmdIndex < commandList.commands.length; cmdIndex++)
        {
            auto cmd = &commandList.commands[cmdIndex];
            if (commandToInvoke == cmd.name)
            {
                const result = cmd.func(args);
                if (result == 0)
                {
                    writeln("--------------------------------------------------------------------------------");
                    cmdIndex++;
                    if (!cmd.inSequence || cmdIndex >= commandList.commands.length)
                    {
                        writeln("Success");
                        return 0;
                    }
                    cmd = &commandList.commands[cmdIndex];
                    if (!cmd.inSequence)
                    {
                        writeln("Success");
                        return 0;
                    }
                    writeln("Success, next step(s) are:");
                    for (;;)
                    {
                        writefln("    '%s'%s", cmd.name, cmd.isOptional ? " (optional)" : "");
                        cmdIndex++;
                        if (cmdIndex >= commandList.commands.length)
                            break;
                        cmd = &commandList.commands[cmdIndex];
                        if (!cmd.inSequence)
                            break;
                    }
                }
                return result;
            }
        }
    }

    logError("unknown command '", commandToInvoke, "'");
    return 1;
}

enum MemoryUnit : ubyte
{
    byte_, kiloByte, megaByte, gigaByte,
}
struct MemoryUnitInfo
{
    ubyte byteShift;
    string qemuPostfix;
    string fdiskPostfix;
}
immutable MemoryUnitInfo[] memoryUnitInfos = [
    MemoryUnit.byte_    : immutable MemoryUnitInfo( 0, "B", "B"),
    MemoryUnit.kiloByte : immutable MemoryUnitInfo(10, "K", "K"),
    MemoryUnit.megaByte : immutable MemoryUnitInfo(20, "M", "M"),
    MemoryUnit.gigaByte : immutable MemoryUnitInfo(30, "G", "G"),
];
auto info(MemoryUnit unit) { return &memoryUnitInfos[unit]; }


struct MemorySize
{
    uint value;
    MemoryUnit unit;
    bool nonZero() const { return value != 0; }
    ulong byteValue() const
    {
        return (cast(ulong)value) << unit.info.byteShift;
    }
    auto formatQemu() const
    {
        static struct Formatter
        {
            const(MemorySize) memorySize;
            void toString(scope void delegate(const(char)[]) sink)
            {
                formattedWrite(sink, "%s%s", memorySize.value,
                    memorySize.unit.info.qemuPostfix);
            }
        }
        return Formatter(this);
    }
    auto formatFdisk() const
    {
        static struct Formatter
        {
            const(MemorySize) memorySize;
            void toString(scope void delegate(const(char)[]) sink)
            {
                formattedWrite(sink, "%s%s", memorySize.value,
                    memorySize.unit.info.qemuPostfix);
            }
        }
        return Formatter(this);
    }
}

struct KernelPaths
{
    string image;
}
struct Mounts
{
    string rootfs;
    string rootfsAbsolute;
}

struct LoopPartFiles
{
    string rootfs;
    string swap;
}

// crystal is meant to reside in the first 16 sectors
// of the disk
enum CrystalReserveSectorCount = 16;
enum CrystalReserveSize = CrystalReserveSectorCount * 512;
struct CrystalBootloaderFiles
{
    string dir;
    string source;
    string list;
    string binary;
}
struct Config
{
    string kernelPath;
    string kernelRepo;
    string kernelCommandLine;

    string imageFile;
    MemorySize sectorSize;
    MemorySize imageSize;
    MemorySize crystalBootloaderKernelReserve;
    string rootfsType;
    MemorySize rootfsSize;
    MemorySize swapSize;

    string compiler;

    ulong getMinSectorsToHold(MemorySize memorySize) const
    {
        const byteSize = memorySize.byteValue;
        const sectorByteSize = this.sectorSize.byteValue;
        ulong sectorsNeeded = byteSize / sectorByteSize;
        if (byteSize % sectorByteSize > 0)
            sectorsNeeded++;
        return sectorsNeeded;
    }
    KernelPaths getKernelPaths() const
    {
        return KernelPaths(
            // todo: this should be configurable
            kernelPath ~ "/arch/x86_64/boot/bzImage");
    }
    CrystalBootloaderFiles getCrystalBootloaderFiles() const
    {
        const dir = "crystal";
        return CrystalBootloaderFiles(
            dir,
            dir.appendPath("crystal.asm"),
            dir.appendPath("crystal.list"),
            dir.appendPath("crystal.bin"));
    }
    auto mapImage(size_t offset, size_t length, Flag!"writeable" writeable) const
    {
        mixin tempCString!("imageFileTempCStr", "imageFile");
        return MappedFile.openAndMap(imageFileTempCStr.str, offset, length, writeable);
    }

    Mounts getMounts() const
    {
        auto rootfs = imageFile ~ ".rootfs";
        return Mounts(rootfs, rootfs.absolutePath);
    }
    LoopPartFiles getLoopPartFiles(string loopFile) const
    {
        return LoopPartFiles(
            loopFile ~ "p1",
            loopFile ~ "p2");
    }
}

struct ConfigParser
{
    string filename;
    string text;
    uint lineNumber;
    this(string filename)
    {
        this.filename = filename;
        if (!exists(filename))
        {
            logError("config file '", filename, "' does not exist");
            exit(1);
        }
        this.text = cast(string)readText(filename);
        this.lineNumber = 1;
    }
    void configError(T...)(string fmt, T args)
    {
        logError(filename, "(", lineNumber, ") ", format(fmt, args));
        exit(1);
    }
    Config parse()
    {
        auto config = Config();
        //Nullable!Bootloader bootloader;

        foreach (line; text.lineSplitter)
        {
            line = line.strip();
            if (line.length == 0 || line[0] == '#')
            { }
            /*
            else if (line.skipOver("bootloader "))
            {
                line = line.stripLeft;
                bootloader = tryParseEnum!Bootloader(line);
                if (bootloader.isNull)
                    configError("invalid bootloader value '%s'", line);
            }
            */
            else if (line.skipOver("kernelPath "))
                config.kernelPath = line.stripLeft;
            else if (line.skipOver("kernelRepo "))
                config.kernelRepo = line.stripLeft;
            else if (line.skipOver("kernelCommandLine "))
                config.kernelCommandLine = line.stripLeft;
            else if (line.skipOver("imageFile "))
                config.imageFile = line.stripLeft;
            else if (line.skipOver("sectorSize "))
                config.sectorSize = parseMemorySize(line.stripLeft);
            else if (line.skipOver("imageSize "))
                config.imageSize = parseMemorySize(line.stripLeft);
            else if (line.skipOver("crystalBootloaderKernelReserve "))
                config.crystalBootloaderKernelReserve = parseMemorySize(line.stripLeft);
            else if (line.skipOver("rootfsPartition "))
            {
                config.rootfsType = tryNext(&line);
                if (!config.rootfsType)
                    configError("rootfsPartition requires a type (i.e. ext4) and a size (i.e. 20G)");
                config.rootfsSize = parseMemorySize(line.stripLeft);
            }
            else if (line.skipOver("swapPartition "))
                config.swapSize = parseMemorySize(line.stripLeft);
            else if (line.skipOver("compiler "))
                config.compiler = line.stripLeft;
            else
            {
                logError("unknown config '", line, "'");
                exit(1);
            }
            lineNumber++;
        }

        /*
        enforce(!bootloader.isNull, "config file is missing the 'bootloader' setting");
        config.bootloader = bootloader.unsafeGetValue;
        final switch (config.bootloader)
        {
        case Bootloader.crystal:
            enforce(config.crystalBootloaderKernelReserve.nonZero,
                "config file is missing the 'crystalBootloaderKernelReserve' setting");
        }
        */
        enforce(config.kernelPath !is null, "config file is missing the 'kernelPath' setting");
        enforce(config.imageFile !is null, "config file is missing the 'imageFile' setting");
        enforce(config.imageSize.nonZero, "config file is missing the 'imageSize' setting");
        enforce(config.rootfsType !is null, "config file is missing the 'rootfsPartition' setting");
        enforce(config.swapSize.nonZero , "config file is missing the 'swapPartition' setting");
        return config;
    }
    string tryNext(string* inOutLine)
    {
        auto line = *inOutLine;
        scope(exit) *inOutLine = line;

        line = line.stripLeft;
        if (line.length == 0)
            return null; // nothing next
        auto spaceIndex = line.indexOf(' ');
        if (spaceIndex < 0)
        {
            auto result = line;
            line = line[$ .. $];
            return result;
        }
        auto result = line[0 .. spaceIndex];
        line = line[spaceIndex .. $];
        return result;
    }
    MemorySize parseMemorySize(string size)
    {
        size_t valueLength = 0;
        for (;; valueLength++)
        {
            if (valueLength >= size.length)
                configError("invalid memory size '%s', missing unit (i.e. G, M)", size);
            if (!size[valueLength].isDigit)
                break;
        }
        if (valueLength == 0)
            configError("invalid memory size '%s'", size);

        MemoryUnit unit;
        string unitString = size[valueLength .. $];
        if (unitString == "G")
            unit = MemoryUnit.gigaByte;
        else if (unitString == "M")
            unit = MemoryUnit.megaByte;
        else if (unitString == "B")
            unit = MemoryUnit.byte_;
        else
            configError("invalid memory size '%s', unknown unit '%s'", size, unitString);

        try
        {
            return MemorySize(size[0 .. valueLength].to!uint, unit);
        }
        catch (ConvException e)
        {
            configError("invalid memory size '%s'", size);
            assert(0);
        }
    }
}

auto appendPath(T, U)(T dir, U path)
{
    if (dir.length == 0)
        return path;
    if (path.length == 0)
        return dir;
    assert(dir[$-1] != '/', "no paths should end in '/'");
    assert(path[0]  != '/', "cannot append an absolute path to a relative one");
    return dir ~ "/" ~ path;
}

size_t asSizeT(ulong value, lazy string errorPrefix, lazy string errorPostfix)
{
    if (value > size_t.max)
    {
        import std.stdio;
        writeln("Error: ", errorPrefix, value, errorPostfix);
        exit(1);
    }
    return cast(size_t)value;
}

bool isDigit(char c) { return c <= '9' && c >= '0'; }
Config parseConfig()
{
    auto parser = ConfigParser("maros.config");
    auto config = parser.parse();
    return config;
}

bool prompt(string msg)
{
    import std.stdio;
    for (;;)
    {
        write(msg, " (y/n) ");
        stdout.flush();
        auto response = stdin.readln().strip();
        if (response == "y")
            return true; // yes
        if (response == "n")
            return false; // no
    }
}

pragma(inline) uint asUint(ulong value)
in { assert(value <= uint.max, "value too large"); } do
{
    return cast(uint)value;
}


string tryGetImageLoopFile(ref const Config config)
{
    log("checking if image '", config.imageFile, "' is looped");
    const command = format("sudo losetup -j %s", config.imageFile.formatFile);
    auto output = exec(command);
    if (output.length == 0)
        return null;

    auto colonIndex = output.indexOf(":");
    enforce(colonIndex >= 0, format("output of '%s' (see above) did not have a colon ':' to delimit end of loop filename", command));
    return output[0 .. colonIndex];
}
string loopImage(ref const Config config)
{
    auto loopFile = tryGetImageLoopFile(config);
    if (loopFile)
    {
        log("image file '", config.imageFile, "' is already looped to '", loopFile, "'");
    }
    else
    {
        log("image file '", config.imageFile, "' is not looped, looping it now");
        exec(format("sudo losetup -f -P %s", config.imageFile.formatFile));
        loopFile = tryGetImageLoopFile(config);
        enforce(loopFile !is null, "attempted to loop the image but could not find the loop file");
        log("looped image '", config.imageFile, "' to '", loopFile, "'");
    }
    log("Loop Partitions:");
    run(format("ls -l %sp*", loopFile));
    return loopFile;
}
void unloopImage(string loopFile)
{
    log("unlooping image...");
    exec(format("sudo losetup -d %s", loopFile.formatFile));
}

struct Rootfs
{
    static ulong getPartitionOffset(ref const Config config)
    {
        return CrystalReserveSectorCount + config.getMinSectorsToHold(
            config.crystalBootloaderKernelReserve); // kernel reserve
    }
    static struct IsMountedResult
    {
        bool isMounted;
        string notMountedReason;
    }
    static IsMountedResult rootfsIsMounted(ref const Config config, ref const Mounts mounts)
    {
        log("checking if rootfs is mounted to '", mounts.rootfs, "'");
        if (!exists(mounts.rootfs))
        {
            return IsMountedResult(false, format("mount dir '%s' does not exist", mounts.rootfs));
        }
        auto output = exec("sudo mount -l", mounts.rootfsAbsolute);
        if (output.length == 0)
        {
            return IsMountedResult(false, format("mount dir '%s' is not in `mount -l` output", mounts.rootfs));
        }
        return IsMountedResult(true);
    }
    static void mount(ref const Config config, ref const Mounts mounts)
    {
        {
            const result = rootfsIsMounted(config, mounts);
            if (result.isMounted)
            {
                log("rootfs is already mounted to '", mounts.rootfs, "'");
                return;
            }
        }
        log("rootfs is not mounted");

        if (!exists(mounts.rootfs))
            logMkdir(mounts.rootfs);

        exec(format("sudo mount -t %s -o loop,rw,offset=%s %s %s",
            config.rootfsType, Rootfs.getPartitionOffset(config) * 512,
            config.imageFile.formatFile, mounts.rootfs.formatDir));
        exec(format("sudo chown `whoami` %s", mounts.rootfs.formatDir));
        /*
        import mar.filesys : mount;
        mixin tempCString!("imageFileCStr", "config.imageFile");
        mixin tempCString!("targetCStr", "mounts.rootfs");
        mixin tempCString!("typeCStr", "config.rootfsType");
        auto options = format("loop,rw,offset=%s", Rootfs.getPartitionOffset(config) * 512);
        mixin tempCString!("optionsCStr", "options");
        log("mount -t ", typeCStr.str, " -o ", optionsCStr.str, " ", imageFileCStr.str, " ", targetCStr.str);
        auto result = mount(imageFileCStr.str, targetCStr.str, typeCStr.str, 0, optionsCStr.str.raw);
        if (result != 0)
        {
            logError("mount failed, returned ", result);
            exit(1);
        }
        */
    }
    static void unmount(ref const Config config, ref const Mounts mounts)
    {
        {
            const result = rootfsIsMounted(config, mounts);
            if (!result.isMounted)
            {
                log("rootfs is not mounted '", mounts.rootfs, "'");
                return;
            }
        }
        log("rootfs is mounted...unmounting");
        exec(format("sudo umount %s", mounts.rootfs));
        exec(format("sudo rmdir %s", mounts.rootfs));
    }
}

struct CommandLineTool
{
    string name;
    bool setRootSuid;
    string[] versions;
    uint caps;
    this(string name, Flag!"setRootSuid" setRootSuid = No.setRootSuid, string[] versions = null, uint caps = 0)
    {
        this.name = name;
        this.setRootSuid = setRootSuid;
        this.versions = versions;
        this.caps = caps;
    }
}
immutable commandLineTools = [
    CommandLineTool("init"),
    CommandLineTool("msh"),
    CommandLineTool("env"),
    CommandLineTool("mount"),
    CommandLineTool("umount"),
    CommandLineTool("pwd"),
    CommandLineTool("ls"),
    CommandLineTool("mkdir"),
    CommandLineTool("chvt"),
    CommandLineTool("fgconsole"),
    CommandLineTool("cat"),
    CommandLineTool("openvt"),
    CommandLineTool("insmod"),
    CommandLineTool("masterm"),
    CommandLineTool("medit", No.setRootSuid, ["NoExit"]),
    CommandLineTool("rex", No.setRootSuid, null, CAP_TO_MASK(CAP_SYS_ADMIN) | CAP_TO_MASK(CAP_SYS_CHROOT)),
    CommandLineTool("rexrootops", Yes.setRootSuid),
];


enum CommandFlags
{
    none       = 0x00,
    inSequence = 0x01,
    optional   = 0x02,
}
enum cmdNoFlags = CommandFlags.none;
enum cmdInSequence = CommandFlags.inSequence;
enum cmdInSequenceOptional = CommandFlags.inSequence | CommandFlags.optional;

struct Command
{
    string name;
    string description;
    CommandFlags flags;
    int function(string[] args) func;
    bool inSequence() const
    {
        return (flags & CommandFlags.inSequence) != 0;
    }
    bool isOptional() const
    {
        return (flags & CommandFlags.optional) != 0;
    }
}


// =============================================================================
// Build Commands
// =============================================================================
immutable buildCommands = [

Command("installTools", "install tools to build", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "installTools requires 0 arguments");
    run("sudo apt-get install git fakeroot build-essential" ~
    " ncurses-dev xz-utils libssl-dev bc libelf-dev flex bison gcc" ~
    " make nasm");
    return 0;
}),

Command("cloneKernel", "clone the linux kernel", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "cloneKernel requires 0 arguments");
    const config = parseConfig();

    if (!config.kernelRepo)
    {
        logError("cannot 'cloneRepo' because no 'kernelRepo' is configured");
        return 1;
    }

    if (exists(config.kernelPath))
    {
        log("kernel '", config.kernelPath, "' already exists");
    }
    else
    {
        // TODO: move this to config.txt
        run(format("git clone %s %s",
            config.kernelRepo.formatQuotedIfSpaces,
            config.kernelPath.formatQuotedIfSpaces));
    }
    return 0;
}),

Command("cloneBootloader", "clone the bootloader", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "clonerBootloader requires 0 arguments");
    const config = parseConfig();

    auto repo = "crystal";
    if (exists("crystal"))
    {
        log("crystal repo '", repo, "' already exists");
    }
    else
    {
        run(format("git clone %s %s", "https://github.com/marler8997/crystal", repo));
    }
    return 0;
}),

Command("buildBootloader", "build the bootloader", cmdInSequence, function(string[] args)
{
    enforce(args.length == 0, "buildBootloader requires 0 arguments");
    const config = parseConfig();

    const files = config.getCrystalBootloaderFiles();
    run(format("nasm -o %s -l %s -Dcmd_line=\"%s\" %s",
        files.binary.formatFile, files.list.formatFile,
        config.kernelCommandLine, files.source.formatFile));

    return 0;
}),

Command("buildUser", "build userspace of the os", cmdInSequence, function(string[] args)
{
    bool force;
    foreach (arg; args)
    {
        if (arg == "force")
            force = true;
        else
        {
            logError("unknown argument '", arg, "'");
            return 1; // error
        }
    }
    const config = parseConfig();

    enum Mode
    {
        debug_,
        release,
    }
    //auto mode = Mode.debug_;
    auto mode = Mode.release;

    string compiler = config.compiler ~ CompilerArgs()
        .version_("NoStdc")
        .conf("")
        .betterC
        //.inline
        .toString;

    final switch (mode)
    {
    case Mode.debug_ : compiler ~= " -debug -g"; break;
    case Mode.release: compiler ~= " -release -O -inline"; break;
    }

    const userSourcePath   = marosRelativeShortPath("user");
    const rootfsPath = "rootfs";
    const sbinPath   = rootfsPath ~ "/sbin";
    const objPath  = "obj";
    logMkdir(rootfsPath);
    logMkdir(sbinPath);
    logMkdir(objPath);

    const druntimePath = marosRelativeShortPath("mar/druntime");
    const marlibPath = marosRelativeShortPath("mar/src");

    const includePaths = [
        druntimePath,
        marlibPath,
        userSourcePath,
    ];

    foreach (ref tool; commandLineTools)
    {
        const src = userSourcePath ~ "/" ~ tool.name ~ ".d";
        const toolObjPath  = "obj/" ~ tool.name;
        logMkdir(toolObjPath);

        const binaryFilename = (sbinPath ~ "/" ~ tool.name).makeSentinel;
        const buildJsonFilename = (toolObjPath ~ "/info.json").makeSentinel;

        bool needsBuild = true;
        if (!force && fileExists(buildJsonFilename.ptr))
        {
            auto buildFiles = tryGetBuildFiles(buildJsonFilename, src, includePaths, toolObjPath);
            if (buildFiles)
            {
                auto binaryTime = binaryFilename.array.timeLastModified(SysTime.min);
                if (binaryTime > SysTime.min)
                {
                    needsBuild = false;
                    foreach (buildFile; buildFiles)
                    {
                        if (buildFile.src.timeLastModified > binaryTime)
                        {
                            needsBuild = true;
                            break;
                        }
                    }
                }
            }
        }

        if (needsBuild)
        {
            auto compilerArgs = CompilerArgs();
            if (tool.versions)
            {
                foreach (version_; tool.versions)
                {
                    compilerArgs.version_(version_);
                }
            }
            run(compiler ~ compilerArgs
                .includeImports("object") // include the 'object' module
                .includeImports(".")      // include by default
                .noLink
                .outputDir(toolObjPath)
                .preserveOutputPaths
                .jsonFile(buildJsonFilename.array)
                .jsonIncludes("semantics")
                .includePaths(includePaths)
                .source(src)
                .toString);
            auto buildFiles = tryGetBuildFiles(buildJsonFilename, src, includePaths, toolObjPath);

            bool forceGoldLinker = false;
            string linker = "ld";
            if (forceGoldLinker)
            {
                linker = "/usr/bin/gold --strip-lto-sections";
            }

            run(linker ~ " --gc-sections -static --output " ~ binaryFilename.array ~ " " ~ buildFiles.map!(s => s.obj).join(" "));

            if (tool.setRootSuid)
            {
                run("sudo chown root:root " ~ binaryFilename.array);
                run("sudo chmod +s " ~ binaryFilename.array);
            }
            if (tool.caps)
            {
                string prefix = "";
                string capString = "";

                uint caps = tool.caps;
                if (caps & CAP_TO_MASK(CAP_SYS_ADMIN)) {
                    caps &= ~CAP_TO_MASK(CAP_SYS_ADMIN);
                    capString ~= prefix ~ "cap_sys_admin";
                    prefix = ",";
                }
                if (caps & CAP_TO_MASK(CAP_SYS_CHROOT)) {
                    caps &= ~CAP_TO_MASK(CAP_SYS_CHROOT);
                    capString ~= prefix ~ "cap_sys_chroot";
                    prefix = ",";
                }
                if (caps) {
                    logError("tool caps contain unhandled flags 0x", caps.formatHex);
                    return 1; // fail
                }
                run("sudo setcap " ~ capString ~ "+ep " ~ binaryFilename.array);
            }
        }
        else
        {
            log(binaryFilename.array, " is up-to-date");
        }
    }
    return 0;
}),

]; // end of buildCommands

// =============================================================================
// Disk Setup Commands
// =============================================================================
immutable diskSetupCommands = [

Command("allocImage", "allocate a file for the disk image", cmdInSequence, function(string[] args)
{
    enforce(args.length == 0, "allocImage requies 0 arguments");
    const config = parseConfig();
    if (exists(config.imageFile))
    {
        if (!prompt(format("would you like to overrwrite the existing image '%s'?", config.imageFile)))
            return 1;
    }

    /*
    mixin tempCString!("imageFileCStr", "config.imageFile");
    auto fd = open(imageFileCStr.str, OpenFlags(OpenAccess.writeOnly, OpenCreateFlags.creat));
    auto result = fallocate(fd,...
    close(fd);
    */

    run(format("truncate -s %s %s", config.imageSize.byteValue, config.imageFile.formatFile));
    return 0;
}),

Command("zeroImage", "initialize the disk image to zero", cmdInSequenceOptional, function(string[] args)
{
    enforce(args.length == 0, "allocImage requies 0 arguments");
    const config = parseConfig();

    const imageFileSize = getFileSize(config.imageFile).asSizeT("file size ", " is too large to map");
    enforce(imageFileSize == config.imageSize.byteValue,
        format("image file size '%s' != configured image size '%s'",
            imageFileSize, config.imageSize.byteValue));

    log("zeroing image of ", imageFileSize, " bytes...");
    auto mappedImage = config.mapImage(0, imageFileSize, Yes.writeable);
    memset(mappedImage.ptr, 0, imageFileSize);
    mappedImage.unmapAndClose();
    return 0;
}),

Command("partition", "partition the disk image", cmdInSequence, function(string[] args)
{
    enforce(args.length == 0, "partition requires 0 arguments");
    const config = parseConfig();
    enforce(exists(config.imageFile),
        format("image file '%s' does not exist, have you run 'allocImage'?", config.imageFile));


    ulong part1SectorOffset = Rootfs.getPartitionOffset(config);
    ulong part1SectorCount  = config.getMinSectorsToHold(config.rootfsSize);
    ulong part2SectorOffset = part1SectorOffset + part1SectorCount;
    ulong part2SectorCount  = config.getMinSectorsToHold(config.swapSize);

    auto mappedImage = config.mapImage(0, 512, Yes.writeable);
    auto mbrPtr = cast(mbr.OnDiskFormat*)mappedImage.ptr;

    //
    // rootfs partition
    //
    mbrPtr.partitions[0].status = mbr.PartitionStatus.bootable;
    mbrPtr.partitions[0].firstSectorChs.setDefault();
    mbrPtr.partitions[0].type = mbr.PartitionType.linux;
    mbrPtr.partitions[0].lastSectorChs.setDefault();
    mbrPtr.partitions[0].firstSectorLba = part1SectorOffset.asUint.toLittleEndian;
    mbrPtr.partitions[0].sectorCount    = part1SectorCount.asUint.toLittleEndian;
    //
    // swap partition
    //
    mbrPtr.partitions[1].status = mbr.PartitionStatus.none;
    mbrPtr.partitions[1].firstSectorChs.setDefault();
    mbrPtr.partitions[1].type = mbr.PartitionType.linuxSwapOrSunContainer;
    mbrPtr.partitions[1].lastSectorChs.setDefault();
    mbrPtr.partitions[1].firstSectorLba = part2SectorOffset.asUint.toLittleEndian;
    mbrPtr.partitions[1].sectorCount    = part2SectorCount.asUint.toLittleEndian;

    mbrPtr.setBootSignature();

    mappedImage.unmapAndClose();

/+
    run(format("sudo parted %s mklabel msdos", config.imageFile.formatFile));

    auto p1Kb = 1024;
    auto p2Kb = p1Kb + config.rootfsSize.kbValue;
    auto p3Kb = p2Kb + config.swapSize.kbValue;

    run(format("sudo parted %s mkpart primary %s %sKiB %sKiB",
        config.imageFile.formatFile, config.rootfsType, p1Kb, p2Kb));
    run(format("sudo parted %s mkpart primary linux-swap %sKiB %sKiB",
        config.imageFile.formatFile, p2Kb, p3Kb));
    run(format("sudo parted %s set 1 boot on", config.imageFile.formatFile));
    run(format("sudo parted %s print", config.imageFile.formatFile));
+/
    return 0;
}),

Command("makefs", "make the filesystems", cmdInSequence, function(string[] args)
{
    enforce(args.length == 0, "makefs requires 0 arguments");
    const config = parseConfig();

    {
        auto loopFile = loopImage(config);
        scope(exit) unloopImage(loopFile);
        //const loopFile = getImageLoopFile(config);
        const loopPartFiles = config.getLoopPartFiles(loopFile);
        run(format("sudo mkfs -t ext4 %s", loopPartFiles.rootfs.formatFile));
        run(format("sudo mkswap %s", loopPartFiles.swap.formatFile));
    }
    return 0;
}),

Command("installBootloader", "install the bootloader", cmdInSequence, function(string[] args)
{
    enforce(args.length == 0, "install requires 0 arguments");
    const config = parseConfig();

    const files = config.getCrystalBootloaderFiles();
    enforce(exists(files.binary), format(
        "bootloader binary '%s' does not exist, have you run 'buildBootloader'?",
        files.binary));
    mixin tempCString!("binaryTempCStr", "files.binary");
    const bootloaderSize = getFileSize(binaryTempCStr.str).asSizeT("bootloader image size ", " is too big to map");
    log("bootloader file is ", bootloaderSize, " bytes");
    enforce(bootloaderSize <= CrystalReserveSize,
        format("bootloader is too large (%s bytes, max is %s bytes)", bootloaderSize, CrystalReserveSize));
    auto mappedImage = config.mapImage(0, CrystalReserveSize, Yes.writeable);
    {
        auto bootloaderImage = MappedFile.openAndMap(binaryTempCStr.str, 0, mbr.BootstrapSize, No.writeable);
        log("copying bootsector code (", mbr.BootstrapSize, " bytes)...");
        memcpy(mappedImage.ptr, bootloaderImage.ptr, mbr.BootstrapSize);
        if (bootloaderSize > 512)
        {
            const copySize = bootloaderSize - 512;
            log("copying ", copySize, " more bytes after the boot sector...");
            acopy(mappedImage.ptr + 512, bootloaderImage.ptr + 512, copySize);
            //memcpy(mappedImage.ptr + 512, bootloaderImage.ptr + 512, copySize);
        }
        else
        {
            log("all code is within the boot sector");
        }
        bootloaderImage.unmapAndClose();
    }
    {
        const zeroSize = CrystalReserveSize - bootloaderSize;
        log("zeroing the rest of the crystal reserved sectors (", zeroSize, " bytes)...");
        memset(mappedImage.ptr + bootloaderSize, 0, zeroSize);
    }
    mappedImage.unmapAndClose();

    log("Succesfully installed the crystal bootloader");
    return 0;
}),

Command("installKernel", "install the kernel to the rootfs", cmdInSequence, function(string[] args)
{
    enforce(args.length == 0, "installKernel requires 0 arguments");
    const config = parseConfig();

    const kernelPaths = config.getKernelPaths();
    if (!exists(kernelPaths.image))
    {
        logError("kernel image '", kernelPaths.image, "' does not exist, have you built the kernel?");
        return 1;
    }

    if (true /*config.bootloader == Bootloader.crystal*/)
    {
        // kernel gets installed starting at sector 17 of the disk
        mixin tempCString!("kernelPathTempCStr", "kernelPaths.image");
        const kernelImageSize = getFileSize(kernelPathTempCStr.str)
            .asSizeT("kernel image size ", " is too big to map");
        log("kernel image is \"", kernelPaths.image, "\" is ", kernelImageSize, " bytes");
        auto kernelImageMap = MappedFile.openAndMap(kernelPathTempCStr.str, 0, kernelImageSize, No.writeable);
        auto diskImageMap = config.mapImage(0, CrystalReserveSize + kernelImageSize, Yes.writeable);

        log("Copying ", kernelImageSize, " bytes from kernel image to disk image...");
        memcpy(diskImageMap.ptr + CrystalReserveSize, kernelImageMap.ptr, kernelImageSize);

        diskImageMap.unmapAndClose();
        kernelImageMap.unmapAndClose();
    }
    else
    {
        const mounts = config.getMounts();

        Rootfs.mount(config, mounts);
        scope(exit) Rootfs.unmount(config, mounts);

        const rootfsBoot = mounts.rootfs ~ "/boot";
        logMkdir(rootfsBoot);
        run(format("sudo cp %s %s", kernelPaths.image, rootfsBoot));
    }
    log("Succesfully installed kernel");
    return 0;
}),

Command("installRootfs", "install files/programs to rootfs", cmdInSequence, function(string[] args)
{
    enforce(args.length == 0, "installRootfs requires 0 arguments");
    const config = parseConfig();
    const mounts = config.getMounts();

    Rootfs.mount(config, mounts);
    scope(exit) Rootfs.unmount(config, mounts);

    // create the directory structure
    logMkdir(mounts.rootfs ~ "/dev", S_IRWXU | S_IRWXG | (S_IROTH | S_IXOTH));
    logMkdir(mounts.rootfs ~ "/proc", (S_IRUSR | S_IXUSR) | (S_IRGRP | S_IXGRP) | (S_IROTH | S_IXOTH));
    logMkdir(mounts.rootfs ~ "/sys", (S_IRUSR | S_IXUSR) | (S_IRGRP | S_IXGRP) | (S_IROTH | S_IXOTH));
    logMkdir(mounts.rootfs ~ "/var", S_IRWXU | (S_IRGRP | S_IXGRP) | (S_IROTH | S_IXOTH));
    logMkdir(mounts.rootfs ~ "/tmp", S_IRWXU | S_IRWXG | S_IRWXO);
    //logMkdir(mounts.rootfs ~ "/root", Yes.asRoot); // not sure I need this one

/*
    // used for the terminfo capability database
    {
        const targetTerminfo = mounts.rootfs ~ "/terminfo";
        const sourceTerminfo = "terminfo";
        logMkdir(targetTerminfo, S_IRWXU | S_IRWXG | S_IROTH);
        exec(format("cp %s/* %s", sourceTerminfo, targetTerminfo));
    }
*/
    const targetSbinPath = mounts.rootfs ~ "/sbin";
    logMkdir(targetSbinPath, S_IRWXU | S_IRWXG | S_IRWXO);

    const sourcePath = "rootfs";
    const sourceSbinPath = sourcePath ~ "/sbin";
    foreach (ref tool; commandLineTools)
    {
        const exe = sourceSbinPath ~ "/" ~ tool.name;
        if (!exists(exe))
        {
            logError("cannot find '", exe, "', have you run 'buildUser'?");
            return 1;
        }
        logCopy(exe, targetSbinPath ~ "/" ~ tool.name, Yes.asRoot);
    }

    return 0;
}),

]; // End of diskSetupCommands

// =============================================================================
// Utility Commands
// =============================================================================
immutable utilityCommands = [

Command("status", "try to get the current status of the configured image", cmdNoFlags, function(string[] args)
{
    logError("status command not implemented");
    return 1;
}),

Command("installFile", "Install one of more files <src>[:<dst>] or <src>[:<dir>/]", cmdNoFlags, function(string[] args)
{
    if (args.length == 0)
    {
        logError("please supply one or more files");
        return 1;
    }
    const config = parseConfig();
    const mounts = config.getMounts();

    Rootfs.mount(config, mounts);
    scope (exit) Rootfs.unmount(config, mounts);

    foreach (arg; args)
    {
        string file;
        string destDir;
        auto colonIndex = arg.indexOf(':');
        if (colonIndex >= 0)
        {
            file = arg[0 .. colonIndex];
            destDir = arg[colonIndex + 1 .. $];
        }
        else
        {
            file = arg;
            destDir = null;
        }
        auto result = installFile(file, mounts.rootfs, destDir);
        if (result.failed)
            return 1; // fail
    }
    return 0;
}),

Command("installElf", "Install an elf program and it's library dependencies <src>[:<dst>] or <src>[:<dir>/]", cmdNoFlags, function(string[] args)
{
    if (args.length == 0)
    {
        logError("please supply one or more elf binaries");
        return 1;
    }

    bool useLdd = true;
    string progName = useLdd ? "ldd" : "readelf";
    auto prog = findProgram(environment.get("PATH").verifySentinel.ptr, progName);
    if (prog.isNull)
    {
        logError("failed to find program '", progName, "'");
        return 1; // fail
    }

    const config = parseConfig();
    const mounts = config.getMounts();

    Rootfs.mount(config, mounts);
    scope (exit) Rootfs.unmount(config, mounts);

    foreach (arg; args)
    {
        SentinelArray!(immutable(char)) elfSourceFile;
        string elfDestDir;
        {
            auto colonIndex = arg.indexOf(':');
            if (colonIndex >= 0)
            {
                elfSourceFile = sprintMallocSentinel(arg[0 .. colonIndex]).asImmutable;
                elfDestDir = arg[colonIndex + 1 .. $];
            }
            else
            {
                elfSourceFile = arg.makeSentinel;
                elfDestDir = null;
            }
        }

        if (usePath(elfSourceFile.array))
        {
            if (!fileExists(elfSourceFile.ptr))
            {
                log("looking for '", elfSourceFile, "'...");
                auto result = findProgram(environment.get("PATH").verifySentinel.ptr, elfSourceFile.array);
                if (result.isNull)
                {
                    logError("failed to find program '", elfSourceFile, "'");
                    return 1;
                }
                elfSourceFile = result.walkToArray.asImmutable;
                log("found program at '", elfSourceFile, "'");
            }
        }

        if (useLdd)
        {
            auto result = installElfWithLdd(prog, elfSourceFile, elfDestDir, mounts.rootfs);
            if (result.failed)
                return 1;
        }
        else
        {
            auto result = installElfWithReadelf(prog, elfSourceFile, elfDestDir, mounts.rootfs);
            if (result.failed)
                return 1;
        }
    }
    return 0;
}),

Command("startQemu", "start the os using qemu", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "startQemu requires 0 arguments");
    const config = parseConfig();

    auto qemuProgName = "qemu-system-x86_64";
    auto qemuProg = findProgram(environment.get("PATH").verifySentinel.ptr, qemuProgName);
    if (qemuProg.isNull)
    {
        logError("failed to find program '", qemuProgName, "'");
        return 1; // fail
    }
    auto procBuilder = ProcBuilder.forExeFile(qemuProg);
    procBuilder.tryPut(lit!"-m").enforce;
    procBuilder.tryPut(lit!"2048").enforce;
    procBuilder.tryPut(lit!"-drive").enforce;
    procBuilder.tryPut(sprintMallocSentinel("format=raw,file=", config.imageFile)).enforce;

    // optional, enable kvm (TODO: make this an option somehow)
    procBuilder.tryPut(lit!"--enable-kvm").enforce;
    {
        enum SerialSetting {default_, stdio, file, telnet }
        const serialSetting = SerialSetting.stdio;
        final switch (serialSetting)
        {
        case SerialSetting.default_: break;
        case SerialSetting.stdio:
            procBuilder.tryPut(lit!"-serial").enforce;
            procBuilder.tryPut(lit!"stdio").enforce;
            break;
        case SerialSetting.file:
            procBuilder.tryPut(lit!"-serial").enforce;
            procBuilder.tryPut(lit!"file:serial.log").enforce;
            break;
        case SerialSetting.telnet:
            procBuilder.tryPut(lit!"-serial").enforce;
            procBuilder.tryPut(lit!"telnet:0.0.0.0:1234,server,wait").enforce;
            break;
        }
    }
    run(procBuilder);
    return 0;
}),

Command("installBochs", "install the bochs emulator", cmdNoFlags, function(string[] args)
{
    run("sudo apt-get install bochs bochs-x");
    return 0;
}),
Command("startBochs", "start the os using bochs", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "startBochs requires 0 arguments");
    const config = parseConfig();

    run("bochs -f /dev/null"
        ~        ` 'memory: guest=1024, host=1024'`
        ~        ` 'boot: disk'`
        ~ format(` 'ata0-master: type=disk, path=%s, mode=flat'`, config.imageFile));
    return 0;
}),

Command("readMbr", "read/print the MBR of the image using the mar library", cmdNoFlags, function(string[] args)
{
    import std.stdio;
    enforce(args.length == 0, "readMbr requires 0 arguments");
    const config = parseConfig();

    writefln("Reading MBR of '%s'", config.imageFile);
    writeln("--------------------------------------------------------------------------------");

    auto f = File(config.imageFile, "rb");
    mbr.OnDiskFormat mbrPtr;
    assert(mbrPtr.bytes.length == f.rawRead(*mbrPtr.bytes).length);
    if (!mbrPtr.signatureIsValid)
    {
        logError("invalid mbr signature '", mbrPtr.bootSignatureValue.toHostEndian, "'");
        return 1;
    }

    foreach (i, ref part; mbrPtr.partitions)
    {
        writefln("part %s: type=%s(0x%x)", i + 1, part.type.name, part.type.enumValue);
        writefln(" status=0x%02x%s", part.status, part.bootable ? " (bootable)" : "");
        writefln(" firstSectorChs %s", part.firstSectorChs);
        writefln(" lastSectorChs  %s", part.lastSectorChs);
        const firstSectorLba = part.firstSectorLba.toHostEndian;
        const sectorCount    = part.sectorCount.toHostEndian;
        writefln(" firstSectorLba 0x%08x %s", firstSectorLba, firstSectorLba);
        writefln(" sectorCount    0x%08x %s", sectorCount, sectorCount);
    }
    return 0;

}),

Command("zeroMbr", "zero the image mbr", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "zeroMbr requires 0 arguments");
    const config = parseConfig();

    auto mappedImage = config.mapImage(0, 512, Yes.writeable);
    memset(mappedImage.ptr, 0, 512);
    mappedImage.unmapAndClose();
    return 0;
}),

Command("mountRootfs", "mount the looped image", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "mount requires 0 arguments");
    const config = parseConfig();
    const mounts = config.getMounts();

    Rootfs.mount(config, mounts);
    return 0;
}),
Command("unmountRootfs", "unmount the disk image", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "unmount requires 0 arguments");
    const config = parseConfig();
    const mounts = config.getMounts();
    Rootfs.unmount(config, mounts);
    return 0;
}),

Command("loopImage", "attach the image file to a loop device and scan for partitions", cmdInSequence, function(string[] args)
{
    enforce(args.length == 0, "loopImage requires 0 arguments");
    const config = parseConfig();
    loopImage(config);
    return 0;
}),
Command("unloopImage", "release the image file from the loop device", cmdInSequence, function(string[] args)
{
    enforce(args.length == 0, "unloopImage requires 0 arguments");
    const config = parseConfig();

    auto loopFile = tryGetImageLoopFile(config);
    if (!loopFile)
    {
        log("image '", config.imageFile, "' it not looped");
    }
    else
        unloopImage(loopFile);

    return 0;
}),

Command("hostRunInit", "run the init process on the host machine", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "unloopImage requires 0 arguments");
    const config = parseConfig();

    const rootfsPath = "rootfs";
    run(format("sudo chroot %s /sbin/init", rootfsPath));
    return 0;
}),
Command("hostCleanInit", "cleanup after running the init process on the host machine", cmdNoFlags, function(string[] args)
{
    enforce(args.length == 0, "unloopImage requires 0 arguments");
    const config = parseConfig();

    const rootfsPath = "rootfs";
    tryExec(format("sudo umount %s/proc", rootfsPath));
    tryExec(format("sudo rmdir %s/proc", rootfsPath));
    return 0;
}),

];
