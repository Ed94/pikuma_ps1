#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
# include "gcc_asm.h"
#endif

/* ============================================================================
 *  REGISTER INTEGER IDS (preprocessor-visible)
 * ============================================================================
 *  Every R_* enum below has a parallel R_*_Code `#define` so that the
 *  preprocessor can stringify the integer (e.g. for asm clobber lists and
 *  register-variable declarations via `rgcc(R_X)`). The enum value is
 *  bound to the `#define` so the two forms cannot drift apart.
 *
 *  Only registers that get stringified need a `_Code` form; the rest are
 *  plain enum values. If you need to add a new one, follow the pattern:
 *      #define R_T7_Code 15
 *      R_T7 = R_T7_Code,        // in the enum
 *
 *  User code should always reference the enum form (`R_T4`) at arithmetic
 *  sites and let `reg_str(R_T4_Code)` / `rgcc(R_T4)` handle the stringify
 *  cases — never write the bare number `12`.
 * ============================================================================ */
#define R_0_Code    0
#define R_AT_Code   1
#define R_V0_Code   2
#define R_V1_Code   3
#define R_A0_Code   4
#define R_A1_Code   5
#define R_A2_Code   6
#define R_A3_Code   7
#define R_T0_Code   8
#define R_T1_Code   9
#define R_T2_Code  10
#define R_T3_Code  11
#define R_T4_Code  12
#define R_T5_Code  13
#define R_T6_Code  14
#define R_T7_Code  15
#define R_S0_Code  16
#define R_S1_Code  17
#define R_S2_Code  18
#define R_S3_Code  19
#define R_S4_Code  20
#define R_S5_Code  21
#define R_S6_Code  22
#define R_S7_Code  23
#define R_T8_Code  24
#define R_T9_Code  25
#define R_K0_Code  26
#define R_K1_Code  27
#define R_GP_Code  28
#define R_SP_Code  29
#define R_FP_Code  30
#define R_RA_Code  31

enum {
/* --- MIPS CPU Registers --- */

	R_0  = R_0_Code,  R_AT = R_AT_Code,   R_V0 = R_V0_Code,   R_V1 = R_V1_Code,
	R_A0 = R_A0_Code,  R_A1 = R_A1_Code,   R_A2 = R_A2_Code,   R_A3 = R_A3_Code,
	R_T0 = R_T0_Code,  R_T1 = R_T1_Code,   R_T2 = R_T2_Code,  R_T3 = R_T3_Code,
	R_T4 = R_T4_Code,  R_T5 = R_T5_Code,   R_T6 = R_T6_Code,  R_T7 = R_T7_Code,
	R_S0 = R_S0_Code,  R_S1 = R_S1_Code,   R_S2 = R_S2_Code,  R_S3 = R_S3_Code,
	R_S4 = R_S4_Code,  R_S5 = R_S5_Code,   R_S6 = R_S6_Code,  R_S7 = R_S7_Code,
	R_T8 = R_T8_Code,  R_T9 = R_T9_Code,   R_K0 = R_K0_Code,  R_K1 = R_K1_Code,
	R_GP = R_GP_Code,  R_SP = R_SP_Code,   R_FP = R_FP_Code,  R_RA = R_RA_Code

/* Semantic Aliases for MIPS Registers (O32 ABI) */

	, rdiscard      = R_0  /* Hardwired to 0 */
	, rret_0        = R_V0 /* Function return value */
	, rret_1        = R_V1 /* Second return value (e.g., 64-bit) */
	, rarg_0        = R_A0 /* First function argument */
	, rarg_1        = R_A1 /* Second function argument */
	, rarg_2        = R_A2 /* Third function argument */
	, rarg_3        = R_A3 /* Fourth function argument */
	, rtmp_0        = R_T0 /* Temporary (Caller saved) */
	, rtmp_1        = R_T1 /* Temporary (Caller saved) */
	, rtmp_2        = R_T2 /* Temporary (Caller saved) */
	, rsaved_0      = R_S0 /* Saved register (Callee saved) */
	, rstack_ptr    = R_SP /* Stack Pointer */
	, rret_addr     = R_RA /* Return Address (populated by JAL) */

/* --- MIPS CPU Opcodes (Bits 31-26) --- */

