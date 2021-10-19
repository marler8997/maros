ENTRY(_start)
MEMORY {
    # just hardcode to 10M LENGTH for now
    load_mem (rwx) : ORIGIN = 0x100000, LENGTH = 10M
    ro_mem   (r)   : ORIGIN = 0x200000, LENGTH = 10M
}
SECTIONS {
    . = ORIGIN(load_mem);
    .bootheader ALIGN(4) : {
        KEEP(*(.bootheader))
        # NOTE: I can't seem to get the linker to
        #       put .text.start before 0x280 (like 0x274), it's like
        #       it needs to align it on a 16-byte boundary
        . = ORIGIN(load_mem) + 0x280;
        *(.text.start)
    } >load_mem
    .text : {
        *(.text*)
    }
    # TODO: should I ALIGN(4)???
    .rodata  : {
        *(.rodata*)
    } >ro_mem
}
