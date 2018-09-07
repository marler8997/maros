module log;
/**
Log an error.
*/
void logError(T...)(T args)
{
    import mar.file;
    stderr.write("Error: ", args, "\n");
}
/**
Log details that reveal what the code is doing/how it works.
*/
void logInfo(T...)(T args)
{
    version (EnableLogInfo)
    {
        import mar.file;
        stdout.write(args, "\n");
    }
}