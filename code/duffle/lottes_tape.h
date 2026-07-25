#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "gcc_asm.h"
# include "mips.h"
# include "gte.h"
# include "memory.h"
#	include "atom_dsl.h"
#	include "gen/duffle.macs.h"
#	include "gen/duffle.offsets.h"
#endif

typedef U4 const MipsCode;
typedef Slice_(MipsCode);
typedef Slice_MipsCode MipsAtom;

#define MipsAtom_(sym) MipsCode sym [] align_(4) =

// Used for components with no args (e.g., ac_load_tri_indices) or identifier-args (hardcoded register names).
//   MipsAtomComp_(ac_X) { body }
// expands to:
//   MipsCode ac_X[] align_(4) = { body };
#define MipsAtomComp_(sym) MipsCode sym [] align_(4) =

// Used for components with value-args (e.g., ac_format_f3_color).
//   FI_ MipsAtom ac_X(args) MipsAtomComp_Proc_(ac_X, { body })
// expands to:
//   FI_ MipsAtom ac_X(args) { MipsCode ac_X[] align_(4) = { body }; return slice_from_array(MipsCode, ac_X); }
#define MipsAtomComp_Proc_(sym, ...) { MipsCode sym [] align_(4) = __VA_ARGS__; return slice_from_array(MipsCode, sym); }

// Auto-generated component macros (<module>/gen/<dir>/<dir>.macs.h) are included manually by the unity build.

/* Register aliases */
enum {
	R_AtomJmp    = R_T9 atom_reg,  /* debug-visible; tape yield handshake scratch */
	R_TapePtr    = R_T8 atom_reg,  /* The Instruction Stream Pointer */
	R_InCursor   = R_T4,

	R_PrimCursor = R_T7 atom_reg atom_type(U4 *),    /* VRAM output cursor (primitive buffer) */
	R_FaceCursor = R_T4 atom_reg atom_type(V4_S2 *), /* Cube face-index cursor (V4_S2*); floor context switches to V3_S2* via atom_phase */
	R_VertBase   = R_T5 atom_reg atom_type(V3_S2 *), /* Base address of the vertex array */
	R_OtBase     = R_T6 atom_reg atom_type(U4 *),    /* Base address of the Ordering Table */

/* Stringification codes for the GCC inline assembler clobber lists. */
#define R_TapePtr_Code     R_T8_Code
#define R_InCursor_Code    R_T4_Code

#define R_PrimCursor_Code  R_T7_Code
#define R_FaceCursor_Code  R_T4_Code
#define R_VertBase_Code    R_T5_Code
#define R_OtBase_Code      R_T6_Code
};

#pragma region Tape Drive
/* ---------------------------------------------------------------------------
 *  TAPE DRIVE ABI & REGISTER ALIASES (the enum moved earlier; see below)
 * ---------------------------------------------------------------------------*/

/* The 'Exit' Atom */
atom_dbg_skip_over() MipsAtom_(tape_exit) { jump_reg(rret_addr), nop };

/* Generalized Tape Engine Runner */
NI_ void tape_run(Slice_MipsCode tape) { register U4* tp rgcc(R_TapePtr) = u4_r(tape.ptr); asm volatile(
	asm_words(
			add_ui(     R_SP, R_SP, -MipsStackAlignment) /* Allocate stack space */
		, store_word( R_RA, R_SP,           0)         /* Safely backup $ra to the stack */
		, load_word(  R_AtomJmp, R_TapePtr, 0)         /* Bootstrap the first jump */
		, add_ui_self(R_TapePtr, S_(MipsCode))         /* Advance tape */
		, call_reg(   R_AtomJmp)                       /* jalr $t9 */
		, nop                                          /* Branch delay slot */
		, load_word(  R_RA, R_SP, 0)                   /* Restore $ra from stack */
		, add_ui_self(R_SP, MipsStackAlignment)        /* Deallocate stack space */
	)
	asm_rpins, r_use(tp)
	asm_clobber: 
			rlit(R_AT)
		, rlit(R_V0), rlit(R_V1)
		, rlit(R_T0), rlit(R_T1), rlit(R_T2), rlit(R_T3)
		/* Tell GCC the tape engine owns and destroys the workspace registers */
		, rlit(R_PrimCursor), rlit(R_FaceCursor), rlit(R_VertBase), rlit(R_OtBase)
		, rlit(R_T9)
		, clb_mem_drain 
); }