	, op_special = 0x00 /* R-Type instructions (uses FUNCT field) */
	, op_bcond   = 0x01 /* Branch on condition */
	, op_j       = 0x02 /* Jump */
	, op_jal     = 0x03 /* Jump and Link */
	, op_beq     = 0x04 /* Branch on Equal */
	, op_bne     = 0x05 /* Branch on Not Equal */
	, op_blez    = 0x06 /* Branch on Less Than or Equal to Zero */
	, op_bgtz    = 0x07 /* Branch on Greater Than Zero */
	, op_addi    = 0x08 /* Add Immediate */
	, op_addiu   = 0x09 /* Add Immediate Unsigned */
	, op_slti    = 0x0A /* Set on Less Than Immediate */
	, op_sltiu   = 0x0B /* Set on Less Than Immediate Unsigned */
	, op_andi    = 0x0C /* AND Immediate */
	, op_ori     = 0x0D /* OR Immediate */
	, op_xori    = 0x0E /* XOR Immediate */
	, op_lui     = 0x0F /* Load Upper Immediate */
	, op_cop0    = 0x10 /* Coprocessor 0 (System) */
	, op_cop2    = 0x12 /* Coprocessor 2 (GTE) */
	, op_la      = 0
	, op_li      = 0
	, op_lb      = 0x20 /* Load Byte */
	, op_lh      = 0x21 /* Load Halfword */
	, op_lw      = 0x23 /* Load Word */
	, op_lbu     = 0x24 /* Load Byte Unsigned */
	, op_lhu     = 0x25 /* Load Halfword Unsigned */
	, op_sb      = 0x28 /* Store Byte */
	, op_sh      = 0x29 /* Store Halfword */
	, op_sw      = 0x2B /* Store Word */


	, op_load_addr  = op_la
	, op_load_imm   = op_li
	, op_jump       = op_j
	, op_jump_nlink = op_jal

/* --- MIPS CPU Function Codes (Bits 5-0, used when OP == MIPS_OP_SPECIAL) --- */

	, fc_sll     = 0x00 /* Shift Word Left Logical */
	, fc_srl     = 0x02 /* Shift Word Right Logical */
	, fc_sra     = 0x03 /* Shift Word Right Arithmetic */
	, fc_sllv    = 0x04 /* Shift Word Left Logical Variable */
	, fc_srlv    = 0x06 /* Shift Word Right Logical Variable */
	, fc_srav    = 0x07 /* Shift Word Right Arithmetic Variable */
	, fc_jr      = 0x08 /* Jump Register */
	, fc_jalr    = 0x09 /* Jump and Link Register */
	, fc_syscall = 0x0C /* System Call */
	, fc_break   = 0x0D /* Breakpoint */
	, fc_mfhi    = 0x10 /* Move From HI */
	, fc_mthi    = 0x11 /* Move To HI */
	, fc_mflo    = 0x12 /* Move From LO */
	, fc_mtlo    = 0x13 /* Move To LO */
	, fc_mult    = 0x18 /* Multiply Word */
	, fc_multu   = 0x19 /* Multiply Unsigned Word */
	, fc_div     = 0x1A /* Divide Word */
	, fc_divu    = 0x1B /* Divide Unsigned Word */
	, fc_add     = 0x20 /* Add Word */
	, fc_addu    = 0x21 /* Add Unsigned Word */
	, fc_sub     = 0x22 /* Subtract Word */
	, fc_subu    = 0x23 /* Subtract Unsigned Word */
	, fc_and     = 0x24 /* AND */
	, fc_or      = 0x25 /* OR */
	, fc_xor     = 0x26 /* XOR */
	, fc_nor     = 0x27 /* NOR */
	, fc_slt     = 0x2A /* Set on Less Than */
	, fc_sltu    = 0x2B /* Set on Less Than Unsigned */

	, fc_jump_reg   = fc_jr

/* --- Coprocessor 0 (System Control & Exceptions) --- */

	, cop_mf = 0x00 /* Move From Coprocessor */
	, cop_mt = 0x04 /* Move To Coprocessor */
};


// Bitfield Packets (Encoders)

enum { _BitOffsets = 0
/* Bit Offsets for MIPS Instruction Fields */

