/**
Resource: https://wiki.osdev.org/Calling_Conventions
*/
module stdm.start;
template startMixin()
{
    version (linux)
    {
        enum startMixin = q{
        /**
        STACK (Low to High)
        ------------------------------
        RSP  --> | argc              |
        argv --> | argv[0]           |
                 | argv[1]           |
                 | ...               |
                 | argv[argc] (NULL) |
        envp --> | envp[0]           |
                 | envp[1]           |
                 | ...               |
                 | (NULL)            |
        */
        extern (C) void _start()
        {
            asm
            {
                naked;
                xor RBP,RBP;  // zero the frame pointer register
                              // I think this helps backtraces know the call stack is over
                //
                // set argc
                //
                pop RDI;      // RDI(first arg to 'main') = argc
                //
                // set argv
                //
                mov RSI,RSP;  // RSI(second arg to 'main) = argv (pointer to stack)
                //
                // set envp
                //
                mov RDX,RDI;  // first put the argc count into RDX (where envp will go)
                add RDX,1;    // add 1 to value from argc (handle one NULL pointer after argv)
                shl RDX, 3;   // multiple argc by 8 (get offset of envp)
                add RDX,RSP;  // offset this value from the current stack pointer
                //
                // prepare stack for main
                //
                add RSP,-8;   // move stack pointer below argc
                and RSP, 0xFFFFFFFFFFFFFFF8; // align stack pointer on 8-byte boundary
                call main;
                //
                // exit syscall
                //
                mov RDI, RAX;  // syscall param 1 = RAX (return value of main)
                mov RAX, 60;   // SYS_exit
                syscall;
            }
        }
        };
    }
    else static assert(0, "start not implemented for this platform");
}
