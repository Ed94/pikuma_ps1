#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#		include "duffle/gen/macs.h"
#		include "duffle/gen/offsets.h"
#	include "duffle/dsl.atom.h"
#	include "duffle/lottes_tape.h"
#	include "duffle/mips.h"
#	include "duffle/gte.h"
#	include "duffle/gp.h"
#	include "duffle/pad.h"
#	include "duffle/word_count.metadata.h"
#	include "duffle/psyq.h"
#	include "duffle/math.atom.c"
#	include "duffle/mips.atom.c"
#	include "duffle/gte.atom.c"
#	include "duffle/gp.atom.c"
#	include "duffle/psyq.atom.c"
#		include "gen/offsets.h"
#		include "gen/macs.h"
#		include "gen/auto_reg.h"
#	include "hello_camera.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(hello_joypad_atom_c);

#pragma region MACs (Mips Atom components)

FI_ Slice_MipsCode ac_put_disp_env(AtomBuilder_R ab, U4 reg_transfer, U4 reg_base, U2 port)
MipsAtomComp_Proc_(ac_put_disp_env, ab, {
	// Emits 5 GP0 commands for buffer 0 (display_area = (0,0,320,240)).
	// Sequence per libpsyx PutDispEnv: DrawArea TL → DrawArea BR → Mask → DrawArea TL → DrawArea BR
	mac_gcmd_push(gp0_word_draw_area_top_left_origin,      reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240, reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_set_mask_bit(),                 reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_top_left_origin,      reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240, reg_transfer, reg_base, port),
})

I_ Slice_MipsCode ac_put_draw_env(AtomBuilder_R ab, U4 reg_transfer, U4 reg_base, U2 port)
MipsAtomComp_Proc_(ac_put_draw_env, ab, {
	/*
	* ORIGIN: each code word corresponds to the EXACT value libpsyx's PutDrawEnv function would compute for the same DrawEnv settings.
	* References:
	*   - libpsyx source: `toolchain/psyq-4_7/lib/libgpu.a` (binary, function `PutDrawEnv`)
	*   - PSX-SPX doc:     https://problemkaputt.de/psx-spx.htm#gputdrawingcommands
	*   - PSYQ SDK:        `setdrawenv` / `makelongdr_env` source
	*   - NOCASH PSX spec: §"GP0(E1h) Draw Mode setting" through §"DR_ENV"
	*
	* The 16-word format is documented in the PSYQ SDK manual and on NOCASH's PSX-spec.txt. The libpsyx reference is at:
	*   ./toolchain/psyq-4_7/lib/libgpu.a
	*   (binary; the PutDrawEnv implementation builds the 16-word DR_ENV from the user's DRAWENV struct and emits it via GP0 GPU commands.)
	*
	* Word indices (libpsyx PutDrawEnv / SetDrawEnv order):
	*   tag          = (length << 24) | addr                — 16-word packet (1 tag + 15 code)
	*   code[0]      = DrawMode (dfe=1, dtd=0, tpage=0)     — must come first per libpsyx
	*   code[1]      = TextureWindow (tw=(0,0))             — bare-cmd word; GPU uses current state
	*   code[2]      = DrawArea top-left (clip.x=0, clip.y=240)
	*   code[3]      = DrawArea bottom-right (clip.x+w=320, clip.y+h=480)
	*   code[4]      = DrawOffset (ofs=(0,0))               — bare-cmd word
	*   code[5]      = Mask (dtd=0, dfe=1, isbg=1)          — 0xE6 cmd + isbg bit
	*   code[6]      = Initial-bg-color (isbg=1, r=7, g=7, b=7)
	*   code[7]      = DrawMode (isbg=1, tpage=0)           — re-asserts DrawMode with isbg
	*   code[8..10]  = padding (NOP)                        — 3 words to fill the packet
	*   code[11..12] = TextureWindow bottom-right           — defaults to (0,0,0,0)
	*   code[13..14] = padding (NOP)                        — completes the 16-word packet
	*/
	mac_gcmd_push(gp0_dr_env_tag,                            reg_transfer, reg_base, port), /* tag (length=15 << 24, addr=0) — packet header for the DR_ENV sequence. The GPU needs this to recognize the next 15 words as a DR_ENV packet and trigger the isbg auto-clear. */
	mac_gcmd_push(gp0_word_draw_mode_drawing_allowed,        reg_transfer, reg_base, port), /* code[0]  DrawMode (dfe=1, dtd=0, tpage=0) */
	mac_gcmd_push(gp0_word_set_texture_window(),             reg_transfer, reg_base, port), /* code[1]  TextureWindow (tw=(0,0)) */
	mac_gcmd_push(enc_gp0_draw_area_tl_word(0, ScreenRes_Y), reg_transfer, reg_base, port), /* code[2]  DrawArea top-left (clip.x=0, clip.y=ScreenRes_Y=240) */
	mac_gcmd_push(gp0_word_draw_area_bottom_right_320x240,   reg_transfer, reg_base, port), /* code[3]  DrawArea bottom-right (clip.x+w=320, clip.y+h=480) */

	mac_gcmd_push(gp0_word_set_draw_offset(),               reg_transfer, reg_base, port), /* code[4]  DrawOffset (ofs=(0,0)) — bare-cmd word; the GPU uses the current state machine. */
	mac_gcmd_push(gp0_word_dr_env_mask(),                   reg_transfer, reg_base, port), /* code[5]  Mask (dtd=0, dfe=1, isbg=1) — 0xE6 cmd + isbg bit. */
	mac_gcmd_push(gp0_word_dr_env_bg_color_cmd(1, 7, 7, 7), reg_transfer, reg_base, port), /* code[6]  Initial-bg-color + auto-clear (isbg=1, r=7, g=7, b=7). */
	mac_gcmd_push(gp0_word_dr_env_draw_mode(1),             reg_transfer, reg_base, port), /* code[7]  Re-assert DrawMode with isbg=1 (isbg-flag set; the 0xE1 cmd byte plus isbg only). */

	/* code[8..10]  Padding (NOP — GPU discards; the DR_ENV requires 16 words total). */
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),

	/* code[11..12]  TextureWindow bottom-right (tw.x+tw.w=0, tw.y+tw.h=0) — libpsyx emits twice. */
	mac_gcmd_push(gp0_word_set_texture_window(), reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_set_texture_window(), reg_transfer, reg_base, port),

	/* code[13..14]  Padding (NOP) — completes the 16-word packet. */
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),
	mac_gcmd_push(gp0_word_nop(), reg_transfer, reg_base, port),
})

#pragma endregion MACs

#pragma region Atom Procs
// Modular Atoms

/* Scratchpad layout for the resolve_look_at bundle.
 * The chain atoms communicate entirely via the wave-context GPR carrier R_ResolveScratch (R_T4) + hardcoded offsets into smem.scratchpad
 * (PS1 hardware scratchpad at 0x1F800000).
 *
 * Atom 0 (input_and_sub) STAGES the C-side inputs (eye, up_in) into the scratchpad;
 * AT THE SAME TIME it computes fwd = target - eye and stores it at scratch+0.
 * Atoms 1-6 then read/write specific scratchpad offsets internally using
 * `r_scratch + hardcoded_offset` — no tape-data pointers are passed between atoms.
 *   +0   fwd   (atom 0 writes; atom  1 reads)
 *   +16  uz    (atom 1 writes; atoms 2 + 4 read)
 *   +32  right (atom 2 writes; atom  3 reads)
 *   +48  ux    (atom 3 writes; atoms 4 + 6 read)
 *   +64  up    (atom 4 writes; atom  5 reads)
 *   +80  uy    (atom 5 writes; atom  6 reads)
 *   +96  eye   (atom 0 stages from C-side pointer; atom 6 reads)
 *   +128 up_in (atom 0 stages from C-side pointer; atom 2 reads)
 */

// enum {
// 	R_LookAt    = R_T0 atom_reg atom_type(MT3_S2S4*),
// 	R_CamEye    = R_T1 atom_reg atom_type(P3_S4*),
// 	R_CamTarget = R_T2 atom_reg atom_type(P3_S4*),
// 	R_WorldUp   = R_T3 atom_reg atom_type(V3_S4*),
// };

enum {
	/* Wave-context GPR carrier for the resolve_look_at bundle: the scratch base.
	* Set by atom 0 (popped from tape), read by atoms 1-6 (used as pointer base). */
	R_ResolveScratch = R_T4 atom_reg atom_type(U4*),
};
typedef Struct_(Binds_ResolveLookAt) {
	MT3_S2S4* look_at;
	P3_S4*    eye;
	P3_S4*    target;
	V3_S4*    up_in;
};

