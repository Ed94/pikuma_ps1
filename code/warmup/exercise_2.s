.psx
.create "exercise_2.bin", 0x80010000

; Entry Point of Code
.org 0x80010000

; Constant declaration
BASE_ADDR equ 0x0000

; Symbol Alias Table

; Instructions
; Load
load_imm   equ li ; dst_reg, immeidate value
; Store
store_word equ sw ; src_reg, dst_address 
; Addition
add_s  equ add   ; dst_reg, reg_a, reg_b (signed)
add_u  equ add   ; dst_reg, reg_a, reg_b (unsigned)
add_si equ addi  ; dst_reg, src_reg, immediate value (signed)
add_ui equ addiu ; dst_reg, src_reg, immediate value (unsigned)
; Branch
branch_equal    equ beq ; reg, value(reg, immediate), dst_label
branch_lt_equal equ ble ; reg, value(reg, immediate), dst_label

; Registers
; Temporaries, may be changed by subroutines
rtemp_0 equ $t0
rtemp_1 equ $t1
rtemp_2 equ $t2

main:
	; TODO:
	;	1. Start $t0 with the value 1 and $t1 with the value 0
	;	2. Loop, incrementing $t0 until it reaches the value 10
	;	3. Keep adding and accumulating all values of $t0 inside $t1

	; Attempt:
	load_imm rtemp_0, 1
	; load_imm rtemp_1, 0
	move     rtemp_1, $zero
loop:
	add_s  rtemp_1, rtemp_1, rtemp_0
	add_si rtemp_0, rtemp_0, 1
	branch_lt_equal rtemp_0, 10, loop
	nop
	; branch_equal rtemp_0, 10, end
	; nop
	; j            loop
end:
.close
