/* ============================================================================
 *  duffle DSL Suffix Conventions
 *  ============================================================================
 *
 *  Every mnemonic in this header follows the same suffix grammar:
 *
 *  Primitive commands: gp0_cmd_poly_f3 = 0x20    (byte opcode)
 *  Packed 32-bit cmd:  gp0_word_poly_f3(r, g, b) (32-bit, shifted)
 *
 *  Type ordering: domain?_(direction)?_action_target_modifier_type?
 *  Examples: add_ui             (add + unsigned + immediate)
 *            add_s              (add + signed, R-type implicit)
 *            shift_lleft        (shift + logical + left)
 *            shift_aright       (shift + arithmetic + right)
 *            call_reg(rs)       (call + register, $ra implicit)
 *            gte_mv_to_data_r   (gte + mv + to + data + register)
 *            gte_lw_v0_xy(base) (gte + lw + v0 + xy)
 *            load_upper_i       (load-upper + immediate, unique verb)
 *
 *  Vendor mnemonics (gte_mtc2, gte_mfc2, gte_lwc2, gte_swc2, etc.) are
 *  NOT in this header. They live in the opt-in `gte_vendor_sym.h` for
 *  users who prefer the textbook MIPS assembly mnemonics.
 * ============================================================================ */

#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "math.h"
#	include "mips.h"
#endif

#pragma region ASM DSL
/* ============================================================================
 *  gte.h — Geometry Transformation Engine (COP2) for the PS1
 * ============================================================================
 *
 *  Hand-rolled DSL for emitting GTE/MIPS instruction words as raw `.word`
 *  constants from C. No GCC inline-assembly string syntax in the code body.
 *
 *  PHILOSOPHY
 *  ----------
 *  1. A 32-bit instruction word is composed from per-field encoders. Each
 *     encoder knows only its own bit range; the composite ORs them together.
 *     No magic numbers inside any encoder body. Every shift and mask is a
 *     named constant from the bitfield-layout enum below.
 *
 *  2. Pure (compile-time) instructions. Every GTE *command* (RTPS, RTPT,
 *     NCLIP, MVMVA, …) and every COP2 *transfer* (ctc2/cfc2) with a constant
 *     rs/rt/rd — are emitted as a single integer constant via
 *     `asm_inline(...)` from gcc_asm.h. The C compiler constant-folds
 *     these into `.word` directives in .rodata.
 *
 *  3. Runtime-base-register instructions (lwc2, swc2, lw, sw, …) cannot be
 *     a pure compile-time word because the `rs` field is chosen by the
 *     compiler at codegen. For these we use a "placeholder-pun" pattern:
 *     a fixed register number (R_T4 = $12) is baked into the rs field of
 *     the `.word` constant, and the macro declares a `"r"(arg)` input
 *     constraint plus a clobber on the same register. The compiler is
 *     therefore *forced* to bind `arg` to that exact register, and the
 *     constant is correct.
 *
 *  USAGE
 *  -----
 *      // Pure command sequence — all bits compile-time:
 *      asm volatile(
 *          asm_inline( gte_cmd_rtpt , gte_cmd_nclip , gte_cmd_avsz3 )
 *          asm_clobber( clbr_volatile_gprs )
 *      );
 *
 *      // Runtime-base-register load — caller picks the base GPR:
 *      register V3_S2* p_in_12 __asm__("$12") = verts[0].ptr;
 *      gte_load_v0(p_in_12, R_T4);   // R_T4 = 12 = $t4 = $12
 *
 *      // Three independent bases for an RTPT pipeline:
 *      register V3_S2* p0 gcc_reg(R_T4) = verts[0].ptr;
 *      register V3_S2* p1 gcc_reg(R_T5) = verts[1].ptr;
 *      register V3_S2* p2 gcc_reg(R_T6) = verts[2].ptr;
 *      gte_load_v0(p0, R_T4);
 *      gte_load_v1(p1, R_T5);
 *      gte_load_v2(p2, R_T6);
 *      gte_rtpt();
 *
 *  STYLE NOTES
 *  -----------
 *  - Per-field encoders are named `enc_gte_<field>(value)` and each one
 *    self-masks its argument before shifting. Mirrors the `enc_op / enc_rs
 *    / enc_rt / ...` family in mips.h.
 *  - The composite `enc_gte_cmdw(sf, mx, v, cv, lm, cmd)` is a flat OR of
 *    the per-field encoders, plus the COP2/CO base.
 *  - Pre-baked shortcuts (`gte_cmd_rtpt`, `gte_cmd_rtps`, …) are defined
 *    for the common cases so call sites read like assembly source.
 *  - All register/field values are enums (not `#define`s) so they show up
 *    in debugger symbol tables and IDE autocomplete.
 *
 *  SEE ALSO
 *  --------
 *  - gcc_asm.h: the `.word` emitter (`asm_inline`, `asm_clobber`, clobbers)
 *  - mips.h:    the MIPS encoder layer this builds on
 */

