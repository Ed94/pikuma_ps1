/*
 * tape_atom_dsl.h
 * ============================================================================
 *
 * TAPE ATOM DSL — annotation layer for tape atoms (lottes_tape.h).
 *
 * This header turns `__attribute__((annotate(...)))` and `_Pragma(...)` into
 * a small named DSL that the metaprogram can validate against.
 *
 *   The C compiler treats every macro below as a no-op:
 *     - atom_init / atom_terminate / atom_bind / atom_setup / atom_commit /
 *       atom_annot all expand to `__attribute__((annotate("..."))) MipsAtom_(name)`
 *       — accepted by GCC (with -Wno-attributes), absent at runtime.
 *     - atom_resource / atom_region / atom_group / atom_cadence / atom_async
 *       expand to `_Pragma("...")` — accepted by any C11 preprocessor.
 *
 *   The metaprogram (tape_atom_annotation_pass.lua) reads the source-as-written
 *   and validates:
 *     - every MipsAtom_ has one atom_*() annotation (no orphans)
 *     - phase is recognized (init/bind/setup/work/commit/terminate)
 *     - reads/writes reference canonical wave-context registers
 *     - rbind atoms reference a real Binds_* struct declaration
 *     - word-counts in tapre metadata agree with the body's actual .word count
 *     - resource/region/group/cadence/async pragmas are spelled correctly and
 *       reference known enum values
 *
 * ============================================================================
 *
 *  PUTTING IT ON AN ATOM — the canonical pattern
 *
 *      _tape_resources_
 *      atom_resource(cube_tri, "model_ship_cube")
 *      atom_region  (cube_tri, PRIM_ARENA)
 *      atom_group   (cube_tri, GROUP_RENDER_PRIMS)
 *      atom_cadence (cube_tri, CADENCE_FRAME)
 *
 *      atom_annot(cube_tri, phase_work,
 *                 tape_regs(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase),
 *                 tape_regs(R_PrimCursor, R_FaceCursor))
 *      internal MipsAtom_(cube_tri) {
 *          atom_label(culling),
 *          // ... atom body ...
 *          atom_label(bounds_chk),
 *      };
 *
 *      atom_offset(culling, bounds_chk)         // ← branch target, validated
 *
 *  RBIND pattern — `Binds_*` is the contract
 *
 *      // Wave-context register layout (declarative):
 *      typedef struct Binds_TrackFaceBatch {
 *          U4 R_PrimCursor,  R_FaceCursor,
 *            R_VertBase,    R_OtBase;
 *      } Binds_TrackFaceBatch;
 *
 *      atom_resource(rbind_track_face_batch, "track_face_batch_42")
 *      atom_region  (rbind_track_face_batch, HEAP_3D)
 *      atom_group   (rbind_track_face_batch, GROUP_LOAD_FACES)
 *      atom_cadence (rbind_track_face_batch, CADENCE_ONDEMAND)
 *      atom_async   (rbind_track_face_batch, true)
 *
 *      atom_bind(rbind_track_face_batch, Binds_TrackFaceBatch,
 *                tape_regs(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase))
 *      internal MipsAtom_(rbind_track_face_batch) { ... };
 *
 *  Annotation rules
 *  ----------------
 *      1. Each MipsAtom_(name) needs EXACTLY ONE atom_*() macro on the line
 *         immediately above. No annotation = orphan (warning). Two annotations
 *         on the same name = duplicate (error).
 *
 *      2. atom_init and atom_terminate take only the name.
 *
 *      3. atom_setup and atom_commit take name + reads.
 *
 *      4. atom_bind takes name + Binds_* type + writes.
 *
 *      5. atom_annot takes name + phase token + reads + writes.
 *         Phase tokens: phase_init / phase_bind / phase_setup / phase_work /
 *         phase_commit / phase_terminate.
 *
 *      6. Optional pragmas (atom_resource / atom_region / atom_group /
 *         atom_cadence / atom_async) attach metadata to the atom. They can
 *         appear in any order, with one per atom. They're independent of the
 *         atom_*() macro — multiple pragmatics are fine.
 *
 * ============================================================================
 *
 *  WHY A SEPARATE LAYER (not just put everything in source comments)?
 *
 *      Source comments are invisible to the compiler. Annotations live in the
 *      source as actual C tokens, so:
 *        - they can never silently get out of sync with the code (the build
 *          fails at preprocessing if the metaprogram disagrees)
 *        - they can be cross-validated against metadata (build fails if a
 *          WORD_COUNT entry drifts away from the .word count in source)
 *        - they make the C compiler a witness ("there's a marker here, and
 *          it's labelled, and it has arguments") without making the C compile
 *          itself do any work
 *
 * ============================================================================
 */

 #ifdef INTELLISENSE_DIRECTIVES
