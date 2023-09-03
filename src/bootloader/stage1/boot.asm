org 0x7C00
bits 16


%define ENDL 0x0D, 0x0A


;
; FAT12 header
;
jmp short start
nop

; oem identifier
bdb_oem:                    db 'MSWIN4.1'           ; 8 bytes (MSWIN4.1 for compatibility)
bdb_bytes_per_sector:       dw 512
bdb_sectors_per_cluster:    db 1
bdb_reserved_sectors:       dw 1
bdb_fat_count:              db 2
bdb_dir_entries_count:      dw 0E0h
bdb_total_sectors:          dw 2880                 ; 2880 * 512 = 1.44MB
bdb_media_descriptor_type:  db 0F0h                 ; F0 = 3.5" floppy disk
bdb_sectors_per_fat:        dw 9                    ; 9 sectors/fat
bdb_sectors_per_track:      dw 18
bdb_heads:                  dw 2
bdb_hidden_sectors:         dd 0
bdb_large_sector_count:     dd 0

; extended boot record
ebr_drive_number:           db 0                    ; 0x00 floppy, 0x80 hdd (useless)
                            db 0                    ; reserved
ebr_signature:              db 29h
ebr_volume_id:              db 12h, 34h, 56h, 78h   ; serial number, value doesn't matter
ebr_volume_label:           db 'MOS        '        ; 11 bytes, padded with spaces
ebr_system_id:              db 'FAT12   '           ; 8 bytes


;
; Code
;

start:
    ; setup data segments
    mov ax, 0                       ; you cannot write to ds/es directly
    mov ds, ax
    mov es, ax

    ; setup stack
    mov ss, ax
    mov sp, 0x7C00                  ; stack grows down (FIFO)

    ; since some BIOSes start the boot sector at 0x7C00:0000 instead of 0x0000:7C00, we need to make sure we are in the expected location
    push es
    push word .after
    retf

.after:
    ; read something from floppy
    mov [ebr_drive_number], dl

    mov si, booting_msg
    call print

    ; read drive parameters (sectors per track and head count) instead of relying on data on formatted disk
    push es
    mov ah, 08h
    int 13h
    jc floppy_error
    pop es

    and cl, 0x3F                    ; remove 2 bits
    xor ch, ch
    mov [bdb_sectors_per_track], cx ; sector count

    inc dh
    mov [bdb_heads], dh             ; head count

    ; compute LBA of root directory = reserved + fats * sectors_per_fat (can be hardcoded)
    mov ax, [bdb_sectors_per_fat]
    mov bl, [bdb_fat_count]
    xor bh, bh
    mul bx                          ; ax = (fats * sectors_per_fat)
    add ax, [bdb_reserved_sectors]  ; ax = LBA of root directory
    push ax

    ; compute size of root directory = (32 * number_of_entries) / bytes_per_sector
    mov ax, [bdb_dir_entries_count]
    shl ax, 5                       ; ax *= 32
    xor dx, dx                      ; dx = 0
    div word [bdb_bytes_per_sector] ; number of sectors to read

    test dx, dx                     ; if dx != 0, add 1
    jz .root_dir_after
    inc ax                          ; it's used when the sector is partially filled

.root_dir_after:
    ; read root directory
    mov cl, al                      ; cl = number of sectors to read = size of root directory
    pop ax                          ; ax = LBA of root directory
    mov dl, [ebr_drive_number]      ; dl = drive number
    mov bx, buffer                  ; es:bx = buffer
    call disk_read

    ; search for stage2 file
    xor bx, bx
    mov di, buffer

.search_stage2:
    mov si, file_stage2_bin
    mov cx, 11                      ; compare 11 bytes
    push di
    repe cmpsb
    pop di
    je .found_stage2

    add di, 32
    inc bx
    cmp bx, [bdb_dir_entries_count]
    jl .search_stage2

    jmp stage2_not_found            ; stage2 not found

.found_stage2:
    mov ax, [di + 26]               ; first logical cluster field (offset 26), di should have the address to the entry
    mov [stage2_cluster], ax

    ; load FAT from disk into memory
    mov ax, [bdb_reserved_sectors]
    mov bx, buffer
    mov cl, [bdb_sectors_per_fat]
    mov dl, [ebr_drive_number]
    call disk_read

    ; read stage2 and process FAT chain
    mov bx, STAGE2_LOAD_SEGMENT
    mov es, bx
    mov bx, STAGE2_LOAD_OFFSET