typedef Relative_(FArena) Struct_(TapeBuilder) { U4 ptr; U4 capacity; U4 used; };
FI_ void        tb_init(TapeBuilder* tb, FArena* arena) { tb->ptr = arena->start; tb->used = 0; }
FI_ TapeBuilder tb_make_old(             FArena* arena) { return (TapeBuilder){ arena->start, 0 }; }
FI_ TapeBuilder tb_make(Slice mem) { return (TapeBuilder){ mem.ptr, mem.len, 0 }; }

#define tb_emit_(tb, atom) tb_emit(tb, atom)
FI_ void tb_emit(TapeBuilder* tb, MipsCode* atom) { u4_r(tb->ptr)[tb->used] = u4_(atom); ++ tb->used; }
FI_ void tb_data(TapeBuilder* tb, U4        data) { u4_r(tb->ptr)[tb->used] = u4_(data); ++ tb->used; }

FI_ Slice_MipsCode tb_end  (TapeBuilder* tb) { tb_emit(tb,tape_exit); return (Slice_MipsCode){ C_(U4*,tb->ptr), tb->used }; }
FI_ Slice_MipsCode tb_slice(TapeBuilder  tb) {                        return (Slice_MipsCode){ C_(U4*,tb.ptr),  tb.used }; }
#define tb_scope(tb) for(U4 tbs_once=0;tbs_once==0;++tbs_once,tb_emit(tb,tape_exit))

#pragma endregion Tape Drive

#pragma region Macro Mips Atom Components
/* ---------------------------------------------------------------------------
 *  MACRO ATOM Components (Reusable Assembly Components)
 *  These do NOT yield. They are expanded inline inside Tape Atoms.
 * ---------------------------------------------------------------------------*/

// The 'Yield' sequence for Tape Atoms (mac_yield). 
atom_dbg_skip_over() MipsAtomComp_(ac_yield) {
	load_word(R_AtomJmp, R_TapePtr, 0),
	add_ui_self(         R_TapePtr, S_(MipsCode)),
	jump_reg( R_AtomJmp), nop,
};

/* Words: 3; Loads 3 S2 indices from the face array */
atom_dbg_skip_over() MipsAtomComp_(ac_load_tri_indices) {
	load_half_u(R_T0, R_FaceCursor, 0 * S_(S2)),
	load_half_u(R_T1, R_FaceCursor, 1 * S_(S2)),
	load_half_u(R_T2, R_FaceCursor, 2 * S_(S2)),
};

/* Words: 18; Translates indices to vertex addresses and pushes them to GTE  */
atom_dbg_skip_over() MipsAtomComp_(ac_gte_load_tri_verts) {
	shift_lleft(R_AT, R_T0, v3s2_byteoff), add_u_self(R_AT, R_VertBase), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), gte_mv_to_data_r(R_V0, C2_VXY0), gte_mv_to_data_r(R_V1, C2_VZ0),
	shift_lleft(R_AT, R_T1, v3s2_byteoff), add_u_self(R_AT, R_VertBase), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), gte_mv_to_data_r(R_V0, C2_VXY1), gte_mv_to_data_r(R_V1, C2_VZ1),
	shift_lleft(R_AT, R_T2, v3s2_byteoff), add_u_self(R_AT, R_VertBase), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), gte_mv_to_data_r(R_V0, C2_VXY2), gte_mv_to_data_r(R_V1, C2_VZ2),
};

/* Words: 11; Correctly inserts a primitive into the Ordering Table linked list.
 * Hardcoded for Poly_F3 (5 words). For Poly_G4, use ac_insert_ot_tag_g4. */
MipsAtomComp_(ac_insert_ot_tag_f3) {
	shift_lleft( R_T1, R_T1, S_(U4)/2),                        // T1 = otz * S_(U4) (otz arg is implicit R_T1)
	add_u_self(  R_T1, R_OtBase),                              // T1 = & OrderingTable[OTZ]
	load_word(   R_AT, R_T1,         O_(PolyTag,code)),        // AT = old_ot_head
	load_upper_i(R_V0, (S_(Poly_F3)/S_(U4) - S_(PolyTag)/S_(U4)) << PolyTag_len_bits), // V0 = (5 - 1) << 24 = 4 << 24
	mask_upper(  R_AT, R_AT,         S_(PolyTag_len_bits)),    // Strip upper 8 bits (length from prev cell) → keep only low 24
	or_u(        R_AT, R_AT, R_V0),                            // Merge length
	store_word(  R_AT, R_PrimCursor, O_(PolyTag,code)),        // prim->tag = packed(prim_length, old_addr)
	shift_lleft( R_AT, R_PrimCursor, S_(PolyTag_len_bits)),    // AT = (prim_length << 24) | old_addr
	shift_lright(R_AT, R_AT,         S_(PolyTag_len_bits)),
	store_word(  R_AT, R_T1,         O_(PolyTag,code)),        // OrderingTable[OTZ] = PrimCursor
};