#pragma once
// #include <stdint.h>
#endif

/* ============================================================================
 * PHASE TOKENS — strings, used as the second arg to atom_annot(...)
 *
 * Why strings? They preserve the metaprogram's ability to read phase directly
 * from the source-as-written, even when the macro isn't expanded. The Lua
 * tool also has a MACRO_EXPANSION table for resolving phase_* source-level
 * references.
 *
 *   atom_annot(cube_tri, phase_work, ...)    ← legal
 *   atom_annot(cube_tri, "work", ...)        ← legal (and equivalent)
 *   atom_annot(cube_tri, phase_setup, ...)   ← legal
 *
 * ============================================================================*/

#define phase_init       "init"
#define phase_bind       "bind"
#define phase_setup      "setup"
#define phase_work       "work"
#define phase_commit     "commit"
#define phase_terminate  "terminate"

/* ============================================================================
 * WAVE-CONTEXT REGISTERS — canonical register set for the tape wave model.
 *
 * The tape-atom runtime carries four registers across a wave:
 *
 *   R_PrimCursor  output pointer into the prim arena (next OT entry to write)
 *   R_FaceCursor  input pointer into the face array (next face to consume)
 *   R_VertBase    base pointer into the vertex arena (this wave's vertices)
 *   R_OtBase      base pointer into the ordering table (this wave's OT slot)
 *
 * Each atom declares its reads/writes against this canonical set. The Lua
 * tool rejects wave-context positions that reference any other register
 * (warning today — the C compiler's R_T4..R_T7 / R_RA / etc. aliases are
 * implementation details and not part of the typed surface).
 *
 * If your atom needs to touch GTE / SP / DMA / other side state, declare it
 * at the source level as you normally would — but DO NOT put those registers
 * in tape_regs(...). Wave-context is a closed set.
 *
 * ============================================================================*/

/* ============================================================================
 * REGION TOKENS — memory regions atoms may allocate from or write into.
 *
 * Use atom_region(name, REGION) to declare. The Lua tool validates that the
 * region is in this set, AND that:
 *   - rbind atoms declare the source region (usually HEAP_3D or CDROM_STREAM)
 *   - work atoms declare the destination region (the arena they push to)
 *   - commit atoms must declare a region equal to what setup wrote, so the
 *     C-side mirror is consistent
 *
 * Add new regions by extending this list and the metaprogram's KNOWN_REGIONS.
 * Don't add regions ad-hoc — every new region becomes part of the contract.
 *
 * ============================================================================*/
#define REGION_PRIM_ARENA     prim_arena       /* OT/prim packet arena */
#define REGION_FACE_ARENA     face_arena       /* face index array */
#define REGION_VERTEX_ARENA   vertex_arena     /* vertex pool */
#define REGION_OT_ARENA       ot_arena         /* ordering-table array */
#define REGION_HEAP_3D        heap_3d_models   /* loaded model heap */
#define REGION_CDROM_STREAM   cdrom_stream     /* CDROM read buffer */
#define REGION_VRAM           vram_heap        /* VRAM texture/GPU buffer */

