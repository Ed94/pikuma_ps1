.psx
.create "factorial.bin", 0x80010000

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
; Subtraction
sub_s equ sub    ; 
sub_u equ subu   ; 
; Branch
branch_equal    equ beq ; reg, value(reg, immediate), dst_label
branch_gt_equal equ bge ; reg, value(reg, immediate), dst_label
branch_gt       equ bgt ; reg, value(reg, immediate), dst_label
branch_lt       equ blt ; reg, value(reg, immediate), dst_label
; Jump
jump       equ j   ; address:    immediate
jump_nlink equ jal ; subroutine: immeidate
jump_reg   equ jr  ; address:    register
jump_nreg  equ jrl ; subroutine: register

; Registers
; Temporaries, may be changed by subroutines
rtmp_0 equ $t0
rtmp_1 equ $t1
rtmp_2 equ $t2
rtmp_3 equ $t3
rtmp_4 equ $t4
; Subroutine arguments
rarg_0 equ $a0
rarg_1 equ $a1
rarg_2 equ $a2
rarg_3 equ $a3
; Subroutine return values
rret_0 equ $v0
rret_1 equ $v1

main:
		li rarg_0, 5
	jump_nlink factorial

; args:
;	num: rarg_0
.func factorial
num        equ rarg_0
id_term    equ rtmp_0
id_product equ rtmp_1
term       equ rtmp_2
sum        equ rtmp_3
	li term,    1
	li sum,     1
	li id_term, 1
	loop_term: branch_gt id_term, num, break_loop_term :: nop
		li sum,        0
		li id_product, 0
		loop_prod: branch_gt_equal id_product, id_term, break_loop_prod :: nop
			add_s  sum,        sum,        term
			add_si id_product, id_product, 1
		jump loop_prod :: nop :: break_loop_prod:
		move   term,    sum
		add_si id_term, id_term, 1
	jump loop_term :: nop :: break_loop_term:
	move rret_0, sum
.endfunc	

.close
