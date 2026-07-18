/*
 * atom_dsl.h
 * ============================================================================
 *
 * ATOM DSL: Annotation layer for tape atoms (lottes_tape.h).
 * The metaprogram (scripts/passes/annotation.lua) reads source-as-written and validates:
 *   - atom_info(...) shape: up to three sub-calls (atom_bind(Binds_X), atom_reads(...), atom_writes(...)) in any order and are optional.
 *   - rbind atoms (atom_info(..., atom_bind(Binds_X), ...)) reference a real Binds_* struct declaration.
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
 *           - atom_bind(Binds_X)
 *           - atom_reads(...)
 *           - atom_writes(...)
 *      3. atom_bind(Binds_X): metaprogram cross-references Binds_X against the `typedef struct Binds_X { ... } Binds_X;` declaration.
 *      4. atom_reads(...) and atom_writes(...): Used to to check if registers are used correctly in macros: R_PrimCursor / R_FaceCursor / R_VertBase / R_OtBase.
 *      5. atom_label(name: Utilize with atom_offset as a target location.
 *      6. atom_offset(F, T): Resolved by gen/atom_offsets.h, generated from the atom_label markers. Calculated during the offset pass of the lua  metaprogram.
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

/* ----------------------------------------------------------------------------
 * atom_reg (per-enum opt-in marker for the DWARF register-alias registry)
 *
 * The bare `atom_reg` token adjacent to an enum entry in mips.h / lottes_tape.h flags that alias as debug-visible for scan_source's register_alias_registry.
 * The C preprocessor strips it to a comment so no runtime symbol is created; the Lua scanner reads the bare token.
 * ----------------------------------------------------------------------------*/
#define atom_reg /* atom_reg: opt the preceding enum entry into the DWARF registry */

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
 * Typed-view annotations (Registry for DWARF RR_<R_X> chain resolution)
 *   atom_type(<T>) -- overloaded:
 *      (a) enum-site default: `R_Foo = R_Tn, atom_reg atom_type(T)` 
 *      Sets the per-alias default typed view in the register_alias_registry.
 *      Consumed by the DWARF chain step (e) when no per-atom atom_ctx / atom_phase / atom_type callsite provides a stronger resolution.
 *      (b) callsite override: `atom_reads(R_Foo atom_type(T), ...)` Overrides the per-alias default for THIS atom only.
 *      Last-write-wins per R_Name; conflict -> error.
 *   atom_ctx(<atom_name>) -- atom-info sub-call:
 *       Propagate another atom's atom.rbind.fields (its Binds_* typed fields) into THIS atom's typed-view resolution.
 *       The named atom must be an rbind atom (have `atom_bind(Binds_X)` in its `atom_info`).
 *       Used as the escape hatch when atom_phase is not the natural correlation.
 *   atom_phase(<label>) -- atom-info sub-call: 
 *       Free-form C-identifier label for grouping atoms.
 *       Within a phase, the FIRST atom in source-order that owns its own atom.rbind provides 
 *       the Binds_* field types used by all other atoms in the same phase.
 *       The preferred correlation mechanism; atom_ctx is the escape hatch for non-natural cases.
 *
 * All three expand to C comments
 * (the bare-token convention matching `atom_reg` and `atom_dbg_skip_over`).
 * The Lua scanner reads the bare tokens in source-as-written; the C preprocessor strips them.
 * ----------------------------------------------------------------------------*/
#define atom_type(T)        /* atom_type: associate <T> with the preceding enum entry (enum site) or this register (atom-info site) */
#define atom_ctx(atom_name) /* atom_ctx: propagate <atom_name>'s Binds_* field types into this atom's typed views */
#define atom_phase(label)   /* atom_phase: tag this atom with <label> for grouped typed-view resolution */

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
 * If gen/atom_offsets.h is stale (or atom_label(name) is undefined), `atom_offset_F_T` becomes an undefined macro and the C build fails.
 * ============================================================================*/
#define atom_offset(F, T) atom_offset_ ## F ## _ ## T
// atom_label is a pure annotation for the metaprogram's offset calculations.
#define atom_label(name) /* atom_label anchor: name */
