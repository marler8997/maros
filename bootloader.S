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
.global _start

bootloader_reserve_sector_count = 16
bootloader_size = bootloader_end - _start

// These values are based on the offset the register will be stored
// after running pushad
ax_fmt = 28
cx_fmt = 24
dx_fmt = 20
bx_fmt = 16

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
        mov $bootloader_size, %ax
        mov $.msg_started_dx_ax, %si
        call printfln

        // calculate extra sector count to read
        // todo: can I calculate this at compile time?
        mov $bootloader_size - 512, %ax
        mov %ax, %bx
        shr $9, %ax      // divide by 512
        and $0x01ff, %bx // get remainder
        cmp $0, %bx
        jz .skip_add_sector
        inc %ax
    .skip_add_sector:
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
    .msg_started_dx_ax:
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

        // this line ensures the boot sector code doesn't spill into
        // the partition table of the MBR
        .fill 446-(. - _start), 1, 0
        .fill 510-(. - _start), 1, 0xcc // special value so you can see where the partition table is
        .byte 0x55
        .byte 0xaa
////////////////////////////////////////////////////////////////////////////////
// 2nd stage bootloader
////////////////////////////////////////////////////////////////////////////////
second_stage:
        mov $msg_at_stage2, %si
        call printfln

        // read the kernel command line sector
        mov $1, %ax             // sector_count
        mov $0x00009c00, %ebx  // dest 0xssss_oooo s=segment o=offset
        call read_disk

        //
        // read kernel command line
        //
        xor %bx, %bx   // zero out the counter
        .next_cmd_line_char:
        cmpb $0, 0x9c00(%bx)
        jz .found_cmd_line_null
        inc %bx
        mov $error_msg_kernel_cmd_line_has_no_null_terminator, %si
        cmp $512, %bx
        je fatal_error
        jmp .next_cmd_line_char
      .found_cmd_line_null:
        mov %bx, kernel_cmd_line_size
        // print the kernel command line
        mov $msg_kernel_cmd_line_prefix_bx, %si
        call printf
        mov $0x9c00, %si
        call printf
        mov $msg_kernel_cmd_line_suffix, %si
        call printfln

        //
        //  get into protected mode so we can setup "unreal" mode
        //  to access 32-addresses and load the kernel
        //
        mov $0x2401, %ax         // enable A20 line
        int $0x15
        mov $error_msg_enable_a20, %si
        jc fatal_error

        lgdt gdt_register_value    // load the global descriptor table
        mov %cr0, %eax             // enable protected mode bit in control register
        // NOTE: do not modify eax until after 'back_to_real_mode'
        or $1, %eax
        mov %eax, %cr0
        // jmp $+2                // WHAT DOES THIS DO???
        mov $0x8, %bx // first descriptor in GDT
        mov %bx, %ds
        mov %bx, %es
        mov %bx, %gs
        and $0xfe, %al // 'back_to_real_mode'
        mov %eax, %cr0 // disable protected mode bit in control register

        // restore segments registers
        xor %ax, %ax
        mov %ax, %ds
        mov %ax, %gs
        mov $0x1000, %ax // set es to segment for kernel (starts being used below at "read kernel setup sectors")
        mov %ax, %es
        sti

        //
        // now in "unreal" mode
        //

        // read the first sector of the kernel which tells us how many
        // sectors to read for the rest of the kernel setup memory
        mov $1, %ax            // sector_count
        mov $0x10000000, %ebx // dest 0xssss_oooo s=segment o=offset
        call read_disk

        //
        // read kernel setup sectors
        //
        xor %ah, %ah                     // zero ah so when we print ax it only shows al
        mov %es:0x1f1, %al               // kernel setup size
        mov $msg_kernel_setup_sector_count_ax, %si // print the size
        call printfln

        // default to 4 sectors if we got a value of 0
        cmp $0, %ax
        jne .skip_set_to_4
        mov $4, %ax
    .skip_set_to_4:
        mov $0x10000200, %ebx     // dest 0xssss_oooo s=segment, o=offset
        call read_disk

        //
        // verify kernel boot version is >= 2.04
        //
        mov %es:0x206, %dx
        mov $msg_kernel_boot_version_dx, %si
        call printfln
        mov $error_msg_kernel_boot_version_too_old, %si
        cmp $0x204, %dx
        jb fatal_error

        //
        // TODO: check that the cmd_line_size is <= the maximum
        //       command line size defined in the kernel which
        //       would be found at es:0x238 (cmdline_size)
        //       something like
        //       mv si, error_msg.kernel_cmd_line_too_big_az
        //       mov ax, [es:0x238]
        //       cmp [kernel_cmd_line_size], ax
        //       jg fatal_error

        //
        // check kernel loadflags to make sure LOADED_HIGH is true
        //
        mov $error_msg_kernel_not_loaded_high, %si
        testb $0x1, %es:0x211
        jz fatal_error
        // pass information to kernel
        movb  $0xe1,    %es:0x210   // 0xTV T=loader_type V=version
        movb  $0x80,    %es:0x211   // heap use? !! set bit5 to make kernel quiet
        movw  $0xde00,  %es:0x224   // heap_end_ptr
        movb  $0x01,    %es:0x227   // ext_loader_type / bootloader id
        movl  $0x1e000, %es:0x228   // cmd line ptr

        // copy cmd line
        mov $0x9c00, %si  // kernel command line address
        mov $0xe000, %di
        mov kernel_cmd_line_size, %cx
        rep movsb                       // copy from DS:si to ES:di

        // load_kernel
        mov %es:0x1f4, %edx             // syssize (size of protected-mode code in 16-byte paragraphs)
        shl $4, %edx                    // convert to bytes
        mov $msg_loading_kernel_edx, %si
        call printfln
        call loader_length_in_edx

        // read initrd size
        mov $1, %ax            // sector count
        mov $0x0000a000, %ebx  // dest 0xssss_oooo s=segment o=offset
        call read_disk

        mov 0xa000, %edx              // get initrd size
        mov $msg_loading_initrd_edx, %si
        call printfln
        mov %edx, %es:0x21c            // tell kernel how big initrd is

        // method 1 (load initrd right after the kernel)
        //mov eax, [highmove_addr]      // get the next load address, where initrd will be loaded
        // method 2 (load initrd at this predefined address, qemu loads it here)
        mov $0x7fab000, %eax
        mov %eax, highmove_addr        // tell loader to load initrd here
        // end of methods
        mov %eax, %es:0x218            // tell the kernel where the initrd lives
        call loader_length_in_edx