/* C2 data registers */

/* --- GTE Data Registers (Coprocessor 2) ---
 * Preprocessor-visible integer ids for the COP2 data register file.
 * Each enum value is bound to a parallel `_Code` `#define` so the
 * preprocessor can stringify the integer (for `reg_str`/`rgcc` paths).
 * Same pattern as the GPR `_Code` set in mips.h. */
#define C2_VXY0_Code  0
#define C2_VZ0_Code   1
#define C2_VXY1_Code  2
#define C2_VZ1_Code   3
#define C2_VXY2_Code  4
#define C2_VZ2_Code   5
#define C2_RGB_Code   6
#define C2_OTZ_Code   7
#define C2_IR0_Code   8
#define C2_IR1_Code   9
#define C2_IR2_Code  10
#define C2_IR3_Code  11
#define C2_SXY0_Code 12
#define C2_SXY1_Code 13
#define C2_SXY2_Code 14
#define C2_SXYP_Code 15
#define C2_SZ0_Code  16
#define C2_SZ1_Code  17
#define C2_SZ2_Code  18
#define C2_SZ3_Code  19
#define C2_RGB0_Code 20
#define C2_RGB1_Code 21
#define C2_RGB2_Code 22
#define C2_RES1_Code 23
#define C2_MAC0_Code 24
#define C2_MAC1_Code 25
#define C2_MAC2_Code 26
#define C2_MAC3_Code 27
#define C2_IRGB_Code 28
#define C2_ORGB_Code 29
#define C2_LZCS_Code 30
#define C2_LZCR_Code 31

enum {
	C2_VXY0 = C2_VXY0_Code, C2_VZ0  = C2_VZ0_Code,  C2_VXY1 = C2_VXY1_Code, C2_VZ1  = C2_VZ1_Code,
	C2_VXY2 = C2_VXY2_Code, C2_VZ2  = C2_VZ2_Code,  C2_RGB  = C2_RGB_Code,  C2_OTZ  = C2_OTZ_Code,
	C2_IR0  = C2_IR0_Code,  C2_IR1  = C2_IR1_Code,  C2_IR2  = C2_IR2_Code,  C2_IR3  = C2_IR3_Code,
	C2_SXY0 = C2_SXY0_Code, C2_SXY1 = C2_SXY1_Code, C2_SXY2 = C2_SXY2_Code, C2_SXYP = C2_SXYP_Code,
	C2_SZ0  = C2_SZ0_Code,  C2_SZ1  = C2_SZ1_Code,  C2_SZ2  = C2_SZ2_Code,  C2_SZ3  = C2_SZ3_Code,
	C2_RGB0 = C2_RGB0_Code, C2_RGB1 = C2_RGB1_Code, C2_RGB2 = C2_RGB2_Code, C2_RES1 = C2_RES1_Code,
	C2_MAC0 = C2_MAC0_Code, C2_MAC1 = C2_MAC1_Code, C2_MAC2 = C2_MAC2_Code, C2_MAC3 = C2_MAC3_Code,
	C2_IRGB = C2_IRGB_Code, C2_ORGB = C2_ORGB_Code, C2_LZCS = C2_LZCS_Code, C2_LZCR = C2_LZCR_Code
};

/* Semantic Aliases for GTE Data Registers */
enum {
	gte_in_v0_xy     = C2_VXY0, /* Input Vector 0 (X, Y) */
	gte_in_v0_z      = C2_VZ0,  /* Input Vector 0 (Z) */
	gte_in_v1_xy     = C2_VXY1, /* Input Vector 1 (X, Y) */
	gte_in_v1_z      = C2_VZ1,  /* Input Vector 1 (Z) */
	gte_in_v2_xy     = C2_VXY2, /* Input Vector 2 (X, Y) */
	gte_in_v2_z      = C2_VZ2,  /* Input Vector 2 (Z) */
	gte_in_rgb       = C2_RGB,  /* Input Color (R, G, B, MipsCode) */
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
	gte_cmd_rtpt      = 0x30, /* Rot/Trans Perspective Triple (3 vertices) */
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

/* --- GTE Control Register Indices (for ctc2/cfc2) ---
 * Preprocessor-visible integer ids for the COP2 control register file.
 * Each enum value is bound to a parallel `_Code` `#define` so the
 * preprocessor can stringify the integer (for `reg_str`/`rgcc` paths).
 * Same pattern as the GPR `_Code` set in mips.h. Note: indices 21-23
 * are reserved/unused on real hardware, so there's a gap. */
#define gte_cr_RT11_Code  0
#define gte_cr_RT12_Code  1  /* packed with RT13 in bits 16..31 */
#define gte_cr_RT13_Code  2  /* packed with RT22 in bits 16..31 */
#define gte_cr_RT21_Code  3  /* packed with RT31 in bits 16..31 */
#define gte_cr_RT22_Code  4  /* RT33 alone (low 16 bits used) */
// #define gte_cr_RT23_Code  5
// #define gte_cr_RT31_Code  6
// #define gte_cr_RT32_Code  7
// #define gte_cr_RT33_Code  8
#define gte_cr_TRX_Code   5   /* PSX SDK convention: C2 r5 = TRX (alone, 32-bit) */
#define gte_cr_TRY_Code   6   /* PSX SDK convention: C2 r6 = TRY (alone, 32-bit) */
#define gte_cr_TRZ_Code   7   /* PSX SDK convention: C2 r7 = TRZ (alone, 32-bit) */
#define gte_cr_L11_Code  12
#define gte_cr_L12_Code  13
#define gte_cr_L13_Code  14
#define gte_cr_L21_Code  15
#define gte_cr_L22_Code  16
#define gte_cr_L23_Code  17
#define gte_cr_LR1_Code  18
#define gte_cr_LR2_Code  19
#define gte_cr_LR3_Code  20
#define gte_cr_RBK_Code  24
#define gte_cr_GBK_Code  25
#define gte_cr_BBK_Code  26
#define gte_cr_RFC_Code  27
#define gte_cr_GFC_Code  28
#define gte_cr_BFC_Code  29
#define gte_cr_OFX_Code  30
#define gte_cr_OFY_Code  31

enum {
	gte_cr_RT11 = gte_cr_RT11_Code, gte_cr_RT12 = gte_cr_RT12_Code, gte_cr_RT13 = gte_cr_RT13_Code,
	gte_cr_RT21 = gte_cr_RT21_Code, gte_cr_RT22 = gte_cr_RT22_Code, //gte_cr_RT23 = gte_cr_RT23_Code,
	// gte_cr_RT31 = gte_cr_RT31_Code, gte_cr_RT32 = gte_cr_RT32_Code, gte_cr_RT33 = gte_cr_RT33_Code,
	gte_cr_TRX  = gte_cr_TRX_Code,  gte_cr_TRY  = gte_cr_TRY_Code,  gte_cr_TRZ  = gte_cr_TRZ_Code,
	gte_cr_L11  = gte_cr_L11_Code,  gte_cr_L12  = gte_cr_L12_Code,  gte_cr_L13  = gte_cr_L13_Code,
	gte_cr_L21  = gte_cr_L21_Code,  gte_cr_L22  = gte_cr_L22_Code,  gte_cr_L23  = gte_cr_L23_Code,
	gte_cr_LR1  = gte_cr_LR1_Code,  gte_cr_LR2  = gte_cr_LR2_Code,  gte_cr_LR3  = gte_cr_LR3_Code,
	gte_cr_RBK  = gte_cr_RBK_Code,  gte_cr_GBK  = gte_cr_GBK_Code,  gte_cr_BBK  = gte_cr_BBK_Code,
	gte_cr_RFC  = gte_cr_RFC_Code,  gte_cr_GFC  = gte_cr_GFC_Code,  gte_cr_BFC  = gte_cr_BFC_Code,
	gte_cr_OFX  = gte_cr_OFX_Code,  gte_cr_OFY  = gte_cr_OFY_Code,
};

enum { _C2_OPS_ = 0

	, op_lwc2    = 0x32 /* Load Word  to   Coprocessor 2 (GTE) */
	, op_swc2    = 0x3A /* Store Word from Coprocessor 2 (GTE) */
};

/* COP2 (GTE) Transfer Format: ctc2 rt, rd or cfc2 rt, rd
 * Layout: [op_cop2:6][sub:5][rt:5][rd:5][0:11]
 *   - sub: cop_mf (0x00) for cfc2, cop_mt (0x04) for ctc2
 *   - rt:  GPR source/dest
 *   - rd:  COP2 control register index (0..31) */
#define enc_gte_tx(sub, rt, rd) (enc_op(op_cop2) | enc_rs(sub) | enc_rt(rt) | enc_rd(rd))

// #define gte_mv_to_data_r(rt, rd)   enc_gte_tx(cop_mt, (rt), (rd)) /* Move GPR (rt) to GTE Control Register (rd) */
// #define gte_mv_from_data_r(rt, rd) enc_gte_tx(cop_mf, (rt), (rd)) /* Move GTE Control Register (rd) to GPR (rt) */

/* GTE Data vs Control Register Transfers */
#define gte_mv_from_data_r(rt, rd) enc_gte_tx(0x00, (rt), (rd)) /* Move from GTE Data Reg (e.g. MAC0, OTZ) */
#define gte_mv_from_ctrl_r(rt, rd) enc_gte_tx(0x02, (rt), (rd)) /* Move from GTE Control Reg */
#define gte_mv_to_data_r(rt, rd)   enc_gte_tx(0x04, (rt), (rd)) /* Move to GTE Data Reg (e.g. VXY0) */
#define gte_mv_to_ctrl_r(rt, rd)   enc_gte_tx(0x06, (rt), (rd)) /* Move to GTE Control Reg (e.g. Matrices) */

/* COP2 Data Load (lwc2): `lwc2 rt, off(rs)`
 * Layout: [op_lwc2:6][rs:5][rt:5][imm:16]
 *   - rs: GPR base address
 *   - rt: COP2 data register index (0..31)
 *   - imm: signed 16-bit offset
 * NOTE: When `rs` is a runtime register, the encoding cannot be pre-baked
 * into a .word — use the string-style `gte_load_v0` macro below instead. */
#define enc_gte_lw(rt, base, off) enc_i(op_lwc2, (base), (rt), (off))
/* Store Word */
#define enc_gte_sw(rt, base, off) enc_i(op_swc2, (base), (rt), (off))

/* Semantic aliases for the COP2 data load/store. The `c2` in `lwc2`/
 * `swc2` is redundant when we're already inside the `gte_` namespace.
 *   gte_lw rt, base, off  →  lwc2 rt, off(base)
 *   gte_sw rt, base, off  →  swc2 rt, off(base)
 * For the typical user-facing vector-level load (xy + z as two
 * instructions), use the higher-level `gte_load_vN` macros below. */
#define gte_lw(rt, base, off) enc_gte_lw(rt, base, off)
#define gte_sw(rt, base, off) enc_gte_sw(rt, base, off)

/* GTE Command Format
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
#define enc_gte_sf(sf)   (((sf)  & gte_mask_sf ) << gte_shift_sf )
#define enc_gte_mx(mx)   (((mx)  & gte_mask_mx ) << gte_shift_mx )
#define enc_gte_v(v)     (((v)   & gte_mask_v  ) << gte_shift_v  )
#define enc_gte_cv(cv)   (((cv)  & gte_mask_cv ) << gte_shift_cv )
#define enc_gte_lm(lm)   (((lm)  & gte_mask_lm ) << gte_shift_lm )
#define enc_gte_cmd(cmd) (((cmd) & gte_mask_cmd) << gte_shift_cmd)

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

/* GTE command words for the common cases.
 *
 * These are pure compile-time integer constants — the C compiler
 * constant-folds them into `.word` directives in .rodata. Use them
 * inside `asm_inline(...)` blocks (see `gte_rtpt` below for the
 * canonical idiom).
 *
 * Decomposition (per the `enc_gte_<field>` definitions above):
 *   gte_cmdw_<name> = gte_cmd_base | enc_gte_cmd(<cmd>)
 
 * The SF/MX/V/CV/LM fields are all zero in the common cases (standard
 * rotation-matrix, no scaling factor, V0 vector, translation vector,
 * no clamp), so the only varying bits are the `cmd` field.
 *
 * Naming follows the file's convention: `gte_cmd_*` is the raw
 * 6-bit `cmd` field id, `gte_cmdw_*` is the fully-encoded 32-bit
 * instruction word ready to drop into a `.word` directive.
 *
 * --------------------------------------------------------------------------
 *  PsyQ-compatibility note (RTPS/RTPT):
 *  The original Sony PsyQ `inline_n.h` ships RTPT as `cop2 0x0280030` and
 *  RTPS as `cop2 0x0180001`. Both have `0x20` set in the upper-reserved
 *  region (bit 21) AND `sf=1` (bit 19) — i.e. the "no division" flag.
 *  Per psx-spec these bits are reserved/must-be-zero, but the real GTE
 *  hardware and PCSX-Redux's GTE model both IGNORE them on these two
 *  commands (the perspective divide happens regardless of `sf`).
 *
 *  If we emit a strictly-spec-compliant word (`sf=0`, reserved bits
 *  clear), PCSX-Redux's GTE checks those bits more strictly than the
 *  silicon does and RTPT silently no-ops — the floor's screen
 *  coordinates come out as raw projection-of-rotation (Z never
 *  divided), `nclip` ends up wrong, and the triangle is culled.
 *
 *  So for RTPS and RTPT we OR-in the `0x28` "PsyQ compat" pattern to
 *  match the working bit pattern everyone has shipped for 25 years.
 *  NCLIP/OP/MVMVA stay spec-clean — their reserved bits really are
 *  zero in the original PsyQ source.
 * --------------------------------------------------------------------------
 */
#define gte_cmdw_psyq_compat  (1u << 21 | enc_gte_sf(gte_sf_integer))

#define gte_cmdw_rtps   (gte_cmd_base | enc_gte_cmd(gte_cmd_rtps ) | gte_cmdw_psyq_compat)
#define gte_cmdw_rtpt   (gte_cmd_base | enc_gte_cmd(gte_cmd_rtpt ) | gte_cmdw_psyq_compat)
#define gte_cmdw_nclip  (gte_cmd_base | enc_gte_cmd(gte_cmd_nclip))
#define gte_cmdw_op     (gte_cmd_base | enc_gte_cmd(gte_cmd_op   ))
#define gte_cmdw_mvmva  (gte_cmd_base | enc_gte_cmd(gte_cmd_mvmva))

#define gte_cmdw_rotate_translate_perspective_triple gte_cmdw_rtpt

/* PsyQ compatibility bits for AVSZ3 (Bits 20, 22, 24 must be set) */
#define gte_cmdw_psyq_avsz3_compat (0x15 << 20)
#define gte_cmd_avsz3               0x2D

#define gte_cmdw_avsz3 (gte_cmd_base | enc_gte_cmd(gte_cmd_avsz3) | gte_cmdw_psyq_avsz3_compat)

// Takes the three screen-space Z values of the triangle → averages them → writes the result into the OTZ register.
#define gte_avg_sort_z3 gte_cmdw_avsz3

/* AVSZ4 — average Z of 4 vertices (for quads) */
#define gte_cmd_avsz4 0x2E
#define gte_cmdw_avsz4 (gte_cmd_base | enc_gte_cmd(gte_cmd_avsz4) | gte_cmdw_psyq_avsz3_compat)

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

/* lwc2 encoding helpers parameterized on the base GPR.
 *
 * gte_lw_v0_xy(base)  → lwc2 $0,  0(base)   ; C2_VXY0
 * gte_lw_v0_z(base)   → lwc2 $1,  4(base)   ; C2_VZ0
 * gte_lw_v1_xy(base)  → lwc2 $2,  0(base)   ; C2_VXY1
 * gte_lw_v1_z(base)   → lwc2 $3,  4(base)   ; C2_VZ1
 * gte_lw_v2_xy(base)  → lwc2 $4,  0(base)   ; C2_VXY2
 * gte_lw_v2_z(base)   → lwc2 $5,  4(base)   ; C2_VZ2
 *
 * `base` is the GPR number to bake into the .word constant's `rs` field.
 * These are pure compile-time integers; the C compiler constant-folds
 * them into .word directives. */

enum {
	GTE_Z_Offset = 4
};

#define gte_lw_v0_xy(base)  enc_gte_lw(gte_in_v0_xy, (base), 0)
#define gte_lw_v0_z(base)   enc_gte_lw(gte_in_v0_z,  (base), GTE_Z_Offset)
#define gte_lw_v1_xy(base)  enc_gte_lw(gte_in_v1_xy, (base), 0)
#define gte_lw_v1_z(base)   enc_gte_lw(gte_in_v1_z,  (base), GTE_Z_Offset)
#define gte_lw_v2_xy(base)  enc_gte_lw(gte_in_v2_xy, (base), 0)
#define gte_lw_v2_z(base)   enc_gte_lw(gte_in_v2_z,  (base), GTE_Z_Offset)

/* gte_load_vN(r_ptr, base) — placeholder-punned lwc2 loaders
 *
 * Emits `.word` constants encoding `lwc2 $N, off(<base>)` for the chosen
 * GTE vector register, where `<base>` is the GPR number you pass in
 * (typically one of R_T4..R_T9 for the standard "3-pointer" pattern).
 *
 * The caller MUST bind `r_ptr` to that same GPR via a register variable:
 *     register V3_S2* p_in_12 __asm__("$12") = my_ptr;
 *     gte_load_v0(p_in_12, R_T4);   // R_T4 = 12, base is $12
 *
 * Then `"r"(r_ptr)` inside the asm binds to $12 (the only register
 * `p_in_12` can live in), which is exactly the register the .word
 * constants expect. A `"$12"` clobber would conflict with the
 * register-variable binding ("asm specifier for variable conflicts
 * with asm clobber list"), so we omit it. The other ABI-clobbers
 * ($2/$8/$9/$31) stay because the GTE instructions don't touch
 * caller-saved GPRs but the kernel does treat them as volatile.
 *
 * WHICH REGISTER TO PICK
 * ----------------------
 * Any caller-saved GPR is safe. Recommended default for an RTPT-style
 * 3-pointer pipeline:
 *   gte_load_v0(p0, R_T4);  // $12
 *   gte_load_v1(p1, R_T5);  // $13
 *   gte_load_v2(p2, R_T6);  // $14
 * Avoid $0 (zero), $1 (at), $26/$27 (k0/k1), $28-$31 (gp/sp/fp/ra).
 *
 * Shape of the generated `asm volatile (...)`:
 *   code section       : ".word %0, %1"                 (from asm_inline)
 *   outputs section    : (empty, the 2nd colon)
 *   inputs section     : "i"(w0), "i"(w1), "r"(r_ptr)   — r_ptr bound to <base>
 *   clobbers section   : "$2", "$8", ..., "memory"      (from asm_clobber)
 *   3 colons total, GCC-legal. No string-syntax mnemonics in the .word body.
 *
 * The `asm_clobber(...)` helper from gcc_asm.h prepends the colon that
 * starts the clobbers section. */
#define gte_load_v0(r_ptr, base) asm volatile(       \
	asm_words( gte_lw_v0_xy(base), gte_lw_v0_z(base) ) \
	asm_rpins,   r_use(r_ptr)                          \
	asm_clobber: rlit(R_V0), rlit(R_T0), rlit(R_T1), rlit(R_RA), clb_mem_drain \
)

