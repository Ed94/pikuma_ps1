#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "gcc_asm.h"
# include "mips.h"
# include "gte.h"
# include "memory.h"
#endif

/* ---------------------------------------------------------------------------
 *  TAPE DRIVE ABI & REGISTER ALIASES
 * ---------------------------------------------------------------------------
 *  We map the MIPS temporary registers to a persistent global workspace.
 *  The C compiler is completely unaware of these bindings.
 * ---------------------------------------------------------------------------*/
enum {
	R_TapePtr  = R_T8,  /* The Instruction Stream Pointer */
	R_PrimCur  = R_T7,  /* VRAM output cursor (primitive buffer) */
	R_FaceCur  = R_T4,  /* Input data cursor (indices/faces) */
	R_VertBase = R_T5,  /* Base address of the vertex array */
	R_OtBase   = R_T6,  /* Base address of the Ordering Table */
/* Stringification codes for the GCC inline assembler clobber lists */
#define R_TapePtr_Code  R_T8_Code
#define R_PrimCur_Code  R_T7_Code
#define R_FaceCur_Code  R_T4_Code
#define R_VertBase_Code R_T5_Code
#define R_OtBase_Code   R_T6_Code
};

/* The 'Yield' sequence for Tape Atoms.
 * Loads the next pointer from the tape, advances the tape, and jumps. 
 * Cost: ~ 4 cycles */
#define mips_yield()              \
	  load_word(R_T9, R_TapePtr, 0) \
	, add_ui_1(       R_TapePtr, 4) \
	, jump_reg( R_T9)               \
	, nop

/* The 'Exit' Atom */
MipsAtom_(tape_exit) { jump_reg(rret_addr), nop };

typedef Slice_(U4);

/* Generalized Tape Engine Runner */
FI_ void tape_run(Slice_U4 tape) { register U4* tp rgcc(R_TapePtr) = tape.ptr; asm volatile(
	asm_words(
			add_ui(    R_SP, R_SP,      -8)   /* Allocate stack space */
		, store_word(R_RA, R_SP,       0)   /* Safely backup $ra to the stack */
		, load_word( R_T9, R_TapePtr,  0)   /* Bootstrap the first jump */
		, add_ui_1(  R_TapePtr, 4)          /* Advance tape */
		, jump_nreg(R_T9)                   /* jalr $t9 */
		, nop                               /* Branch delay slot */
		, load_word(R_RA, R_SP, 0)          /* Restore $ra from stack */
		, add_ui_1( R_SP, 8)                /* Deallocate stack space */
	)
	asm_rpins, r_use(tp)
	asm_clobber: 
			rlit(R_AT_Code)
		, rlit(R_V0_Code), rlit(R_V1_Code)
		, rlit(R_T0_Code), rlit(R_T1_Code), rlit(R_T2_Code), rlit(R_T3_Code)
		/* Tell GCC the tape engine owns and destroys the workspace registers */
		, rlit(R_PrimCur_Code), rlit(R_FaceCur_Code), rlit(R_VertBase_Code), rlit(R_OtBase_Code)
		, rlit(R_T9_Code)
		, clb_mem_drain 
); }

typedef Struct_(TapeBuilder) { U4 ptr; U4 count; };
FI_ void        tb_init(TapeBuilder* tb, FArena* arena) { tb->ptr = arena->start; tb->count = 0; }
FI_ TapeBuilder tb_make(                 FArena* arena) { return (TapeBuilder){ arena->start, 0 }; }

FI_ void tb_emit(TapeBuilder* tb, MipsAtom* atom) { u4_r(tb->ptr)[tb->count] = u4_(atom); ++ tb->count; }
FI_ void tb_data(TapeBuilder* tb, U4    data) { u4_r(tb->ptr)[tb->count] = u4_(data); ++ tb->count; }

