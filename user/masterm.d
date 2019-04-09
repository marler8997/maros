import mar.array : aequals;
import mar.sentinel : SentinelPtr, lit, litPtr, assumeSentinel;
import mar.c : cstring;
import mar.print : formatHex;
import mar.cmdopt;
import mar.file : read;
import mar.stdio : stdin, stdout;
import mar.process : exit;
import mar.env : getenv;
import mar.linux.signals;// : SIGWINCH, sigaction_t, sigaction;
import mar.linux.ttyioctl;

import log;
import termgraph;

import mar.start;
mixin(startMixin);

void logDev(T...)(T args)
{
    import mar.file;
    stdout.writeln("[DEV] ", args);
}

void usage()
{
    import mar.stdio : stdout;
    stdout.write("Usage: masterm [-options]\n");
    stdout.write("Options:\n");
    stdout.write("  --term <term>     Use <term> instead of the TERM environment variable\n");
    stdout.write("  --termfile <term> Instead of searching for <term> just use this file\n");
}

extern (C) int main(uint argc, SentinelPtr!cstring argv, SentinelPtr!cstring envp)
{
    argc--;
    argv++;

    cstring term;
    cstring termfile;

    {
        uint originalArgc = argc;
        argc = 0;
        for (uint i = 0; i < originalArgc; i++)
        {
            auto arg = argv[i];
            if (arg[0] != '-')
                argv[argc++] = arg;
            // NOTE: this is less likely than --term
            //       but we have to check it before because
            //       of a bug with aequals
            else if (aequals(arg, lit!"--termfile"))
                termfile = getOptArg(argv, &i);
            else if (aequals(arg, lit!"--term"))
                term = getOptArg(argv, &i);
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

    {
        termios arg;
        auto result = tcgetattr(stdout, &arg);
        if (result.failed)
        {
            logError("tcgetattr failed, returned ", result.numval);
            return 1;
        }
        stdout.write("stdout:\n");
        stdout.write(" c_iflag (input mode flags): 0x", arg.c_iflag.formatHex, "\n");
   // tcflag_t c_iflag;   // input mode flags
   // tcflag_t c_oflag;   // output mode flags
   // tcflag_t c_cflag;   // control mode flags
   // tcflag_t c_lflag;   // local mode flags
   // cc_t c_line;        // line discipline
   // cc_t[NCCS] c_cc;    // control characters

    }

    registerSignals();

    WindowSize winSize;
    {
        auto result = tryGetWindowSize(&winSize);
        if (result.failed)
        {
            // error message already printed
            return 1;
        }
    }
    stdout.write("window size: ", winSize.width, "x", winSize.height, "\n");

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
}

extern (C) void signalHandler(int arg)
{
    if (arg == SIGWINCH)
    {
        stdout.write("windowSizeChanged! signal=", arg, "\n");
        WindowSize winSize;
        {
            auto result = tryGetWindowSize(&winSize);
            if (result.failed)
            {
                // error message already printed
                return;
            }
        }
        stdout.write("window size: ", winSize.width, "x", winSize.height, "\n");
    }
    else
    {
        stdout.write("got signal ", arg, "\n");
    }
}

void registerSignals()
{
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
                exit(1);
            }
        }
    }
}