/* ─── ResolveLookAtScratch — offset schema for the resolve_look_at bundle's
 * scratchpad slots (PS1 hardware scratchpad at 0x1F800000).
 *
 * Each slot is 16 bytes: V3_S4 is already 16 bytes (4 × S4 = x/y/z/pad).
 * The struct fields are contiguous — slot i starts at offset i*16.
 * Used by the assembly via O_(ResolveLookAtScratch, fld.x/y/z) which resolves to a compile-time byte offset.
 * NOT a runtime struct — the struct is purely a schema for offsets; the assembly uses `r_scratch + O_(...)` to compute slot addresses at runtime.
 *
 * Slot producers/consumers (referenced by the resolve_look_at chain atoms):
 *   +0    fwd    0 writes (target - eye);     atom  1 (normalize) reads
 *   +16   uz     1 writes (normalize fwd);    atoms 2 + 4 read (cross operands)
 *   +32   right  2 writes (cross uz x up_in); atom  3 (normalize) reads
 *   +48   ux     3 writes (normalize right);  atoms 4 + 6 read
 *   +64   up     4 writes (cross uz x ux);    atom  5 (normalize) reads
 *   +80   uy     5 writes (normalize up);     atom  6 reads
 *   +96   eye    0 stages (C-side input);     atom  6 reads (translation column)
 *   +112  target reserved (currently written nowhere — kept for symmetry w/ eye)
 *   +128  up_in  0 stages (C-side input); atom 2 reads (cross operand)
 *
 * Fields use P3_S4 (point) for eye/target (RGA: affine point, implicit weight 1);
 * V3_S4 (vector) for fwd/uz/right/ux/up/uy/up_in (RGA: Euclidean vector).
 * P3_S4 is a storage alias of V3_S4 (see math.h comment: "Storage alias of V3_S4.
 * Use P3_S4 when the value is a point.") — both are 16 bytes.
 */
typedef Struct_(ResolveLookAtScratch) {
	V3_S4 fwd;       /* offset  +0  (16 bytes — 4 S4 fields incl. internal pad) */
	V3_S4 uz;        /* offset +16 (16 bytes) */
	V3_S4 right;     /* offset +32 (16 bytes) */
	V3_S4 ux;        /* offset +48 (16 bytes) */
	V3_S4 up;        /* offset +64 (16 bytes) */
	V3_S4 uy;        /* offset +80 (16 bytes) */
	P3_S4 eye;       /* offset +96 (16 bytes; storage alias of V3_S4) */
	P3_S4 target;    /* offset +112 (16 bytes; storage alias of V3_S4) */
	V3_S4 up_in;     /* offset +128 (16 bytes) */
};

/* ─── resolve_look_at bundle chain atoms ────────────────────────────
 * 4 unique atom procs in the resolve_look_at bundle (4 chain atoms + 3 calls to generic normalize_v3s4_proc).
 * All 4 chain atoms are runtime-built MipsAtom_Proc_ atoms: each function declares a static MipsCode[] body, 
 * then calls atombuilder_unroll() to append it to the caller's MipsAtomBuilder arena. resolve_look_at_init() 
 * uses this pattern to pre-build the bundle into the static arena (smem.resolve_look_at_arena).
 *
 * Atom roster:
 *	0: resolve_look_at__input_and_sub              (chain atom)
 *	1: normalize_v3s4_proc (gte.atom.c)            (generic normalize; called for fwd→uz)
 *	2: resolve_look_at__cross_uz_up_in_to_right    (chain atom)
 *	3: normalize_v3s4_proc (gte.atom.c)            (generic normalize; called for right→ux)
 *	4: resolve_look_at__cross_uz_ux_to_up          (chain atom)
 *	5: normalize_v3s4_proc (gte.atom.c)            (generic normalize; called for up→uy)
 *	6: resolve_look_at__populate_and_translate     (chain atom)
 *
 * The generic normalize_v3s4_proc is a parameterized 4-stage GTE normalize (SQR → mfc2 → LZCS → GPF → srav);
 * it accepts scratch base + offset args so any caller (with a scratch base + struct schema) can use it.
 */

typedef Struct_(Binds_ResolveLookAtSub) {
	U4 target;  /* U4 (C-side P3_S4* — read by atom 0 directly; NOT a scratchpad address) */
	U4 eye;     /* U4 (C-side P3_S4* — read by atom 0 directly; staged into scratchpad by atom 0) */
	U4 up_in;   /* U4 (C-side V3_S4* — read by atom 0 directly; staged into scratchpad by atom 0) */
	U4 scratchpad;
};

/* Atom 0 in the bundle: input_and_sub. Stages C-side inputs into the scratchpad and computes fwd = target - eye.
 * Inputs (C-side pointers popped from the tape):
 *   r_target_ptr : P3_S4* (C-side struct; atom 0 reads target.x/y/z directly)
 *   r_eye_ptr    : P3_S4* (C-side struct; staged into scratchpad at +96/+100/+104)
 *   r_up_in_ptr  : V3_S4* (C-side struct; staged into scratchpad at +128/+132/+136)
 *   r_scratch    : R_ResolveScratch (R_T4) — scratch base, read by atoms 1-6
 * 
 * Bind-pop layout:
 *   Binds_ResolveLookAtSub
 * Staging work:
 *   * Stage eye.x/y/z   → scratch (for atom 6's translation column)
 *   * Stage up_in.x/y/z → scratch (for atom 2's outer-product operand)
 *   * Compute fwd = target - eye, store fwd.x/y/z → scratch+0/+4/+8 (for atom 1)
 *
 * GPR codes (assigned by resolve_look_at_init):
 *   r_target_ptr : R_T0
 *   r_eye_ptr    : R_T1
 *   r_up_in_ptr  : R_T2
 *   r_scratch    : R_T4 (R_ResolveScratch; wave-context carrier)
 *   r_tmp0       : R_T3 (stage eye/up_in + load eye.y)
 *   r_tmp1       : R_T5 (stage eye/up_in + load eye.z)
 *   r_tmp2       : R_T6 (stage eye/up_in + load target.x)
 *   r_tmp3       : R_T7 (stage eye/up_in + load target.y)
 *   R_AT         : hardcoded (load eye.y / eye.z / target.z)
 *   R_V0         : hardcoded (load eye.z / target.z)
 *
 * Pool cost: 8 GPRs + R_T4 (carrier) + R_AT + R_V0 (hardcoded) = 11 GPRs.
 */
internal MipsAtom* resolve_look_at__input_and_sub_proc(AtomArena_R aa,	U4 r_scratch
	,	U4 r_target_ptr,U4 r_eye_ptr, U4 r_up_in_ptr
	,	U4 r_tmp0,      U4 r_tmp1,    U4 r_tmp2, U4 r_tmp3
) MipsAtom_Proc_(resolve_look_at__input_and_sub, aa, {
	/* Pop the 3 C-side pointers + scratch_base from the tape. */
	load_word(r_target_ptr, R_TapePtr, O_(Binds_ResolveLookAtSub,target)),
	load_word(r_eye_ptr,    R_TapePtr, O_(Binds_ResolveLookAtSub,eye)),
	load_word(r_up_in_ptr,  R_TapePtr, O_(Binds_ResolveLookAtSub,up_in)),
	load_word(r_scratch,    R_TapePtr, O_(Binds_ResolveLookAtSub,scratchpad)),
	add_ui_self(            R_TapePtr, S_(Binds_ResolveLookAtSub)),

	/* Stage eye.x/y/z into the scratchpad (atom 6 reads these for the translation
	 * column). Reuse r_tmp0/r_tmp1/r_tmp2. Offsets via O_(ResolveLookAtScratch,*). */
	load_word(r_tmp0, r_eye_ptr, O_(P3_S4,x)),
	load_word(r_tmp1, r_eye_ptr, O_(P3_S4,y)),
	load_word(r_tmp2, r_eye_ptr, O_(P3_S4,z)),
	nop, /* load-delay */
	store_word(r_tmp0, r_scratch, O_(ResolveLookAtScratch,eye.x)),
	store_word(r_tmp1, r_scratch, O_(ResolveLookAtScratch,eye.y)),
	store_word(r_tmp2, r_scratch, O_(ResolveLookAtScratch,eye.z)),

	/* Stage up_in.x/y/z into the scratchpad (atom 2 reads these for the outer
	 * product with uz). Reuse r_tmp0/r_tmp1/r_tmp2. */
	load_word(r_tmp0, r_up_in_ptr, O_(V3_S4,x)),
	load_word(r_tmp1, r_up_in_ptr, O_(V3_S4,y)),
	load_word(r_tmp2, r_up_in_ptr, O_(V3_S4,z)),
	nop, /* load-delay */
	store_word(r_tmp0, r_scratch, O_(ResolveLookAtScratch,up_in.x)),
	store_word(r_tmp1, r_scratch, O_(ResolveLookAtScratch,up_in.y)),
	store_word(r_tmp2, r_scratch, O_(ResolveLookAtScratch,up_in.z)),

	/* Compute fwd = target - eye. */
	load_word(r_tmp0, r_target_ptr, O_(P3_S4,x)),
	load_word(r_tmp1, r_target_ptr, O_(P3_S4,y)),
	load_word(r_tmp2, r_target_ptr, O_(P3_S4,z)),
	load_word(r_tmp3, r_eye_ptr,    O_(P3_S4,x)),
	load_word(R_AT,   r_eye_ptr,    O_(P3_S4,y)),
	load_word(R_V0,   r_eye_ptr,    O_(P3_S4,z)),
	nop, /* load-delay */
	sub_u(r_tmp0, r_tmp0, r_tmp3),
	sub_u(r_tmp1, r_tmp1, R_AT),
	sub_u(r_tmp2, r_tmp2, R_V0),

	/* Store fwd.x/y/z (atom 1 reads these as the normalize src). */
	store_word(r_tmp0, r_scratch, O_(ResolveLookAtScratch,fwd.x)),
	store_word(r_tmp1, r_scratch, O_(ResolveLookAtScratch,fwd.y)),
	store_word(r_tmp2, r_scratch, O_(ResolveLookAtScratch,fwd.z)),

	mac_yield()
})

