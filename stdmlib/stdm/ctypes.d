module stdm.ctypes;

version (linux)
{
    public import stdm.linux.cthunk;
}
else version (Windows)
{
    alias off_t = uint;
}
else static assert(0, "unsupported platform");