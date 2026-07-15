/*
 * atom_dsl.h
 * ============================================================================
 *
 * ATOM DSL: Annotation layer for tape atoms (lottes_tape.h).
 * The metaprogram (scripts/passes/annotation.lua) reads source-as-written and validates:
 *   - atom_info(...) shape: up to three sub-calls (atom_bind(Binds_X), atom_reads(...), atom_writes(...)) in any order and are optional.
 *   - rbind atoms (atom_info(..., atom_bind(Binds_X), ...)) reference a real Binds_* struct declaration.
 *   - wave-context positions only reference the 4-register set: R_PrimCursor / R_FaceCursor / R_VertBase / R_OtBase.
 *     Note(Ed): Not sure if I'll generlaize this later.
 *   - atom word-counts in word_counts.metadata.h match the body's actual .word count.
 *
 * Pure macro anntation.
 * ---------------
 * Don't want to constraint the macro usage to some attribute placment constraint, etc, don't want ot dela with the compiler.
 * atom_info, atom_bind, atom_reads, atom_writes, atom_label, atom_dbg_skip_over each expand to a C comment or to nothing
 * (C preprocessor strips them to whitespace).
 *
 * ============================================================================
 *  Usage:
 *      MipsAtom_(cube_tri) atom_info(
 *         atom_reads (R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
 *       , atom_writes(R_PrimCursor, R_FaceCursor)
 *      ){
 *          atom_label(culling),
 *          // ... atom body ...
 *          atom_offset(culling, bounds_chk)         // branch target, validated
 *          // ... atom body ...
 *          atom_label(bounds_chk),
 *      };
 *
 *
 *  Data Binding pattern -- atom_bind as a sub-call of atom_info
 *
 *      // Wave-context register layout (declarative):
 *      typedef Struct_(Binds_TrackFaceBatch) { 
 * 					U4 PrimCursor; 
 * 					U4 FaceCursor;
 *          U4 VertBase;
 * 					U4 OtBase;
 *      };
 *      MipsAtom_(rbind_track_face_batch) atom_info(
 *         atom_bind(Binds_TrackFaceBatch)
 *       , atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
 *      ){ ... };
 *
 *  Annotation rules
 *  ----------------
 *      1. atom_info(...) is OPTIONAL. Atoms without atom_info are silently skipped by the metaprogram.
 *      2. If present, atom_info takes up to three sub-calls, all order-independent within the arg list:
 *           - atom_bind(Binds_X) (binds a struct context to an atom).
 *           - atom_reads(...) (context registers)
 *           - atom_writes(...) (context registers)
 *      3. atom_bind(Binds_X): metaprogram cross-references Binds_X against the `typedef struct Binds_X { ... } Binds_X;` declaration.
 *      4. atom_reads(...) and atom_writes(...) used to to check if registers are used correctly in macros: R_PrimCursor / R_FaceCursor / R_VertBase / R_OtBase.
 *      5. atom_label(name) utilize with atom_offset as a target location.
 *      6. atom_offset(F, T) is resolved by gen/atom_offsets.h, generated from the atom_label markers. Calculated during the offset pass of the lua  metaprogram.
 */

#ifdef INTELLISENSE_DIRECTIVES
#pragma once
// #include <stdint.h>
#endif

/* ============================================================================
 * atom_reads(...) / atom_writes(...)
 *
 * Used during the static analysis pass of the metaprogram to do 
 * ============================================================================*/
#define atom_reads(...)  (__VA_ARGS__)
#define atom_writes(...) (__VA_ARGS__)

/* ============================================================================
 *   atom_info :
 *      MipsAtom_(cube_tri) atom_info(
 *         atom_reads (R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
 *       , atom_writes(R_PrimCursor, R_FaceCursor)
 *      ){ ... };
 * 
 *  - atom_bind(Binds_X): metaprogram cross-references Binds_X against the `typedef struct Binds_X { ... } Binds_X;` declaration.
 *  - atom_reads(...):    comma-list of registers
 *  - atom_writes(...):   comma-list of registers
 * ============================================================================*/
#define atom_info(...)  /* atom_info(__VA_ARGS__) */

/* ----------------------------------------------------------------------------
 * DEBUG SOURCE-STEP MARKERS
 *
 * Place atom_dbg_skip_over() before a MipsAtom_, MipsAtomComp_, or MipsAtomComp_Proc_. 
 * The following declaration kind determines whether the marker selects a whole atom or a component inline view.
 * The source scanner associates the marker with that declaration; placement diagnostics are handled by the annotation pass.
 * ----------------------------------------------------------------------------*/
#define atom_dbg_skip_over() /* atom_dbg_skip_over: skip the following atom or component source view */

/* ----------------------------------------------------------------------------
 * atom_bind(Binds_X) -- rbind sub-call of atom_info
 *
 *   MipsAtom_(rbind_cube_tri) atom_info(
 *         atom_bind(Binds_CubeTri)
 *       , atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
 *   ){ ... };
 *
 * The Binds_X MUST be a typedef'd type (declared via `typedef struct Binds_X { ... } Binds_X;` somewhere in the source).
 * ----------------------------------------------------------------------------*/
#define atom_bind(binds_struct)  /* atom_bind(binds_struct) */

/* ============================================================================
 * atom_label / atom_offset — branch target machinery
 *
 *   atom_label(culling)                      ← nothing in C; anchor only
 *   ... body ...
 *   atom_label(bounds_chk)                   ← another anchor
 *
 *   atom_offset(culling, bounds_chk)         ← resolved by gen/.offsets.h
 *
 * The metaprogram generates gen/atom_offsets.h with one #define with the offset value per atom_offset(F, T) call.
 * The preprocessor then expands the call to the right immediate value.
 *
 * If gen/atom_offsets.h is stale (or atom_label(name) is undefined), `atom_offset_F_T`
 * becomes an undefined macro and the C build fails.
 * ============================================================================*/
#define atom_offset(F, T) atom_offset_ ## F ## _ ## T
// atom_label is a pure annotation for the metaprogram's offset calculations.
#define atom_label(name) /* atom_label anchor: name */