#define gte_load_v1(r_ptr, base) asm volatile(       \
	asm_words( gte_lw_v1_xy(base), gte_lw_v1_z(base) ) \
	asm_rpins,   r_use(r_ptr)                          \
	asm_clobber: rlit(R_V0), rlit(R_T0), rlit(R_T1), rlit(R_RA), clb_mem_drain \
)

#define gte_load_v2(r_ptr, base) asm volatile(       \
	asm_words( gte_lw_v2_xy(base), gte_lw_v2_z(base) ) \
	asm_rpins,   r_use(r_ptr)                          \
	asm_clobber: rlit(R_V0), rlit(R_T0), rlit(R_T1), rlit(R_RA), clb_mem_drain \
)

/* gte_load_v0v1v2(p0, p1, p2, b0, b1, b2) — the canonical prelude to gte_cmd_rtpt.
 *
 * Loads all three GTE input vectors (6 words) from three separate pointers,
 * one per GTE vector register, each loaded from its own base GPR. Caller
 * must bind each `pN` to `bN` via a register variable.
 *
 *   register V3_S2* p0 rgcc(R_T4) = verts[0].ptr;  // → __asm__("$12")
 *   register V3_S2* p1 rgcc(R_T5) = verts[1].ptr;  // → __asm__("$13")
 *   register V3_S2* p2 rgcc(R_T6) = verts[2].ptr;  // → __asm__("$14")
 *   gte_load_v0v1v2(p0, p1, p2, R_T4, R_T5, R_T6);
 *   gte_rtpt();
 */
