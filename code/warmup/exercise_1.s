.psx
.create "exercise_1.bin", 0x80010000

; Entry Point of Code
.org 0x80010000

; Constant declaration
BASE_ADDR equ 0x0000

; Symbol Alias Table

; Instructions
load_imm   equ li ; dst_reg, immeidate value
store_word equ sw ; src_reg, dst_address 

; Registers
rtemp_0 equ $t0
rtemp_1 equ $t1
rtemp_2 equ $t2

main:
	; TODO:
	;	1. Load $t0 with the immediate decimal value of 1
	;	2. Load $t1 with the immediate decimal value of 256
	;	3. Load $t2 with the immediate decimal value of 17

	; Attempt:
	load_imm rtemp_0, 1
	load_imm rtemp_1, 256
	load_imm rtemp_2, 17
end:
.close
