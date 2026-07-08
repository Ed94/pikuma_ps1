#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "gcc_asm.h"
# include "mips.h"
# include "gte.h"
# include "memory.h"
#	include "atom_dsl.h"
#endif

typedef U4 const MipsCode;
#define MipsAtom_(sym) MipsCode tmpl(code,sym) [] align_(4) =

#pragma region Tape Drive
/* ---------------------------------------------------------------------------
 *  TAPE DRIVE ABI & REGISTER ALIASES
 * ---------------------------------------------------------------------------
 *  We map the MIPS temporary registers to a persistent global workspace.
 *  The C compiler is completely unaware of these bindings.
 * ---------------------------------------------------------------------------*/
enum {
	R_AtomJmp    = R_T9,
	R_TapePtr    = R_T8,  /* The Instruction Stream Pointer */
	R_InCursor   = R_T4,  /* Input data cursor */

	R_PrimCursor = R_T7,  /* VRAM output cursor (primitive buffer) */
	R_FaceCursor = R_T4,  /* Input data cursor (indices/faces) */
	R_VertBase   = R_T5,  /* Base address of the vertex array */
	R_OtBase     = R_T6,  /* Base address of the Ordering Table */

/* Stringification codes for the GCC inline assembler clobber lists */
#define R_TapePtr_Code     R_T8_Code
#define R_InCursor_Code    R_T4_Code

#define R_PrimCursor_Code  R_T7_Code
#define R_FaceCursor_Code  R_T4_Code
#define R_VertBase_Code    R_T5_Code
#define R_OtBase_Code      R_T6_Code
};

/* The 'Exit' Atom */
MipsAtom_(tape_exit) { jump_reg(rret_addr), nop };

