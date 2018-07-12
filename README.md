
TODO: add some info here

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
see if I can support the bsd kernel
