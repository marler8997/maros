module log;
/**
Log an error.
*/
void logError(T...)(T args)
{
    import stdm.file;
    print(stderr, "Error: ", args, "\n");
}
/**
Log details that reveal what the code is doing/how it works.
*/
void logInfo(T...)(T args)
{
    version (EnableLogInfo)
    {
        import stdm.file;
        print(stdout, args, "\n");
    }
}