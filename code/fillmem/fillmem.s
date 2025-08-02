.psx
.create "fillmem.bin", 0x80010000

; Entry Point of Code
.org 0x80010000

; Constant declaration
BASE_ADDR equ 0x0000

Main:
	li $t0, 0xA000 ; $t0 = 0xA000
	li $t1, 0xA0FF ; $t1 = 0xA0FF
	li $t2, 0x11   ; $t2 = 0x11

Loop:
	sb   $t2, BASE_ADDR($t0) ; $Store byte at 0x0000 + t0
	addi $t0, $t0, 1         ; ++ t0
	blt  $t0, $t1, Loop      ; while (t0 < t1) keep looping

.close