FI_ Slice_U4 tb_end  (TapeBuilder* tb) { tb_emit(tb,code_tape_exit); return (Slice_U4){ C_(U4*,tb->ptr), tb->count }; }
FI_ Slice_U4 tb_slice(TapeBuilder  tb) {                             return (Slice_U4){ C_(U4*,tb.ptr),  tb.count }; }
#define tb_scope(tb) for(U4 tbs_once=0;tbs_once==0;++tbs_once,tb_emit(tb,code_tape_exit))

/* ---------------------------------------------------------------------------
 *  MACRO ATOMS (Reusable Assembly Components)
 *  These do NOT yield. They are expanded inline inside Tape Atoms.
 * ---------------------------------------------------------------------------*/

/* Loads 3 16-bit indices from the face array */
#define mac_load_tri_indices(r_idx0, r_idx1, r_idx2) \
	  load_half_u(r_idx0, R_FaceCur, 0) \
	, load_half_u(r_idx1, R_FaceCur, 2) \
	, load_half_u(r_idx2, R_FaceCur, 4)

/* Translates indices to vertex addresses and pushes them to GTE */
#define mac_load_tri_verts(r_idx0, r_idx1, r_idx2) \
	  shift_ll(R_AT, r_idx0, 3), add_u(R_AT, R_AT, R_VertBase), load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4), gte_mt(R_V0, C2_VXY0), gte_mt(R_V1, C2_VZ0) \
	, shift_ll(R_AT, r_idx1, 3), add_u(R_AT, R_AT, R_VertBase), load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4), gte_mt(R_V0, C2_VXY1), gte_mt(R_V1, C2_VZ1) \
	, shift_ll(R_AT, r_idx2, 3), add_u(R_AT, R_AT, R_VertBase), load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4), gte_mt(R_V0, C2_VXY2), gte_mt(R_V1, C2_VZ2)

/* Formats the primitive memory layout (Tag + Color + Coordinates) */
#define mac_format_prim_f3(color_hi, color_lo)          \
	  store_word(R_0, R_PrimCur,  0)                      \
	, load_ui(R_AT, color_hi), or_i(R_AT, R_AT, color_lo) \
	, store_word(R_AT, R_PrimCur, 4)                      \
	, gte_sw(C2_SXY0, R_PrimCur, 8)                       \
	, gte_sw(C2_SXY1, R_PrimCur, 12)                      \
	, gte_sw(C2_SXY2, R_PrimCur, 16)

/* Correctly inserts a primitive into the Ordering Table linked list */
#define mac_insert_ot_tag(r_otz, prim_length)                               \
	  shift_ll(  R_T1, r_otz, 2)                                              \
	, add_u(     R_T1, R_T1, R_OtBase)   /* T1 = &OrderingTable[OTZ] */       \
	, load_word( R_AT, R_T1, 0)          /* AT = old_ot_head */               \
	, load_ui(   R_V0, prim_length)      /* V0 = Length << 24 */              \
	, shift_ll(  R_AT, R_AT, 8)          /* Strip upper 8 bits from old_ot */ \
	, shift_lr(  R_AT, R_AT, 8)                                               \
	, or_u(      R_AT, R_AT, R_V0)       /* Merge length */                   \
	, store_word(R_AT, R_PrimCur, 0)     /* prim->tag = old_ot_head */        \
	, shift_ll(  R_AT, R_PrimCur, 8)     /* AT = PrimCur & 0x00FFFFFF */      \
	, shift_lr(  R_AT, R_AT, 8)                                               \
	, store_word(R_AT, R_T1, 0)          /* OrderingTable[OTZ] = PrimCur */

internal MipsAtom_(bind_workspace) {
	/* Pop 4 arguments from the tape directly into the workspace registers */
	load_word(R_PrimCur,  R_TapePtr,  0), 
	load_word(R_FaceCur,  R_TapePtr,  4), 
	load_word(R_VertBase, R_TapePtr,  8), 
	load_word(R_OtBase,   R_TapePtr, 12), 
	add_ui_1(             R_TapePtr, 16),
	mips_yield()
};

internal MipsAtom_(sync_prim_cursor) {
	/* Pop the C-struct address and base address from the tape */
	load_word(R_AT, R_TapePtr, 0), /* AT = &pa->used */
	load_word(R_T0, R_TapePtr, 4), /* T0 = prim_base */
	add_ui_1(       R_TapePtr, 8),
	/* Calculate byte offset and store directly back to RAM */
	sub_u(R_T0, R_PrimCur, R_T0),
	store_word(R_T0, R_AT, 0),
	mips_yield()
};

internal MipsAtom_(set_gte_world) {
	/* Pop matrix address from tape into R_T3 ($11) */
	load_word(R_T3,      R_TapePtr, 0),
	add_ui_1( R_TapePtr, 4),

	/* Load 3x3 Rotation + 3x1 Translation from R_T3 into GTE CONTROL Regs (ctc2) */
	load_word(R_T0, R_T3,  0),    load_word(R_T1, R_T3,  4),
	gte_ct(   R_T0, gte_cr_RT11), gte_ct(   R_T1, gte_cr_RT12),
	load_word(R_T0, R_T3,  8),    load_word(R_T1, R_T3, 12),    load_word(R_T2, R_T3, 16),
	gte_ct(   R_T0, gte_cr_RT13), gte_ct(   R_T1, gte_cr_RT21), gte_ct(   R_T2, gte_cr_RT22),
	load_word(R_T0, R_T3, 20),    load_word(R_T1, R_T3, 24),    load_word(R_T2, R_T3, 28),
	gte_ct(   R_T0, gte_cr_TRX),  gte_ct(   R_T1, gte_cr_TRY),  gte_ct(   R_T2, gte_cr_TRZ),

	mips_yield()
};

internal MipsAtom_(floor_tri) {
	mac_load_tri_indices(R_T0, R_T1, R_T2),
	mac_load_tri_verts(  R_T0, R_T1, R_T2),

	/* 3. Execute Math */
	nop, nop, gte_cmdw_rtpt,
	nop, nop, gte_cmdw_nclip,
	nop, nop, 

	/* 4. Culling (Branch forward 29 instructions if Backface) */
	gte_mf(R_T0, C2_MAC0),
	nop,                      
	branch_le_zero(R_T0, 29), 
	nop,                      
	
	/* 5. Format Primitive */
	mac_format_prim_f3(0x20FF, 0xFFFF), /* High: 0x20/B, Low: G/R */
	
	/* 6. Calculate Depth */
	nop, nop, gte_cmdw_avsz3,            
	nop, nop, 
	gte_mf(R_T1, C2_OTZ),      
	
	/* 7. Bounds Check OTZ < 2048 (Branch forward 13 instructions to skip insertion) */
	add_ui(      R_AT, R_0,  2048),   
	slt_u(       R_AT, R_T1, R_AT), 
	branch_equal(R_AT, R_0,  13),   
	nop, 
	
	/* 8. Insert into Ordering Table Linked List */
	mac_insert_ot_tag(R_T1, 0x0400), /* Length = 4 words */

	add_ui(R_PrimCur, R_PrimCur, 20), /* Advance Prim Cursor (5 words) */
	/* 9. Advance Input Cursor & Yield (Both branch targets land here) */
	add_ui(R_FaceCur, R_FaceCur, 8),  /* Advance Face Cursor (4 * S2 = 8 bytes) */
	mips_yield()
};

/* DIAGNOSTIC 1: Pure tape loop test */
internal MipsAtom_(diag_yield) { mips_yield() };

/* DIAGNOSTIC 2: Pure memory test (No GTE). Draws a fixed cyan triangle. */
internal MipsAtom_(diag_color) {
	store_word(R_0, R_T7, 0), 
	load_ui(   R_AT, 0x20FF),       /* High: MipsAtom 0x20 + Color B:FF */
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

	mips_yield()
};

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

	mips_yield()
};
