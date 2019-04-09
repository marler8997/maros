/**

Design:


Components:

Graphics: display graphics to provide feedback to the user

Editor: executes "editor commands" which result in file editing and graphics updates

Input: a component that accepts input and traslates it to "editor commands"
       this would be considered the "driver" of the program.
       it should only need a reference to the editor component
*/

import mar.passfail;
import mar.enforce;
import mar.array : aequals, acopy;
import mar.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.print : formatHex;
import ascii = mar.ascii;
//import mar.cmdopt;
import mar.file : read;
import mar.stdio : stdin;
//import mar.env : getenv;
import mar.linux.signals : sigaction_t, sigaction, SIGWINCH, SIGINT, SIGHUP, SIGTERM, SIGUSR1;
import mar.linux.ttyioctl;

import log;
import termgraph;

import mar.start;
mixin(startMixin);

void logDev(T...)(T args)
{
    import mar.stdio : stdout;
    stdout.writeln("[DEV] ", args);
}

void usage()
{
    import mar.stdio : stdout;
    stdout.writeln("Usage: medit");
    stdout.writeln("Options:");
    stdout.writeln("  <none yet>");
}

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
            else if (aequals(arg, lit!"-h") || aequals(arg, lit!"--help"))
            {
                usage();
                return 1;
            }
            else
            {
                logError("unknown option \"", arg, "\"");
                return 1;
            }
        }
    }

/*
    TermCapsFile termcapsFile;

    if (!termfile.isNull)
    {
        if (!term.isNull)
        {
            logError("--term and --termfile cannot both be provided");
            return 1;
        }
        termcapsFile = loadTermCapsFile(termfile);
    }
    else
    {
        if (term.isNull)
        {
            term = envp.getenv("TERM");
            if (term.isNull)
            {
                logError("no TERM environment variable and no --term provided, quitting for now");
                return 1;
            }
            logDev("TERM=", term);
        }
        termcapsFile = loadTermCaps(term);
    }
    */

    if (registerSignals().failed)
        return 1; // error already logged
    if (Terminal.setup().failed)
        return 1; // error already logged
    // TODO: make sure this executes even on terminating signals
    scope (exit) Terminal.restore();

    if (clearScreen().reportFail("failed to clear graphics: ", Result.val).failed)
        return 1;

    WindowSize winSize;
    {
        auto result = tryGetWindowSize(&winSize);
        if (result.failed)
        {
            // error message already printed
            return 1;
        }
    }
    logDev("window size: ", winSize.width, "x", winSize.height);
/+
    for (;;)
    {
        ubyte[100] buffer = void;
        auto length = read(stdin, buffer);
        if (length.numval <= 0)
        {
            if (length.numval < 0)
            {
                if (length.numval == -4)
                {
                    //
                    continue;
                }
                logError("read failed, returned ", length.numval);
                exit(1);
            }
            return 0;
        }
        foreach (c; buffer[0 .. length.val])
        {
            if (c == 'q')
                return 0;
            else if (c == 'i')
                setCursor(CursorState.invisible);
            else if (c == 'v')
                setCursor(CursorState.visible);
            else if (c == 'c')
                clearScreen();
            else if (c == 'e')
                eraseDisplay();
            else if (c == '\n')
            {}
            else
                stdout.write("unknown command '", c, "'\n");
        }
    }
    +/
    InputState inputState;
    char[100] buffer;
    size_t dataLength = 0;
    for (;;)
    {
        if (dataLength == buffer.length)
        {
            logError("code bug?");
            break;
        }
        {
            //logDev("read");
            auto result = read(stdin, buffer[dataLength .. $]);
            if (result.numval <= 0)
            {
                if (result.failed)
                {
                    logError("read stdin failed, returned ", result.numval);
                    return 1;
                }
                logDev("stdin closed");
                break;
            }
            //logDev("got ", result.val, " bytes");
            dataLength += result.val;
        }
        auto processed = processInput(buffer[0 .. dataLength], &inputState);
        if (inputState.quit)
            break;
        //logDev("processed ", processed, " bytes");
        auto newLength = dataLength - processed;
        if (processed > 0)
            acopy(buffer.ptr, buffer.ptr + processed, newLength);
        dataLength = newLength;
    }
    return 0;
}

enum SequenceState
{
    initial,
    escape, // Got ESC
    csi,    // Got CSI or 'ESC + ['
}

struct InputState
{
    bool quit;
    SequenceState sequenceState;
}

// http://man7.org/linux/man-pages/man4/console_codes.4.html
enum ControlCodes : char
{
    null_          =  0,
    // ...
    bell           =  7, // 0x07
    backspace      =  8, // 0x08 (backspace 1 column, but not past beginning of line)
    tab            =  9, // 0x09 (go to next tab stop, else end of line)
    newline        = 10, // 0x0A (line feed)
    verticalTab    = 11, // 0x0B (line feed)
    formFeed       = 12, // 0x0C (line feed)
    carriageReturn = 13, // 0x0D
    shiftOut       = 14, // 0x0E (activate G1 character set)
    shiftIn        = 15, // 0x0F (activate G0 character set)
    // ...
    cancel         = 24, // 0x18 (interrupt escape sequence)
    // ..
    substitute     = 26, // 0x1A (interrupt escape sequence)
    escape         = 27, // 0x1B (start an escape sequence)
    // ...
    delete_        = 127, // 0x7F (ignored)
    csi            = 155, // 0x9B (INVALID IN UTF8 MODE) (equivalent to "ESC + [")
}

