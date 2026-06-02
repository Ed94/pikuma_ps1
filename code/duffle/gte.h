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

/* --- GTE Command Bit-Field Layout ---
 * A GTE command word (sent to COP2 with RS=1) is laid out as:
 *
 *   31........25 24 23..19 18..17 16..15 14..13 12..11 10  9.......6  5.......0
 *   +------------+--+-----+------+------+------+------+---+--------+----------+
 *   |  0x3E (COP2)| 1|  -- |  sf  |  mx  |  v   |  cv  | --|  lm  |  -- |  cmd  |
 *   +------------+--+-----+------+------+------+------+---+--------+----------+
 *                                    \_____ GTE_PAYLOAD _____/       \__ GTE_CMD __/
 *
 * Shifts/masks below are the *bit positions* and *bit widths* of each
 * configurable field, used by the ENC_GTE_CMD encoder. Mirrors the
 * OPCODE_SHIFT / RS_SHIFT convention used in mips.h.
 */

	gte_shift_sf  = 19,  gte_width_sf  = 1,  gte_mask_sf  = 0x1,
	gte_shift_mx  = 17,  gte_width_mx  = 2,  gte_mask_mx  = 0x3,
	gte_shift_v   = 15,  gte_width_v   = 2,  gte_mask_v   = 0x3,
	gte_shift_cv  = 13,  gte_width_cv  = 2,  gte_mask_cv  = 0x3,
	gte_shift_lm  = 10,  gte_width_lm  = 1,  gte_mask_lm  = 0x1,
	gte_shift_cmd =  0,  gte_width_cmd = 6,  gte_mask_cmd = 0x3F,
};

/* --- GTE Control Register Indices (for ctc2/cfc2) --- */

enum {
    gte_cr_RT11 = 0,  gte_cr_RT12 = 1,  gte_cr_RT13 = 2,
    gte_cr_RT21 = 3,  gte_cr_RT22 = 4,  gte_cr_RT23 = 5,
    gte_cr_RT31 = 6,  gte_cr_RT32 = 7,  gte_cr_RT33 = 8,
    gte_cr_TRX  = 9,  gte_cr_TRY  = 10, gte_cr_TRZ  = 11,
    gte_cr_L11  = 12, gte_cr_L12  = 13, gte_cr_L13  = 14,
    gte_cr_L21  = 15, gte_cr_L22  = 16, gte_cr_L23  = 17,
    gte_cr_LR1  = 18, gte_cr_LR2  = 19, gte_cr_LR3  = 20,
    gte_cr_RBK  = 24, gte_cr_GBK  = 25, gte_cr_BBK  = 26,
    gte_cr_RFC  = 27, gte_cr_GFC  = 28, gte_cr_BFC  = 29,
    gte_cr_OFX  = 30, gte_cr_OFY  = 31,
};

enum { _C2_OPS_ = 0

	, op_lwc2    = 0x32 /* Load Word to Coprocessor 2 (GTE) */
	, op_swc2    = 0x3A /* Store Word from Coprocessor 2 (GTE) */
};

/* COP2 (GTE) Transfer Format: ctc2 rt, rd or cfc2 rt, rd
 * Layout: [op_cop2:6][sub:5][rt:5][rd:5][0:11]
 *   - sub: cop_mf (0x00) for cfc2, cop_mt (0x04) for ctc2
 *   - rt:  GPR source/dest
 *   - rd:  COP2 control register index (0..31) */
#define enc_cop2_tx(sub, rt, rd) (enc_op(op_cop2) | enc_rs(sub) | enc_rt(rt) | enc_rd(rd))

/* COP2 Data Load (lwc2): `lwc2 rt, off(rs)`
 * Layout: [op_lwc2:6][rs:5][rt:5][imm:16]
 *   - rs: GPR base address
 *   - rt: COP2 data register index (0..31)
 *   - imm: signed 16-bit offset
 * NOTE: When `rs` is a runtime register, the encoding cannot be pre-baked
 * into a .word — use the string-style `gte_load_v0` macro below instead. */
