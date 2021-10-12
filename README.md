A toy OS.  Currently includes:

* an x86 bootloader
* build tools to create a bootable disk image
* a linux rootfs (would like to add support for more kernels)


Dependencies
--------------------------------------------------------------------------------
* A linux kernel image (see `Linux.md` for build instructions).
* The Zig compiler and an OS that can run the Zig compiler

Configuration
--------------------------------------------------------------------------------
Edit `config.zig` to modify the configuration.

Build
--------------------------------------------------------------------------------
```
zig build
```

This will build a bootable disk image in `zig-out/maros.img`.

Run `zig build --help` to see custom steps that can be run individually.

Test userspace tools on the host
--------------------------------------------------------------------------------
```
sudo chroot rootfs <tool>
```
Examples:
```
sudo chroot rootfs /sbin/shell
sudo chroot rootfs /sbin/init
sudo chroot rootfs /sbin/mount
```

# Resources

* small C standard library implementation: https://github.com/aligrudi/neatlibc

Bootloader Resources
--------------------------------------------------------------------------------
* x86 bios spec http://www.ctyme.com/intr/int-10.htm

TODO
--------------------------------------------------------------------------------
* get zig running in the OS, use it to build itself
* see if I can support the bsd kernel
* add programs `rm`, `strace`, `echo`
