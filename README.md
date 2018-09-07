Configuration
--------------------------------------------------------------------------------
For now all the configuration is in `config.txt`.  An example is commited but
feel free to modify it to fit your needs.

Build
--------------------------------------------------------------------------------
The build script is written in D, but depends on the mar library. It assumes it
can access the repo via the "mar" folder located in the root repository. You
can clone the repo diretly here:
```bash
git clone https://github.com/marler8997/mar
```
or link to it somewhere else
```bash
ln -s <mar_repo_path> mar
```

After that you can run `./build.d` to see all the commands to build your linux
distribution.

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
add programs `rm`, `strace`, `echo`