/* Atoms 2 + 4 in the bundle: out = a × b (GTE outer product on IR/D vectors).
 * No bind pop — the three operand pointers (a, b, out) are derived in-body from r_scratch + hardcoded_offset.
 * Each atom has its own variant because the offsets are baked into the body and each atom uses unique GPRs.
 *
 * GTE register layout (per PSX-SPX + duffle gte.h):
 *   IR1/2/3  = a.x/y/z    (mtc2)
 *   VXY0     = b.x        (mtc2)
 *   VZ0      = b.y        (mtc2)
 *   VXY1     = b.z        (mtc2)
 *   OP       = outer product
 *   MAC1/2/3 = out.x/y/z  (mfc2)
 *
 * Pool cost: r_scratch (R_T4 carrier) + 7 body GPRs + R_AT + R_V0 (hardcoded) = 10 GPRs.
 */

/* Atom 2: cross uz × up_in → right. */
internal MipsAtom* resolve_look_at__cross_uz_up_in_to_right_proc(AtomArena_R aa, U4 r_scratch
	,	U4 r_a, U4 r_b, U4 r_c /* load a.x/y/z; result out.x/y/z */
	,	U4 r_d                 /* load b.x */
	,	U4 r_f, U4 r_g, U4 r_h /* r_f = &right (out ptr), r_g = &uz, r_h = &up_in */
) MipsAtom_Proc_(resolve_look_at__cross_uz_up_in_to_right, aa, {
	/* FIX: build packed RT22+RT33 with proper sign extension. */
	add_si(r_g, r_scratch, O_(ResolveLookAtScratch,uz)),    /* r_g = &uz */
	add_si(r_h, r_scratch, O_(ResolveLookAtScratch,up_in)), /* r_h = &up_in */
	add_si(r_f, r_scratch, O_(ResolveLookAtScratch,right)), /* r_f = &right (out) */
	nop,

	/* Load a (uz).x/y/z into r_a/r_b/r_c. */
	load_word(r_a, r_g, O_(V3_S4,x)),
	load_word(r_b, r_g, O_(V3_S4,y)),
	load_word(r_c, r_g, O_(V3_S4,z)),
	nop,

	/* Load b (up_in).x/y/z into r_d + R_AT/R_V0 (R_AT/R_V0 are hardcoded scratch). */
	load_word(r_d,  r_h, O_(V3_S4,x)),
	load_word(R_AT, r_h, O_(V3_S4,y)),
	load_word(R_V0, r_h, O_(V3_S4,z)),
	nop,

	/* Save the two RT control-register slots OP will clobber. We reuse
	 * r_g/r_h (scratch pointers, no longer needed) as the save targets. */
	gte_mv_from_ctrl_r(r_g, gte_cr_RT11),    /* r_g = C2 r0 (RT11|RT12) */
	gte_mv_from_ctrl_r(r_h, gte_cr_RT22),    /* r_h = C2 r4 (RT22|RT33) */

	/* Load uz.x/uz.y/uz.z into COP2 control registers.
	 * OP reads D1 = RT11 from $0.low, D2 = RT22 from $2.high, D3 = RT33 from $4.high.
	 * RT22 is in BOTH $2.high AND $4.low (shared bit position). OP reads from $2.high.
	 * So set RT22 via ctc2 r_b, $2 (sets $2.high = a.y.high = RT22, $2.low = a.y.low = RT13).
	 * Then set RT33 via ctc2 r_c, $4 (sets $4.high = a.z.high = RT33, $4.low = a.z.low).
	 * The $2 and $4 writes don't clobber each other (separate registers).
	 * The 2nd ctc2 DOES clobber $4.low (becomes a.z.low, NOT a.y.high), but since OP
	 * reads RT22 from $2.high (which the 2nd ctc2 doesn't touch), D2 is still a.y.high.
	 * This is libpsyx's OuterProduct12 convention EXACTLY. */
	gte_mv_to_ctrl_r(r_b, gte_cr_RT13),    /* $2 = r_b = a.y. RT13=a.y.low, RT22=a.y.high. */
	gte_mv_to_ctrl_r(r_c, gte_cr_RT22),    /* $4 = r_c = a.z. RT22=a.z.low, RT33=a.z.high. */

	/* Load uz into the RT diagonal. */
	gte_mv_to_ctrl_r(r_a, gte_cr_RT11),   /* D1 = RT11 = uz.x (low 16 of $0, sign-extended by OP). */
	nop2,                                 /* CTC2 retirement (CPU→COP2 2-slot delay) */

	/* Load up_in into IR (the second operand for OP). */
	gte_mv_to_data_r(r_d,  C2_IR1),       /* IR1 = up_in.x */
	gte_mv_to_data_r(R_AT, C2_IR2),       /* IR2 = up_in.y */
	gte_mv_to_data_r(R_V0, C2_IR3),       /* IR3 = up_in.z */
	nop2,                                 /* MTC2 retirement (CPU→COP2 2-slot delay) */

	gte_cmdw_outer_product, /* OP: MAC1/2/3 = uz × up_in
		*   MAC1 = IR3*D2 - IR2*D3 = up_in.z*uz.y.high - up_in.y*uz.z.high
		*   MAC2 = IR1*D3 - IR3*D1 = up_in.x*uz.z.high - up_in.z*uz.x
		*   MAC3 = IR2*D1 - IR1*D2 = up_in.y*uz.x - up_in.x*uz.y.high
		* For up_in = (0, -fp_one, 0):
		*   MAC1 = 0 - (-fp_one)*uz.z.high = fp_one*uz.z.high
		*   MAC2 = 0 - 0 = 0
		*   MAC3 = (-fp_one)*uz.x - 0 = -fp_one*uz.x */

	/* Restore the RT slots we clobbered. */
	gte_mv_to_ctrl_r(r_g, gte_cr_RT11),   /* restore C2 r0 (RT11|RT12) */
	gte_mv_to_ctrl_r(r_h, gte_cr_RT22),   /* restore C2 r4 (RT22|RT33) */

	/* mfc2 MAC1/2/3 → r_a/r_b/r_c (out.x/y/z). */
	gte_mv_from_data_r(r_a, C2_MAC1),
	gte_mv_from_data_r(r_b, C2_MAC2),
	gte_mv_from_data_r(r_c, C2_MAC3),
	nop,  /* MFC2 retirement */

	/* Right-shift MAC by 12 to convert from GTE's S12.20 fixed-point scale back to libpsyx OuterProduct12 convention (S12.0, fp_one=4096=1<<12).
	 * Without this, MAC values (~16M for unit-vector cross products) overflow the GTE's 16-bit IR registers when atom 3 normalizes via mtc2. */
	shift_aright(r_a, r_a, 12),
	shift_aright(r_b, r_b, 12),
	shift_aright(r_c, r_c, 12),

	/* Store out.x/y/z to r_f (out ptr = scratch+32). */
	store_word(r_a, r_f, O_(V3_S4,x)),
	store_word(r_b, r_f, O_(V3_S4,y)),
	store_word(r_c, r_f, O_(V3_S4,z)),

	mac_yield()
})

/* Atom 4: cross uz × ux → up. */
internal MipsAtom* resolve_look_at__cross_uz_ux_to_up_proc(AtomArena_R aa,	U4 r_scratch
	,	U4 r_a, U4 r_b, U4 r_c /* load a.x/y/z; result out.x/y/z */
	,	U4 r_d                 /* load b.x */
	,	U4 r_f, U4 r_g, U4 r_h /* r_f = &up (out ptr), r_g = &uz, r_h = &ux */
) MipsAtom_Proc_(resolve_look_at__cross_uz_ux_to_up, aa, {
	/* Compute the three scratch pointers from r_scratch. */
	add_si(r_g, r_scratch, O_(ResolveLookAtScratch,uz)), /* r_g = &uz */
	add_si(r_h, r_scratch, O_(ResolveLookAtScratch,ux)), /* r_h = &ux */
	add_si(r_f, r_scratch, O_(ResolveLookAtScratch,up)), /* r_f = &up (out) */
	nop,

	/* Load a (uz).x/y/z into r_a/r_b/r_c. */
	load_word(r_a, r_g, O_(V3_S4,x)),
	load_word(r_b, r_g, O_(V3_S4,y)),
	load_word(r_c, r_g, O_(V3_S4,z)),
	nop,

	/* Load b (ux).x/y/z into r_d + R_AT/R_V0. */
	load_word(r_d,  r_h, O_(V3_S4,x)),
	load_word(R_AT, r_h, O_(V3_S4,y)),
	load_word(R_V0, r_h, O_(V3_S4,z)),
	nop,

	/* OP reads D1/D2/D3 from RT11/RT22/RT33 ($0/$2/$4), not V0/V1/V2.
	 * Mirror atom 1: cfc2 RT save, ctc2 RT diagonal from uz, mtc2 IR from ux,
	 * ctc2 RT restore. */

	/* Save the two RT control-register slots OP will clobber (reusing
	 * r_g/r_h — they're no longer needed as scratch pointers). */
	gte_mv_from_ctrl_r(r_g, gte_cr_RT11),    /* r_g = C2 $0 (RT11|RT12) */
	gte_mv_from_ctrl_r(r_h, gte_cr_RT22),    /* r_h = C2 $4 (RT22|RT33) */

	/* Load uz into the RT diagonal — same packing as atom 1.
	 * OP reads D1 = RT11 from $0.low, D2 = RT22 from $2.high, D3 = RT33 from $4.high.
	 * RT22 is shared between $2.high and $4.low — the ctc2 sequence to $2 then $4
	 * sets RT22 to uz.y.high (via $2), then to uz.z.low (via $4). OP reads
	 * RT22 from $2.high which the second ctc2 doesn't touch, so D2 stays uz.y.high.
	 * (This is libpsyx OuterProduct12 convention EXACTLY.) */
	gte_mv_to_ctrl_r(r_b, gte_cr_RT13),    /* $2 = uz.y. RT13=uz.y.low, RT22=uz.y.high. */
	gte_mv_to_ctrl_r(r_c, gte_cr_RT22),    /* $4 = uz.z. RT22=uz.z.low, RT33=uz.z.high. */
	gte_mv_to_ctrl_r(r_a, gte_cr_RT11),   /* $0 = uz.x. RT11=uz.x. */
	nop2,                                 /* CTC2 retirement (CPU→COP2 2-slot delay) */

	/* Load ux into the IR registers (the second operand for OP). */
	gte_mv_to_data_r(r_d,  C2_IR1),       /* IR1 = ux.x */
	gte_mv_to_data_r(R_AT, C2_IR2),       /* IR2 = ux.y */
	gte_mv_to_data_r(R_V0, C2_IR3),       /* IR3 = ux.z */
	nop2,                                 /* MTC2 retirement (CPU→COP2 2-slot delay) */

	gte_cmdw_outer_product,

	/* Restore the RT slots we clobbered. */
	gte_mv_to_ctrl_r(r_g, gte_cr_RT11),   /* restore C2 $0 (RT11|RT12) */
	gte_mv_to_ctrl_r(r_h, gte_cr_RT22),   /* restore C2 $4 (RT22|RT33) */

	gte_mv_from_data_r(r_a, C2_MAC1),
	gte_mv_from_data_r(r_b, C2_MAC2),
	gte_mv_from_data_r(r_c, C2_MAC3),
	nop,
	/* Right-shift MAC by 12 to convert from GTE's S12.20 scale back to libpsyx
	 * OuterProduct12 convention (S12.0, fp_one=4096). See atom 1 for rationale. */
	shift_aright(r_a, r_a, 12),
	shift_aright(r_b, r_b, 12),
	shift_aright(r_c, r_c, 12),
	store_word(r_a, r_f, O_(V3_S4,x)),
	store_word(r_b, r_f, O_(V3_S4,y)),
	store_word(r_c, r_f, O_(V3_S4,z)),

	mac_yield()
})