/* Words: 11; Correctly inserts a primitive into the Ordering Table linked list.
 * Hardcoded for Poly_G4 (9 words). For Poly_F3, use ac_insert_ot_tag_f3. */
MipsAtomComp_(ac_insert_ot_tag_g4) {
	shift_lleft( R_T1, R_T1, S_(U4)/2),                        // T1 = otz * S_(U4) (otz arg is implicit R_T1)
	add_u_self(  R_T1, R_OtBase),                              // T1 = & OrderingTable[OTZ]
	load_word(   R_AT, R_T1,         O_(PolyTag,code)),        // AT = old_ot_head
	load_upper_i(R_V0, (S_(Poly_G4)/S_(U4) - S_(PolyTag)/S_(U4)) << PolyTag_len_bits), // V0 = (9 - 1) << 24 = 8 << 24
	mask_upper(  R_AT, R_AT,         S_(PolyTag_len_bits)),    // Strip upper 8 bits (length from prev cell) → keep only low 24
	or_u(        R_AT, R_AT, R_V0),                            // Merge length
	store_word(  R_AT, R_PrimCursor, O_(PolyTag,code)),        // prim->tag = packed(prim_length, old_addr)
	shift_lleft( R_AT, R_PrimCursor, S_(PolyTag_len_bits)),    // AT = (prim_length << 24) | old_addr
	shift_lright(R_AT, R_AT,         S_(PolyTag_len_bits)),
	store_word(  R_AT, R_T1,         O_(PolyTag,code)),        // OrderingTable[OTZ] = PrimCursor
};

/* Words: 3; Emits one (cmd|color) word to R_PrimCursor at the given
 * byte offset. Internal helper used by the *_format_*_color macros. */
FI_ MipsAtom ac_pack_color_word(U4 off, U4 cmd, U1 r, U1 g, U1 b)
MipsAtomComp_Proc_(ac_pack_color_word, {
	load_upper_i(R_AT, (cmd) << 8  | (b)),
	or_i_self(   R_AT, ((g)  << 8) | (r)),
	store_word(  R_AT, R_PrimCursor, (off)),
})

/* Words: 3; Emits the F3 command+color word (cmd byte | BLUE | GREEN | RED)
 * Args: _r, _g, _b are 8-bit RGB byte values (not raw 16-bit fields). */
FI_ MipsAtom ac_format_f3_color(U1 r, U1 g, U1 b)
atom_dbg_skip_over() MipsAtomComp_Proc_(ac_format_f3_color, { mac_pack_color_word(O_(Poly_F3,color), gp0_cmd_poly_f3, r, g, b) })

/* Words: 3; Stores the 3 transformed (V2_S2 screen) vertices to the F3.
 * PIPELINE: post-RTPT (SXY0=v0.screen, SXY1=v1.screen, SXY2=v2.screen). */
atom_dbg_skip_over() MipsAtomComp_(ac_gte_store_f3_post_rtpt) {
	gte_sw(C2_SXY0, R_PrimCursor, O_(Poly_F3,p0)),
	gte_sw(C2_SXY1, R_PrimCursor, O_(Poly_F3,p1)),
	gte_sw(C2_SXY2, R_PrimCursor, O_(Poly_F3,p2)),
};

/* Words: 12; Emits the four (code|color) words of a Poly_G4.
 * Args: rN,gN,bN are 8-bit RGB byte values for each of the 4 vertices. */
FI_ MipsAtom ac_format_g4_color(
	U1 r0, U1 g0, U1 b0,
  U1 r1, U1 g1, U1 b1,
  U1 r2, U1 g2, U1 b2,
  U1 r3, U1 g3, U1 b3)
MipsAtomComp_Proc_(ac_format_g4_color, {
	mac_pack_color_word(O_(Poly_G4,c0), gp0_cmd_poly_g4, r0,g0,b0),
	mac_pack_color_word(O_(Poly_G4,c1), 0,               r1,g1,b1),
	mac_pack_color_word(O_(Poly_G4,c2), 0,               r2,g2,b2),
	mac_pack_color_word(O_(Poly_G4,c3), 0,               r3,g3,b3),
})

/* Words: 3; Stores the 3 transformed (V2_S2 screen) vertices of the
 * G4 triangle portion to p0/p1/p2.
 * PIPELINE: post-RTPT, pre-RTPS (SXY0=v0.screen, SXY1=v1.screen, SXY2=v2.screen). 
 * MUST be called BEFORE V3-RTPS, otherwise SXY0/1/2
 * get overwritten with v3 (RTPS writes only to SXY2, but to keep the
 * three registers aligned with v0/v1/v2 you must store before RTPS).
 * The macro name declares the pipeline position; check #6 (GTE state-
 * machine validation) verifies the call site matches the declaration. */
