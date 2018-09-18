/**
This tool contains all the operations that the rex program must do as root.

For example, only the root user can create the /var/rex directory, however,
we don't want to have to run the full rex program as root.
*/
import mar.array : aequals, indexOrMax, find, amove, startsWith;
import mar.sentinel : SentinelPtr, SentinelArray, lit, litPtr, assumeSentinel;
import mar.c : cstring, tempCString;
import mar.mem : malloc, free;
import mar.print : formatHex, sprintMallocNoSentinel, sprintMallocSentinel;
import mar.file : FileD, open, openat, close, read, lseek, isDir, fstatat, formatMode,
                   stat_t, ModeFlags, OpenFlags, OpenAccess, OpenCreateFlags, SeekFrom;
static import mar.file.perm;
import mar.io : stdout;
import mar.filesys : umask, mkdir, rmdir, umount2,
                      linux_dirent, getdents, LinuxDirentRange,
                      AT_SYMLINK_NOFOLLOW;
import mar.process : exit;

import log;

__gshared bool dryRun = false;

import mar.start;
mixin(startMixin);

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argc--;
    argv++;
    if (argc == 0)
    {
        stdout.write("Usage: rexrootops <operation>\n"
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
            else if (aequals(arg, "--dry-run"))
            {
                // print operations, but do not perform them
                dryRun = true;
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
        stdout.write("/var/rex already exists\n");
    }
    else
    {
        stdout.write("creating /var/rex...\n");
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
    // We need to keep unmounting until we do a run where nothing
    // is unmounted.  This is because we read the /proc/mounts file
    // a buffer at a time and perform the unmounts at the same time.
    // So...if an unmount is performed while reading /proc/mounts, we will
    // miss some of the mounts.  Note that this could also be the case
    // if another process was unmounting at the same time.  To really get
    // everything unmounted, we should really make sure we read it all at once.
    // But, another process could mount something right after so we can never
    // guarantee that there won't be mounted directories before we remove all
    // the files.
    for (;;)
    {
        auto unmountCount = doUnmounts();
	if (unmountCount == 0)
	    break;
    }

    return cleanFiles();
}


uint doUnmounts()
{
    auto mounts = open(litPtr!"/proc/mounts", OpenFlags(OpenAccess.readOnly));
    if (!mounts.isValid)
    {
        logError("open /proc/mounts failed ", mounts);
        exit(1);
    }
    scope(exit) close(mounts);
    //logInfo("open returned ", mounts);


    // TODO: this reading of a file and going through it line by line
    //       is probably VERY common, should move this to a library
    enum MAX_MOUNT_LINE = 200;
    char[MAX_MOUNT_LINE] buffer;

    size_t dataLength = 0;
    uint unmountCount = 0;
    for (;;)
    {
        if (dataLength == buffer.length)
        {
            // TODO: maybe increase the buffer size in this case
            logError("mount line exceeded max size of ", buffer.length);
	    exit(1);
        }
        {
            auto size = read(mounts, buffer[dataLength.. $]);
            if (size.numval <= 0)
            {
                if (size.failed)
                {
                    logError("read of /proc/mounts failed, returned ", size.numval);
		    exit(1);
                }
                break;
            }
	    //stdout.write("----STRT------\n");
	    //stdout.write(buffer[dataLength .. dataLength + size.val]);
	    //stdout.write("\n----END------\n");
            dataLength += size.val;
        }

        // process lines
        auto lineStart = buffer.ptr;
        auto limit = buffer.ptr + dataLength;
        for (;;)
        {
            auto newline = find(lineStart, limit, '\n');
            if (newline == limit)
                break;
            auto line = lineStart[0 .. newline - lineStart];
	    if (doUnmount(line))
	        unmountCount++;
            lineStart = newline + 1;
        }
        auto dataLeft = limit - lineStart;
        if (dataLength > 0)
        {
            amove(buffer.ptr, lineStart, dataLeft);
        }
        dataLength = dataLeft;
    }

    return unmountCount;
}

auto getMountPoint(inout(char)[] line)
{
    auto spaceIndex = line.indexOrMax(' ');
    if (spaceIndex == spaceIndex.max)
        return null;
    line = line[spaceIndex + 1 .. $];
    spaceIndex = line.indexOrMax(' ');
    if (spaceIndex == spaceIndex.max)
        return null;
    return line[0 .. spaceIndex];
}

// returns: true if it unmounted
bool doUnmount(const(char)[] line)
{
    //stdout.write("[DEBUG] ", line, "\n");
    auto mountPoint = getMountPoint(line);
    if (mountPoint is null)
    {
        logError("failed to find mount-point in line '", line, "'");
	exit(1);
    }
    //stdout.write("[DEBUG]   mount point is '", mountPoint, "'\n");
    if (mountPoint.startsWith("/var/rex"))
    {
        stdout.write("unmount '", mountPoint, "'\n");
	auto temp = sprintMallocSentinel(mountPoint);
	if (temp.ptr.isNull)
	{
	    logError("malloc failed for mountPoint string");
	    exit(1);
	}
	scope (exit) free(temp.ptr.raw);
	//stdout.write("[DEBUG]   '", temp.ptr, "'\n");
        auto umountResult = umount2(temp.ptr, 0);
	if (umountResult.failed)
	{
	    logError("umount '", temp.ptr, "' failed, returned ", umountResult.numval);
	    exit(1);
	}
	return true;
    }
    return false;
}

bool isCurrentOrParentDir(cstring name)
{
    return name[0] == '.' &&
        (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'));
}
int cleanFiles()
{
    auto rexDirFd = open(litPtr!"/var/rex", OpenFlags(OpenAccess.readOnly, OpenCreateFlags.dir));
    if (!rexDirFd.isValid)
    {
        if (rexDirFd.numval == -2)
        {
            stdout.write("/var/rex does not exist, nothing to clean\n");
            return 0;
        }
        logError("open(\"/var/rex\") failed, returned ", rexDirFd.numval);
        return 1;
    }
    cleanDir(lit!"/var/rex", rexDirFd);
    return 1;
}

void cleanDir(SentinelArray!(const(char)) dirName, FileD dirFd)
{
    //stdout.write("cleanDir ", dirName, "\n");

    // TODO: need to check if it is a mount point
    //       if it is, we need to unmount it
    //       the problem is what happens if it becomes mounted after
    //       we check but before we recurse into it?
    //       then we would be deleting files in the mounted point.
    



    enum DefaultBufferSize = 2048;
    auto buffer = cast(ubyte*)malloc(DefaultBufferSize);
    if (!buffer)
    {
        logError("malloc(", DefaultBufferSize, ") failed");
        exit(1);
    }

    uint entryRemoveCount = 0;
    for (;;)
    {
        auto entries = cast(linux_dirent*)buffer;
        auto result = getdents(dirFd, entries, DefaultBufferSize);
        if (result.numval <= 0)
        {
            if (result.failed)
            {
                logError("getdents failed, it returned ", result.numval);
                exit(1);
            }
            break;
        }
        entryRemoveCount += cleanDirEntries(dirName, dirFd, entries, result.val);
    }

    // try to clean the directory
    // !!! FOR NOW: only remove directories that were empty
    if (entryRemoveCount > 0)
    {
        stdout.write("[DEBUG] not cleaning non-empty dir '", dirName, "'\n");
    }
    else
    {
        stdout.write("rmdir(\"", dirName, "\")\n");
        if (!dryRun)
        {
            auto result = rmdir(dirName.ptr);
            if (result.failed)
            {
                logError("rmdir(\"", dirName, "\") failed, returned ", result.numval);
                exit(1);
            }
        }
    }
}
uint cleanDirEntries(SentinelArray!(const(char)) dirName, FileD dirFd,
    linux_dirent* entries, ptrdiff_t size)
{
    //stdout.write("[DEBUG] cleanDirEntries '", dirName, "', fd=", dirFd.numval, ", size=", size, "...\n");
    uint entryRemoveCount = 0;
    foreach (entry; LinuxDirentRange(size, entries))
    {
        if (isCurrentOrParentDir(entry.nameCString))
            continue;

        stat_t status;
        // TODO: use flag AT_SYMLINK_NOFOLLOW
        auto result = fstatat(dirFd, entry.nameCString, &status, AT_SYMLINK_NOFOLLOW);
        if (result.failed)
        {
            logError("fastatat(.., \"", entry.nameCString, "\" failed, returned ", result.numval);
            exit(1);
        }
        /*
        stdout.write(dirName, '/', entry.nameCString, "\n");
        stdout.write("  dev=", status.st_dev, ", ino=", status.st_ino, "\n");
        stdout.write("  mode=", status.st_mode.formatMode, "\n");
        stdout.write("  nlink=", status.st_nlink, "\n");
        stdout.write("  uid=", status.st_uid, ", gid=", status.st_gid, "\n");
        */
        if (mar.file.perm.isDir(status.st_mode))
        {
            auto subdirName = sprintMallocSentinel(dirName, '/', entry.nameCString);
            if (subdirName.isNull)
            {
                logError("malloc for dir name failed");
                exit(1);
            }
            //stdout.write("    ", subdirName, " is a dir!\n");
            auto subdirFd = openat(dirFd, entry.nameCString,
                OpenFlags(OpenAccess.readOnly, OpenCreateFlags.dir));
            if (!subdirFd.isValid)
            {
                logError("openat(dirfd, \"", entry.nameCString, "\", ro,dir) failed, returned ",
                    subdirFd.numval);
                exit(1);
            }
            cleanDir(subdirName, subdirFd);
            close(subdirFd);
            entryRemoveCount++;
        }
        else
        {
            // TODO: remove the file
            entryRemoveCount++;
        }
    }
    return entryRemoveCount;
}