// start the kernel
        mov $msg_jumping_to_kernel, %si
        call printfln
        cli
        mov $0x1000, %ax
        mov %ax, %ds
        mov %ax, %es
        mov %ax, %fs
        mov %ax, %gs
        mov %ax, %ss
        mov $0xe000, %sp
        ljmp $0x1020,$0
// spin forever (I think I can just remove this)
        jmp .

loader_length_in_edx:
    .loader_length_in_edx_loop:
        //mov si, .msg_size_left    ; print progress
        //call printfln
        cmp $512 * 127, %edx
        jl .read_last_part
    .read_127_sectors:
        mov $127, %ax
        mov $0x20000000, %ebx // 0xssss_oooo s=segment o=offset
        call read_disk
        call highmove
        sub $512 * 127, %edx
        jmp .loader_length_in_edx_loop
    .read_last_part:
        jz .done
        shr $9, %edx // divide by 512
        inc %edx      // increase by one in case it wasn't divisible by 512, loading more junk sectors is OK
        mov %dx, %ax
        mov $0x20000000, %ebx // 0xssss_oooo s=segment o=offset
        call read_disk
        call highmove
    .done:
        ret
    .msg_size_left: .ascii "%e"
                    .byte  dx_fmt
                    .ascii " bytes left to read...\0"

// Move 127 sectors at address 0x20000 to the next address at highmove_addr
// source = 0x20000
// count = 512 * 127 fixed (note, copying junk at the end doesn't matter)
// don't think we can use rep movsb here as it won't use edi/esi in unreal mode
highmove_addr: .int 0x100000
highmove:
        pushal
        mov $0x20000, %esi
        mov highmove_addr, %edi
        mov $512 * 127, %edx
        mov $0, %ecx                  // pointer
    .highmove_loop:
        mov %ds:(%esi), %eax
        mov %eax, %ds:(%edi)
        add $4, %esi
        add $4, %edi
        sub $4, %edx
        jnz .highmove_loop
        mov %edi, highmove_addr
        popal
        ret

////////////////////////////////////////////////////////////////////////////////
gdt_register_value:
        .word gdt_end - gdt - 1
        .long gdt
gdt:
        .quad 0          // first entry 0
        // flat data segment
        .word 0xffff     // limit[0:15] (4gb)
        .word 0          // base[0:15]
        .byte 0          // base[16:23]
        .byte 0b10010010 // access byte
        .byte 0b11001111 // [7..4]=flage [3..0] = limit[16:19]
        .byte 0          // base[24:31]
gdt_end:
////////////////////////////////////////////////////////////////////////////////

kernel_cmd_line_size: .word 0

msg_at_stage2:                    .ascii "at stage 2\0"
msg_kernel_cmd_line_prefix_bx:    .ascii "kernel cmd line (%"
                                  .byte  bx_fmt
                                  .ascii " bytes) '\0"
msg_kernel_cmd_line_suffix:       .ascii "'\0"
msg_kernel_setup_sector_count_ax: .ascii "kernel setup sector count: %"
                                  .byte  ax_fmt
                                  .byte  0
msg_kernel_boot_version_dx:       .ascii "kernel boot version: %"
                                  .byte  dx_fmt
                                  .byte  0
msg_loading_kernel_edx:           .ascii "loading kernel (%e"
                                  .byte  dx_fmt
                                  .ascii " bytes)...\0"
msg_loading_initrd_edx:           .ascii "loading initrd (%e"
                                  .byte  dx_fmt
                                  .ascii " bytes)...\0"
msg_jumping_to_kernel:            .ascii "jumping to kernel\0"

error_msg_enable_a20:                   .ascii "failed to enable a20 line\0"
error_msg_kernel_boot_version_too_old:  .ascii "kernel version too old\0"
error_msg_kernel_not_loaded_high:       .ascii "kernel LOADED_HIGH is 0\0"
error_msg_kernel_cmd_line_has_no_null_terminator: .ascii "kernel cmd line sector has no NULL terminator\0"

bootloader_end:
