
# Building Linux

This is a quick guide to configure/build linux.

#### Install build tools:
```
$ sudo apt install git fakeroot build-essential ncurses-dev xz-utils libssl-dev bc libelf-dev flex bison gcc make nasm
```

#### Clone the kernel repo
```
$ git clone git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git linux-stable
```

Make sure to checkout the correct commit/tag.  If you want the latest stable release you can find it by running:
```
git -C linux-stable tag -l | sort
```
once you've identified the latest release check it out using:
```
git -C linux-stable checkout <tag> -b <tag>
```

# Building with Nix

```
nix-shell -p gcc openssl libelf bc flex bison
```

### configure

```
# you can start with the default configuration like this
make -C linux-stable ARCH=x86_64 x86_64_defconfig

# OR you can start with your current host config by copying it:
cp /boot/config-$(uname -r) linux-stable/.config

# if you copied your own config, you can normalize it by running
make -C linux-stable defconfig

# To make any changes you can use the console gui (ncurses)
# by running
make -C linux-stable menuconfig

# Note: you can also use this interactive command line tool that
#       will ask you a thousand questions:
make -C linux-stable config

# there is also
make -C linux-stable xconfig
make -C linux-stable gconfig
```
* compile the kernel
```
make -C linux-stable -j$(nproc)

# note: you can run 'nproc --all' to get your core count
```

Linux Bootloaders
--------------------------------------------------------------------------------
There's 2 big bootloaders that support linux, `GRUB 2` and `syslinux`.  Linux
also provides a specification for it's boot protocol:

https://github.com/torvalds/linux/blob/master/Documentation/x86/boot.txt

I've decided to create my own bootloader since it will be simple and
educational.  It's called crystal.  It's a very "static" bootloader, however,
I think a dynamic/scriptable/recoverable/interactive bootloader would be
better in the long run.  Although, the crystal bootloader might be better
for certain applications.

https://github.com/marler8997/crystal

Resources
--------------------------------------------------------------------------------
* Linux Kernel Boot Process: https://0xax.gitbooks.io/linux-insides/content/Booting/
* Linux Disk/Filesystems: https://www.ibm.com/developerworks/library/l-lpic1-102-1/index.html
* Writing a tiny bootloader: http://joebergeron.io/posts/post_two.html
* www.linuxfromscratch.org
* Filesystem Hierarchy Standard: http://refspecs.linuxfoundation.org/fhs.shtml
* POSIX.1-2008: http://pubs.opengroup.org/onlinepubs/9699919799/
* Syscall List: http://man7.org/linux/man-pages/man2/syscalls.2.html
* Procfs overview: https://www.tldp.org/LDP/Linux-Filesystem-Hierarchy/html/proc.html
* Sysfs overview: http://man7.org/linux/man-pages/man5/sysfs.5.html
* Ioctls for console terminal and virtual consoles: http://man7.org/linux/man-pages/man4/console_ioctl.4.html