#define gte_load_v0v1v2(p0, p1, p2, b0, b1, b2) asm volatile( \
	asm_words( \
		gte_lw_v0_xy(b0), gte_lw_v0_z(b0),  \
		gte_lw_v1_xy(b1), gte_lw_v1_z(b1),  \
		gte_lw_v2_xy(b2), gte_lw_v2_z(b2) ) \
	asm_rpins                             \
		, r_use(p0), r_use(p1), r_use(p2)   \
	asm_clobber: rlit(R_V0), rlit(R_T0), rlit(R_T1), rlit(R_RA), clb_mem_drain \
)

/**
 * @brief Rotate, Translate and Perspective Triple (23 cycles)
 *
 * @details Performs rotation, translation and perspective calculation of three
 * vertices at once. The equation performed is the same as gte_rtps() only
 * repeated three times for each vertex. The result of the first vertex is
 * stored in GTE data register C2_SXY0, the second vector in C2_SXY1 then
 * C2_SXY2.
 *
 * Encoder-style emission (no inline-asm strings in the code body):
 *   1. Two `nop` words fill the COP2 pipeline latency — the GTE
 *      takes ~8 cycles per perspective divide, and the nops let any
 *      preceding lwc2/swc2 retire before RTPT starts reading its
 *      inputs from V0/V1/V2.
 *   2. The RTPT command word itself is `gte_cmdw_rtpt` (see the
 *      pre-baked encoders above) — `0x0280030` decoded as
 *      `op_cop2` | CO(1) | cmd=RTPT, with all SF/MX/V/CV/LM fields
 *      zero (standard rotation, no scaling, V0 vector, translation
 *      vector, no clamp).
 *
 * Clobbers the caller-saved GPRs via `clbr_volatile_gprs` (per the kernel
 * ABI) plus the standard "memory" barrier. Does not clobber any COP2
 * data/control register — those have to be saved by the caller if
 * they need to survive across the call (RTPT writes SXY0..2, SZ0..3,
 * OTZ, MAC0..3, IR0..3, etc.).
 */
