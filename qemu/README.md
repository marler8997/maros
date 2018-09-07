Using QEMU
--------------------------------------------------------------------------------

### Install qemu
```
sudo apt-get install qemu
```
### Create Virtual Machine

Create a hard disk image
```
qemu-img create <image_file> <size>

# example
qemu-img create disk.img 20G
```

Install an OS using a CD
```
qemu-system-x86_64 -m <ram_size_megs> -hda <image_file> -boot d -cdrom <cd_image_file>
```

### Start the machine

```
qemu-system-x86_64 -m <ram_size_megs> -hda <image_file>
```
