#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "math.h"
#	include "mips.h"
#endif

/* C2 data registers */

/* --- GTE Data Registers (Coprocessor 2) --- */
typedef enum {
    C2_VXY0 = 0,  C2_VZ0  = 1,  C2_VXY1 = 2,  C2_VZ1  = 3,
    C2_VXY2 = 4,  C2_VZ2  = 5,  C2_RGB  = 6,  C2_OTZ  = 7,
    C2_IR0  = 8,  C2_IR1  = 9,  C2_IR2  = 10, C2_IR3  = 11,
    C2_SXY0 = 12, C2_SXY1 = 13, C2_SXY2 = 14, C2_SXYP = 15,
    C2_SZ0  = 16, C2_SZ1  = 17, C2_SZ2  = 18, C2_SZ3  = 19,
    C2_RGB0 = 20, C2_RGB1 = 21, C2_RGB2 = 22, C2_RES1 = 23,
    C2_MAC0 = 24, C2_MAC1 = 25, C2_MAC2 = 26, C2_MAC3 = 27,
    C2_IRGB = 28, C2_ORGB = 29, C2_LZCS = 30, C2_LZCR = 31
};

/* Semantic Aliases for GTE Data Registers */

#define GTE_IN_VEC0_XY   C2_VXY0 /* Input Vector 0 (X, Y) */
#define GTE_IN_VEC0_Z    C2_VZ0  /* Input Vector 0 (Z) */
#define GTE_IN_VEC1_XY   C2_VXY1 /* Input Vector 1 (X, Y) */
#define GTE_IN_VEC1_Z    C2_VZ1  /* Input Vector 1 (Z) */
#define GTE_IN_VEC2_XY   C2_VXY2 /* Input Vector 2 (X, Y) */
#define GTE_IN_VEC2_Z    C2_VZ2  /* Input Vector 2 (Z) */
#define GTE_IN_COLOR     C2_RGB  /* Input Color (R, G, B, Code) */
#define GTE_OUT_SCR_XY0  C2_SXY0 /* Output Screen Coord 0 (X, Y) */
#define GTE_OUT_SCR_XY1  C2_SXY1 /* Output Screen Coord 1 (X, Y) */
#define GTE_OUT_SCR_XY2  C2_SXY2 /* Output Screen Coord 2 (X, Y) */
#define GTE_OUT_DEPTH    C2_OTZ  /* Output Ordering Table Z (Depth) */
#define GTE_MATH_ACCUM0  C2_MAC0 /* Math Accumulator 0 */
#define GTE_MATH_ACCUM1  C2_MAC1 /* Math Accumulator 1 */
#define GTE_MATH_ACCUM2  C2_MAC2 /* Math Accumulator 2 */

/* --- GTE Command Semantics (The Bitfield Meanings) --- 
 * A GTE command is a single 32-bit word sent to COP2.
 * It is highly configurable via bitfields.
 */

/* Shift Fraction (Bit 19) - Determines fixed-point division */
#define GTE_SF_FRACTIONAL 0  /* Divide result by 4096 (Standard 4.12 fixed point) */
#define GTE_SF_INTEGER    1  /* No division (Raw integer math) */

/* Matrix Select (Bits 18-17) - Which 3x3 matrix to multiply by */
#define GTE_MX_ROTATION   0  /* Rotation Matrix (RT) */
#define GTE_MX_LIGHT      1  /* Light Matrix (LL) */
#define GTE_MX_COLOR      2  /* Color Matrix (LC) */
#define GTE_MX_NONE       3  /* Reserved / Do not multiply */

/* Vector Select (Bits 16-15) - Which input vector to use */
#define GTE_V_VEC0        0  /* Use Vector 0 (VXY0, VZ0) */
#define GTE_V_VEC1        1  /* Use Vector 1 (VXY1, VZ1) */
#define GTE_V_VEC2        2  /* Use Vector 2 (VXY2, VZ2) */
#define GTE_V_IR_REGS     3  /* Use Intermediate Registers (IR1, IR2, IR3) */

/* Control Vector Select (Bits 14-13) - Which vector to ADD after multiplication */
#define GTE_CV_TRANSLATE  0  /* Add Translation Vector (TRX, TRY, TRZ) */
#define GTE_CV_BG_COLOR   1  /* Add Background Color (RBK, GBK, BBK) */
#define GTE_CV_FAR_COLOR  2  /* Add Far Color (RFC, GFC, BFC) */
#define GTE_CV_NONE       3  /* Add Zero (No addition) */

/* Limit/Clamp (Bit 10) - Prevents overflow artifacts */
#define GTE_LM_NORMAL     0  /* Normal math (can overflow) */
#define GTE_LM_CLAMP      1  /* Clamp results to valid hardware ranges (e.g., RGB 0-255) */

/* Core Command IDs (Bits 5-0) */
#define GTE_CMD_RTPS      0x01 /* Rot/Trans Perspective Single (1 vertex) */
#define GTE_CMD_RTPT      0x02 /* Rot/Trans Perspective Triple (3 vertices) */
#define GTE_CMD_NCLIP     0x06 /* Normal Clipping (Backface culling) */
#define GTE_CMD_OP        0x0C /* Outer Product */
#define GTE_CMD_MVMVA     0x12 /* Matrix Vector Multiply & Add (Custom math) */


/* COP2 (GTE) Transfer Format 
 * Opcode is always MIPS_OP_COP2. The 'sub' field determines direction (MT/MF). */
#define ENC_COP2_TX(sub, rt, rd) \
    ((MIPS_OP_COP2 << MIPS_OPCODE_SHIFT) | \
     (((sub) & MIPS_REG_MASK) << MIPS_RS_SHIFT) | \
     (((rt) & MIPS_REG_MASK)  << MIPS_RT_SHIFT) | \
     (((rd) & MIPS_REG_MASK)  << MIPS_RD_SHIFT))

/* GTE Command Format (The math engine trigger) 
 * Opcode is always MIPS_OP_COP2, RS is always 1 (CO).
 * The lower 25 bits are the GTE-specific command payload. */
#define GTE_CMD_BASE ((MIPS_OP_COP2 << MIPS_OPCODE_SHIFT) | (1 << 25))
#define ENC_GTE_CMD(sf, mx, v, cv, lm, cmd) \
    (GTE_CMD_BASE | \
     (((sf) & 1) << 19) | (((mx) & 3) << 17) | (((v)  & 3) << 15) | \
     (((cv) & 3) << 13) | (((lm) & 1) << 10) | ((cmd) & 0x3F))