/* Generalized Tape Engine Runner */
FI_ void tape_run(Slice_U4 tape) { register U4* tp rgcc(R_TapePtr) = tape.ptr; asm volatile(
	asm_words(
			add_ui(    R_SP, R_SP, -MipsStackAlignment) /* Allocate stack space */
		, store_word(R_RA, R_SP,           0)         /* Safely backup $ra to the stack */
		, load_word( R_AtomJmp, R_TapePtr, 0)         /* Bootstrap the first jump */
		, add_ui_1(  R_TapePtr, S_(MipsCode))         /* Advance tape */
		, jump_nreg( R_AtomJmp)                       /* jalr $t9 */
		, nop                                         /* Branch delay slot */
		, load_word(R_RA, R_SP, 0)                    /* Restore $ra from stack */
		, add_ui_1( R_SP, MipsStackAlignment)         /* Deallocate stack space */
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

#define tb_emit_(tb, atom) tb_emit(tb, tmpl(code,atom))
FI_ void tb_emit(TapeBuilder* tb, MipsCode* atom) { u4_r(tb->ptr)[tb->used] = u4_(atom); ++ tb->used; }
FI_ void tb_data(TapeBuilder* tb, U4        data) { u4_r(tb->ptr)[tb->used] = u4_(data); ++ tb->used; }

FI_ Slice_U4 tb_end  (TapeBuilder* tb) { tb_emit(tb,code_tape_exit); return (Slice_U4){ C_(U4*,tb->ptr), tb->used }; }
FI_ Slice_U4 tb_slice(TapeBuilder  tb) {                             return (Slice_U4){ C_(U4*,tb.ptr),  tb.used }; }
#define tb_scope(tb) for(U4 tbs_once=0;tbs_once==0;++tbs_once,tb_emit(tb,code_tape_exit))

#pragma endregion Tape Drive

#pragma region Macro Mips Atom Components
/* ---------------------------------------------------------------------------
 *  MACRO ATOM Components (Reusable Assembly Components)
 *  These do NOT yield. They are expanded inline inside Tape Atoms.
 * ---------------------------------------------------------------------------*/

/* The 'Yield' sequence for Tape Atoms.
 * Loads the next pointer from the tape, advances the tape, and jumps. 
 * Cost: ~ 4 cycles */
#define mac_yield()                               \
	  load_word(R_AtomJmp, R_TapePtr, 0)            \
	, add_ui_1(            R_TapePtr, S_(MipsCode)) \
	, jump_reg( R_AtomJmp)                          \
	, nop

/* Words: 3; Loads 3 S2 indices from the face array */
#define mac_load_tri_indices(rId_0, rId_1, rId_2) \
	  load_half_u(rId_0, R_FaceCursor, 0 * S_(S2)) \
	, load_half_u(rId_1, R_FaceCursor, 1 * S_(S2)) \
	, load_half_u(rId_2, R_FaceCursor, 2 * S_(S2))

/* Words: 18; Translates indices to vertex addresses and pushes them to GTE 
	R_AT  = rId_[#] << 3; 
	R_AT += R_VertBase;
	R_V0  = R_AT[0];
	gte_mt(R_V0, V.xy[#]);
	gte_mt(R_V1, V.z [#]);
*/
#define mac_load_tri_verts(rId_0, rId_1, rId_2) \
	  shift_ll(R_AT, rId_0, v3s2_byteoff), add_u_1(R_AT, R_VertBase), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), gte_mt(R_V0, C2_VXY0), gte_mt(R_V1, C2_VZ0) \
	, shift_ll(R_AT, rId_1, v3s2_byteoff), add_u_1(R_AT, R_VertBase), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), gte_mt(R_V0, C2_VXY1), gte_mt(R_V1, C2_VZ1) \
	, shift_ll(R_AT, rId_2, v3s2_byteoff), add_u_1(R_AT, R_VertBase), load_word(R_V0, R_AT, O_(V3_S2,x)), load_word(R_V1, R_AT, O_(V3_S2,z)), gte_mt(R_V0, C2_VXY2), gte_mt(R_V1, C2_VZ2)

	//TODO(Ed): Add more type annotation
/* Words: 11; Correctly inserts a primitive into the Ordering Table linked list */
#define mac_insert_ot_tag(r_otz, prim_length) \
	  shift_ll( R_T1, r_otz, 2)                              /* T1 = r_otz * S_(U4) */            \
	, add_u(    R_T1, R_T1,         R_OtBase)                /* T1 = & OrderingTable[OTZ] */      \
	, load_word(R_AT, R_T1,         O_(PolyTag,bf_addr_len)) /* AT = old_ot_head */               \
	, load_ui(  R_V0, prim_length)                           /* V0 = prim_length << 16 (high 16 bits of a tag) */ \
	, shift_ll_lr(R_AT, R_AT,       S_(PolyTag_len_bits))    /* Strip upper 8 bits (length from prev cell) → keep only low 24 */ \
	, or_u(      R_AT, R_AT, R_V0)                            /* Merge length */                  \
	, store_word(R_AT, R_PrimCursor, O_(PolyTag,bf_addr_len)) /* prim->tag = packed(prim_length, old_addr) */ \
	, shift_ll(  R_AT, R_PrimCursor, S_(PolyTag_len_bits))    /* AT = (prim_length << 24) | old_addr */ \
	, shift_lr(  R_AT, R_AT,         S_(PolyTag_len_bits))                                        \
	, store_word(R_AT, R_T1,         O_(PolyTag,bf_addr_len)) /* OrderingTable[OTZ] = PrimCursor */

#pragma endregion Macro Atom Components

#pragma region Mips Atom Builder
// This allows for runtime procedural authoring of mips atoms.

typedef Struct_(FMipsAtom512) { U4 data[512]; U4 used; };

typedef Slice_(MipsCode); typedef Slice_MipsCode MipsAtom; 
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
	LP_ MipsAtom_(yield) { mac_yield() };
	mem_copy(ab->start, u4_(code_yield), S_(code_yield));
	mem_bump(ab->start, ab->capacity, & ab->used, S_(code_yield));
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
// TODO(Ed): Annotate magic offsets
internal MipsAtom_(mips_flush_icache) {
	  add_ui(rstack_ptr, rstack_ptr, -MipsStackAlignment) /* sp -= 8 */
	, store_word(rret_addr, rstack_ptr, 4)      /* sw  $ra,   4($sp)   */
	, add_ui(rret_0, rdiscard, bios_flushcache) /* addiu $a0, $0, 0x44 */
	, add_ui(rtmp_0, rdiscard, bios_table_addr) /* addiu $t0, $0, 0xA0 */
	, jump_link(rtmp_0, rret_addr)              /* jalr  $t0, $ra      */
	, nop                                       /* BD slot             */
	, load_word(rret_addr, rstack_ptr, 4)       /* lw   $ra, 4($sp)    */
	, jump_reg(rret_addr)                       /* jr   $ra            */
	, add_ui(rstack_ptr, rstack_ptr, MipsStackAlignment)  /* sp += 8 (BD) */
	, mac_yield()
};

typedef Struct_(Binds_SetGteWorld) {
	U4 transform;
};
// TODO(Ed): Bugged, fix
internal MipsAtom_(set_gte_world) {
	/* Pop matrix address from tape into R_T3 ($11) */
	load_word(R_T3, R_TapePtr, O_(Binds_SetGteWorld,transform)),
	add_ui_1(       R_TapePtr, S_(Binds_SetGteWorld)),

// TODO(Ed): Annotate magic offsets.
	/* Load 3x3 Rotation + 3x1 Translation from R_T3 into GTE CONTROL Regs (ctc2) */
	load_word(R_T0, R_T3,  0),    load_word(R_T1, R_T3,  4),
	gte_ct(   R_T0, gte_cr_RT11), gte_ct(   R_T1, gte_cr_RT12),
	load_word(R_T0, R_T3,  8),    load_word(R_T1, R_T3, 12),    load_word(R_T2, R_T3, 16),
	gte_ct(   R_T0, gte_cr_RT13), gte_ct(   R_T1, gte_cr_RT21), gte_ct(   R_T2, gte_cr_RT22),
	load_word(R_T0, R_T3, 20),    load_word(R_T1, R_T3, 24),    load_word(R_T2, R_T3, 28),
	gte_ct(   R_T0, gte_cr_TRX),  gte_ct(   R_T1, gte_cr_TRY),  gte_ct(   R_T2, gte_cr_TRZ),

	mac_yield()
};

// TODO(Ed): I'm not sure yet if the bindings are redundant with the floortri atom yet.

/* DIAGNOSTIC 1: Pure tape loop test */
internal MipsAtom_(diag_yield) { mac_yield() };

// TODO(Ed): Reduce magic numbers/offsets
/* DIAGNOSTIC 2: Pure memory test (No GTE). Draws a fixed cyan triangle. */
internal MipsAtom_(diag_color) {
	store_word(R_0, R_T7, 0), 
	load_ui(   R_AT, gcmd_poly_f3 << 8 | 0xFF), /* High: MipsCode Poly_F3(0x20) + Color B:FF */
	or_i(      R_AT, R_AT, 0xFF00), /* Low:  Color G:FF, R:00 (Cyan) */
	store_word(R_AT, R_T7, 4),
	
	/* Fake coordinates - Swapped winding order to prevent GPU culling! */
	load_ui(R_AT, 0x0010), or_i(R_AT, R_AT, 0x0010), store_word(R_AT, R_T7, 8),  /* (16, 16) */
	load_ui(R_AT, 0x0050), or_i(R_AT, R_AT, 0x0010), store_word(R_AT, R_T7, 12), /* (80, 16) */
	load_ui(R_AT, 0x0010), or_i(R_AT, R_AT, 0x0050), store_word(R_AT, R_T7, 16), /* (16, 80) */

	add_ui(  R_T1, R_0,  10),
	shift_ll(R_T1, R_T1, 2), 
	add_u(   R_T1, R_T1, R_T6),         
	
	load_word( R_AT, R_T1, 0),        
	load_ui(   R_V0, 0x0400),   // <--- Fills load delay slot! 
	store_word(R_AT, R_T7, 0),       
	
	shift_ll(  R_AT, R_T7, 8), shift_lr(R_AT, R_AT, 8),         
	or_u(      R_AT, R_AT, R_V0),          
	store_word(R_AT, R_T1, 0),       

	add_ui(R_T7, R_T7, 20),          

	mac_yield()
};

// TODO(Ed): Reduce magic numbers/offsets
/* DIAGNOSTIC 3: Pure GTE test (No Memory Writes) */
internal MipsAtom_(diag_gte) {
	/* Load 3 indices */
	load_half_u(R_T0, R_T4, 0),
	load_half_u(R_T1, R_T4, 2),
	load_half_u(R_T2, R_T4, 4),

	/* Load Vertices into GTE */
	shift_ll( R_AT, R_T0, 3), add_u(    R_AT, R_AT, R_T5),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mt(   R_V0, C2_VXY0), gte_mt(   R_V1, C2_VZ0),

	shift_ll( R_AT, R_T1, 3), add_u(    R_AT, R_AT, R_T5),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mt(   R_V0, C2_VXY1), gte_mt(   R_V1, C2_VZ1),

	shift_ll( R_AT, R_T2, 3), add_u(    R_AT, R_AT, R_T5),
	load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
	gte_mt(   R_V0, C2_VXY2), gte_mt(   R_V1, C2_VZ2),

	/* Run Math */
	nop, nop, gte_cmdw_rtpt,
	nop, nop, gte_cmdw_nclip,
	nop, nop,

	/* Advance Face Cursor and Yield */
	add_ui(R_T4, R_T4, 8),

	mac_yield()
};

#pragma endregion Baked Mips Atoms
