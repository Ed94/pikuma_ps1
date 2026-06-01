#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

/* --- MIPS CPU Registers --- */
typedef enum {
    R_ZERO = 0, R_AT = 1,   R_V0 = 2,   R_V1 = 3,
    R_A0 = 4,   R_A1 = 5,   R_A2 = 6,   R_A3 = 7,
    R_T0 = 8,   R_T1 = 9,   R_T2 = 10,  R_T3 = 11,
    R_T4 = 12,  R_T5 = 13,  R_T6 = 14,  R_T7 = 15,
    R_S0 = 16,  R_S1 = 17,  R_S2 = 18,  R_S3 = 19,
    R_S4 = 20,  R_S5 = 21,  R_S6 = 22,  R_S7 = 23,
    R_T8 = 24,  R_T9 = 25,  R_K0 = 26,  R_K1 = 27,
    R_GP = 28,  R_SP = 29,  R_FP = 30,  R_RA = 31
};

/* Semantic Aliases for MIPS Registers (O32 ABI) */

#define REG_DISCARD      R_ZERO /* Hardwired to 0 */
#define REG_RETURN_VAL   R_V0   /* Function return value */
#define REG_RETURN_VAL2  R_V1   /* Second return value (e.g., 64-bit) */
#define REG_ARG_0        R_A0   /* First function argument */
#define REG_ARG_1        R_A1   /* Second function argument */
#define REG_ARG_2        R_A2   /* Third function argument */
#define REG_ARG_3        R_A3   /* Fourth function argument */
#define REG_TEMP_0       R_T0   /* Temporary (Caller saved) */
#define REG_TEMP_1       R_T1   /* Temporary (Caller saved) */
#define REG_TEMP_2       R_T2   /* Temporary (Caller saved) */
#define REG_SAVED_0      R_S0   /* Saved register (Callee saved) */
#define REG_STACK_PTR    R_SP   /* Stack Pointer */
#define REG_RETURN_ADDR  R_RA   /* Return Address (populated by JAL) */

/* --- MIPS CPU Opcodes (Bits 31-26) --- */

#define MIPS_OP_SPECIAL  0x00 /* R-Type instructions (uses FUNCT field) */
#define MIPS_OP_BCOND    0x01 /* Branch on condition */
#define MIPS_OP_J        0x02 /* Jump */
#define MIPS_OP_JAL      0x03 /* Jump and Link */
#define MIPS_OP_BEQ      0x04 /* Branch on Equal */
#define MIPS_OP_BNE      0x05 /* Branch on Not Equal */
#define MIPS_OP_BLEZ     0x06 /* Branch on Less Than or Equal to Zero */
#define MIPS_OP_BGTZ     0x07 /* Branch on Greater Than Zero */
#define MIPS_OP_ADDI     0x08 /* Add Immediate */
#define MIPS_OP_ADDIU    0x09 /* Add Immediate Unsigned */
#define MIPS_OP_SLTI     0x0A /* Set on Less Than Immediate */
#define MIPS_OP_SLTIU    0x0B /* Set on Less Than Immediate Unsigned */
#define MIPS_OP_ANDI     0x0C /* AND Immediate */
#define MIPS_OP_ORI      0x0D /* OR Immediate */
#define MIPS_OP_XORI     0x0E /* XOR Immediate */
#define MIPS_OP_LUI      0x0F /* Load Upper Immediate */
#define MIPS_OP_COP0     0x10 /* Coprocessor 0 (System) */
#define MIPS_OP_COP2     0x12 /* Coprocessor 2 (GTE) */
#define MIPS_OP_LB       0x20 /* Load Byte */
#define MIPS_OP_LH       0x21 /* Load Halfword */
#define MIPS_OP_LW       0x23 /* Load Word */
#define MIPS_OP_LBU      0x24 /* Load Byte Unsigned */
#define MIPS_OP_LHU      0x25 /* Load Halfword Unsigned */
#define MIPS_OP_SB       0x28 /* Store Byte */
#define MIPS_OP_SH       0x29 /* Store Halfword */
#define MIPS_OP_SW       0x2B /* Store Word */

