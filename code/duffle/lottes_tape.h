#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "gcc_asm.h"
# include "mips.h"
# include "gte.h"
# include "memory.h"
#endif

/* R_T8 is our dedicated Tape Pointer (TP) */
#define R_TP      R_T8
#define R_TP_Code R_T8_Code

/* The 'Yield' sequence for CodeBlobs */
#define mips_yield \
      load_word(R_T9, R_TP, 0) \
    , add_ui(R_TP, R_TP, 4)    \
    , jump_reg(R_T9)           \
    , nop

/* The 'Exit' Atom */
internal Code CodeBlob_(tape_exit) { jump_reg(rret_addr), nop };

typedef Slice_(U4);

FI_ void tape_run(Slice_U4 tape, B1** r_prim_cursor, void* face_cursor, void* vert_base, void* ot_base) {
    register U4*   tp   rgcc(R_TP) = tape.ptr;
    register B1*   pcur rgcc(R_T7) = *r_prim_cursor;
    register void* r_t4 rgcc(R_T4) = face_cursor;
    register void* r_t5 rgcc(R_T5) = vert_base;
    register void* r_t6 rgcc(R_T6) = ot_base;

    asm volatile(
        "lw    $25, 0(%0);"   
        "addiu %0, %0, 4;"    
        "jalr  $25;"          
        "nop;"                
        : "+r"(tp), "+r"(pcur), "+r"(r_t4), "+r"(r_t5), "+r"(r_t6)
        : 
        : "at", "v0", "v1", "t0", "t1", "t2", "t3", "t9", "ra", "memory" 
    );
    
    *r_prim_cursor = pcur; 
}

typedef Struct_(TapeBuilder) {FArena* arena;};
FI_ TapeBuilder tb_begin(FArena* arena) {return (TapeBuilder){ arena };}

I_ void tb_emit(TapeBuilder* tb, Code* atom) {
	U4* slot = farena_push_type(tb->arena, U4); 
	slot[0] = (U4)atom;
}

I_ Slice_U4 tb_end(TapeBuilder* tb) {
	tb_emit(tb, code_tape_exit);
	return (Slice_U4){ (U4*)tb->arena->start, tb->arena->used / 4 };
}

internal Code CodeBlob_(atom_set_gte_world) {
    /* Pop matrix address from tape into R_T3 ($11) */
    load_word(R_T3, R_TP, 0),
    add_ui(R_TP, R_TP, 4),

    /* Load 3x3 Rotation + 3x1 Translation from R_T3 into GTE CONTROL Regs (ctc2) */
    load_word(R_T0, R_T3,  0), load_word(R_T1, R_T3,  4),
    gte_ct(R_T0, gte_cr_RT11), gte_ct(R_T1, gte_cr_RT12),
    
    load_word(R_T0, R_T3,  8), load_word(R_T1, R_T3, 12), load_word(R_T2, R_T3, 16),
    gte_ct(R_T0, gte_cr_RT13), gte_ct(R_T1, gte_cr_RT21), gte_ct(R_T2, gte_cr_RT22),
    
    load_word(R_T0, R_T3, 20), load_word(R_T1, R_T3, 24), load_word(R_T2, R_T3, 28),
    gte_ct(R_T0, gte_cr_TRX),  gte_ct(R_T1, gte_cr_TRY),  gte_ct(R_T2, gte_cr_TRZ),
    
    mips_yield
};

internal Code CodeBlob_(atom_floor_tri) {
    /* 1. Load 3 indices from $t4 */
    load_half_u(R_T0, R_T4, 0),
    load_half_u(R_T1, R_T4, 2),
    load_half_u(R_T2, R_T4, 4),

    /* 2. Load Vertices: Addr = Base + (idx * 8). Write to GTE DATA Regs (mtc2) */
    shift_ll(R_AT, R_T0, 3), add_u(R_AT, R_AT, R_T5),
    load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
    gte_mt(R_V0, C2_VXY0), gte_mt(R_V1, C2_VZ0),

    shift_ll(R_AT, R_T1, 3), add_u(R_AT, R_AT, R_T5),
    load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
    gte_mt(R_V0, C2_VXY1), gte_mt(R_V1, C2_VZ1),

    shift_ll(R_AT, R_T2, 3), add_u(R_AT, R_AT, R_T5),
    load_word(R_V0, R_AT, 0), load_word(R_V1, R_AT, 4),
    gte_mt(R_V0, C2_VXY2), gte_mt(R_V1, C2_VZ2),

    /* 3. RTPT + NCLIP */
    nop, nop, gte_cmdw_rtpt,
    nop, nop, gte_cmdw_nclip,
    nop, nop, /* Wait for NCLIP to finish */

    /* 4. Check NCLIP. 
       If MAC0 <= 0 (Backface), branch to end.
       Target is 28 instructions past the delay slot. */
    gte_mf(R_T0, C2_MAC0),
    branch_le_zero(R_T0, 28), 
    nop, /* <--- DELAY SLOT (Index 0) */

    /* 5. Store Primitive Data */
    /*  1 */ store_word(R_0, R_T7, 0), 
    /*  2 */ load_ui(R_AT, 0x20FF),     /* High: Code 0x20 + Color R:FF */
    /*  3 */ or_i(R_AT, R_AT, 0xFFFF),  /* Low: Color G:FF, B:FF */
    /*  4 */ store_word(R_AT, R_T7, 4),
    /*  5 */ enc_gte_sw(C2_SXY0, R_T7, 8),
    /*  6 */ enc_gte_sw(C2_SXY1, R_T7, 12),
    /*  7 */ enc_gte_sw(C2_SXY2, R_T7, 16),

    /* 6. OT Insertion with Bounds Checking */
    /*  8 */ nop, 
    /*  9 */ nop, 
    /* 10 */ enc_gte_cmd(0x2D),         /* AVSZ3 */
    /* 11 */ nop,                       /* Wait for AVSZ3 */
    /* 12 */ nop,                       /* Wait for AVSZ3 */
    /* 13 */ gte_mf(R_T1, C2_OTZ),      /* T1 = Depth index */
    
    /* Bounds Check: OTZ < 2048 */
    /* 14 */ load_ui(R_AT, 2048),
    /* 15 */ slt_u(R_AT, R_T1, R_AT),   /* AT = (OTZ < 2048) ? 1 : 0 */
    /* 16 */ branch_equal(R_AT, R_0, 11), /* If AT == 0, skip to end (11 instrs past delay) */
    /* 17 */ nop, /* <--- DELAY SLOT (Index 0 for Bounds branch) */
    
    /*  18 (1)  */ shift_ll(R_T1, R_T1, 2), 
    /*  19 (2)  */ add_u(R_T1, R_T1, R_T6),         /* T1 = &OrderingTable[OTZ] */
    /*  20 (3)  */ load_word(R_AT, R_T1, 0),        /* AT = current head */
    /*  21 (4)  */ store_word(R_AT, R_T7, 0),       /* prim->next = head */
    
    /* Create Tag in AT: Len 4 (0x04) in top 8 bits, T7 in bottom 24 */
    /*  22 (5)  */ shift_ll(R_AT, R_T7, 8),
    /*  23 (6)  */ shift_lr(R_AT, R_AT, 8),         /* AT = T7 & 0x00FFFFFF */
    /*  24 (7)  */ load_ui(R_V0, 0x0400),           /* V0 = 0x04000000 */
    /*  25 (8)  */ or_u(R_AT, R_AT, R_V0),          /* AT = Tag */
    
    /*  26 (9)  */ store_word(R_AT, R_T1, 0),       /* OrderingTable[OTZ] = Tag */
    /*  27 (10) */ add_ui(R_T7, R_T7, 20),          /* Advance Prim Cursor (5 words) */

    /* 7. Yield */
    /*  28 (11) */ add_ui(R_T4, R_T4, 8),           /* Advance Face Cursor (4 * S2 = 8 bytes) */
    mips_yield
};
