/*
 * atom_dsl.h
 * ============================================================================
 *
 * ATOM DSL: Annotation layer for tape atoms (lottes_tape.h).
 *
 *   WHAT THIS HEADER IS
 *   -------------------
 *   The metaprogram (scripts/passes/annotation.lua) reads source-as-written
 *   and validates:
 *     - atom_info(...) shape: up to three sub-calls (atom_bind(Binds_X),
 *       atom_reads(...), atom_writes(...)) in any order. All optional.
 *       (No phase token for now; phases may be reintroduced later.)
 *     - rbind atoms (atom_info(..., atom_bind(Binds_X), ...)) reference a
 *       real Binds_* struct declaration.
 *     - wave-context positions only reference the canonical 4-register
 *       set: R_PrimCursor / R_FaceCursor / R_VertBase / R_OtBase.
 *     - atom word-counts in word_counts.metadata.h agree with the body's
 *       actual .word count.
 *
 *   WHY A PURE MACRO (atom_info, atom_bind, atom_reads, atom_writes, atom_label)
 *   -----------------------------------------------------------------
 *   Each of these expands to a C comment or to nothing. The C preprocessor
 *   strips them to whitespace. The metaprogram reads the literal token from
 *   source-as-written, NOT from the preprocessed output. This means:
 *     - the C compiler does no work for them (no __attribute__, no
 *       _Pragma, no asm side-effects)
 *     - they can never silently drift from the metaprogram's view
 *       (the metaprogram re-reads the source on every build)
 *     - the annotation is invisible to the linker, debugger, and IDE
 *
 * ============================================================================
 *
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
 *      1. atom_info(...) is OPTIONAL. Most atoms have no annotation.
 *         Atoms without atom_info are silently skipped by the metaprogram.
 *
 *      2. If present, atom_info takes up to three sub-calls, all
 *         order-independent within the arg list:
 *           - atom_bind(Binds_X) (optional; only for rbind atoms)
 *           - atom_reads(...) (optional; wave-context registers)
 *           - atom_writes(...) (optional; wave-context registers)
 *
 *      3. atom_bind(Binds_X) pins the ABI-struct shape -- the metaprogram
 *         cross-references Binds_X against the
 *         `typedef struct Binds_X { ... } Binds_X;` declaration.
 *
 *      4. atom_reads(...) and atom_writes(...) args are wave-context
 *         registers: R_PrimCursor / R_FaceCursor / R_VertBase / R_OtBase.
 *         Closed set. GTE / SP / DMA / I/O state is declared in source
 *         comments, not in atom_reads/atom_writes.
 *
 *      5. atom_label(name) is an anchor -- the macro is empty in C; the
 *         metaprogram records the marker at the current pos for offset
 *         calculation.
 *
 *      6. atom_offset(F, T) is resolved by gen/atom_offsets.h, generated
 *         from the atom_label markers.
 */

#ifdef INTELLISENSE_DIRECTIVES
#pragma once
// #include <stdint.h>
#endif

/* ============================================================================
 * WAVE-CONTEXT REGISTERS -- canonical register set for the tape wave model.
 *
 *   R_PrimCursor  output pointer into the prim arena (next OT entry to write)
 *   R_FaceCursor  input pointer into the face array (next face to consume)
 *   R_VertBase    base pointer into the vertex arena (this wave's vertices)
 *   R_OtBase      base pointer into the ordering table (this wave's OT slot)
 *
 * Closed set. If your atom needs to touch GTE / SP / DMA / other side state,
 * declare it at the source level as you normally would -- but DO NOT put
 * those registers in atom_reads/atom_writes.
 *
 * ============================================================================*/

/* ============================================================================
 * atom_reads(...) / atom_writes(...) -- wave-context register list
 *
 *   atom_reads(R_PrimCursor, R_FaceCursor)
 *         ->  (R_PrimCursor, R_FaceCursor)   // comma-evaluated, discarded
 *
 * The macro produces a comma-evaluated expression that the C compiler
 * silently discards (it sits in an unused arg position -- the result is
 * never bound). The Lua tool pattern-matches the "atom_reads(...)" /
 * "atom_writes(...)" token to extract the list.
 *
 * You can have at most one atom_reads(...) and at most one atom_writes(...)
 * in an atom_info(...) call. To declare multiple disjoint sets (rare), just
 * declare the union -- the metaprogram doesn't track which reads need which
 * writes at this granularity.
 *
 * ============================================================================*/
#define atom_reads(...)  (__VA_ARGS__)
#define atom_writes(...) (__VA_ARGS__)

/* ============================================================================
 * ATOM ANNOTATION MACROS
 *
 *   atom_info -- single unified annotation. OPTIONAL. Most atoms have none.
 *
 *      MipsAtom_(cube_tri) atom_info(
 *         atom_reads (R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
 *       , atom_writes(R_PrimCursor, R_FaceCursor)
 *      ){ ... };
 *
 *   Shape (sub-args order-independent; all optional):
 *     - atom_bind(Binds_X):  at most one; pins the ABI-struct shape
 *     - atom_reads(...):     at most one; comma-list of wave-context registers
 *     - atom_writes(...):    at most one; comma-list of wave-context registers
 *
 *   No phase token for now. The metaprogram doesn't check ordering across
 *   atoms -- phases (init / bind / setup / work / commit / terminate) will
 *   be reintroduced when ordering checks are added.
 *
 *   The macro expands to a C comment (or to nothing). The C compiler does
 *   no work. The metaprogram reads the source-as-written directly.
 *
 * ============================================================================*/
#define atom_info(...)  /* atom_info(__VA_ARGS__) */

/* ----------------------------------------------------------------------------
 * atom_bind(Binds_X) -- rbind sub-call of atom_info
 *
 *   MipsAtom_(rbind_cube_tri) atom_info(
 *         atom_bind(Binds_CubeTri)
 *       , atom_writes(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase)
 *   ){ ... };
 *
 * The Binds_X MUST be a typedef'd type (declared via
 * `typedef struct Binds_X { ... } Binds_X;` somewhere in the source).
 * The Lua tool cross-references this. Missing struct = error.
 *
 * atom_bind is a SUB-CALL of atom_info, not a standalone annotation macro.
 *
 * The macro expands to a C comment. The metaprogram reads source-as-written.
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
 * The metaprogram generates gen/atom_offsets.h with one
 *   #define atom_offset__culling__bounds_chk  ((target - branch_pos - 1))
 * per atom_offset(F, T) call. The preprocessor then expands your call to
 * the right immediate value.
 *
 * If gen/atom_offsets.h is stale (or atom_label(name) is undefined),
 * `atom_offset__F__T` becomes an undefined macro and the C build fails.
 * This catches:
 *   - typo in atom_label (no anchor → metaprogram doesn't emit the macro)
 *   - .offsets.h not regenerated after body edits
 *   - body edit that broke the offset math (recompile + retest picks it up
 *     in CPU emulator)
 *
 * ============================================================================*/

#define atom_offset(F, T) atom_offset_ ## F ## _ ## T
/* atom_label is a pure annotation for the metaprogram's offset calculations.
 * The macro expands to a C comment, so the C preprocessor strips it to
 * whitespace — NO instruction word is emitted in the asm. The metaprogram
 * still recognises the literal `atom_label(name)` token in source and
 * records the marker at the current pos. */
#define atom_label(name) /* atom_label anchor: name */