.load_stage2_loop:
    ; read next cluster
    mov ax, [stage2_cluster]

    add ax, 31                      ; first cluster = (stage2_cluster - 2) * sectors_per_cluster + start_sector, start_sector = reserved + fats + root dir size = 1 + 18 + 134 = 33 (not nice because hardcoded)
    mov cl, 1
    mov dl, [ebr_drive_number]
    call disk_read

    add bx, [bdb_bytes_per_sector]  ; this will overflow if the stage2.bin is larger than 64KB

    ; compute location of next cluster
    mov ax, [stage2_cluster]
    mov cx, 3
    mul cx
    mov cx, 2
    div cx                          ; ax = index of entry in FAT, dx = cluster mod 2

    mov si, buffer
    add si, ax
    mov ax, [ds:si]                 ; read entry from FAT table at index ax

    or dx, dx
    jz .even

.odd:
    shr ax, 4
    jmp .next_cluster_after

.even:
    and ax, 0x0FFF

.next_cluster_after:
    cmp ax, 0x0FF8                  ; end of chain
    jae .read_finish

    mov [stage2_cluster], ax
    jmp .load_stage2_loop

.read_finish:
    ; jump to stage2
    mov dl, [ebr_drive_number]      ; boot device in dl

    mov ax, STAGE2_LOAD_SEGMENT     ; set segment registers
    mov ds, ax
    mov es, ax
    
    jmp STAGE2_LOAD_SEGMENT:STAGE2_LOAD_OFFSET

    jmp wait_key_and_reboot         ; should never happen
    cli
    hlt


;
; Error handlers
;

floppy_error:
    mov si, floppy_error_msg
    call print
    jmp wait_key_and_reboot


stage2_not_found:
    mov si, stage2_not_found_msg
    call print
    jmp wait_key_and_reboot


;
; Utility routines
;

wait_key_and_reboot:
    mov ah, 0
    int 16h                 ; wait for key press
    jmp 0FFFFh:0            ; reboot


.halt:
    cli                     ; disable interrupts
    hlt


;
; Print a string to the screen
; Parameters:
;   - ds:si - pointer to the string
;
print:
    push si
    push ax
    push bx

.loop:
    lodsb                   ; load character in al
    or al, al               ; check if al is null
    jz .done                ; if null, jump to done

    mov ah, 0x0E            ; teletype output
    mov bh, 0               ; page number
    int 0x10                ; print character

    jmp .loop

.done:
    pop bx
    pop ax
    pop si
    ret



;
; Disk routines
;

;
; Converts an LBA address to a CHS address
; Parameters:
;   - ax: LBA address
; Returns:
;   - cx [bits 0-5]: sector number
;   - cx [bits 6-15]: cylinder
;   - dh: head
;
lba_to_chs:
    push ax
    push dx

    xor dx, dx                          ; dx = 0
    div word [bdb_sectors_per_track]    ; ax = LBA / sectors_per_track, dx = LBA % sectors_per_track

    inc dx                              ; dx = (LBA % sectors_per_track) + 1 -> sector
    mov cx, dx                          ; cx = sector

    xor dx, dx                          ; dx = 0
    div word [bdb_heads]                ; ax = LBA / heads -> cylinder, dx = LBA % heads -> head

    mov dh, dl                          ; dh = head
    mov ch, al                          ; ch = cylinder (lower 8 bits)
    shl ah, 6
    or cl, ah                           ; cl = cylinder (upper 2 bits)

    pop ax
    mov dl, al                          ; restore dl
    pop ax
    ret


;
; Reads sectors from a disk
; Parameters:
;   - ax: LBA address
;   - cl: number of sectors to read (up to 128)
;   - dl: drive number
;   - es:bx: memory address where to store read data
;
disk_read:
    push ax
    push bx
    push cx
    push dx
    push di

    push cx                        ; to temporarily save cl (number of sectors to read)
    call lba_to_chs                ; convert LBA to CHS
    pop ax                         ; al = number of sectors to read

    mov ah, 02h
    mov di, 3                      ; retry counter


.retry:
    pusha                          ; save all registers to the stack (we don't know what bios modifies)
    stc                            ; set carry flag (error flag)
    int 13h                        ; read sectors (carry flag cleared if success)
    jnc .done                      ; if success, jump to done

    popa
    call disk_reset

    dec di
    test di, di                     ; if di != 0 loop
    jnz .retry


.fail:
    jmp floppy_error


.done:
    popa
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret


;
; Resets disk controller
; Parameters:
;   dl: drive number
;
disk_reset:
    pusha
    mov ah, 0
    stc
    int 13h
    jc floppy_error
    popa
    ret



booting_msg:                    db 'Booting MOS...', ENDL, 0
floppy_error_msg:               db 'Read from disk failed!', ENDL, 0
stage2_not_found_msg:           db 'BootloaderS2 not found!', ENDL, 0

file_stage2_bin:                db 'BOOTS2  BIN'
stage2_cluster:                 dw 0

STAGE2_LOAD_SEGMENT             equ 0x2000
STAGE2_LOAD_OFFSET              equ 0

times 510-($-$$) db 0
dw 0AA55h

buffer: