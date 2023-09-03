org 0x0
bits 16


%define ENDL 0x0D, 0x0A


start:
    mov si, msg
    call print

.halt:
    cli
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


msg: db 'Hello World from Kernel!', ENDL, 0