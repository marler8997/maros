Linux Bootloaders
--------------------------------------------------------------------------------
There's 2 big bootloaders that support linux, `GRUB 2` and `syslinux`.  Linux
also provides a specification for it's boot protocol:
https://github.com/torvalds/linux/blob/v4.16/Documentation/x86/boot.txt.

I've decided to create my own bootloader since it will be simple and
educational.  It's called crystal.  It's a very "static" bootloader, however,
I think a dynamic/scriptable/recoverable/interactive bootloader would be
better in the long run.  Although, the crystal bootloader might be better
for certain applications.