	, OPCODE_SHIFT = 26
	, RS_SHIFT     = 21
	, RT_SHIFT     = 16
	, RD_SHIFT     = 11
	, SHAMT_SHIFT  = 6  /* Shift Amount */
	, FC_SHIFT     = 0

/* Bit Masks to prevent overflow into adjacent fields */

	, OPCODE_MASK  = 0x3F
	, REG_MASK     = 0x1F
	, SHAMT_MASK   = 0x1F /* Shift Amount */
	, FC_MASK      = 0x3F
	, IMM_MASK     = 0xFFFF
};

#define enc_op(op)       (((op)    & OPCODE_MASK) << OPCODE_SHIFT)
#define enc_rs(rs)       (((rs)    & REG_MASK)    << RS_SHIFT)
#define enc_rt(rt)       (((rt)    & REG_MASK)    << RT_SHIFT)
#define enc_rd(rd)       (((rd)    & REG_MASK)    << RD_SHIFT)
#define enc_shamt(shamt) (((shamt) & SHAMT_MASK)  << SHAMT_SHIFT)
#define enc_fc(fc)       (((fc)    & FC_MASK)     << FC_SHIFT)
#define enc_imm(imm)     (((imm)   & IMM_MASK))

/* MIPS R-Type Instruction Format (Register-to-Register) */
#define enc_r(op, rs, rt, rd, shamt, fc) (enc_op(op) | enc_rs(rs) | enc_rt(rt) | enc_rd(rd) | enc_shamt(shamt) | enc_fc(fc))
/* MIPS I-Type Instruction Format (Immediate/Constant) */
#define enc_i(op, rs, rt, imm)           (enc_op(op) | enc_rs(rs) | enc_rt(rt) | enc_imm(imm))

/* COP0 (System) Transfer Format: mtc0 rt, rd or mfc0 rt, rd
 * `sub` is the COP0 sub-opcode (cop_mf=0 or cop_mt=4), placed in rs slot.
 * `rt` is the GPR operand (in rt slot).
 * `rd` is the COP0 register index (in rd slot at bits 15..11). */
#define enc_cop0_tx(sub, rt, rd) enc_i(op_cop0, (sub), (rt), ((rd) << 11))

/* COP0 Return From Exception (rfe) */
#define enc_rfe() 0x42000010

/* --- Semantic Encoders (MIPS mnemonics) ---
 * Argument order matches the MIPS assembly syntax:
 *   dest-first, then source operands, then immediate last.
 *
 *   load_word(rt, base, off)   → lw   rt, off(base)
 *   store_word(rt, base, off)  → sw   rt, off(base)
 *   add_ui(rt, rs, imm)        → addiu rt, rs, imm
 *   shift_ll(rd, rt, shamt)    → sll   rd, rt, shamt
 *   jump_reg(rs)               → jr    rs
 *   jump_link(rs, rd)          → jalr  rs        (link in rd, default $ra)
 *   nop()                      → sll   $0, $0, 0
 */
#define load_word(rt, base, off)   enc_i(op_lw,    (base), (rt), (off))
#define load_byte(rt, base, off)   enc_i(op_lb,    (base), (rt), (off))
#define load_half(rt, base, off)   enc_i(op_lh,    (base), (rt), (off))
#define load_byte_u(rt, base, off) enc_i(op_lbu,   (base), (rt), (off))
#define load_half_u(rt, base, off) enc_i(op_lhu,   (base), (rt), (off))
#define store_word(rt, base, off)  enc_i(op_sw,    (base), (rt), (off))
#define add_ui(rt, rs, imm)        enc_i(op_addiu, (rs),   (rt), (imm))
#define andi_op(rt, rs, imm)       enc_i(op_andi,  (rs),   (rt), (imm))
#define ori_op(rt, rs, imm)        enc_i(op_ori,   (rs),   (rt), (imm))
#define xori_op(rt, rs, imm)       enc_i(op_xori,  (rs),   (rt), (imm))
#define lui_op(rt, imm)            enc_i(op_lui,   R_0,    (rt), (imm))

/* Shift family (R-type). shift_ll/lr/ra: `sll rd, rt, shamt` */
#define shift_ll(rd, rt, shamt)    enc_r(op_special, R_0,  (rt), (rd), (shamt), fc_sll)
#define shift_lr(rd, rt, shamt)    enc_r(op_special, R_0,  (rt), (rd), (shamt), fc_srl)
#define shift_ra(rd, rt, shamt)    enc_r(op_special, R_0,  (rt), (rd), (shamt), fc_sra)