atom_dbg_skip_over() MipsAtomComp_(ac_gte_store_g4_p012_post_rtpt_pre_rtps) {
	gte_sw(C2_SXY0, R_PrimCursor, O_(Poly_G4,p0)),
	gte_sw(C2_SXY1, R_PrimCursor, O_(Poly_G4,p1)),
	gte_sw(C2_SXY2, R_PrimCursor, O_(Poly_G4,p2)),
};

/* Words: 1; Stores the V3 screen coord to the G4's p3 slot.
 * PIPELINE: post-RTPS (SXY2 holds v3.screen because RTPS writes its
 * single-vertex result to SXY2; SXY0 still holds v0.screen from the
 * earlier RTPT — DO NOT read SXY0 here, that's the bug this name
 * prevents).
 */
atom_dbg_skip_over() MipsAtomComp_(ac_gte_store_g4_p3_post_rtps) { gte_sw(C2_SXY2, R_PrimCursor, O_(Poly_G4,p3)) };

#pragma endregion Macro Atom Components

#pragma region Mips Atom Builder
// This allows for runtime procedural authoring of mips atoms.

typedef Struct_(FMipsAtom512) { U4 data[512]; U4 used; };

// FArena Related
typedef Relative_(FArena) Struct_(MipsAtomBuilder) { U4 start; U4 capacity; U4 used; };
// Whatever the builder is writting to should most likely coresspond
// to something that can fit within instruction cache?

FI_ void atombuilder_unroll(MipsAtomBuilder_R ab, Slice_MipsCode_R code) {
	assert(ab->capacity - ab->used - code->len);
	mem_copy(ab->start, u4_(code->ptr), code->len);
	mem_bump(ab->start, ab->capacity, & ab->used, code->len);
}
#define atombuilder_unroll_mac(ab, mac) atombuilder_unroll(ab, slice_arg_from_array(Slice_MipsCode, mac))

// When done authoring, utilize this to cap-off the atom
FI_ void atombuilder_end(MipsAtomBuilder_R ab) {
	mem_copy(ab->start, u4_(ac_yield), S_(ac_yield));
	mem_bump(ab->start, ab->capacity, & ab->used, S_(ac_yield));
}

#define mipsatom_from_builder(ab) (MipsAtom){ab.start, ab.used}

#pragma endregion Mips Atom Builder

#pragma region Baked Mips Atoms
// These atoms are resolved at compile time and are (usually) statically linked readonly data.

enum {
	bios_flushcache = 0x44,
	bios_table_addr = 0xA0,
};

/* Flushes the Instruction Cache (PSX A-function 0x44 via BIOS stub at 0xA0).
 * Sequence (per MIPS ABI; arguments in arg registers, RA pushed to stack):
 *   1. sp -= 8;  sw $ra, 4($sp)        ; save RA
 *   2. $a0 = bios_flushcache (arg0)
 *   3. $t0 = bios_table_addr           ; t0 = &BIOS A-function table
 *   4. jalr $t0, $ra                   ; call BIOS(flushcache)
 *      nop                             ; branch delay slot
 *   5. lw $ra, 4($sp);  jr $ra         ; restore & return
 *   6. sp += 8
 */
internal MipsAtom_(mips_flush_icache) {
	add_ui(rstack_ptr, rstack_ptr, -MipsStackAlignment), // sp -= 8
	store_word(rret_addr, rstack_ptr, S_(U4)),           // sw  $ra,   4($sp) 
	add_ui(rret_0, rdiscard, bios_flushcache),           // addiu $a0, $0, 0x44 
	add_ui(rtmp_0, rdiscard, bios_table_addr),           // addiu $t0, $0, 0xA0 
	jump_link(rtmp_0, rret_addr), nop,                   // jalr  $t0, $ra, BD slot
	load_word(rret_addr, rstack_ptr, S_(U4)),            // lw   $ra, 4($sp) 
	jump_reg(rret_addr),                                 // jr   $ra 
	add_ui(rstack_ptr, rstack_ptr, MipsStackAlignment),  // sp += 8 (BD) 
	mac_yield(),
};

