module termgraph;

import stdm.passfail;
import stdm.flag;
import stdm.sentinel : assumeSentinel;
import stdm.c : cstring;
import stdm.format : sprint;
import stdm.file : open, OpenFlags, OpenAccess, tryGetFileSize, write, stdout, print, stderr;
import stdm.mmap : MemoryMap, createMemoryMap;
import stdm.process : exit;

import log;

struct TermCapsFile
{
    MemoryMap map;
    TermCaps caps;
    const(char)[] text() const
    {
        return map.array!char;
    }
}

struct TermCaps
{
}

auto loadTermCaps(cstring term)
{
    // TODO: don't use a static size
    char[100] filename;
    sprint(filename, "/terminfo/", term, "\0");
    return loadTermCapsFile(filename.ptr.assumeSentinel);
}
auto loadTermCapsFile(cstring termfile)
{
    auto fileSize = tryGetFileSize(termfile);
    if (fileSize.failed)
    {
        print(stderr, "WARNING: failed to get size for \"", termfile, "\", returned ", fileSize.errorCode, "\n");
        return TermCapsFile();
        //logError("failed to get size for \"", termfile, "\", returned ", fileSize.errorCode);
        //exit(1);
    }
    auto fd = open(termfile, OpenFlags(OpenAccess.readOnly));
    if (!fd.isValid)
    {
        logError("open \"", termfile, "\" failed, returned ", fd.numval);
        exit(1);
    }

    auto termcapsFile = TermCapsFile();
    termcapsFile.map = createMemoryMap(null, fileSize.val, No.writeable, fd, 0);
    if (termcapsFile.map.failed)
    {
        logError("failed to map term file, returned ", termcapsFile.map.numval);
        exit(1);
    }

    auto parser = TermCapsParser(&termcapsFile.caps, termcapsFile.text.ptr,
        termcapsFile.text.ptr + termcapsFile.text.length, 1, termfile);
    parser.parse();
    return termcapsFile;
}

struct TermCapsParser
{
    TermCaps* caps;
    const(char)* next;
    const(char)* limit;
    uint lineNumber;
    cstring filenameForErrors;

    void parse()
    {

    }
}


void clearScreen()
{
    write(stdout, "\33[2J");
}

enum CursorState
{
    visible,
    invisible,
}
void setCursor(CursorState state)
{
    final switch (state)
    {
    case CursorState.visible:
        write(stdout, "\33[?25h");
        break;
    case CursorState.invisible:
        write(stdout, "\33[?25l");
        break;
    }
}

void eraseDisplay()
{
    write(stdout, "\33[2J");
}



struct linux_winsize
{
    ushort row;
    ushort col;
    ushort unused1;
    ushort unused2;
}


struct WindowSize
{
    private linux_winsize winSize;
    auto width() const { return winSize.col; }
    auto height() const { return winSize.row; }
}

passfail tryGetWindowSize(WindowSize* size)
{
    import stdm.linux.ioctl : ioctl;
    import stdm.linux.ttyioctl : TIOCGWINSZ;
    auto result = ioctl(stdout, TIOCGWINSZ, size);
    if (result.failed)
    {
        logError("ioctl TIOCGWINSZ failed, returned ", result.numval);
        return passfail.fail;
    }
    return passfail.pass;
}