/* ============================================================================
 * CADENCE TOKENS — how often the atom runs.
 *
 *   frame    runs every vsync (rendering, input poll)
 *   once     runs exactly once per process lifetime (init, terminate)
 *   ondemand runs when triggered by event (CDROM load, async DMA complete)
 *
 * Used as a hint for the metaprogram to flag:
 *   - frame-cadence atoms that have side effects (they'll be hit many times,
 *     so avoid global state mutation unless it's idempotent)
 *   - once-cadence atoms inside "if (frame_count == 0)" guards (the guard
 *     is then provably one-shot, the metaprogram can lift initialization)
 *   - ondemand atoms that are missed by the wave scheduler (forces async
 *     and discards yield results without further processing)
 *
 * ============================================================================*/
#define CADENCE_FRAME     frame
#define CADENCE_ONCE      once
#define CADENCE_ONDEMAND  ondemand

/* ============================================================================
 * tape_regs(...) — wave-context register list
 *
 *   tape_regs(R_PrimCursor, R_FaceCursor)  →  (R_PrimCursor, R_FaceCursor)
 *
 * The macro produces a comma-evaluated expression that the C compiler
 * silently discards (it's wrapped in parentheses in the call argument
 * position — the result is never bound). The Lua tool pattern-matches the
 * "tape_regs(...)" token to extract the list.
 *
 * You can have at most one tape_regs(...) in the reads slot and one in the
 * writes slot of atom_annot. To declare multiple disjoint sets (rare), just
 * declare the union — the metaprogram doesn't track which reads need which
 * writes at this granularity.
 *
 * ============================================================================*/
#define tape_regs(...) (__VA_ARGS__)

/* ============================================================================
 * ATOM ANNOTATION MACROS
 *
 *   Each expands to `__attribute__((annotate("kind"))) MipsAtom_(name)` —
 *   the GCC attribute is accepted under -Wno-attributes (already in your
 *   build flags) and stripped at runtime. The annotation string is just the
 *   macro kind ("atom_annot", "atom_bind", etc.) — the metaprogram reads
 *   the macro call's full args list from the source-as-written.
 *
 * ============================================================================*/

/* ----------------------------------------------------------------------------
 * atom_init — entry into tape_runtime_main
 *
 *   atom_init(tape_main)
 *   internal MipsAtom_(tape_main) { ... };
 *
 * Implies: no reads, no writes (wave-context not established yet).
 * ----------------------------------------------------------------------------*/
#define atom_init(name) __attribute__((annotate("atom_init")))

/* ----------------------------------------------------------------------------
 * atom_terminate — exit from tape_runtime_main
 *
 *   atom_terminate(tape_exit)
 *   internal MipsAtom_(tape_exit) { ... };
 *
 * Implies: no reads, no writes (wave-context destroyed at this point).
 * ----------------------------------------------------------------------------*/
#define atom_terminate(name) __attribute__((annotate("atom_terminate")))

/* ----------------------------------------------------------------------------
 * atom_setup — pre-work atom: prepares engine state (e.g., set_gte_world)
 *
 *   atom_setup(set_gte_world, tape_regs(R_TapePtr))
 *   internal MipsAtom_(set_gte_world) { ... };
 *
 * Reads:   anything (the engine state you're reading)
 * Writes:  engine state (GTE / DMA / etc. — declared in source, not part of
 *          wave-context, so doesn't go in tape_regs)
 *
 * The metaprogram checks that setup is followed (in atomic order) by a work
 * atom in the same wave — there's no point in setting up state if no one
 * reads it.
 * ----------------------------------------------------------------------------*/
#define atom_setup(name, reads) __attribute__((annotate("atom_setup")))

/* ----------------------------------------------------------------------------
 * atom_commit — post-work atom: flushes wave-context back to C-side state
 *
 *   atom_commit(sync_prim_cursor, tape_regs(R_PrimCursor))
 *   internal MipsAtom_(sync_prim_cursor) { ... };
 *
 * Reads:   wave-context registers (the ones you sync back to C)
 * Writes:  C-side mirror (declared in source — not part of wave-context)
 *
 * The metaprogram checks that commit is preceded (in atomic order) by a
 * work atom that wrote the registers this commit is reading.
 * ----------------------------------------------------------------------------*/
#define atom_commit(name, reads) __attribute__((annotate("atom_commit")))

