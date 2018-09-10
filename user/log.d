module log;

/**
Log an error.
*/
void logError(T...)(T args)
{
    import mar.io : stderr;
    stderr.writeln("Error: ", args);
}
/**
Log details that reveal what the code is doing/how it works.
*/
void logInfo(T...)(T args)
{
    version (EnableLogInfo)
    {
        import mar.io : stdout;
        stdout.writeln(args);
    }
}