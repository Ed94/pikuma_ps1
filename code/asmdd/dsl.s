# Symbol Alias Table

# Instructions
# Load
.macro load_addr p1, p2
    la \p1, \p2
.endm
.macro load_imm p1, p2
    li \p1, \p2
.endm
.macro load_uimm p1, p2
    lui \p1, \p2
.endm
.macro load_word p1, p2
    lw \p1, \p2
.endm
# Store
.macro store_word p1, p2
    sw \p1, \p2
.endm
# Shift
.macro shift_ll p1, p2, p3
    sll \p1, \p2, \p3
.endm
.macro shift_rl p1, p2, p3
    srl \p1, \p2, \p3
.endm
.macro shift_ra p1, p2, p3
    sra \p1, \p2, \p3
.endm
# Addition
.macro add_s p1, p2, p3
    add \p1, \p2, \p3
.endm
.macro add_u p1, p2, p3
    add \p1, \p2, \p3
.endm
.macro add_si p1, p2, p3
    addi \p1, \p2, \p3
.endm
.macro add_ui p1, p2, p3
    addiu \p1, \p2, \p3
.endm
# Subtraction
.macro sub_s p1, p2, p3
    sub \p1, \p2, \p3
.endm
.macro sub_u p1, p2, p3
    subu \p1, \p2, \p3
.endm
# Multiplication

# Division
.macro div_s p1, p2
    div \p1, \p2
.endm
.macro div_u p1, p2
    divu \p1, \p2
.endm
.macro mov_from_high p1
    mfhi \p1
.endm
.macro mov_from_low p1
    mflo \p1
.endm
# Branch
.macro branch_ne_zero p1, p2
    bnez \p1, \p2
.endm
.macro branch_equal p1, p2, p3
    beq \p1, \p2, \p3
.endm
.macro branch_gt_equal p1, p2, p3
    bge \p1, \p2, \p3
.endm
.macro branch_gt p1, p2, p3
    bgt \p1, \p2, \p3
.endm
.macro branch_lt p1, p2, p3
    blt \p1, \p2, \p3
.endm
# Jump
.macro jump p1
    j \p1
.endm
.macro jump_nlink p1
    jal \p1
.endm
.macro jump_reg p1
    jr \p1
.endm
.macro jump_nreg p1
    jalr \p1
.endm

# Registers
# Stack
.equiv rstack_ptr, $sp # I have this but won't really use the alias..
# Temporaries, may be changed by subroutines
.set rtmp_0, $t0
.set rtmp_1, $t1
.set rtmp_2, $t2
.set rtmp_3, $t3
.set rtmp_4, $t4
# Static Variables
.set rstatic_0, $s0
.set rstatic_1, $s1
.set rstatic_2, $s2
.set rstatic_3, $s3
.set rstatic_4, $s4
.set rstatic_5, $s5
.set rstatic_6, $s6
.set rstatic_7, $s7
# Subroutine arguments
.set rarg_0, $a0
.set rarg_1, $a1
.set rarg_2, $a2
.set rarg_3, $a3
# Subroutine return values
.set rret_0, $v0
.set rret_1, $v1
# Subroutine return address when doing a sub
.set rret_addr, $ra

# Data Widths
.set byte, 1
.set word, 4

.macro stack_alloc amount
	add_ui $sp, - \amount
.endm

.macro stack_release amount
	add_ui $sp, \amount
.endm
