const buildconfig = @import("buildconfig.zig");
const Config = buildconfig.Config;
const sizeFromStr = buildconfig.sizeFromStr;

pub fn makeConfig() !Config {
    return Config {
        // TODO: make kernel configurable, i.e.
        // kernel linux
        // kernel someOtherKernel...
        // kernel linuxStable
        // kernel linux3.2
        //.kernelPath = "linux_stable",
        //.kernelRepo = "git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git",
        .kernel_image = "linux_stable/arch/x86/boot/bzImage",

        .kernelCommandLine = "root=/dev/sda1 console=ttyS0",
        //.kernelCommandLine = "root=/dev/sda1",
    
        //.imageFile = "maros.img",
    
        //.sectorSize = buildconfig.sizeFromStr("512B"),
        .imageSize = buildconfig.sizeFromStr("18M"),
        .rootfsPart = .{
            .fstype = "ext4",
            .size = buildconfig.sizeFromStr("5M"),
        },
        .swapSize = buildconfig.sizeFromStr("1M"),
    
        .combine_tools = true,
    };
}
