module stdm.file;

version (linux)
{
    public import stdm.linux.file;
    //static import stdm.linux.file;
    //alias FileD = stdm.linux.file.FileD;
}
else version (Windows)
{
    alias FileD = uint;
    auto getFileSize(T)(T filename)
    {
        assert(0, "getFileSize not implemented on Windows");
        return ulong.min;
    }
}
else static assert(0, __MODULE__ ~ " is not supported on this platform");
