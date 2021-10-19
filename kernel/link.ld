ENTRY(_start)
MEMORY {
    # just hardcode to 10M LENGTH for now
    load_mem (rwx) : ORIGIN = 0x100000, LENGTH = 10M
    ro_mem   (r)   : ORIGIN = 0x200000, LENGTH = 10M
}
SECTIONS {
    . = ORIGIN(load_mem);
    .bootheader ORIGIN(load_mem) : {
        KEEP(*(.bootheader))
    } >load_mem
    .text : {
        *(.text*)
    }
    # TODO: should I ALIGN(4)???
    .rodata  : {
        *(.rodata*)
    } >ro_mem
}