#define enc_cop2_lwc2(rt, base, off)  enc_i(op_lwc2, (base), (rt), (off))
#define enc_cop2_swc2(rt, base, off)  enc_i(op_swc2, (base), (rt), (off))

/* GTE Command Format (The math engine trigger)
 * Opcode is always MIPS_OP_COP2, RS is always 1 (CO).
 * The lower 25 bits are the GTE-specific command payload.
 *
 * The granular `enc_gte_<field>(x)` macros below mirror the `enc_op`/`enc_rs`
 * pattern in mips.h: each one self-masks and shifts its own field, so a
 * caller can build up a GTE command piece by piece (handy for state-driven
 * MVMVA emitters that vary one field at a time).
 *
 * `ENC_GTE_CMD` is the all-in-one convenience for emitting a full command
 * word in one go. It just ORs the per-field encoders together. */
#define gte_cmd_base (enc_op(op_cop2) | (1 << 25))

/* Per-field encoders. Each one does (value & mask) << shift on its own. */
#define enc_gte_sf(sf)       (((sf)  & gte_mask_sf ) << gte_shift_sf )
#define enc_gte_mx(mx)       (((mx)  & gte_mask_mx ) << gte_shift_mx )
#define enc_gte_v(v)         (((v)   & gte_mask_v  ) << gte_shift_v  )
#define enc_gte_cv(cv)       (((cv)  & gte_mask_cv ) << gte_shift_cv )
#define enc_gte_lm(lm)       (((lm)  & gte_mask_lm ) << gte_shift_lm )
#define enc_gte_cmd(cmd)     (((cmd) & gte_mask_cmd) << gte_shift_cmd)

/* Composite: all six GTE fields + the COP2/CO base. */
#define enc_gte_cmdw(sf, mx, v, cv, lm, cmd) ( \
     gte_cmd_base     \
   | enc_gte_sf(sf)   \
   | enc_gte_mx(mx)   \
   | enc_gte_v(v)     \
   | enc_gte_cv(cv)   \
   | enc_gte_lm(lm)   \
   | enc_gte_cmd(cmd) \
)

/**
 * @brief Loads a single SVECTOR to GTE vector register V0
 *
 * @details Loads values from an SVECTOR struct to GTE data registers C2_VXY0
 * (XY at offset 0) and C2_VZ0 (Z at offset 4) using `lwc2`.
 *
 * Uses string-style GCC inline asm with `%0` substitution because the
 * base register `r0` is a runtime GPR chosen by the compiler — it cannot
 * be encoded into a static `.word` constant.
 *
 * Usage:
 *   asm_gte_load_v0(svector_ptr);
 */

/* Pre-baked constants: lwc2 $N, off($12) — plain integers the C compiler
 * constant-folds into .word directives. The R_T4 in the name reminds you
 * that the `rs` field is baked to R_T4 ($12), forcing the placeholder-pun
 * pattern below. */
#define gte_lwc2_v0_RT4   enc_cop2_lwc2(gte_in_v0_xy, R_T4, 0)
#define gte_lwc2_v0z_RT4  enc_cop2_lwc2(gte_in_v0_z,  R_T4, 4)
#define gte_lwc2_v1_RT4   enc_cop2_lwc2(gte_in_v1_xy, R_T4, 0)
#define gte_lwc2_v1z_RT4  enc_cop2_lwc2(gte_in_v1_z,  R_T4, 4)
#define gte_lwc2_v2_RT4   enc_cop2_lwc2(gte_in_v2_xy, R_T4, 0)
#define gte_lwc2_v2z_RT4  enc_cop2_lwc2(gte_in_v2_z,  R_T4, 4)