typedef Struct_(Binds_SetGteWorld) {
	M3_S2* transform;
};
internal MipsAtom_(set_gte_world) atom_info(
		atom_bind(Binds_SetGteWorld)
	,	atom_reads(R_TapePtr)
){
	/* Pop matrix address from tape into R_T3 ($11) */
	load_word(R_T3, R_TapePtr, O_(Binds_SetGteWorld,transform)),
	add_ui_self(    R_TapePtr, S_(Binds_SetGteWorld)),
	/* Load 3x3 Rotation + 3x1 Translation from R_T3 into GTE CONTROL Regs (ctc2) */
	load_word(R_T0, R_T3, 0),  load_word(R_T1, R_T3,  4),
	gte_mv_to_ctrl_r(R_T0, gte_cr_RT11), gte_mv_to_ctrl_r(R_T1, gte_cr_RT12),
	load_word(R_T0, R_T3, 8),  load_word(R_T1, R_T3, 12), load_word(R_T2, R_T3, 16),
	gte_mv_to_ctrl_r(R_T0, gte_cr_RT13), gte_mv_to_ctrl_r(R_T1, gte_cr_RT21), gte_mv_to_ctrl_r(R_T2, gte_cr_RT22),
	load_word(R_T0, R_T3, 20), load_word(R_T1, R_T3, 24), load_word(R_T2, R_T3, 28),
	gte_mv_to_ctrl_r(R_T0, gte_cr_TRX),  gte_mv_to_ctrl_r(R_T1, gte_cr_TRY),  gte_mv_to_ctrl_r(R_T2, gte_cr_TRZ),
	mac_yield()
};

/* DIAGNOSTIC 1: Pure tape loop test */
internal MipsAtom_(diag_yield) { mac_yield() };

/* DIAGNOSTIC 2: Pure memory test (No GTE). Draws a fixed cyan triangle. */
internal MipsAtom_(diag_color) {
	store_word(  R_0, R_T7, 0), 
	load_upper_i(R_AT, gp0_cmd_poly_f3 << 8 | 0xFF), /* High: MipsCode Poly_F3(0x20) + Color B:FF */
	or_i_self(   R_AT, 0xFF00),                      /* Low:  Color G:FF, R:00 (Cyan) */
	store_word(  R_AT, R_T7, 4),
	
	/* Fake coordinates - Swapped winding order to prevent GPU culling! */
	load_upper_i(R_AT, 0x0010), or_i_self(R_AT, 0x0010), store_word(R_AT, R_T7, 8),  /* (16, 16) */
	load_upper_i(R_AT, 0x0050), or_i_self(R_AT, 0x0010), store_word(R_AT, R_T7, 12), /* (80, 16) */
	load_upper_i(R_AT, 0x0010), or_i_self(R_AT, 0x0050), store_word(R_AT, R_T7, 16), /* (16, 80) */

	add_ui(          R_T1, R_0,  10),
	shift_lleft_self(R_T1,       S_(U4)/2), 
	add_u_self(      R_T1,       R_T6),         
	
	load_word(   R_AT, R_T1, 0),        
	load_upper_i(R_V0, (S_(Poly_F3)/S_(U4) - S_(PolyTag)/S_(U4)) << PolyTag_len_bits),
	store_word(  R_AT, R_T7, 0),       
	shift_lleft(R_AT, R_T7, S_(PolyTag_len_bits)), shift_lright(R_AT, R_AT, S_(PolyTag_len_bits)),         
	or_u_self(  R_AT, R_V0),          
	store_word( R_AT, R_T1, 0),       

	add_ui(R_T7, R_T7, 20),          

	mac_yield()
};

/* DIAGNOSTIC 3: Pure GTE test (No Memory Writes) */
internal MipsAtom_(diag_gte) {
	/* Load 3 indices */
	load_half_u(R_T0, R_T4, 0),
	load_half_u(R_T1, R_T4, 2),
	load_half_u(R_T2, R_T4, 4),

	/* Load Vertices into GTE */
	shift_lleft( R_AT, R_T0, 3), add_u(    R_AT, R_AT, R_T5),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY0), gte_mv_to_data_r(R_V1, C2_VZ0),

	shift_lleft( R_AT, R_T1, 3), add_u(R_AT, R_AT, R_T5),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY1), gte_mv_to_data_r(R_V1, C2_VZ1),

	shift_lleft(R_AT, R_T2, 3), add_u(R_AT, R_AT, R_T5),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mv_to_data_r(R_V0, C2_VXY2), gte_mv_to_data_r(R_V1, C2_VZ2),

	/* Run Math */
	nop2, gte_cmdw_rtpt,
	nop2, gte_cmdw_nclip,
	nop2,

	/* Advance Face Cursor and Yield */
	add_ui(R_T4, R_T4, 8),

	mac_yield()
};

#pragma endregion Baked Mips Atoms
