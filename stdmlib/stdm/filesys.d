module stdm.filesys;

version (linux)
{
    public import stdm.linux.filesys;
}
else version (Windows)
{
}
else static assert(0, __MODULE__ ~ " is not supported on this platform");