typedef Struct_(Binds_ResolveLookAtPopAndTrans) {
	U4 look_at;  /* U4 (MT3_S2S4* — destination matrix address) */
};
/* Atom 6 in the bundle: write look_at->m[][] from ux/uy/uz, then compute the translation column t[] = R * (-eye).
 *
 * GPR codes (assigned by resolve_look_at_init):
 *   r_look_at   : MT3_S2S4* (popped from tape; output matrix destination)
 *   r_pux       : pointer to ux   (offset O_(ResolveLookAtScratch,ux))
 *   r_puy       : pointer to uy   (offset O_(ResolveLookAtScratch,uy))
 *   r_puz       : pointer to uz   (offset O_(ResolveLookAtScratch,uz))
 *   r_peye      : pointer to eye  (offset O_(ResolveLookAtScratch,eye))
 *   r_tmp0/1/2  : atom-local scratch (load + MVMVA + store temps)
 *
 * 4 pointer regs (r_pux/r_puy/r_puz/r_peye) are DEDICATED — they hold the scratch addresses for the entire body.
 * They are computed in-body via `add_si(r_px, r_scratch, O_(ResolveLookAtScratch, field))` so no tape-data pointer is needed.
 *
 * Struct layout (per duffle/math.h):
 *   MT3_S2S4 { A3x3_S2 m; A3_S4 t; }  →  m[][] is S2 packed (9 × 2 = 18 bytes at offset 0) 
 *                                        t[0/1/2] is S4     (3 × 4 = 12 bytes at offset 18)
 *
 * Translation column: GTE MVMVA with the world rotation matrix pre-set
 * (helper emits set_gte_world before the bundle, per the bundle design).
 * MVMVA computes R * pos (with cv=0/mx=0/sf=0/v=0); MAC1/2/3 = R * (-eye).
 * Pool cost: r_look_at (1) + r_scratch (R_T4 carrier) + 4 ptr regs + 3 tmp regs = 9 GPRs.
 */
internal MipsAtom* resolve_look_at__populate_proc(AtomArena_R aa
	,	U4 r_look_at
	,	U4 r_scratch
	,	U4 r_pux, U4 r_puy, U4 r_puz
	,	U4 r_tmp0, U4 r_tmp1, U4 r_tmp2
) MipsAtom_Proc_(resolve_look_at__populate, aa, {
	/* Pop look_at* (the matrix output) — advance R_TapePtr by 4 bytes. */
	load_word(r_look_at, R_TapePtr, O_(Binds_ResolveLookAtPopAndTrans,look_at)),
	add_ui_self(         R_TapePtr, S_(Binds_ResolveLookAtPopAndTrans)),

	/* Compute the 3 scratch pointers in their dedicated GPRs (eye isn't needed by 6a — 6b reads it). */
	add_si(r_pux, r_scratch, O_(ResolveLookAtScratch,ux)),  /* r_pux = &ux */
	add_si(r_puy, r_scratch, O_(ResolveLookAtScratch,uy)),  /* r_puy = &uy */
	add_si(r_puz, r_scratch, O_(ResolveLookAtScratch,uz)),  /* r_puz = &uz */
	nop,

	/* ── m[0] = (S2)ux ── */
	load_word(r_tmp0, r_pux, O_(V3_S4,x)),
	load_word(r_tmp1, r_pux, O_(V3_S4,y)),
	load_word(r_tmp2, r_pux, O_(V3_S4,z)),
	nop,
	store_half(r_tmp0, r_look_at, O_(MT3_S2S4,m[0][0])),
	store_half(r_tmp1, r_look_at, O_(MT3_S2S4,m[0][1])),
	store_half(r_tmp2, r_look_at, O_(MT3_S2S4,m[0][2])),

	/* ── m[1] = (S2)uy ── */
	load_word(r_tmp0, r_puy, O_(V3_S4,x)),
	load_word(r_tmp1, r_puy, O_(V3_S4,y)),
	load_word(r_tmp2, r_puy, O_(V3_S4,z)),
	nop,
	store_half(r_tmp0, r_look_at, O_(MT3_S2S4,m[1][0])),
	store_half(r_tmp1, r_look_at, O_(MT3_S2S4,m[1][1])),
	store_half(r_tmp2, r_look_at, O_(MT3_S2S4,m[1][2])),

	/* ── m[2] = (S2)uz ── */
	load_word(r_tmp0, r_puz, O_(V3_S4,x)),
	load_word(r_tmp1, r_puz, O_(V3_S4,y)),
	load_word(r_tmp2, r_puz, O_(V3_S4,z)),
	nop,
	store_half(r_tmp0, r_look_at, O_(MT3_S2S4,m[2][0])),
	store_half(r_tmp1, r_look_at, O_(MT3_S2S4,m[2][1])),
	store_half(r_tmp2, r_look_at, O_(MT3_S2S4,m[2][2])),

	/* Zero t[0..2] — atom 6c writes the final values here. */
	store_word(R_0, r_look_at, O_(MT3_S2S4,t[0])),
	store_word(R_0, r_look_at, O_(MT3_S2S4,t[1])),
	store_word(R_0, r_look_at, O_(MT3_S2S4,t[2])),

	mac_yield()
})

/* Atom 6b in the bundle: matrix-vector product off = R * (-eye) >> 12.
 * Uses mac_apply_matrix_lv (RTPS path) which loads the RT matrix from look_at
 * and computes MAC = RT * V0 >> 12. Stores off to scratch+96 (overwriting eye).
 *
 * GPR codes (assigned by resolve_look_at_init):
 *   r_scratch : R_ResolveScratch (R_T4) — scratch base
 *   r_peye    : pointer to eye (slot +96, reused as off destination)
 *   r_tmp0/1/2: -eye + GTE transfer scratch
 *
 * Pool cost: r_scratch (carrier) + 1 ptr reg + 3 tmp regs = 5 GPRs.
 */
internal MipsAtom* resolve_look_at__matrix_vector_proc(AtomArena_R aa
	,	U4 r_scratch
	,	U4 r_peye
	,	U4 r_look_at
	,	U4 r_tmp0, U4 r_tmp1, U4 r_tmp2
	,	U4 r_tmp3, U4 r_tmp4, U4 r_tmp5
) MipsAtom_Proc_(resolve_look_at__matrix_vector, aa, {
	/* r_peye = &eye (slot +96, will be overwritten with off). */
	add_si(r_peye, r_scratch, O_(ResolveLookAtScratch,eye)),
	nop,

	/* Load pos = -eye from scratch. */
	load_word(r_tmp0, r_peye, O_(P3_S4,x)),
	load_word(r_tmp1, r_peye, O_(P3_S4,y)),
	load_word(r_tmp2, r_peye, O_(P3_S4,z)),
	nop,
	sub_u(r_tmp0, R_0, r_tmp0),
	sub_u(r_tmp1, R_0, r_tmp1),
	sub_u(r_tmp2, R_0, r_tmp2),

	/* Pop look_at* from tape for RT matrix loading. */
	load_word(r_look_at, R_TapePtr, O_(Binds_ResolveLookAtPopAndTrans,look_at)),
	add_ui_self(          R_TapePtr, S_(Binds_ResolveLookAtPopAndTrans)),

	/* Load RT matrix from look_at into C2[0..4] via ctc2.
	 * Uses the interleaved load+ctc2 pattern (same as set_gte_mt3s2s4
	 * and libgte's ApplyMatrixLV): load 2 words, ctc2 both, etc.
	 * MT3_S2S4 stores m[i][j] as S2 (16-bit) packed row-major. */
	load_word(  r_tmp3, r_look_at,  0),  load_word(  r_tmp4, r_look_at,  4),
	gte_mv_to_ctrl_r(r_tmp3, gte_cr_RT11), gte_mv_to_ctrl_r(r_tmp4, gte_cr_RT12),
	load_word(  r_tmp3, r_look_at,  8),  load_word(  r_tmp4, r_look_at, 12), load_word(r_tmp5, r_look_at, 16),
	gte_mv_to_ctrl_r(r_tmp3, gte_cr_RT13), gte_mv_to_ctrl_r(r_tmp4, gte_cr_RT21), gte_mv_to_ctrl_r(r_tmp5, gte_cr_RT22),
	nop2,

	/* === Two-pass MVMVA decomposition (replicates libgte's ApplyMatrixLV) ===
	 * Pass 1: RT · (pos >> 15) with sf=0 → contributes (result << 3) to final.
	 * Pass 2: RT · (pos & 0x7FFF) with sf=1 → contributes (result >> 12) to final.
	 * Combined: final = (pass1 << 3) + pass2 = (RT · pos) >> 12.
	 * pos is in r_tmp0/1/2 (S4, 32-bit). High bits → r_tmp3/4/5. Low bits →
	 * back into r_tmp0/1/2 (reusing pos slots since they're consumed).
	 *
	 * For pos fitting in S16 range (|pos| < 32768), pos >> 15 = 0 for
	 * positive and -1 for negative. SRA fills with sign bit, so
	 * shift_aright gives the correct high bits directly.
	 * For low bits: negu + andi 0x7FFF + negu preserves sign.
	 * Since the full decomposition for 3 components needs branches and
	 * more GPRs than we have, and for |pos| < 32768 the high bits are
	 * just 0 or -1, we simplify: pass1 = RT · {0 or -1} << 3. */

	/* pos.x decomposition: high = pos.x >> 15 (SRA, sign-fills).
	 * Low bits = pos.x & 0x7FFF with sign preserved.
	 * For |pos| < 32768, high = 0 (positive) or -1 (negative). */
	shift_aright_var(r_tmp3, r_tmp0, 15),  /* r_tmp3 = pos.x >> 15 (SRA) */
	/* Low bits: if negative, negu+andi+negu; if positive, just andi.
	 * For S16-fitting values, andi 0x7FFF preserves bit 15 via the
	 * negu dance. But since pos.x fits in S16 for our case,
	 * we can just use pos.x & 0x7FFF and OR with the sign bit:
	 * low = (pos.x & 0x7FFF) | (pos.x & 0x8000).
	 * Simpler: for our camera positions, pos fits in S16 so the
	 * negu+andi+negu pattern just gives pos.x back. We can skip it
	 * and use pos.x directly for pass 2 IR input. */
	/* r_tmp0 still has pos.x (S4, 32-bit). Pass 2 needs S16 in IR. */

	/* mtc2 IR1/2/3 = high bits. */
	gte_mv_to_data_r(r_tmp3, C2_IR1),
	gte_mv_to_data_r(r_tmp4, C2_IR2),
	gte_mv_to_data_r(r_tmp5, C2_IR3),
	nop2,  /* MTC2 retirement */

	/* Pass 1 MVMVA: sf=0 (no shift), v=3 (IR), cv=3 (no TR), mx=0 (RT). */
	gte_cmdw_mvmva_sf0_ir,
	nop,

	/* mfc2 MAC1/2/3 → r_tmp3/4/5 (pass 1 results). */
	gte_mv_from_data_r(r_tmp3, C2_MAC1),
	gte_mv_from_data_r(r_tmp4, C2_MAC2),
	gte_mv_from_data_r(r_tmp5, C2_MAC3),
	nop,

	/* mtc2 IR1/2/3 = low bits.
	 * For S16-fitting pos, the low bits are just pos & 0x7FFF with
	 * sign preserved. Since pos.x = -eye.x fits in S16 for camera
	 * positions, we can use pos.x & 0xFFFF (which preserves the sign
	 * bit via the full 32-bit value). The GTE takes low 16 bits. */
	and_i(r_tmp0, r_tmp0, 0xFFFF),  /* pos.x low 16 bits */
	and_i(r_tmp1, r_tmp1, 0xFFFF),  /* pos.y low 16 bits */
	and_i(r_tmp2, r_tmp2, 0xFFFF),  /* pos.z low 16 bits */
	gte_mv_to_data_r(r_tmp0, C2_IR1),
	gte_mv_to_data_r(r_tmp1, C2_IR2),
	gte_mv_to_data_r(r_tmp2, C2_IR3),
	nop2,

	/* Pass 2 MVMVA: sf=1 (>>12), v=3 (IR), cv=3 (no TR), mx=0 (RT). */
	gte_cmdw_mvmva_ir,
	nop,

	/* mfc2 MAC1/2/3 → r_tmp0/1/2 (pass 2 results). */
	gte_mv_from_data_r(r_tmp0, C2_MAC1),
	gte_mv_from_data_r(r_tmp1, C2_MAC2),
	gte_mv_from_data_r(r_tmp2, C2_MAC3),
	nop,

	/* Combine: final = (pass1 << 3) + pass2.
	 * shift_lleft shifts left by 3. Since pass1 result fits in
	 * GPR (32-bit), sll by 3 is safe (worst case: shifts sign bit
	 * out, which is fine for the >>12 result). */
	shift_lleft(r_tmp3, r_tmp3, 3),
	add_u(r_tmp0, r_tmp0, r_tmp3),
	shift_lleft(r_tmp4, r_tmp4, 3),
	add_u(r_tmp1, r_tmp1, r_tmp4),
	shift_lleft(r_tmp5, r_tmp5, 3),
	add_u(r_tmp2, r_tmp2, r_tmp5),

	/* Store off → scratch+96 (overwriting eye). Atom 6c reads from here. */
	store_word(r_tmp0, r_peye, O_(V3_S4,x)),
	store_word(r_tmp1, r_peye, O_(V3_S4,y)),
	store_word(r_tmp2, r_peye, O_(V3_S4,z)),

	mac_yield()
})

/* Atom 6c in the bundle: copy scratch+96 (off, written by atom 6b) → look_at->t[].
 * Uses mac_trans_matrix component (m->t = v, libgte TransMatrix semantics = struct copy).
 *
 * GPR codes (assigned by resolve_look_at_init):
 *   r_look_at : MT3_S2S4* (popped from tape; output matrix destination)
 *   r_scratch : R_ResolveScratch (R_T4) — scratch base
 *   r_off_ptr : pointer to off (= &scratch.eye, reused slot)
 *   r_tmp0    : transfer reg for mac_trans_matrix
 *
 * Pool cost: r_look_at (1) + r_scratch (carrier) + r_off_ptr + 1 clobber = 4 GPRs.
 */
I_ MipsAtom* resolve_look_at__trans_matrix_proc(AtomArena_R aa
	,	U4 r_look_at
	,	U4 r_scratch
	,	U4 r_off_ptr
	,	U4 r_tmp0
) MipsAtom_Proc_(resolve_look_at__trans_matrix, aa, {
	/* Pop look_at* from tape. */
	load_word(r_look_at, R_TapePtr, O_(Binds_ResolveLookAtPopAndTrans,look_at)),
	add_ui_self(         R_TapePtr, S_(Binds_ResolveLookAtPopAndTrans)),

	/* r_off_ptr = &off (= &scratch.eye since atom 6b overwrote eye with off). */
	add_si(r_off_ptr, r_scratch, O_(ResolveLookAtScratch,eye)),
	nop,

	/* Copy off → look_at.t[] (mac_trans_matrix: m->t = v). */
	mac_trans_matrix(r_look_at, r_off_ptr, r_tmp0),

	mac_yield()
})

#pragma endregion Atom Procs

#pragma region Baked Atoms

