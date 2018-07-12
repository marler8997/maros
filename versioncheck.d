#!/usr/bin/env rund
import std.typecons : Flag, Yes, No;
import std.conv : to;
import std.string : lineSplitter, strip;
import std.algorithm : max;
import std.format : format;
import std.regex : matchFirst;
import std.file : isSymlink;
import std.stdio;
import std.process;

enum Result
{
    initial,
    versionCommandError,
    versionExtractError,
    versionIsOld,
    // ok results
    ok,
}

struct ExeLink
{
    string exeFile;
    string linkTarget;
}

struct Program
{
    string name;
    string minVersion;
    string customVersionRegex;
    string customVersionArgs;
    Flag!"checkLink" checkLink;

    string error;
    Version version_;
    ExeLink link;
}

enum defaultVersionRegex = `[^0-9]*([0-9\.]+)`;

auto programs = [
    Program("bash"    ,    "3.2"),
    // binutils
    Program("ld"      ,   "2.17"),

    Program("bison"   ,    "2.3"),
    Program("yacc"    ,    "2.3", defaultVersionRegex, null, Yes.checkLink),
    Program("bzip2"   ,  "1.0.4", `^bzip2` ~ defaultVersionRegex),

    // Coreutils-6.9
    // NOTE: I just picked these versions from what was installed in my system
    //       but I should install coreutils 6-9 and see what versions of these programs
    //       it has installed
    Program("chown"  ,    "8.25"),
    Program("diff"   ,     "3.3"),
    Program("find"   ,     "4.7"),

    Program("gawk"   ,     "4.1"),
    Program("awk"    ,     "4.1", defaultVersionRegex, null, Yes.checkLink),

    Program("gcc"    ,     "4.7"),
    Program("g++"    ,     "4.7"),
    Program("ldd"    ,     "2.23"), // TODO: not sure if this version is right

    Program("grep"   ,   "2.5.1a"),
    Program("gzip"   ,   "1.3.12"),
    Program("m4"     ,   "1.4.10", `^m4 \(GNU M4\)` ~ defaultVersionRegex),
    Program("make"   ,     "3.81"),
    Program("patch"  ,    "2.5.4"),
    Program("perl"   ,    "5.8.8", defaultVersionRegex, "-V:version"),
    Program("sed"    ,    "4.1.5"),
    Program("tar"    ,     "1.22"),
    Program("xz"     ,    "5.0.0"),

    // texinfo
    Program("makeinfo",     "4.7", "GNU" ~ defaultVersionRegex),
];
int main(string[] args)
{
    size_t maxProgName      = "prog".length;
    size_t maxVersionLength = "version".length;
    foreach (ref prog; programs)
    {
        updateMax(&maxProgName, prog.name.length);

        if (prog.checkLink)
        {
            auto whichResult = executeShell(`which ` ~ prog.name);
            if (whichResult.status == 0 && whichResult.output.length > 0)
            {
                prog.link.exeFile = whichResult.output.lineSplitter.front;
                if (isSymlink(prog.link.exeFile))
                {
                    auto readlinkResult = executeShell(`readlink -f "` ~ prog.link.exeFile ~ `"`);
                    if (readlinkResult.status == 0)
                    {
                        prog.link.linkTarget = readlinkResult.output.strip();
                    }
                }
            }
        }

        string versionCommand = format("%s %s", prog.name,
            prog.customVersionArgs.or("--version"));
        auto versionResult = executeShell(versionCommand);
        if (versionResult.status != 0)
        {
            printCommandIfThereIsOutput(versionCommand, versionResult.output);
            prog.error = format("version command '%s' failed. exitCode=%s output=%s",
                versionCommand, versionResult.status, (versionResult.output.length == 0) ? "none" : "(see above)");
            continue;
        }
        //writeln("Output:");
        //writeln(versionResult.output);
        {
            auto versionRegex = prog.customVersionRegex.or(defaultVersionRegex);
            auto matchResult = matchFirst(versionResult.output, versionRegex);
            if (matchResult.empty)
            {
                printCommandIfThereIsOutput(versionCommand, versionResult.output);
                prog.error = format("failed to extract version from '%s'. regex='%s' output=%s",
                    versionCommand, versionRegex, (versionResult.output.length == 0) ? "none" : "(see above)");
                continue;
            }
            assert(matchResult.length == 2, "regex bug, match length is not 2");
            prog.version_ = Version(matchResult[1]);
        }
        //writefln("Version '%s'", prog.version_);
        updateMax(&maxVersionLength, prog.version_.value.length);
        auto minVersion = Version(prog.minVersion);
        if (prog.version_ < minVersion)
        {
            prog.error = format("too old, min version is %s", prog.minVersion);
            continue;
        }
    }

// TODO: check host linux kernel version 'cat /proc/version' (>= 3.2)

// TODO: check that /bin/sh points to bash
    /+
    MYSH=$(readlink -f /bin/sh)
echo "/bin/sh -> $MYSH"
echo $MYSH | grep -q bash || echo "ERROR: /bin/sh does not point to bash"
unset MYSH
+/
/+
TODO: check that we can compile a dummy main
echo 'int main(){}' > dummy.c && g++ -o dummy dummy.c
if [ -x dummy ]
  then echo "g++ compilation OK";
  else echo "g++ compilation failed"; fi
rm -f dummy.c dummy
+/

    auto formatString = format("%%%ss | %%%ss | %%s", maxProgName, maxVersionLength);
    writeln("--------------------------------------------------------------------------------");
    writefln(formatString, "prog", "version", "result");
    writeln("--------------------------------------------------------------------------------");
    uint errorCount = 0;
    foreach (ref prog; programs)
    {
        string result;
        if (prog.error)
        {
            result = prog.error;
            errorCount++;
        }
        else
        {
            result = format("up-to-date (min=%s)", prog.minVersion);
            if (prog.link.linkTarget)
                result ~= format(" (%s -> %s)", prog.link.exeFile, prog.link.linkTarget);
        }
        writefln(formatString, prog.name, prog.version_.value, result);
    }

    writeln("--------------------------------------------------------------------------------");
    if (errorCount > 0)
        writefln("%s error(s)", errorCount);
    else
        writeln("Success (no errors)");

    return errorCount;
}