/* --- MIPS CPU Function Codes (Bits 5-0, used when OP == MIPS_OP_SPECIAL) --- */

#define MIPS_FC_SLL   0x00 /* Shift Word Left Logical */
#define MIPS_FC_SRL   0x02 /* Shift Word Right Logical */
#define MIPS_FC_SRA   0x03 /* Shift Word Right Arithmetic */
#define MIPS_FC_SLLV  0x04 /* Shift Word Left Logical Variable */
#define MIPS_FC_SRLV  0x06 /* Shift Word Right Logical Variable */
#define MIPS_FC_SRAV  0x07 /* Shift Word Right Arithmetic Variable */
#define MIPS_FC_JR    0x08 /* Jump Register */
#define MIPS_FC_JALR  0x09 /* Jump and Link Register */
#define MIPS_FC_SYSCALL 0x0C /* System Call */
#define MIPS_FC_BREAK 0x0D /* Breakpoint */
#define MIPS_FC_MFHI  0x10 /* Move From HI */
#define MIPS_FC_MTHI  0x11 /* Move To HI */
#define MIPS_FC_MFLO  0x12 /* Move From LO */
#define MIPS_FC_MTLO  0x13 /* Move To LO */
#define MIPS_FC_MULT  0x18 /* Multiply Word */
#define MIPS_FC_MULTU 0x19 /* Multiply Unsigned Word */
#define MIPS_FC_DIV   0x1A /* Divide Word */
#define MIPS_FC_DIVU  0x1B /* Divide Unsigned Word */
#define MIPS_FC_ADD   0x20 /* Add Word */
#define MIPS_FC_ADDU  0x21 /* Add Unsigned Word */
#define MIPS_FC_SUB   0x22 /* Subtract Word */
#define MIPS_FC_SUBU  0x23 /* Subtract Unsigned Word */
#define MIPS_FC_AND   0x24 /* AND */
#define MIPS_FC_OR    0x25 /* OR */
#define MIPS_FC_XOR   0x26 /* XOR */
#define MIPS_FC_NOR   0x27 /* NOR */
#define MIPS_FC_SLT   0x2A /* Set on Less Than */
#define MIPS_FC_SLTU  0x2B /* Set on Less Than Unsigned */

/* --- Coprocessor 0 (System Control & Exceptions) --- */

#define MIPS_COP_MF      0x00 /* Move From Coprocessor */
#define MIPS_COP_MT      0x04 /* Move To Coprocessor */




// Bitfield Packets (Encoders)

/* Bit Offsets for MIPS Instruction Fields */

#define MIPS_OPCODE_SHIFT 26
#define MIPS_RS_SHIFT     21
#define MIPS_RT_SHIFT     16
#define MIPS_RD_SHIFT     11
#define MIPS_SHAMT_SHIFT  6
#define MIPS_FC_SHIFT     0

/* Bit Masks to prevent overflow into adjacent fields */

#define MIPS_OPCODE_MASK  0x3F
#define MIPS_REG_MASK     0x1F
#define MIPS_SHAMT_MASK   0x1F
#define MIPS_FC_MASK      0x3F
#define MIPS_IMM_MASK     0xFFFF

/* MIPS R-Type Instruction Format (Register-to-Register) */
#define ENC_R(op, rs, rt, rd, shamt, funct) \
	((((op) & MIPS_OPCODE_MASK) << MIPS_OPCODE_SHIFT) | \
		(((rs) & MIPS_REG_MASK)    << MIPS_RS_SHIFT)     | \
		(((rt) & MIPS_REG_MASK)    << MIPS_RT_SHIFT)     | \
		(((rd) & MIPS_REG_MASK)    << MIPS_RD_SHIFT)     | \
		(((shamt) & MIPS_SHAMT_MASK) << MIPS_SHAMT_SHIFT)  | \
		(((funct) & MIPS_FC_MASK) << MIPS_FC_SHIFT))