/* jr rs — jump to address in rs. */
#define jump_reg(rs)               enc_r(op_special, (rs), R_0, R_0, 0, fc_jr)

/* jalr rs, rd — link in rd (default $ra) and jump to address in rs.
 * Layout: [op_special][rs:5][rt=0:5][rd:5][shamt=0:5][fc_jalr=0x09] */
#define jump_link(rs, rd)          enc_r(op_special, (rs), R_0, (rd), 0, fc_jalr)

/* Back-compat alias: the old `load_imm` was a misnomer for `lw`. */
#define load_imm(rt, base, off)    load_word(rt, base, off)

#define nop() shift_ll(rdiscard, rdiscard, 0)

// FI_ void emit_load_imm(U4 rs, U4 rt, U4 imm) { emit(load_imm()); }

// Binary Metaprogramming

typedef U4 const Code;
#define CodeBlob_(sym) tmpl(codeblob,sym) [] align_(4) =

// #define def_code_blob(func_name, func_signature, ...) \
// internal U4 const \
// tmpl(func_name,blob) [] align(4) \
// = { \
// 		__VA_ARGS__ \
// }; \
// internal func_signature func_name = (func_signature)func_name##_blob;

enum {
	bios_flushcache = 0x44,
	bios_table_addr = 0xA0,
};

/* Flushes the Instruction Cache (PSX A-function 0x44 via BIOS stub at 0xA0).
 *
 * Sequence (per MIPS ABI; arguments in arg registers, RA pushed to stack):
 *   1. sp -= 8;  sw $ra, 4($sp)        ; save RA
 *   2. $a0 = bios_flushcache (arg0)
 *   3. $t0 = bios_table_addr           ; t0 = &BIOS A-function table
 *   4. jalr $t0, $ra                    ; call BIOS(flushcache)
 *      nop                              ; branch delay slot
 *   5. lw $ra, 4($sp);  jr $ra          ; restore & return
 *   6. sp += 8
 */
internal
Code CodeBlob_(mips_flush_icache) {
	add_ui(rstack_ptr, rstack_ptr, -8),        /* sp -= 8         */
	store_word(rret_addr, rstack_ptr, 4),      /* sw  $ra, 4($sp) */
	add_ui(rret_0, rdiscard, bios_flushcache), /* addiu $a0, $0, 0x44 */
	add_ui(rtmp_0, rdiscard, bios_table_addr), /* addiu $t0, $0, 0xA0 */
	jump_link(rtmp_0, rret_addr),              /* jalr $t0, $ra   */
	nop(),                                     /* BD slot         */
	load_word(rret_addr, rstack_ptr, 4),       /* lw  $ra, 4($sp) */
	jump_reg(rret_addr),                       /* jr   $ra        */
	add_ui(rstack_ptr, rstack_ptr, 8)          /* sp += 8 (BD)    */
};
FI_ void mips_flush_icache(void) { C_(VoidFn*, codeblob_mips_flush_icache)(); }

/* Standard clobber list for pure-MIPS asm volatile blocks: caller-saved
 * GPRs that the kernel treats as volatile (v0/v1/t0/t1/ra) plus the
 * "memory" barrier. The register ids are passed through `reg_str` so
 * the R_*_Code `#define`s are stringified into "$N" at expansion time. */
#define clb_system \
	reg_str(R_V0_Code), reg_str(R_T0_Code), reg_str(R_T1_Code), reg_str(R_RA_Code), "memory"

#define asm_mips_flush_icache() asm volatile( asm_inline( \
		add_ui(rstack_ptr, rstack_ptr, -8)        \
	, store_word(rret_addr, rstack_ptr, 4)      \
	, add_ui(rret_0, rdiscard, bios_flushcache) \
	, add_ui(rtmp_0, rdiscard, bios_table_addr) \
	, jump_link(rtmp_0, rret_addr)              \
	, nop()                                     \
	, load_word(rret_addr, rstack_ptr, 4)       \
	, jump_reg(rret_addr)                       \
	, add_ui(rstack_ptr, rstack_ptr, 8)         \
) asm_clobber( clb_system ) )

void test_mips_asm() {
	asm_mips_flush_icache();
}

// TAPE & EMITTERS
