ENTRY(_start)
MEMORY {
    ram (rwx) : ORIGIN = 0x7c00, LENGTH = 512 * 16
}

# These values are based on the offset the register will be stored
# after running pushad
ax_fmt = 28;
cx_fmt = 24;
dx_fmt = 20;
bx_fmt = 16;

SECTIONS {
    bootloader_stage2_len = SIZEOF(bootloader) - 512;
    bootloader_stage2_sector_count = (bootloader_stage2_len + 511) / 512;

    . = ORIGIN(ram);
    bootloader : {
        # include the zigbootsector first if it exsts
        *zigbootsector.o(.text.start)
        *zigbootsector.o(.text)
        *zigbootsector.o(.bss)
        *zigbootsector.o(.rodata*)

        # otherwise, we'll use the normal bootsector
        *asmbootsector.o(.text)

        # the stage2 bootloader is loaded at address 0x7e00 by the bootsector code
        . = 0x7e00;
        *(.text.bootstage2)
        *(.text.zigboot)
        *(.rodata*)
    }
}