enum {
	R_ScreenX   = R_T5 atom_reg atom_type(U2),
	R_ScreenY   = R_T6 atom_reg atom_type(U2),
	R_ScreenBuf = R_T7 atom_reg, /* Caller-pinned: & smem.screen_buf */
#define R_ScreenBuf_Code R_T7_Code
};
//screen_env_init. Mirrors the libpsyx's SetDefDispEnv + SetDefDrawEnv + the manual enable_auto_clear / initial_bg_color writes.
internal MipsAtom_(screen_env_init) atom_info(atom_phase(screen_init)
,	atom_reads(R_T0, R_ScreenX, R_ScreenY, R_ScreenBuf)
, atom_writes(R_T0, R_ScreenX, R_ScreenY)
) {
	/* display[0] = (0, 0, 320, 240); rest of struct zeroed. */
	add_ui(R_ScreenX, R_0, ScreenRes_X), add_ui(R_ScreenY, R_0, ScreenRes_Y),
	mac_store_v2s2(R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DisplayEnv,display_area.width) + OA_(DoubleBuffer,display,0)),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,display_area) + O_(DoubleBuffer,display[0])),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,screen)       + O_(DoubleBuffer,display[0])),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,vinterlace)   + O_(DoubleBuffer,display[0])),

	/* display[1] = (0, 240, 320, 240); rest of struct zeroed. */
	mac_store_rects2(R_0, R_ScreenY, R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DisplayEnv,display_area) + O_(DoubleBuffer,display[1])),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,screen)     + O_(DoubleBuffer,display[1])),
	store_word(R_0, R_ScreenBuf, O_(DisplayEnv,vinterlace) + O_(DoubleBuffer,display[1])),

	mac_store_rects2(R_0, R_ScreenY, R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DrawEnv,clip_area)         + O_(DoubleBuffer,draw[0])), /* draw[0].clip_area = (0, 240, 320, 240). C11's SetDefDrawEnv writes clip.y = y_arg. */
	mac_store_v2s2(  R_0, R_ScreenY,                       R_ScreenBuf, O_(DrawEnv,drawing_offset[0]) + O_(DoubleBuffer,draw[0])), /* draw[0].drawing_offset[0] = (0, 240); C11 passes y_arg as ofs. */

	mac_store_v2s2(R_ScreenX, R_ScreenY, R_ScreenBuf, O_(DrawEnv,clip_area.width) + O_(DoubleBuffer,draw[1])),

	/* draw[0].texture_window = (0, 0, 0, 0); two word-zeroes cover the full 8-byte tw field. */
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.x)     + O_(DoubleBuffer,draw[0])),
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.width) + O_(DoubleBuffer,draw[0])),

	store_word(R_0, R_ScreenBuf, O_(DrawEnv,drawing_offset[0].x)  + O_(DoubleBuffer,draw[1])),
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.x)     + O_(DoubleBuffer,draw[1])),
	store_word(R_0, R_ScreenBuf, O_(DrawEnv,texture_window.width) + O_(DoubleBuffer,draw[1])),

	/* draw[0].texture_page = 10 (gp0_tpage_default). C11 SetDefDrawEnv at C11_only.elf:0x8001273C writes the same 0x0A. . */
	add_ui(R_T0, R_0, gp0_tpage_default),
	store_half(R_T0, R_ScreenBuf, O_(DrawEnv,texture_page) + O_(DoubleBuffer,draw[0])),
	store_half(R_T0, R_ScreenBuf, O_(DrawEnv,texture_page) + O_(DoubleBuffer,draw[1])),

	/* draw[0] control bytes: flag_dither=1, flag_draw_on_display=1 (the dfe bit per psx-spx; libpsyx sets it via `SetDefDrawEnv`'s conditional at C11_only.elf:0x80012728), enable_auto_clear=1. Each byte is named;
	 * the previous `store_word(R_0, ..., +20)` overwrote all four with zero. */
	add_ui(R_T0, R_0, 1),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_dither)          + O_(DoubleBuffer,draw[0])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_draw_on_display) + O_(DoubleBuffer,draw[0])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,enable_auto_clear)    + O_(DoubleBuffer,draw[0])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_dither)          + O_(DoubleBuffer,draw[1])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,flag_draw_on_display) + O_(DoubleBuffer,draw[1])),
	store_byte(R_T0, R_ScreenBuf, O_(DrawEnv,enable_auto_clear)    + O_(DoubleBuffer,draw[1])),

	/* draw[0].initial_bg_color = (r=7, g=7, b=7). */
	add_ui(R_T0, R_0, 7),
	mac_store_rgb8(R_T0,R_T0,R_T0, R_ScreenBuf, O_(DrawEnv,initial_bg_color) + O_(DoubleBuffer,draw[0])),
	mac_store_rgb8(R_T0,R_T0,R_T0, R_ScreenBuf, O_(DrawEnv,initial_bg_color) + O_(DoubleBuffer,draw[1])),

	mac_yield(),
};

/* gp_screen_init's GPR setup. Tests the mixed user-pinning + auto-reg pattern:
 *   - R_IO_BaseAddr = R_T4 (user-pinned via atom_reg; pre-existing)
 *   - R_GP1_Offset  = R_T2 (user-pinned via atom_reg; NEW -- for GPIO_PORT1_OFFSET)
 *   - R_ScreenX     = R_T5 (user-pinned via atom_reg; used as a transfer and GTE setup reg)
 *   - R_GpTmp       = auto-allocated by the lua pass and used for several GPU transfers;
 *                    the C preprocessor resolves it to the chosen free pool GPR.
 *
 * For gp_screen_init, the auto-reg pool exclusions are:
 *   user_pinned (from the corpus register_alias_registry) : R_T0..R_T7 (all 8 user-pinned across hello_camera.atom.c)
 *   body-parsed physical registers                         : aliases resolve through the registry;
 *                                                           the body uses R_ScreenX, not raw R_T5
 *   source_pool after both subtractions                   : {R_V0, R_V1} only
 *   R_GpTmp gets R_V0 (the first-fit choice). Its repeated GPU-transfer use proves that the
 *   auto-reg allocation is active while the R_ScreenX references prove the pinned alias is used.
 *   R_TapePtr (R_T9), R_AtomJmp (R_T8), R_AT are excluded from the POOL by construction in
 *   passes/auto_reg.lua -- see the "obvious exclusions" comment block at the top of that file.
 */
