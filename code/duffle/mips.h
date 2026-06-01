#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
# include "gcc_asm.h"
#endif

enum {
/* --- MIPS CPU Registers --- */

	R_0  = 0,  R_AT = 1,   R_V0 = 2,   R_V1 = 3,
	R_A0 = 4,  R_A1 = 5,   R_A2 = 6,   R_A3 = 7,
	R_T0 = 8,  R_T1 = 9,   R_T2 = 10,  R_T3 = 11,
	R_T4 = 12, R_T5 = 13,  R_T6 = 14,  R_T7 = 15,
	R_S0 = 16, R_S1 = 17,  R_S2 = 18,  R_S3 = 19,
	R_S4 = 20, R_S5 = 21,  R_S6 = 22,  R_S7 = 23,
	R_T8 = 24, R_T9 = 25,  R_K0 = 26,  R_K1 = 27,
	R_GP = 28, R_SP = 29,  R_FP = 30,  R_RA = 31

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

/* COP0 (System) Transfer Format */
#define ENC_COP0_TX(sub, rt, rd) \
	((MIPS_OP_COP0 << MIPS_OPCODE_SHIFT) | \
		(((sub) & MIPS_REG_MASK) << MIPS_RS_SHIFT) | \
		(((rt) & MIPS_REG_MASK)  << MIPS_RT_SHIFT) | \
		(((rd) & MIPS_REG_MASK)  << MIPS_RD_SHIFT))


/* COP0 Return From Exception (rfe) */
#define enc_rfe() 0x42000010

#define load_imm(rs,rt,imm)   enc_i(op_lw,    rs, rt, imm)
#define store_word(rs,rt,imm) enc_i(op_sw,    rs, rt, imm)
#define add_ui(rs,rt,imm)     enc_i(op_addiu, rs, rt, imm)
#define shift_ll(rs,rt,rd)    enc_r(op_special, rs, rt, rd, 0, fc_sll)

#define jump_reg(rs)          enc_r(op_special, rs, R_0, R_0, 0, fc_jr)
#define jump_nreg(rs,rt,rd)   enc_r(op_special, rs, rt, rd, 0, fc_jalr)

#define nop() shift_ll(rdiscard, rdiscard, rdiscard)

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

/* Flushes the Instruction Cache */
I_
Code CodeBlob_(mips_flush_icache) {
	add_ui(rstack_ptr, rstack_ptr, -8),
	store_word(rstack_ptr, rret_addr, 4),
	add_ui(rdiscard, rret_0, bios_flushcache), add_ui(rdiscard, rtmp_0, bios_table_addr),
	jump_nreg(rtmp_0, rdiscard, rret_addr), 
	nop(), load_imm(rstack_ptr, rret_addr, 4), jump_reg(rret_addr),
	add_ui(rstack_ptr, rstack_ptr, 8)
};
FI_ void mips_flush_icache(void) { C_(VoidFn*, codeblob_mips_flush_icache)(); }

#define clb_system "$2", "$8", "$9", "$31", "memory"

#define asm_mips_flush_icache() asm volatile( \
	asm_inline( \
			add_ui(rstack_ptr, rstack_ptr, -8) \
		, store_word(rstack_ptr, rret_addr, 4) \
		, add_ui(rdiscard, rret_0, bios_flushcache), add_ui(rdiscard, rtmp_0, bios_table_addr) \
		, jump_nreg(rtmp_0, rdiscard, rret_addr)  \
		, nop(), load_imm(rstack_ptr, rret_addr, 4), jump_reg(rret_addr) \
		, add_ui(rstack_ptr, rstack_ptr, 8) \
	) \
	asm_clobber( clb_system ) \
)

void test()
{
	asm_mips_flush_icache();
}

// TAPE & EMITTERS
