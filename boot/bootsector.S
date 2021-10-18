//
// NOTE: linux boot protocol can be found here:
//
//  https://github.com/torvalds/linux/blob/master/Documentation/x86/boot.rst
//
// Bootloader Memory Map
// ------------------------------------------------------------------------------
// offset  | limit  | size              | Description
// ------------------------------------------------------------------------------
//         | 0x7c00 |                   | The stack (grows down from 0x7c00)
// 0x7c00  | 0x7e00 | 0x0200 (512)      | Bootsector load address
// 0x7e00  | 0x9c00 | 0x1e00 (512 * 15) | Stage 2 load address
// 0x9c00  | 0x9e00 | 0x0200 (512)      | Kernel command line load address
// 0x9e00  | 0xa000 | 0x0200 (512)      | Initrd info load address
// ...
// 0x10000 |        |                   | The location where kernel setup code is loaded (not sure why)
// 0x20000 |        |                   | Temporary location to load kernel before copying to highmove_addr
// 0x100000|        |                   | Location where kernel is loaded (variable highmove_addr)
//                                        Note that it is not loaded here directly, it is loaded
//                                        to address 0x20000 and then moved here as it is read from disk.
//
.code16

// imported symbols
.global bootloader_stage2_sector_count
.global ax_fmt
.global cx_fmt
.global dx_fmt
.global bx_fmt

// exported symbols
.global _start
.global fatal_error
.global printf
.global printfln
.global read_disk

bootloader_reserve_sector_count = 16

// WARNING: this section name must begin with ".text" for it to have the right section flags
.section .text.bootsector

_start:
        // initialize segments and stack
        xor %ax, %ax
        mov %ax, %ds
        mov %ax, %ss
        mov $0x7c00, %esp         // the stack grows down so we put it just below the bootloader
                                  // so it won't overwrite it

        mov %dl, boot_disk_num // save the boot disk number (used in the read_disk function)

        // print start message
        and $0xFF, %dx
        mov $bootloader_stage2_sector_count, %ax
        mov $msg_started_dx_ax, %si
        call printfln

        // ax already contains the sector count
        mov $.msg_loading_stage2_ax, %si
        call printfln

        // read in the rest of the bootloader
        // ax already contains the sector count
        mov $0x00007e00, %ebx  // dest 0xssss_oooo s=segment, o=offset
        call read_disk

        // TODO: get rid of bootloader_reserve_sector_count
        //       just put everything in the sector based on the bootloader size
        movl $bootloader_reserve_sector_count, .next_sector

        jmp second_stage
    msg_started_dx_ax:
        .ascii "maros bootloader v0.0 (drive=%"
        .byte dx_fmt
        .ascii ", size=%"
        .byte ax_fmt
        .ascii ")\0"

    .msg_loading_stage2_ax:
        .ascii "loading stage 2 (%"
        .byte ax_fmt
        .ascii " sectors)\0"
read_disk:
        push %eax
        push %edx
        mov %ax, .sector_count                   // populate extra arguments
        mov %ebx, .dest_segment_and_offset
        mov .next_sector, %edx
        movl %edx, .src_lba
        and $0xffff, %eax                        // increment .next_sector
        add %eax, %edx
        mov %edx, .next_sector
        // call bios "extended read"
        mov $0x42, %ah                           // method 0x42
        mov $.disk_address_packet, %si
        mov boot_disk_num, %dl                   // read from the boot disk
        int $0x13
        mov $.error_msg_ax, %si                   // set error message in case we failed
        shr $8, %ax                              // set the error code in ah to ax so it can
                                                 // be included in the error message
        jc fatal_error
        pop %edx
        pop %eax
        ret
    .next_sector: // static counter variable that tracks the next sector to read
        // TODO: make the initial value configurable?
        .long 1 // start at sector 1
    .disk_address_packet:
        .byte 0x10 // size of the packet
        .byte    0 // reserved
    .sector_count:
        .word 0
    .dest_segment_and_offset:
        .long 0
    .src_lba:
        .quad 0  // lba
    .error_msg_ax:
        .ascii "read_disk failed (e=%"
        .byte ax_fmt
        .ascii ")\0"

        // TODO: remove this, just temporary to align next instructions
        .byte 0
print_ecx_hex_with_prefix:
        push %si
        mov $hex_prefix, %si
        call printf
        pop %si
print_ecx_hex:
        // input: ecx = value to print
        push %ecx
        pusha
        mov %sp, %ax          // save stack pointer to restore it at the end
        dec %sp               // push terminating null onto stack
        movb $0, (%esp)
    .print_ecx_hex_loop:
        mov %cl, %bl
        and $0xf, %bl
        cmp $0xa, %bl
        jl .is_decimal
        add $7, %bl           // add offset to print 'a-f' instead of '0-9'
    .is_decimal:
        add $'0', %bl          // convert hex value to hex digit
        dec %sp               // push char
        mov %bl, (%esp)
        shr $4, %ecx
        cmp $0, %ecx
        jnz .print_ecx_hex_loop
        mov %sp, %si
        call printf
        mov %ax, %sp
        popa
        pop %ecx
        ret
    hex_prefix: .ascii "0x\0"
printfln:
        call printf
print_newline:
        push %si
        mov $.newline, %si
        call printf
        pop %si
        ret
    .newline:
        .ascii "\r\n\0"
printf:
        // input: si points to address of null-terminated string
        // TODO: what do I set bh = page number to? 0?
        pushal
        mov $0x0e, %ah               // Argument for interrupt 10 which says to
                                     // print the character in al to the screen
    .next_char:
        lodsb                        // load next byte from memory pointed to by si
                                     // into al and increment si
        cmp $'%', %al
        jne .not_format_spec
        lodsb
        cmp $'e', %al
        jne .not_32_bit
        lodsb                        // it is a 32-bit value
        mov $0xFFFFFFFF, %ebx
        jmp .print_reg
    .not_32_bit:
        mov $0xFFFF, %ebx
    .print_reg:
        // the value in al should represent one of the <reg>_fmt value
        // which represent the register's offset in the stack after
        // executing pushad
        xor %edx,% edx                         // zero edx
        mov %al, %dl                           // set edx to the register's stack offset
        add %sp, %dx                           // add stack to edx
        mov (%edx), %ecx                       // read the register value from the stack
        and %ebx, %ecx                         // mask the value (if we're not printing 32-bit)
        call print_ecx_hex_with_prefix
        jmp .next_char
    .not_format_spec:
        cmp $0, %al
        je .printf_done          // If char is zero, end of string
    .print_al:
        int $0x10                        // Otherwise, print it
        jmp .next_char
    .printf_done:
        //pop ecx
        //pop ebx
        //pop eax
        popal
        ret
fatal_error:
        // input: si points to address of null-terminated error message
        push %si
        mov $.prefix, %si
        call printf
        pop %si
        call printfln
        cli
        hlt
    .prefix: .ascii "fatal error: \0"
dev_break:
        mov $.msg, %si
        call printfln
        cli
        hlt
    .msg: .ascii "dev break\0"

boot_disk_num: .byte 0

        .fill 446-(. - _start), 1, 0xbb // padding up to the MBR partition table
        .fill 510-(. - _start), 1, 0xcc // special value so you can see where the partition table is
        .byte 0x55
        .byte 0xaa