/* The actual call-site macros — zero string syntax in the .word body.
 *
 * The "r"(r_ptr) input constraint is the irreducible GCC-syntax bit: the
 * base register of lwc2 is a runtime value, so the compiler must allocate
 * one for us. The "$12" clobber + the .word constants having rs=R_T4 ($12)
 * hardwired form the "placeholder-pun" — GCC is forced to bind r_ptr to
 * $12, which is exactly the register the .word constants expect.
 *
 * Uses asm_block_4(code, outs, ins, clb) from gcc_asm.h.
 *   asm_inline(...)    produces the 2-colon code:outputs:inputs body
 *   "r"(r_ptr)         is the runtime-input section body
 *   "$2", ..., "$12"   is the clobber section body
 *   asm_block_4()      joins them with 3 colons and wraps in asm volatile
 *
 * The parens `(...)` around each section let the preprocessor treat the
 * section's contents as a single arg (shielding internal commas), and
 * the `_strip` helper inside asm_block_4 removes those parens so the
 * final C code is clean.
 */
#define gte_load_v0(r_ptr) \
    asm_block_4(                                                \
        (asm_inline( gte_lwc2_v0_RT4, gte_lwc2_v0z_RT4 )),       \
        (),                                                       \
        ("r"(r_ptr)),                                             \
        ("$2", "$8", "$9", "$31", "memory", "$12")               \
    )

#define gte_load_v1(r_ptr) \
    asm_block_4(                                                \
        (asm_inline( gte_lwc2_v1_RT4, gte_lwc2_v1z_RT4 )),       \
        (),                                                       \
        ("r"(r_ptr)),                                             \
        ("$2", "$8", "$9", "$31", "memory", "$12")               \
    )

#define gte_load_v2(r_ptr) \
    asm_block_4(                                                \
        (asm_inline( gte_lwc2_v2_RT4, gte_lwc2_v2z_RT4 )),       \
        (),                                                       \
        ("r"(r_ptr)),                                             \
        ("$2", "$8", "$9", "$31", "memory", "$12")               \
    )

/* All three at once -- the canonical prelude to gte_cmd_rtpt. */
#define gte_load_v0v1v2(r_ptr) \
    asm_block_4(                                                \
        (asm_inline( gte_lwc2_v0_RT4, gte_lwc2_v0z_RT4,           \
                    gte_lwc2_v1_RT4, gte_lwc2_v1z_RT4,           \
                    gte_lwc2_v2_RT4, gte_lwc2_v2z_RT4 )),        \
        (),                                                       \
        ("r"(r_ptr)),                                             \
        ("$2", "$8", "$9", "$31", "memory", "$12")               \
    )

/**
 * @brief Loads a single SVECTOR to GTE vector register V1
 *
 * @details Loads values from an SVECTOR struct to GTE data registers C2_VXY1
 * and C2_VZ1.
 */
// #define gte_load_v1( r0 ) __asm__ volatile ( \
// 	"lwc2	$2, 0( %0 );"	\
// 	"lwc2	$3, 4( %0 );"	\
// 	:						\
// 	: "r"( r0 )				\
// 	: "$t0" )

/**
 * @brief Loads a single SVECTOR to GTE vector register V2
 *
 * @details Loads values from an SVECTOR struct to GTE data registers C2_VXY2
 * and C2_VZ2.
 */
// #define gte_load_v2( r0 ) __asm__ volatile ( \
// 	"lwc2	$4, 0( %0 );"	\
// 	"lwc2	$5, 4( %0 );"	\
// 	:						\
// 	: "r"( r0 )				\
// 	: "$t0" )

#define gte_ldv0(r0)          \
    __asm__ volatile(         \
        "lwc2   $0, 0( %0 );" \
        "lwc2   $1, 4( %0 )"  \
        :                     \
        : "r"(r0))

#define gte_ldv1(r0)          \
    __asm__ volatile(         \
        "lwc2   $2, 0( %0 );" \
        "lwc2   $3, 4( %0 )"  \
        :                     \
        : "r"(r0))