/* ----------------------------------------------------------------------------
 * atom_bind — rbind atom: read wave-context registers from tape pointer
 *
 *   atom_bind(rbind_cube_tri, Binds_CubeTri,
 *             tape_regs(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase))
 *   internal MipsAtom_(rbind_cube_tri) { ... };
 *
 * The binds_struct MUST be a typedef'd type (declared via
 * `typedef struct Binds_X { ... } Binds_X;` somewhere in the source).
 * The Lua tool cross-references this. Missing struct = error.
 *
 * Implicit: reads R_TapePtr, writes the four wave-context registers.
 * ----------------------------------------------------------------------------*/
#define atom_bind(name, binds_struct, writes) __attribute__((annotate("atom_bind")))

/* ----------------------------------------------------------------------------
 * atom_annot — generic work atom with explicit phase
 *
 *   atom_annot(cube_tri, phase_work,
 *              tape_regs(R_PrimCursor, R_FaceCursor, R_VertBase, R_OtBase),
 *              tape_regs(R_PrimCursor, R_FaceCursor))
 *   internal MipsAtom_(cube_tri) { ... };
 *
 * Use this for the bulk of your atoms. For init/setup/commit/bind, prefer
 * the convenience macros above — they pin the phase for you.
 *
 * The phase arg is one of: phase_init / phase_bind / phase_setup /
 * phase_work / phase_commit / phase_terminate. Spelling mistakes are errors.
 * ----------------------------------------------------------------------------*/
#define atom_annot(name, phase, reads, writes) __attribute__((annotate("atom_annot")))

/* ============================================================================
 * RESOURCE / GROUP / CADENCE / REGION / ASYNC — optional atom metadata
 *
 *   These don't annotate the atom semantically (phase/reads/writes do that).
 *   They attach extra context that the metaprogram uses to catch:
 *     - same resource loaded twice in different ways
 *     - atoms that span multiple regions (likely bug — pick one)
 *     - frame-cadence atoms that should be once-cadence (perf / correctness)
 *     - ondemand atoms that aren't async (CDROM races)
 *
 *   You can use as many as apply to a given atom, in any order, immediately
 *   above the atom_*() macro.
 *
 * ============================================================================*/

/* ----------------------------------------------------------------------------
 * atom_resource — name the logical resource the atom references
 *
 *   atom_resource(cube_tri, "model_ship_cube")
 *   atom_resource(load_track_faces, "track_lavender_field_0x42")
 *   atom_resource(play_engine_sfx, "sfx_engine_loop")
 *
 * Use any human-readable string. The metaprogram:
 *   - validates resource strings are non-empty and don't contain control chars
 *   - flags duplicates across atoms with the same name (two atoms claiming
 *     ownership of a resource is usually a refactor artifact or bug)
 *   - flags references to resources that no atom actually defines
 *
 * The arg is a STRING LITERAL, so it can't accidentally alias a variable.
 * ----------------------------------------------------------------------------*/
#define atom_resource(name, res_id) //_Pragma("atom " #name " resource=" res_id)

/* ----------------------------------------------------------------------------
 * atom_region — name the memory region the atom touches
 *
 *   atom_region(cube_tri,   REGION_PRIM_ARENA)
 *   atom_region(load_faces, REGION_HEAP_3D)
 *   atom_region(load_tex,   REGION_VRAM)
 *
 * Use REGION_* tokens above. The metaprogram enforces the closed set.
 *
 * Edge cases the metaprogram catches:
 *   - rbind atom that doesn't declare a SOURCE region (where is it loading from?)
 *   - work atom with no destination region (where is it pushing to?)
 *   - region that disagrees with the Binds_* struct layout (you said it's a
 *     prim_arena rbind but the struct has 4 faces in it — wait, that's wrong)
 * ----------------------------------------------------------------------------*/
#define atom_region(name, region) //_Pragma("atom " #name " region=" #region)