#define gte_rtpt()                        \
	asm volatile(                           \
		asm_words( nop, nop, gte_cmdw_rtpt )  \
		asm_clobber: clbr_volatile_gprs       \
	)

#define gte_rtpt_asm_str() \
	__asm__ volatile( \
		"nop;"          \
		"nop;"          \
		"cop2 0x0280030;")

/**
 * @brief Normal clipping (8 cycles)
 *
 * @details Computes the sign of three screen coordinates (C2_SXY0-2) used for
 * backface culling. If the value of C2_MAC0 is negative, the coordinates are
 * inverted and thus the triangle is back facing.
 *
 * The following equation is performed when executing this GTE command:
 *
 *     MAC0 = SX0*SY1 + SX1*SY2 + SX2*SY0 - SX0*SY2 - SX1*SY0 - SX2*SY1
 *
 * Encoder-style emission (no inline-asm strings in the code body):
 *   1. Two `nop` words fill the COP2 pipeline latency - the GTE
 *      pipeline takes a few cycles per op, and the nops let any
 *      preceding lwc2/swc2/RTPT retire before NCLIP starts reading
 *      its inputs from SXY0/SXY1/SXY2.
 *   2. The NCLIP command word itself is `gte_cmdw_nclip` (see the
 *      pre-baked encoders above) - `0x01400006` decoded as
 *      `op_cop2` | CO(1) | cmd=NCLIP, with all SF/MX/V/CV/LM fields
 *      zero. NCLIP is spec-clean in the original PsyQ source
 *      (unlike RTPS/RTPT which carry the `gte_cmdw_psyq_compat`
 *      quirk), so `gte_cmdw_nclip` does NOT OR in any reserved bits.
 *
 * Clobbers the caller-saved GPRs via `clbr_volatile_gprs` (per the kernel
 * ABI) plus the standard "memory" barrier. Does not clobber any COP2
 * data/control register - those have to be saved by the caller if
 * they need to survive across the call (NCLIP writes MAC0 only; it
 * is purely a sign-of-double-product computation on SXY0..2).
 */
