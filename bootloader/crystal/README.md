The Crystal Bootloader
================================================================================

This bootloader is named "Crystal" to indicate that it is "small" and "clear".
It is meant to do the least amount possible in order to get the kernel started
and print useful information to the user.  It's not meant to be very
configurable at runtime.  Most configuration will be done at build time, so
if you need to change something, you would rebuild and reinstall it.

> Note: even the kernel command line is not configurable, you can change it
>       by recompiling/reinstalling crystal

At some point I will likely attempt to write a new bootloader that is more
configurable.  I think it will work more like a shell, where the high level
operations are "scripted" and can be done manually or changed at runtime. This
means that a user can use the bootloader itself to recover itself, rather than
having to modify it from another machine. But this one should work well for now.

Crystal expects the first 16 sectors of the disk to be reserved for it and
expects the kernel to immediately follow it.  Crystal should fit within 16
sectors (8192 bytes), which means that you don't have to shift the contents
of the disk if you rebuild Crystal with more features.

## How to debug the bootloader

* make sure you assemble your bootloader with a list file (`nasm -l <listfile>`)
* start the emulator in bochs
* you'll get a prompt, set the breakpoint to the line of code you want to break at.
```
> lb <address>
```
The bootloader will be loaded at address `0x7c00` so to get to any line of the bootloader you will add its offset to this address.  For example, if you want to break at the bootloader at offset 0x99, you would invoke:
```
> lb 0x7c99
```
* continue to the breakpoint
```
> c
```
* you can now debug, here's some common debug commands
```
> n # go to the next instruction (do not follow calls)
> s # step to the next instruction (do follow calls)
> r # print registers
> sreg # print segment registers
> x <addr> # print memory at <addr>
> x /<count><format><size> <addr> # print non-default memory at addr
      # i.e. print 10 hex bytes at address 0x7c10: "x /10xb 0x7c10"
```