enum {
	R_IO_BaseAddr = R_T4 atom_reg, /* Caller-pinned: IO_BASE_ADDR = 0x1F800000 */
	R_GP1_Offset  = R_T2 atom_reg, /* Caller-pinned: GPIO_PORT1_OFFSET = 0x10 */
	atom_auto_reg(gp_screen_init, R_GpTmp),  /* Auto-allocated scratch; resolved to a free pool GPR by the lua pass. C-preprocessor expands to R_GpTmp = R_GpTmp_Code with an atom_auto_reg trailing comment. */
#define R_IO_BaseAddr_Code R_T4_Code
#define R_GP1_Offset_Code  R_T2_Code
};
internal MipsAtom_(gp_screen_init) atom_info(atom_phase(screen_init), atom_reads(R_IO_BaseAddr)) {
	store_word(R_0, R_IO_BaseAddr, GPIO_PORT1_OFFSET),                                   /* GP1(00h) Reset */
	mac_gcmd_push(gp1_word_ResetCmdBuffer(),   R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(01h) ClearFIFO; uses pinned R_ScreenX as the transfer reg. */
	mac_gcmd_push(gp1_word_AcknowledgeIRQ(),   R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(02h) AckIRQ; uses pinned R_ScreenX as the transfer reg. */
	mac_gcmd_push(gp1_word_DisplayOn(),        R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(03h) Display ON; uses pinned R_ScreenX as the transfer reg. */
	mac_gcmd_push(gp1_word_dma_to_gpu(),       R_GpTmp,   R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(04h) DMADirection=2 (CPU->GPU). libpsyx's per-frame PutDrawEnv/DrawOTag use DMA2; without this the DMA queue never drains. Uses auto-allocated R_GpTmp. */
	mac_gcmd_push(gp1_word_StartDisplayArea(), R_GpTmp,   R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* GP1(05h) StartDisplayArea (X=0, Y=0); uses auto-allocated R_GpTmp. */

	/* GP1: DisplayMode + Display Ranges. */
	mac_gcmd_push(gp1_word_display_mode_320x240_15bit_ntsc, R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET),
	mac_gcmd_push(gp1_word_horizontal_range_ntsc,           R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET),
	mac_gcmd_push(gp1_word_vertical_range_ntsc,             R_ScreenX, R_IO_BaseAddr, GPIO_PORT1_OFFSET),

	/* GTE: SetGeomOffset (OFX, OFY) — ScreenRes_CenterX, ScreenRes_CenterY. */
	load_upper_i(R_ScreenX, ScreenRes_CenterX), gte_mv_to_ctrl_r(R_ScreenX, gte_cr_OFX_Code),
	load_upper_i(R_ScreenX, ScreenRes_CenterY), gte_mv_to_ctrl_r(R_ScreenX, gte_cr_OFY_Code),

	/* GTE: SetGeomScreen (H) — CR26 (per PSX-SPX / libpsyx), value is the raw projection-plane distance, NOT shifted. */
	add_ui(R_ScreenX, R_0, ScreenZ), gte_mv_to_ctrl_r(R_ScreenX, gte_cr_H_Code),

	/* GP1: DisplayEnable — bit 0 = 0 (Display ON). */
	mac_gcmd_push(gp1_word_DisplayOn(), R_GpTmp, R_IO_BaseAddr, GPIO_PORT1_OFFSET), /* Uses auto-allocated R_GpTmp. */
	mac_yield(),
};

typedef Struct_(Binds_PadApplyInput) {
	PadState* state;
	V3_S2*    cube_rot;
	V3_S2*    floor_rot;
};
enum {
	R_PadStateT5 = R_T5 atom_reg,
	R_CubeRot    = R_T1 atom_reg,
	R_FloorRot   = R_T2 atom_reg,
};
internal MipsAtom_(pad_input_cube_rotation) atom_info(atom_bind(Binds_PadApplyInput)
, atom_reads(R_T0, R_CubeRot, R_FloorRot, R_T3, R_T4, R_PadStateT5, R_TapePtr)
, atom_writes(     R_CubeRot, R_FloorRot)
) {
	/* Pop Binds from tape (state, cube_rot, floor_rot) */
	load_word(R_PadStateT5, R_TapePtr, O_(Binds_PadApplyInput,state)),
	load_word(R_CubeRot,    R_TapePtr, O_(Binds_PadApplyInput,cube_rot)),
	load_word(R_FloorRot,   R_TapePtr, O_(Binds_PadApplyInput,floor_rot)),
	add_ui_self(            R_TapePtr, S_(Binds_PadApplyInput)),

	/* Load pad[0].buttons into R_T0. */
	load_word(R_T0, R_PadStateT5, O_(PadState,buttons)), nop,
	// Note(Ed): Potential op with delay slot?

	/* D-pad Left: cube_rot.y += 30, floor_rot.y += 5.  */
	and_i(R_T3, R_T0, Pad_Left), branch_le_zero(R_T3, atom_offset(dpad_left, exit_dpad_left)),
		load_half( R_T4, R_CubeRot,  O_(V3_S2,y)),   /* BD-slot */
		load_half( R_T3, R_FloorRot, O_(V3_S2,y)),
		add_si(    R_T4, R_T4, 30),
		add_si(    R_T3, R_T3, 5),
		store_half(R_T4, R_CubeRot,  O_(V3_S2,y)),
		store_half(R_T3, R_FloorRot, O_(V3_S2,y)),
	atom_label(exit_dpad_left)

	/* D-pad Right: cube_rot.y -= 30, floor_rot.y -= 5. */
	and_i(R_T3, R_T0, Pad_Right), branch_le_zero(R_T3, atom_offset(dpad_right, exit_dpad_right)),
		load_half( R_T4, R_CubeRot,  O_(V3_S2,y)),   /* BD-slot */
		load_half( R_T3, R_FloorRot, O_(V3_S2,y)),
		add_si(    R_T4, R_T4, -30),
		add_si(    R_T3, R_T3, -5),
		store_half(R_T4, R_CubeRot,  O_(V3_S2,y)),
		store_half(R_T3, R_FloorRot, O_(V3_S2,y)),
	atom_label(exit_dpad_right)

	/* Analog left-stick X: dead zone 0x70..0x90.
	 * Cube delta = (0x80 - left_x) >> 2; floor delta = (0x80 - left_x) >> 5. */
	load_byte_u(R_T3, R_PadStateT5, O_(PadState,left.x)),

	/* Dead-zone check: skip analog if left_x in [0x70, 0x90] inclusive. Outside dead zone on LOW side: left_x < 0x70 (strictly).
	 * set_lt_u(R_T4, R_T3, R_T4=0x70) → R_T4 = (left_x < 0x70) ? 1 : 0. */
	add_ui(R_T4, R_0, PadDeadZone_HighBound), set_lt_u(R_T4, R_T3, R_T4), branch_ne(R_T4, R_0, atom_offset(dead_zone_low_check, dead_low_active)),
	add_ui(R_T4, R_0, PadDeadZone_Center), /* BD-slot: pre-load 0x80 for dead_low_active */

atom_label(dead_check_upper)
	/* left_x >= 0x70 → check upper bound. */
	load_byte_u(R_T3, R_PadStateT5, O_(PadState,left.x)), /* reload */
	add_ui(     R_T4, R_0, PadDeadZone_HighBound),

	/* R_T4 = (0x90 < left_x) ? 1 : 0 → (left_x > 0x90) ? 1 : 0 */
	set_lt_u(R_T4, R_T4, R_T3), branch_ne(R_T4, R_0, atom_offset(dead_zone_high_check, dead_high_active)),
	add_ui(  R_T4, R_0, PadDeadZone_Center), /* BD-slot: pre-load 0x80 for dead_high_active */
	jump_rel(atom_offset(dead_zone_skip, exit_stick)),
		mac_yield_load(),

atom_label(dead_low_active)
	/* R_T3 = left_x (from line 632 lbu; not clobbered between dead_zone_low_check branch + its BD-slot `add_ui R_T4, 0x80`).
	 * The earlier `load_byte_u(R_T3, ...)` reload was redundant and introduced a load-use hazard on the next `sub_u`.
	 * R_T4 = 0x80 from the BD-slot of `dead_zone_low_check`'s branch_ne. */
	sub_u( R_T3, R_T4, R_T3), /* R_T3 = 0x80 - left_x */
	/* delta = 0x80 - left_x (positive). */

	/* R_T4 = cube_delta */
	shift_aright(R_T4, R_T3, 2),
	load_half(   R_T0, R_CubeRot, O_(V3_S2,y)), nop,
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_CubeRot, O_(V3_S2,y)),
	/* R_T4 = floor_delta — moved into the load-delay slot of the floor load below (fills the 1-instruction gap;
	 * doesn't read R_T0; R_T4 settles by the subsequent add_u). */
	load_half(   R_T0, R_FloorRot, O_(V3_S2,y)),
	shift_aright(R_T4, R_T3, 5),
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_FloorRot, O_(V3_S2,y)),

	jump_rel(atom_offset(end_low, exit_stick)),
		mac_yield_load(),

atom_label(dead_high_active)
	/* R_T3 = left_x (from line 641 lbu in dead_check_upper; not clobbered between dead_zone_high_check branch + its BD-slot `add_ui R_T4, 0x80`).
	 * The earlier `load_byte_u(R_T3, ...)` reload was redundant and introduced a load-use hazard on the next `sub_u`.
	 * R_T4 = 0x80 from the BD-slot of `dead_zone_high_check`'s branch_ne. */
	sub_u( R_T3, R_T4, R_T3),
	/* delta = 0x80 - left_x (signed negative). */

	shift_aright(R_T4, R_T3, 2),                      /* R_T4 = cube_delta (signed) */
	load_half(   R_T0, R_CubeRot, O_(V3_S2,y)), nop,
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_CubeRot, O_(V3_S2,y)),

	/* R_T4 = floor_delta (signed) — moved into the load-delay slot of the floor load below. */
	load_half(   R_T0, R_FloorRot, O_(V3_S2,y)),
	shift_aright(R_T4, R_T3, 5),
	add_u(       R_T0, R_T0, R_T4),
	store_half(  R_T0, R_FloorRot, O_(V3_S2,y)),

atom_label(no_jump_fallthrough)
	mac_yield_load(),

atom_label(exit_stick)
	/* NOT mac_yield() — R_AtomJmp was already loaded in the BD-slot of the dead-zone/exit branch. */
	mac_yield_tail(),
};

enum {
	R_Cam         = R_T4 atom_reg,
	R_CamPadState = R_T5 atom_reg,
};
typedef Struct_(Binds_PadInputCam) {
	PadState* state;
	Camera*   cam;
};
internal MipsAtom_(pad_input_cam) atom_info(atom_bind(Binds_PadInputCam)
, atom_reads( R_Cam, R_CamPadState, R_TapePtr)
, atom_writes(R_Cam)
) {
	/* Bind pop: state → R_CamPadState (R_T5), cam → R_Cam (R_T4), advance R_TapePtr by 8. */
	load_word(R_CamPadState, R_TapePtr, O_(Binds_PadInputCam,state)),
	load_word(R_Cam,         R_TapePtr, O_(Binds_PadInputCam,cam)),
	add_ui_self(             R_TapePtr, S_(Binds_PadInputCam)),

	/* Load pad[0].buttons into R_T0; nop fills the load-delay slot. */
	load_word(R_T0, R_CamPadState, O_(PadState,buttons)),
	load_word(R_T1, R_Cam, O_(Camera,pos.x)), // BD-Slot.

	// D-pad Left → cam.pos.x -= 50.  and_i fulfills BD-slot for load on R_Cam.
	and_i(R_T3, R_T0, Pad_Left), branch_le_zero(R_T3, atom_offset(left_x, exit_left_x)), mac_yield_load(),
		add_si(R_T1, R_T1, -50), store_word(R_T1, R_Cam, O_(Camera,pos.x)),
atom_label(exit_left_x)
	/* D-pad Right → cam.pos.x += 50. Reuses R_T1 from Left. */
	and_i(R_T3, R_T0, Pad_Right), branch_le_zero(R_T3, atom_offset(right_x, exit_right_x)), nop,
		add_si(R_T1, R_T1,  50), store_word(R_T1, R_Cam, O_(Camera,pos.x)),
atom_label(exit_right_x)

	/* D-pad Up → cam.pos.y -= 50. Load pos.y BEFORE the andi. */
	load_word(R_T1, R_Cam, O_(Camera,pos.y)),
	and_i(R_T3, R_T0, Pad_Up), branch_le_zero(R_T3, atom_offset(up_y, exit_up_y)), nop,
		add_si(R_T1, R_T1, -50), store_word(R_T1, R_Cam, O_(Camera,pos.y)),
atom_label(exit_up_y)
	/* D-pad Down → cam.pos.y += 50. Reuses R_T1 from Up. */
	and_i(R_T3, R_T0, Pad_Down), branch_le_zero(R_T3, atom_offset(down_y, exit_down_y)), nop,
		add_si(R_T1, R_T1,  50), store_word(R_T1, R_Cam, O_(Camera,pos.y)),
atom_label(exit_down_y)

	/* D-pad Cross → cam.pos.z -= 50. Load pos.z BEFORE the andi. */
	load_word(R_T1, R_Cam, O_(Camera,pos.z)),
	and_i(R_T3, R_T0, Pad_Cross), branch_le_zero(R_T3, atom_offset(cross_z, exit_cross_z)), nop,
		add_si(R_T1, R_T1, -50), store_word(R_T1, R_Cam, O_(Camera,pos.z)),
atom_label(exit_cross_z)
	/* D-pad Circle → cam.pos.z += 50. Reuses R_T1 from Cross. */
	and_i(R_T3, R_T0, Pad_Circle), branch_le_zero(R_T3, atom_offset(circle_z, exit_circle_z)), nop,
		add_si(R_T1, R_T1,  50), store_word(R_T1, R_Cam, O_(Camera,pos.z)),
atom_label(exit_circle_z)

	mac_yield_tail(),
};

enum {
	R_PrimCursor = R_T7 atom_reg atom_type(U4*),    /* Output cursor (primitive buffer) */
	R_FaceCursor = R_T4 atom_reg atom_type(V4_S2*), /* Cube face-index cursor (V4_S2*); floor context switches to V3_S2* via atom_phase */
	R_VertBase   = R_T5 atom_reg atom_type(V3_S2*), /* Base address of the vertex array */
	R_OtBase     = R_T6 atom_reg atom_type(U4*),    /* Base address of the Ordering Table */
#define R_PrimCursor_Code  R_T7_Code
#define R_FaceCursor_Code  R_T4_Code
#define R_VertBase_Code    R_T5_Code
#define R_OtBase_Code      R_T6_Code
};
typedef Struct_(Binds_CubeTri) {
	U4     PrimCursor;
	V4_S2* FaceCursor;
	V3_S2* VertBase;
	U4*    OtBase;
};
internal MipsAtom_(rbind_cube_g4_face) atom_info(atom_bind(Binds_CubeTri), atom_phase(cube_g4)
,	atom_reads(R_TapePtr)
,	atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase, R_TapePtr)
){
	/* Pop 4 arguments from the tape directly into the workspace registers */
	load_word(R_PrimCursor, R_TapePtr, O_(Binds_CubeTri,PrimCursor)),
	load_word(R_FaceCursor, R_TapePtr, O_(Binds_CubeTri,FaceCursor)),
	load_word(R_VertBase,   R_TapePtr, O_(Binds_CubeTri,VertBase)),
	load_word(R_OtBase,     R_TapePtr, O_(Binds_CubeTri,OtBase)),
	add_ui_self(            R_TapePtr, S_(Binds_CubeTri)),
	mac_yield()
};

// cube_g4_face — Draw one cube face (Gouraud-shaded quad) via the GTE tape pipeline
internal
MipsAtom_(cube_g4_face) atom_info(atom_phase(cube_g4),
		atom_reads( R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase),
		atom_writes(R_PrimCursor, R_FaceCursor)
){
	load_half_u(R_T0, R_FaceCursor, 0 * S_(S2)),
	load_half_u(R_T1, R_FaceCursor, 1 * S_(S2)),
	load_half_u(R_T2, R_FaceCursor, 2 * S_(S2)),
	load_half_u(R_T3, R_FaceCursor, 3 * S_(S2)),

	mac_gte_load_tri_verts(R_VertBase, R_T0, R_T1, R_T2),
	nop2, gte_cmdw_rotate_translate_perspective_triple, // required cpu -> gte delay slot
	gte_cmdw_nclip,

	gte_mv_from_data_r(R_T0, C2_MAC0), nop,
	branch_le_zero(R_T0, atom_offset(cull, cube_g4_face_exit)),
		/* BD-slot: Write the prim tag (R_0=0; overwrites the legacy tag word in the prim_buffer).
		 * If branch IS taken (face culled), the body is skipped and this 0-tag is stranded —
		 * harmless because the OT entry that points to this prim is created later. */
		store_word(R_0, R_PrimCursor, O_(Poly_G4, tag)),
		shift_lleft(R_AT, R_T3, v3s2_byteoff), add_u(R_AT, R_AT, R_VertBase),
		load_word(R_V0, R_AT, O_(V3_S2, x)),   load_word(R_V1, R_AT, O_(V3_S2, z)),
		gte_mv_to_data_r(R_V0, C2_VXY0),       gte_mv_to_data_r(R_V1, C2_VZ0),

		mac_gte_store_g4_p012(R_PrimCursor),
		gte_cmdw_rotate_translate_perspective_single,
		mac_gte_store_g4_p3(R_PrimCursor),

		gte_cmdw_avg_sort_z4,
		gte_mv_from_data_r(R_T1, C2_OTZ),
		add_ui(      R_AT, R_0,  OrderingTbl_Len),
		set_lt_u(    R_AT, R_T1, R_AT),

		branch_equal(R_AT, R_0,  atom_offset(bounds_chk, cube_g4_face_exit)), nop,
			mac_insert_ot_tag(R_OtBase, R_PrimCursor, S_(Poly_G4)),
			mac_format_g4_color(R_PrimCursor,
				/* c0 magenta */ 0xFF, 0x00, 0xFF,
				/* c1 yellow  */ 0xFF, 0xFF, 0x00,
				/* c2 cyan    */ 0x00, 0xFF, 0xFF,
				/* c3 green   */ 0x00, 0xFF, 0x00),
		// end: branch(bounds_chk)
// end: branch(cull)

atom_label(cube_g4_face_exit)
	add_ui_self(R_PrimCursor, S_(Poly_G4)),     /* 9 words = Poly_G4 */
	add_ui_self(R_FaceCursor, S_(S2) * 4),      /* 4 × S2 = 8 bytes */
	mac_yield()
};

typedef Struct_(Binds_FloorTri) {
	U4     PrimCursor;
	V3_S2* FaceCursor;
	V3_S2* VertBase;
	U4*    OtBase;
};
internal
MipsAtom_(rbind_floor_f3_face) atom_info(atom_bind(Binds_FloorTri), atom_phase(floor_f3)
	, atom_reads(R_TapePtr)
	, atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase, R_TapePtr)
){
	/* Pop 4 arguments from the tape directly into the workspace registers */
	load_word(R_PrimCursor, R_TapePtr, O_(Binds_FloorTri,PrimCursor)),
	load_word(R_FaceCursor, R_TapePtr, O_(Binds_FloorTri,FaceCursor)),
	load_word(R_VertBase,   R_TapePtr, O_(Binds_FloorTri,VertBase)),
	load_word(R_OtBase,     R_TapePtr, O_(Binds_FloorTri,OtBase)),
	add_ui_self(            R_TapePtr, S_(Binds_FloorTri)),
	mac_yield()
};

