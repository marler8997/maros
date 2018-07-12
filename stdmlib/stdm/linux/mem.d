module stdm.linux.mem;

import stdm.linux.syscall;

pragma(inline) SyscallValueResult!(void*) sbrk(ptrdiff_t increment)
{
    assert(0, "not implemented");
    //import stdm.linux.syscall;
    //return SyscallNegativeErrorOrValue!(void*)(syscall(Syscall.brk, increment));
}