#define gte_nclip()                       \
	asm volatile(                           \
		asm_words( nop, nop, gte_cmdw_nclip ) \
		asm_clobber: clbr_volatile_gprs               \
	)

#define gte_stotz(r0) __asm__ volatile("swc2   $7, 0( %0 )" : : "r"(r0) : "memory")

#define gte_stsxy3(r0, r1, r2)  \
	__asm__ volatile(             \
		"swc2   $12, 0( %0 );"      \
		"swc2   $13, 0( %1 );"      \
		"swc2   $14, 0( %2 )"       \
		:                           \
		: "r"(r0), "r"(r1), "r"(r2) \
		: "memory")

#define gte_avsz3() \
	__asm__ volatile( \
		"nop;"          \
		"nop;"          \
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
 * Same contract as gte_load_v0: caller MUST bind `r0` to $12 via a
 * register variable (`rgcc(R_T4)`) for the `lw $12, off(...)`
 * instructions to read from the right base. The `"r"(r0)` constraint
 * alone doesn't force a specific GPR — it just lets GCC pick one.
 * The .word constants here bake R_T4/R_T5/R_T6 into the `rs` field
 * of each lw, so the lw instructions will only do the right thing
 * if $12/$13/$14 hold the matrix base at runtime.
 *
 *   M3_S2* m = ...;
 *   register M3_S2* m_in_12 rgcc(R_T4) = m;
 *   asm_gte_matrix_set_rotation(m_in_12);
 *
 * We clobber $12/$13/$14 (the ones we use as scratch inside the
 * inline asm) plus the system clobbers; we don't clobber `r0` because
 * the `rgcc` binding already says "this variable lives in $12".
 *
 * WARNING: Incomplete by design. The source macro only writes RT11..RT22
 * (5 of 9 rotation elements); RT23 and the entire RT3x row are left
 * untouched. Real libpsn00b SetRotMatrix writes all 9. Use only when the
 * GTE's remaining rotation entries are already correct, or you will
 * get stale-RT2x/RT3x artifacts in RTPS/RTPT/MVMVA output.
 */
#define asm_gte_matrix_set_rotation(r0) \
	asm volatile(                         \
		asm_words(                          \
			  load_word(R_T5, R_T4,  0)       \
			, load_word(R_T6, R_T4,  4)       \
			, gte_mt(   R_T5,        0)       \
			, gte_mt(   R_T6,        1)       \
			, load_word(R_T5, R_T4,  8)       \
			, load_word(R_T6, R_T4, 12)       \
			, load_word(R_T4, R_T4, 16)       \
			, gte_mt(   R_T5,  2)             \
			, gte_mt(   R_T6,  3)             \
			, gte_mt(   R_T4,  4)             \
		)                                   \
		, r_use(r0)                         \
		asm_clobber: clbr_volatile_gprs, rlit(R_T4), rlit(R_T5), rlit(R_T6) \
	)

#pragma endregion ASM DSL

#pragma region Reserved



#pragma endregion Reserved