/* ----------------------------------------------------------------------------
 * atom_group — bundle atoms into a logical batch (track-load, sound-load, etc.)
 *
 *   atom_group(load_track_face_42,  GROUP_LOAD_FACES)
 *   atom_group(load_track_face_43,  GROUP_LOAD_FACES)
 *   atom_group(swap_face_42_43,     GROUP_VISIBILITY_SWAP)
 *
 * Use any token as the group id. The metaprogram:
 *   - validates all atoms in a group emit their waves in the same tb_group
 *     (no spawning other waves inside a group)
 *   - flags groups with only one member (probably a typo — meant to be a group?)
 *   - validates cross-group edges (no atom reads what another group writes,
 *     unless explicitly grouped together)
 *
 * Useful when:
 *   - subdivisible work (track-face batches, polygon subdivision) needs to
 *     confirm that all batches of one logical visible scene are emitted
 *     together
 *   - async loads (CDROM -> VRAM) need to be grouped so all batches complete
 *     before the swap
 *
 * Use GROUPS for sound effects to track which sound plays during which atom,
 * which is needed if the sound tool ever has to validate "this atom is the
 * trigger for an audio play".
 * ----------------------------------------------------------------------------*/
#define atom_group(name, group_id) //_Pragma("atom " #name " group=" #group_id)

/* ----------------------------------------------------------------------------
 * atom_cadence — declare execution frequency
 *
 *   atom_cadence(render_frame,     CADENCE_FRAME)       // every vsync
 *   atom_cadence(load_track_faces, CADENCE_ONDEMAND)    // on demand
 *   atom_cadence(init_heap,        CADENCE_ONCE)        // process lifetime
 *
 * Default (no atom_cadence call) is CADENCE_FRAME — most atoms run every
 * frame. Override explicitly when not.
 *
 * The metaprogram's checks:
 *   - CADENCE_ONCE atoms inside `if (frame == 0)` or `if (!initialized)` are
 *     tagged, validating that guards are required (or warning if missing)
 *   - CADENCE_FRAME atoms that mutate state outside the wave context get
 *     flagged (likely a bug — state should persist through commits)
 *   - CADENCE_ONDEMAND atoms must have atom_async — otherwise the trigger
 *     mechanism is undefined
 * ----------------------------------------------------------------------------*/
#define atom_cadence(name, cadence) //_Pragma("atom " #name " cadence=" #cadence)

/* ----------------------------------------------------------------------------
 * atom_async — declare whether the atom yields / interacts with CDROM DMA
 *
 *   atom_async(load_track_tex,  true)   // CDROM read yield
 *   atom_async(load_vram,       true)   // VRAM upload DMA
 *   atom_async(render_frame,    false)  // pure compute, no async
 *
 * The metaprogram requires this for CADENCE_ONDEMAND atoms. For
 * CADENCE_FRAME, it's optional but documents intent.
 *
 * Note: CDROM ATOMS in Psy-Q are typically implemented as a chain of
 * "async-init" atom followed by a "wait-for-completion" atom. Both atoms
 * should be marked async=true, and both should have the same resource/group
 * tag (so the metaprogram can verify they're paired).
 * ----------------------------------------------------------------------------*/
#define atom_async(name, is_async) //_Pragma("atom " #name " async=" #is_async)

/* ============================================================================
 * WORD-COUNT ANNOTATION FOR A #define MAC
 *
 *   tape_words(mac_yield, 1)
 *   #define mac_yield()  \
 *       load_word(R_AtomJmp, R_TapePtr, 0), \
 *       add_ui_1(R_TapePtr, 4), \
 *       jump_reg(R_AtomJmp), \
 *       nop
 *
 * The compiler accepts the unknown _Pragma. The Lua tool reads it and
 * cross-checks against WORD_COUNT(mac_yield, 1) in tape_atom.metadata.h.
 * If they disagree, build fails.
 *
 * Use sparingly — only on multi-word macros (single-word ones don't need
 * drift tracking; they're checked by the .word-count pass anyway).
 *
 * ============================================================================*/
#define tape_words(name, n) //_Pragma(#name " tape_atom words=" #n)

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
#define atom_label(name) /* anchor — see metaprogram documentation */
