        .code16

        // imported symbols
        .global fatal_error
        .global printf
        .global printfln
        .global read_disk

        // exported symbols
        .global second_stage

        // WARNING: this section name must begin with ".text" for it to have the right section flags
        .section .text.bootstage2
second_stage:
        mov $msg_at_stage2, %si
        call printfln

        // yay we can call into the zig code!
        mov $msg_do_zig, %si
        call do_some_zig_stuff

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
msg_do_zig: .ascii "called do_some_zig_stuff\0"

error_msg_enable_a20:                   .ascii "failed to enable a20 line\0"
error_msg_kernel_boot_version_too_old:  .ascii "kernel version too old\0"
error_msg_kernel_not_loaded_high:       .ascii "kernel LOADED_HIGH is 0\0"
error_msg_kernel_cmd_line_has_no_null_terminator: .ascii "kernel cmd line sector has no NULL terminator\0"
