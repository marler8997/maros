module stdm.linux.mmap;

// TODO: move this to stdm

import stdm.flag;
import stdm.typecons : ValueOrErrorCode;
import stdm.linux.cthunk : off_t;
import stdm.linux.file : FileD;
import stdm.linux.syscall;

alias mmap   = sys_mmap;
alias munmap = sys_munmap;

enum PROT_NONE   = 0b0000;
enum PROT_READ   = 0b0001;
enum PROT_WRITE  = 0b0010;
enum PROT_EXEC   = 0b0100;

enum MAP_SHARED  = 0b0_0001;
enum MAP_PRIVATE = 0b0_0010;
enum MAP_FIXED   = 0b1_0000;

enum MS_ASYNC      = 1;
enum MS_INVALIDATE = 2;
enum MS_SYNC       = 4;
extern(C) int msync(void* addr, size_t length, int flags);


struct MemoryMap
{
    private SyscallValueResult!(ubyte*) _result;
    private size_t length;
    auto numval() const { return _result.numval; }
    auto failed() const { return _result.failed; }
    auto passed() const { return _result.passed; }

    void* ptr() const { return _result.val; }
    T[] array(T)() const if (T.sizeof == 1)
    {
        return (cast(T*)_result.val)[0 .. length];
    }
    ~this() { unmap(); }
    void unmap()
    {
        if (_result.passed && _result.val != null)
        {
            munmap(_result.val, length);
            _result.set(null);
        }
    }
}
MemoryMap createMemoryMap(void* addrHint, size_t length,
    Flag!"writeable" writeable, FileD fd, off_t fdOffset)
{
    return MemoryMap(mmap(addrHint, length, PROT_READ |
        (writeable ? PROT_WRITE : 0), MAP_SHARED, fd, fdOffset), length);
}
