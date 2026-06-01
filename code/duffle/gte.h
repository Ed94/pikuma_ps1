#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "math.h"
#	include "mips.h"
#endif

/* C2 data registers */

/* --- GTE Data Registers (Coprocessor 2) --- */
enum {
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
enum {
	gte_in_v0_xy     = C2_VXY0, /* Input Vector 0 (X, Y) */
	gte_in_v0_z      = C2_VZ0,  /* Input Vector 0 (Z) */
	gte_in_v1_xy     = C2_VXY1, /* Input Vector 1 (X, Y) */
	gte_in_v1_z      = C2_VZ1,  /* Input Vector 1 (Z) */
	gte_in_v2_xy     = C2_VXY2, /* Input Vector 2 (X, Y) */
	gte_in_v2_z      = C2_VZ2,  /* Input Vector 2 (Z) */
	gte_in_rgb       = C2_RGB,  /* Input Color (R, G, B, Code) */
	gte_out_scr_xy0  = C2_SXY0, /* Output Screen Coord 0 (X, Y) */
	gte_out_scr_xy1  = C2_SXY1, /* Output Screen Coord 1 (X, Y) */
	gte_out_scr_xy2  = C2_SXY2, /* Output Screen Coord 2 (X, Y) */
	gte_out_depth    = C2_OTZ,  /* Output Ordering Table Z (Depth) */
	gte_math_accum0  = C2_MAC0, /* Math Accumulator 0 */
	gte_math_accum1  = C2_MAC1, /* Math Accumulator 1 */
	gte_math_accum2  = C2_MAC2, /* Math Accumulator 2 */
};

/* --- GTE Command Semantics (The Bitfield Meanings) --- 
 * A GTE command is a single 32-bit word sent to COP2.
 * It is highly configurable via bitfields.
 */

enum {
/* Shift Fraction (Bit 19) - Determines fixed-point division */

	gte_sf_fractional = 0,  /* Divide result by 4096 (Standard 4.12 fixed point) */
	gte_sf_integer    = 1,  /* No division (Raw integer math) */

/* Matrix Select (Bits 18-17) - Which 3x3 matrix to multiply by */

	gte_mx_rotation   = 0,  /* Rotation Matrix (RT) */
	gte_mx_light      = 1,  /* Light Matrix (LL) */
	gte_mx_color      = 2,  /* Color Matrix (LC) */
	gte_mx_none       = 3,  /* Reserved / Do not multiply */

/* Vector select (Bits 16-15) - Which input vector to use */

	gte_v_v0        = 0,  /* Use Vector 0 (VXY0, VZ0) */
	gte_v_v1        = 1,  /* Use Vector 1 (VXY1, VZ1) */
	gte_v_v2        = 2,  /* Use Vector 2 (VXY2, VZ2) */
	gte_v_ir_regs   = 3,  /* Use Intermediate Registers (IR1, IR2, IR3) */

/* Control Vector Select (Bits 14-13) - Which vector to ADD after multiplication */

	gte_cv_translate  = 0,  /* Add Translation Vector (TRX, TRY, TRZ) */
	gte_cv_bg_color   = 1,  /* Add Background Color (RBK, GBK, BBK) */
	gte_cv_far_color  = 2,  /* Add Far Color (RFC, GFC, BFC) */
	gte_cv_none       = 3,  /* Add Zero (No addition) */

/* Limit/Clamp (Bit 10) - Prevents overflow artifacts */

	gte_lm_normal     = 0,  /* Normal math (can overflow) */
	gte_lm_clamp      = 1,  /* Clamp results to valid hardware ranges (e.g., RGB 0-255) */

/* Core Command IDs (Bits 5-0) */

	gte_cmd_rtps      = 0x01, /* Rot/Trans Perspective Single (1 vertex) */
	gte_cmd_rtpt      = 0x02, /* Rot/Trans Perspective Triple (3 vertices) */
	gte_cmd_nclip     = 0x06, /* Normal Clipping (Backface culling) */
	gte_cmd_op        = 0x0C, /* Outer Product */
	gte_cmd_mvmva     = 0x12, /* Matrix Vector Multiply & Add (Custom math) */
};

/* COP2 (GTE) Transfer Format 
 * Opcode is always op_cop2. The 'sub' field determines direction (MT/MF). */
#define enc_cop2_tx(sub, rt, rd) enc_op(op_cop2) | enc_rs(sub) | enc_rt(rt) | enc_rd(rd)

/* GTE Command Format (The math engine trigger) 
 * Opcode is always MIPS_OP_COP2, RS is always 1 (CO).
 * The lower 25 bits are the GTE-specific command payload. */
#define gte_cmd_base (enc_op(op_cop2) | (1 << 25))
#define ENC_GTE_CMD(sf, mx, v, cv, lm, cmd) (gte_cmd_base | \
     (((sf) & 1) << 19) | (((mx) & 3) << 17) | (((v)  & 3) << 15) | \
     (((cv) & 3) << 13) | (((lm) & 1) << 10) | ((cmd) & 0x3F))

// #define asm_gte_matrix_set_rotation asm volatile( \
//  asm_inline( \
// 	\
//  ) \
//  asm_clobber() \
// )