/* MIPS I-Type Instruction Format (Immediate/Constant) */
#define ENC_I(op, rs, rt, imm) \
	((((op) & MIPS_OPCODE_MASK) << MIPS_OPCODE_SHIFT) | \
		(((rs) & MIPS_REG_MASK)    << MIPS_RS_SHIFT)     | \
		(((rt) & MIPS_REG_MASK)    << MIPS_RT_SHIFT)     | \
		(((imm) & MIPS_IMM_MASK)))

/* COP0 (System) Transfer Format */
#define ENC_COP0_TX(sub, rt, rd) \
	((MIPS_OP_COP0 << MIPS_OPCODE_SHIFT) | \
		(((sub) & MIPS_REG_MASK) << MIPS_RS_SHIFT) | \
		(((rt) & MIPS_REG_MASK)  << MIPS_RT_SHIFT) | \
		(((rd) & MIPS_REG_MASK)  << MIPS_RD_SHIFT))

/* COP0 Return From Exception (rfe) */
#define ENC_RFE() 0x42000010


// Binary Metaprogramming

typedef U4 const Code;
#define def_code_blob(sym)  sym ## _ ## blob [] align_(4) =

// #define def_code_blob(func_name, func_signature, ...) \
// internal U4 const \
// tmpl(func_name,blob) [] align(4) \
// = { \
// 		__VA_ARGS__ \
// }; \
// internal func_signature func_name = (func_signature)func_name##_blob;

internal 
Code def_code_blob(mips_flush_icache) {
	/* addiu , , -8 */
	ENC_I(MIPS_OP_ADDIU, REG_STACK_PTR, REG_STACK_PTR, -8),
	/* sw , 4() */
	ENC_I(MIPS_OP_SW, REG_STACK_PTR, REG_RETURN_ADDR, 4),
	/* addiu , , 0x44 (BIOS Call 0x44: FlushCache) */
	ENC_I(MIPS_OP_ADDIU, REG_DISCARD, REG_RETURN_VAL, 0x44),
	/* addiu , , 0xA0 (BIOS A0 Table Address) */
	ENC_I(MIPS_OP_ADDIU, REG_DISCARD, REG_TEMP_1, 0xA0),
	/* jalr ,  (Jump to BIOS) */
	ENC_R(MIPS_OP_SPECIAL, REG_TEMP_1, R_ZERO, REG_RETURN_ADDR, 0, MIPS_FC_JALR),
	/* nop (Branch delay slot) */
	ENC_R(MIPS_OP_SPECIAL, R_ZERO, R_ZERO, R_ZERO, 0, MIPS_FC_SLL),
	/* lw , 4() */
	ENC_I(MIPS_OP_LW, REG_STACK_PTR, REG_RETURN_ADDR, 4),
	/* jr  (Return to C code) */
	ENC_R(MIPS_OP_SPECIAL, REG_RETURN_ADDR, R_ZERO, R_ZERO, 0, MIPS_FC_JR),
	/* addiu , , 8 (Branch delay slot: restore stack pointer) */
	ENC_I(MIPS_OP_ADDIU, REG_STACK_PTR, REG_STACK_PTR, 8)
};
FI_ void mips_flush_icache(void) { C_(VoidFn*, mips_flush_icache_blob)(); }

/* Flushes the Instruction Cache so the CPU sees our newly written tape */
// FI_ void mips_flush_icache(void) {
//     /* Uses standard PS1 BIOS A0 table call 0x44 */
//     __asm__ volatile (
//         "li $v0, 0x44\n\t"
//         "li $t1, 0xA0\n\t"
//         "jalr $t1\n\t"
//         "nop"
//         : : : "v0", "t1", "ra", "memory"
//     );
// }





// TAPE & EMITTERS



