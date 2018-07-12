```D
struct BuildSequence
{
   string name;
   BuildNode[] nodes;
}
enum BuildNodeType : ubyte
{
    commands,
    branch,
}
struct BuildNode
{
    private BuildNodeType type;
    union
    {
        Command[] commands;
        BuildSequence[] branches;
    }
    private this(Command[] commands)
    {
        this.type = BuildNodeType.commands;
        this.commands = commands;
    }
    private this(BuildSequence[] branches)
    {
        this.type = BuildNodeType.branch;
        this.branches = branches;
    }
    static auto makeCommands(Command[] commands)
    {
        return BuildNode(commands);
    }
    static auto makeBranches(BuildSequence[] branches)
    {
        return BuildNode(branches);
    }
}

auto buildRoot = BuildSequence("root", [

BuildNode.makeCommands([

Command("installTools", "install tools to build", cmdNoFlags, function(string[] args)
{
    // ...
    return 0;
}),

]),

BuildNode.makeBranches([

BuildSequence("bootloader", [ // root.bootloader (start)

BuildNode.makeCommands([

Command("buildBootloader", "build the bootloader", cmdInSequence, function(string[] args)
{
    // ...
    return 0;
}),
Command("installBootloader", "install the bootloader", cmdInSequence, function(string[] args)
{
    // ...
    return 0;
}),

]),

]), // root.bootloader end

]), // branch end


]); // root sequence end


void usage()
{
    nodeUsage(buildRoot, 0);
}

void nodeUsage(BuildSequence sequence, uint depth)
{
    import std.stdio;
    foreach (node; sequence.nodes)
    {
        final switch (node.type)
        {
        case BuildNodeType.commands:
            foreach (ref cmd; node.commands)
            {
                foreach (i; 0 .. depth) write(" ");
                writefln("%-20s %s", cmd.name, cmd.description);
            }
            break;
        case BuildNodeType.branch:
            depth++;
            foreach (branch; node.branches)
            {
                foreach (i; 0 .. depth) write(" ");
                writeln(bran);
                nodeUsage(branch, depth);                
            }
            depth--;
        }
    }
}
```