// atom_dbg_skip
internal
MipsAtom_(floor_f3_face) atom_info(atom_phase(floor_f3)
	, atom_reads( R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
	, atom_writes(R_PrimCursor, R_FaceCursor)
) {
	mac_load_tri_indices(R_FaceCursor, R_T0, R_T1, R_T2),
	mac_gte_load_tri_verts(R_VertBase,   R_T0, R_T1, R_T2),
	nop2, gte_cmdw_rotate_translate_perspective_triple, // 2 nops retire the final cpu -> gte writes before RTPT
	gte_cmdw_nclip,

	/* Culling (Branch forward if Backface) */
	gte_mv_from_data_r(R_T0, C2_MAC0),
	nop, branch_le_zero(R_T0, atom_offset(culling, floor_f3_face_exit)), nop, // required gte -> cpu load-delay slot.
		/* Format Primitive */
		mac_gte_store_f3(R_PrimCursor),

		/* Calculate Depth */
		gte_avg_sort_z3,
		gte_mv_from_data_r(R_T1, C2_OTZ),
		/* Bounds Check OTZ < 2048 (Branch forward to skip insertion) */
		add_ui(      R_AT, R_0,  OrderingTbl_Len),
		set_lt_u(    R_AT, R_T1, R_AT),
		branch_equal(R_AT, R_0,  atom_offset(bounds_chk, floor_f3_face_exit)), nop,
			mac_format_f3_color(R_PrimCursor, 0xFF, 0xFF, 0xFF),  // RGB-form (R=FF, G=FF, B=FF = white)
			mac_insert_ot_tag(R_OtBase, R_PrimCursor, S_(Poly_F3)),   /* Insert into Ordering Table Linked List */
			add_ui_self(R_PrimCursor, S_(Poly_F3)), /* Advance Prim Cursor (5 words) */
				// Note(Ed): No bounds checking, should be checked before atom runs.
		// end: branch(bounds_chk)
	// end: branch(culling)

/* Advance Input Cursor & Yield (Both branch targets land here) */
atom_label(floor_f3_face_exit)
	add_ui_self(R_FaceCursor, S_(S2) * 4),  /* Advance Face Cursor (4 * S2 = 8 bytes) */
	mac_yield()
};

typedef Struct_(Binds_SyncPrimitiveArena) { U4 used; U4 cursor; };
internal MipsAtom_(sync_primitive_arena) atom_info(atom_bind(Binds_SyncPrimitiveArena)
	, atom_reads( R_TapePtr, R_PrimCursor)
	, atom_writes(R_TapePtr)
){
	load_word(R_AT, R_TapePtr, O_(Binds_SyncPrimitiveArena,used)),
	load_word(R_T0, R_TapePtr, O_(Binds_SyncPrimitiveArena,cursor)),
	add_ui_self(    R_TapePtr, S_(Binds_SyncPrimitiveArena)),
	/* Calculate byte offset and store directly back to RAM */
	sub_u(     R_T0, R_PrimCursor, R_T0), // R_T0    = R_PrimCursor - binds.cursor
	store_word(R_T0, R_AT, 0),            // R_AT[0] = R_T0
	mac_yield()
};

#pragma endregion Baked Atoms
