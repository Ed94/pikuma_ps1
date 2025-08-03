; Symbol Alias Table

; Instructions
; Load
load_imm   equ li  ; dst_reg, immeidate value (signed)
load_uimm  equ lui ; dst_reg, immediate value (unsigned)
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
; Subroutine return address when doing a sub
rret_addr equ $ra