#define gte_ldv2(r0)          \
    __asm__ volatile(         \
        "lwc2   $4, 0( %0 );" \
        "lwc2   $5, 4( %0 )"  \
        :                     \
        : "r"(r0))

#define gte_rtpt()    \
    __asm__ volatile( \
        "nop;"        \
        "nop;"        \
        "cop2 0x0280030;")

#define gte_nclip()   \
    __asm__ volatile( \
        "nop;"        \
        "nop;"        \
        "cop2 0x01400006;")

#define gte_stotz(r0) __asm__ volatile("swc2   $7, 0( %0 )" : : "r"(r0) : "memory")

#define gte_stsxy3(r0, r1, r2)      \
    __asm__ volatile(               \
        "swc2   $12, 0( %0 );"      \
        "swc2   $13, 0( %1 );"      \
        "swc2   $14, 0( %2 )"       \
        :                           \
        : "r"(r0), "r"(r1), "r"(r2) \
        : "memory")

#define gte_avsz3()   \
    __asm__ volatile( \
        "nop;"        \
        "nop;"        \
        "cop2 0x0158002D;")

/* asm_gte_matrix_set_rotation(r0)
 *
 * Loads the 3x3 rotation matrix at `r0` into the GTE's rotation-matrix
 * control registers (RT11..RT22, indices 0..4) via ctc2.
 *
 * Memory layout at r0: five contiguous 32-bit words (offsets 0..16),
 * each holding two packed 16-bit matrix elements. The first 1.5 rows
 * of a standard PSX SDK MATRIX struct (where each row is laid out as
 * [RT_xx, RT_xy] | [RT_xz, pad] | ...).
 *
 * Generated MIPS (mirrors the source macro):
 *
 *   lw   $12,  0( %0 )    ; word 0
 *   lw   $13,  4( %0 )    ; word 1
 *   ctc2 $12,  $0         ; → C2_RT11
 *   ctc2 $13,  $1         ; → C2_RT12
 *   lw   $12,  8( %0 )    ; word 2
 *   lw   $13, 12( %0 )    ; word 3
 *   lw   $14, 16( %0 )    ; word 4
 *   ctc2 $12,  $2         ; → C2_RT13
 *   ctc2 $13,  $3         ; → C2_RT21
 *   ctc2 $14,  $4         ; → C2_RT22
 *
 * Uses string-style GCC inline asm with `%0` substitution because the
 * base register `r0` is a runtime GPR — the `lw` offsets use literal
 * values (0, 4, 8, ...) so only the base register needs substitution.
 *
 * WARNING: Incomplete by design. The source macro only writes RT11..RT22
 * (5 of 9 rotation elements); RT23 and the entire RT3x row are left
 * untouched. Real libpsn00b SetRotMatrix writes all 9. Use only when the
 * GTE's remaining rotation entries are already correct, or you will
 * get stale-RT2x/RT3x artifacts in RTPS/RTPT/MVMVA output.
 */
#define asm_gte_matrix_set_rotation(r0) \
	asm volatile( \
		asm_inline(                         \
			 load_imm(R_T4, r0,  0),          \
			 load_imm(R_T5, r0,  4),          \
			 enc_cop2_tx(cop_mt, R_T4,  0),   \
			 enc_cop2_tx(cop_mt, R_T5,  1),   \
			 load_imm(R_T4, r0,  8),          \
			 load_imm(R_T5, r0, 12),          \
			 load_imm(R_T6, r0, 16),          \
			 enc_cop2_tx(cop_mt, R_T4,  2),   \
			 enc_cop2_tx(cop_mt, R_T5,  3),   \
			 enc_cop2_tx(cop_mt, R_T6,  4)    \
		)                                   \
		asm_clobber( clb_system, "$12", "$13", "$14") \
		: \
		: "r"(r0) \
	)
