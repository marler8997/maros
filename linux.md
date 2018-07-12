
# Building Linux

This is a quick guide to configure/build linux.

All the tools to build linux should have been installed when you ran:
```
./build.d installTools
```

`build.d` can also automatically clone the kernel if it is configured:
```
./build.d cloneKernel
```

Make srue to checkout the correct commit/tag.  If you want the latest stable release you can find it by running:
```
git tag -l | less
```
once you've identified the latest release check it out using:
```
git checkout <tag> -b <tag>
```

### configure
from inside the linux repo:
```
# You can start with your current host config by copying it:
cp /boot/config-$(uname -r) .config

# after copying this config, you can normalize it by running
make defconfig

# To make any changes you can use the console gui (ncurses)
# by running
make menuconfig

# Note: you can also use this interactive command line tool that
#       will ask you a thousand questions:
make config

# there is also
make xconfig
make gconfig
```
* compile the kernel
```
make -j<cores-to-use>

# note: you can run 'nproc --all' to get your core count
```

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