// Escape sequences that do not start with "ESC + ["
enum ImmediateEscapeCodes : char
{
    reset           = 'c',
    lineFeed        = 'D',
    newline         = 'E',
    setTabStop      = 'H', // set tab stop at current column
    reverseLineFeed = 'M',
    // ... TODO: get more from http://man7.org/linux/man-pages/man4/console_codes.4.html (ESC- but not CSI-sequences)
}

size_t processInput(const(char)[] input, InputState* state)
{
    import mar.file : write;
    import mar.stdio : stdout;

    //logDev("processInput \"", ascii.formatEscape(input), "\"");

    size_t offset = 0;
    for (;;)
    {
        if (offset >= input.length)
            return offset;
        auto c = input[offset];
        final switch (state.sequenceState)
        {
        case SequenceState.initial:
            if (!ascii.isUnreadable(c))
            {
                // TODO: use CTL to detect quit
                if (c == 'q')
                {
                    state.quit = true;
                    return offset;
                }
                // todo: don't echo one character at a time
                {
                    auto result = write(stdout, input[offset .. offset + 1]);
                    if (result.failed)
                    {
                        logError("write to stdout failed, returned ", result.numval);
                        state.quit = true;
                        return offset;
                    }
                }
                offset++;
            }
            else if (c == ControlCodes.escape)
            {
                state.sequenceState = SequenceState.escape;
                offset++;
            }
            else if (c == ControlCodes.cancel) // CTL-X
            {

            }
            else
            {
                logError("unknown input '", ascii.formatEscape(input[offset .. $]), "'");
                offset++;
                //state.quit = true;
                //return offset;
            }
            break;
        case SequenceState.escape:
            if (c == '[')
            {
                state.sequenceState = SequenceState.csi;
                offset++;
            }
            else
            {
                logError("TODO: handle immediate escape sequence '", ascii.formatEscape(c), "'");
                state.quit = true;
                return offset;
            }
            break;
        case SequenceState.csi:
            logDev("ESC + [ + ", ascii.formatEscape(c));
            offset++;
            state.sequenceState = SequenceState.initial;
            break;
        }
    }
}


struct Terminal
{
    private static __gshared bool do_restore;
    private static __gshared termios restore_ios;

    /*
    TODO: call Terminal.restore before process exists on kill signals
    TODO: this would be a good candidate for a kernel module that
          restores terminal settings when the process exits
    */
    static passfail setup()
    {
        {
            import mar.stdio : stdout;
            termios ios;
            {
                auto result = tcgetattr(stdout, &ios);
                if (result.failed)
                {
                    logError("tcgetattr failed, returned ", result);
                    return passfail.fail;
                }
            }
            logDev("stdout:");
            logDev(" c_iflag (input mode flags): 0x", ios.c_iflag.formatHex);
   // tcflag_t c_iflag;   // input mode flags
   // tcflag_t c_oflag;   // output mode flags
   // tcflag_t c_cflag;   // control mode flags
   // tcflag_t c_lflag;   // local mode flags
   // cc_t c_line;        // line discipline
   // cc_t[NCCS] c_cc;    // control characters
        }

        if (do_restore)
        {
            logError("Terminal.setup has already been called");
            return passfail.fail;
        }

        {
            auto result = tcgetattr(stdin, &restore_ios);
            if (result.failed)
            {
                logError("tcgetattr failed, returned ", result);
                return passfail.fail;
            }
        }
        logDev("stdin:");
        logDev(" c_lflag (local mode flags): 0x", restore_ios.c_lflag.formatHex);

        auto new_ios = restore_ios;
        new_ios.c_lflag &= ~ICANON; // disable buffered io
        new_ios.c_lflag &= ~ECHO;    // disable echo mode
        auto result = tcsetattrnow(stdin, &new_ios);
        if (result.failed)
        {
            logError("tcsetattr stdin failed, returned ", result);
            return passfail.fail;
        }
        do_restore = true; // set right after tcsetattr succeeds
        return passfail.pass;
    }
    static void restore()
    {
        logDev("Terminal.restore (do_restore=", do_restore, ")");
        if (do_restore)
        {
            auto result = tcsetattrnow(stdin, &restore_ios);
            if (result.failed)
            {
                // nothing we can do, looks like we can't restore the terminal to it's previous state
                logError("failed to restore terminal settings because tcsetattr for stdin failed, returned ", result);
            }
            else
            {
                do_restore = false;
            }
        }
    }
}


extern (C) void signalHandler(int arg)
{
    logDev("[DEBUG] signalHandler ", arg);
    /*
    if (arg == SIGWINCH)
    {
        logDev("windowSizeChanged! signal=", arg);
        WindowSize winSize;
        {
            auto result = tryGetWindowSize(&winSize);
            if (result.failed)
            {
                // error message already printed
                return;
            }
        }
        logDev("window size: ", winSize.width, "x", winSize.height);
    }
    else
    {
        logDev("got signal ", arg);
    }
    */
}

passfail registerSignals()
{
    sigaction_t act;
    act.sa_handler = &signalHandler;
    //act.sa_sigaction = &signalHandler2;
    //act.sa_flags = SA_SIGINFO;
    static immutable signals = [
        SIGWINCH, SIGINT, SIGHUP, SIGTERM, SIGUSR1];
    foreach (signum; signals)
    {
        auto result = sigaction(signum, &act, null);
        if (result.failed)
        {
            logError("sigaction(", signum, ", ...) failed, returned ", result.numval);
            return passfail.fail;
        }
    }
    return passfail.pass;
}

auto clearScreen()
{
    import mar.stdio : stdout;
    import mar.file : write;
    return write(stdout, "\x1b[2J");
}



////////////////////////////////////////////////////////////////////////////////
// Command Implementation Layer
////////////////////////////////////////////////////////////////////////////////
void addCtlX()
{
//    !! not impl
}
Command[] commandQueue;

struct Command
{
}