auto or(T)(T first, T default_)
{
    return first ? first : default_;
}

void updateMax(T)(T* currentMax, T newValue)
{
    if (newValue > *currentMax)
    {
        *currentMax = newValue;
    }
}

void printCommandIfThereIsOutput(string command, string output)
{
    if (output.length == 0)
        return;


    writeln("--------------------------------------------------------------------------------");
    writefln("Command: '%s' Output:", command);
    write(output);
    if (output[$-1] != '\n')
        writeln();
}

struct VersionRange
{
    private const(char)* versionLimit;
    private string current;
    this(string version_)
    in { assert(version_.length > 0, "code bug, empty version"); } do
    {
        this.versionLimit = version_.ptr + version_.length;
        auto next = version_.ptr;
        this.current = next[0 .. next.ptrTo('.', versionLimit) - next];
    }

    bool empty() { return current is null; }
    string front() { return current; }
    void popFront()
    {
        auto next = current.ptr + current.length;
        if (next >= versionLimit)
        {
            current = null;
        }
        else
        {
            next++;
            this.current = next[0 .. next.ptrTo('.', versionLimit) - next];
        }
    }
}
auto ptrTo(inout(char)* ptr, char c, const(char)* limit)
{
    for (; ptr < limit && *ptr != c; ptr++)
    { }
    return ptr;
}

enum THIS_GREATER  = 1;
enum OTHER_GREATER = -1;
struct Version
{
    string value;
    int opCmp(ref const Version other) const
    {
        auto thisRange  = VersionRange(value);
        auto otherRange = VersionRange(other.value);
        for (;;)
        {
            if (thisRange.empty)
                return otherRange.empty ? 0 : OTHER_GREATER;
            auto thisNext = thisRange.front;
            auto otherNext = otherRange.front;
            if (thisNext.length == otherNext.length)
            {
                import std.algorithm : cmp;
                auto result = thisNext.cmp(otherNext);
                if (result != 0)
                    return result;
            }
            else
            {
                return (thisNext.length > otherNext.length) ?
                    THIS_GREATER : OTHER_GREATER;
            }
            thisRange.popFront();
            otherRange.popFront();
        }
    }
}