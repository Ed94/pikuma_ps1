#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "gen/macs.h"
#	include "gen/offsets.h"

#	include "dsl.h"
#	include "gcc_asm.h"
# include "mips.h"
# include "gte.h"
# include "memory.h"
#	include "dsl.atom.h"
#endif

#pragma region Tape Drive
/* -----------------------------------------------------------------------------------------------------------
 *  TAPE DRIVE ABI
 * -----------------------------------------------------------------------------------------------------------
 * Note(Ed): One of the main purposes of this codebase is to help me learn this, 
 * as such the information below may not* be entirely realized or finalized conceptually.
 * -----------------------------------------------------------------------------------------------------------
 * This ABI and its associated legos were directly inspired by researching the work of 
 * Timothy Lottes and Onat Türkçüoğlu; along with many others. It's the simplest bootstrap of a 
 * directly executed chain of assemby arrays (Atoms) that terminate with a yield sequence to the next atom.
 * These eventually lead to a terminal atom for the tape which is defined below as "tape_exit".
 * 
 * This behaves as one of the simplest runtime harnesses ontop of a host-enviornment's execution engine 
 * to author and compose programs with. From here various conventions can be further applied. 
 * To make things easier  to understand it may be better to focus on what this ABI does not have. 
 * It does not have have any branching within the tape but relative branches within atoms or between atoms.
 * Branching nearly is always downstream. Stack usage is non-existent.
 * Push/Pop, FIFO, or Arena/Bump data structures are used by atoms explicitly.
 * In it's current form with the C11 macro dsl, the user also has fullfill manual register allocation per atom.
 * 
 * One of the remarkable things about utilizing this ABI is its essentially interopable with CPUs, GPUs, FPGA, 
 * or, basically anything from the 5th generation consoles and onward.
 * The ABI directly reflects how all computational hardware must be architected in order to execute 
 * digital logic effectively on current era tech.
 * On the PS1 we don't have access to a few features like multi-threading, speculative execution, or L3 cache;
 * but, we can set the foundation for legoing whats required for eventually expanding this ABI's paradigm 
 * and core atoms to take those newer hardware features into account. For example, you can easily expand 
 * this to support wave-based execution model on a PS2 or PS3. Not having a stack or 
 * automatic register allocation means the user cannott ignore excessive argument shuffle across workload or
 * waves and thier phases. Crossing ABI boundaries to other runtimes that do has obviouss penalties.
 * 
 * Learning data-oreinted code becomes a natural progression. Your not fighting a stack-based procedural 
 * paradigm that wants to argument shuffle. There is no ambiguity due to the lack of constraints, for example,
 * on how the user may "call" a procedure in traditional random dispatch runtimes. The user does have to
 * hammer down "rules" or patterns for massaging the compiler to dissolve those call frames; just to get 
 * the asesmbly into its desired form. The form is obvious, and once the user gets to author these compoonents
 * it becomes a game of tetris.
 * 
 * Another feature is this ABI is very compatible with bootstrapping and developing simple toolchains built off
 * of bit-packed annotated command streams the user can directly author, maintatain, and immediately execute.
 * That being like a color forth, or maybe something more familar like an immediate mode library 
 * for various systems such as GUIs. This can make the tetris less of a chore with some helpful policy
 * generation for allocation of registers, helping to choose resuable components, designing DSL on the fly, etc.
 * -----------------------------------------------------------------------------------------------------------
 * TODO(Ed): We need pretty ascii diagrams and proper guides, articles, etc.
 * -----------------------------------------------------------------------------------------------------------
 * For now this ideation has just started functioning. I'm abusing C11 & a lua metaprogram to help establish 
 * a hybrid toolchain to ideate on a traditional text-based authoring UX for this paradigm.
 * If pcsx-redux provides viable hot-reload and persistent data storage beyond save-states
 * (just copying ram to filesystem), I can author a color forth to mess around with.
 * With either an editor in-emulator or on the actual machine itself. Assembly is tedius,
 * but I think this codebase most likely has a pretty ergonomic flavor worst case...
 * */
/* Register Allocation Info */
enum {
	R_AtomJmp  = R_T8 atom_reg,  /* debug-visible; tape yield handshake scratch */
	R_TapePtr  = R_T9 atom_reg,  /* The Instruction Stream Pointer */
/* Stringification codes for the GCC inline assembler clobber lists. */
#define R_AtomJmp_Code R_T8_Code
#define R_TapePtr_Code R_T9_Code

// R_InCursor = R_T4,
// #define R_InCursor_Code    R_T4_Code

// Reserved Registers (Callee-saved):
// - R_T9: Holds the Tape Ptr which we need to increment
//         If we hit a wall with register allocations we can clobber V0 & V1 (return values), defering as opt-in by user.
// - R_RA: Not sure??
// Needed by ac_yield but can be used as atom scratch:
// - R_T8: Will be used as the atom jump register.

// All allocatable registers for mips atoms:
	R_TScratchVolatile = R_AT, // This one is reserved for psuedo instructions, but you can technically use it.
	R_TScratch0  = R_T0,
	R_TScratch1  = R_T1,
	R_TScratch2  = R_T2,
	R_TScratch3  = R_T3,
	R_TScratch4  = R_T4,
	R_TScratch5  = R_T5,
	R_TScratch6  = R_T6,
	R_TScratch7  = R_T7,
	R_TScratch8 =  R_T8,
	R_TScratch10 = R_V0, // Tend to be used with gte DMAs
	R_TScratch11 = R_V1, // Tend to be used with gte DMAs
	// Note(Ed): We can technically clobber these, but don't unless we hit a bottleneck.
	// A 0-2
	// S 0-7
};

typedef U4 const MipsCode; // Underlying type to mips asm words.
typedef Slice_(MipsCode);

typedef U4 const MipsAtom; // Underlying type to an array of mips asm words that must terminate with an ac_yield.
#define MipsAtom_(sym) MipsCode sym [] align_(4) =

// Used for components with no args (e.g., ac_load_tri_indices) or identifier-args (hardcoded register names).
//   MipsAtomComp_(ac_X) { body }
// expands to:
//   MipsCode ac_X[] align_(4) = { body };
#define MipsAtomComp_(sym) MipsCode sym [] align_(4) =

// Used for components with value-args (e.g., ac_format_f3_color).
//   FI_ Slice_MipsCode ac_X(args) MipsAtomComp_Proc_(ac_X, { body })
// expands to:
//   FI_ Slice_MipsCode ac_X(args) { MipsCode ac_X[] align_(4) = { body }; return slice_from_array(MipsCode, ac_X); }
#define MipsAtomComp_Proc_(sym, ...) { MipsCode sym [] align_(4) = __VA_ARGS__; return slice_from_array(MipsCode, sym); }

/* Line-table anchor: gcc only adds a file to the .debug_line file table when the
   file contains line-numbered content. Files containing only:
     - `MipsAtomComp_` static-array declarations, or
     - `MipsAtomComp_Proc_` (force-inline) function bodies whose line info gets
       attributed to the call site at the include point are otherwise omitted from the file table,
			 which breaks the DWARF injection when it tries to resolve atom-component provenance paths.

   Place `ATOM_FILE_LINE_MARKER();` once at file scope in any `.atom.c` that defines atoms.
	 The macro expands to a file-scope `internal U4 const` declaration keeps the file in the line table.
	 The constant is in `.rodata` and unreferenced; the linker may eliminate it.
	 The two-level concat + `__LINE__` suffix makes the identifier unique per call site
	 (the identifier embeds the source line, so duplicates across `#include`d files don't collide). */
#define ATOM_FILE_DEBUGGER_LINE_MARKER(file_name) internal U4 const tmpl(atom_file_debugger_line_marker,file_name) = 0

 typedef Slice_(MipsAtom); typedef Slice_MipsAtom Tape;

/* The 'Exit' Atom */
atom_dbg_skip MipsAtom_(tape_exit) { jump_reg(rret_addr), nop };

// TODO(Ed): When we have a substantial workload/throughput, profile each of these to see impact at ABI boundaries.

/* Tape Runner (Default) */
FI_ void tape_run(Tape tape) { register U4* tape_ptr rgcc(R_TapePtr) = u4_r(tape.ptr); asm volatile(
	asm_words(
		  load_word(  R_AtomJmp, R_TapePtr, 0) /* Bootstrap the first jump */
		, add_ui_self(R_TapePtr, S_(MipsAtom)) /* Advance tape */
		, call_reg(   R_AtomJmp)               /* jalr $t9 */
		, nop                                  /* Branch delay slot */
	)
	asm_rpins, r_use(tape_ptr)
	asm_clobber: 
		rlit(R_AT),
		rlit(R_V0), rlit(R_V1), // We clobber these for GTE ACs (that don't expose register selection, might expose them in the future...)
		rlit(R_T0), rlit(R_T1), rlit(R_T2), rlit(R_T3), rlit(R_T4),
		rlit(R_T5), rlit(R_T6), rlit(R_T7), rlit(R_T8),
		clb_mem_drain 
); }

/* Tape Runner (Static and Arg Clobbers) */
FI_ void tape_run_a02_s07(Tape tape) { register U4* tape_ptr rgcc(R_TapePtr) = u4_r(tape.ptr); asm volatile(
	asm_words(
		  load_word(  R_AtomJmp, R_TapePtr, 0) /* Bootstrap the first jump */
		, add_ui_self(R_TapePtr, S_(MipsAtom)) /* Advance tape */
		, call_reg(   R_AtomJmp)               /* jalr $t9 */
		, nop                                  /* Branch delay slot */
	)
	asm_rpins, r_use(tape_ptr)
	asm_clobber: 
		rlit(R_AT),
		rlit(R_V0), rlit(R_V1), rlit(R_A0), rlit(R_A1), rlit(R_A2),
		rlit(R_T0), rlit(R_T1), rlit(R_T2), rlit(R_T3), rlit(R_T4),
		rlit(R_T5), rlit(R_T6), rlit(R_T7), rlit(R_T8),
		rlit(R_S0), rlit(R_S1), rlit(R_S2), rlit(R_S3), rlit(R_S4),
		rlit(R_S5), rlit(R_S6), rlit(R_S7),
		clb_mem_drain 
); }

// Procedural authoring of tapes:
typedef Relative_(FArena) Struct_(TapeBuilder) { U4 ptr; U4 capacity; U4 used; };
FI_ void        tb_init(TapeBuilder* tb, FArena* arena) { tb->ptr = arena->start; tb->used = 0; }
FI_ TapeBuilder tb_make_old(             FArena* arena) { return (TapeBuilder){ arena->start, 0 }; }
FI_ TapeBuilder tb_make(Slice mem) { return (TapeBuilder){ mem.ptr, mem.len, 0 }; }

FI_ void tb_emit(TapeBuilder* tb, MipsCode* atom) { u4_r(tb->ptr)[tb->used] = u4_(atom); ++ tb->used; }
FI_ void tb_data(TapeBuilder* tb, U4        data) { u4_r(tb->ptr)[tb->used] = u4_(data); ++ tb->used; }
#define tb_emit_(atom)        tb_emit(& tb, atom)
#define tb_data_(field, data) tb_data(& tb, u4_(data))

FI_ Tape tb_end  (TapeBuilder* tb) { tb_emit(tb,tape_exit); return (Tape){ C_(U4*,tb->ptr), tb->used }; }
FI_ Tape tb_slice(TapeBuilder  tb) {                        return (Tape){ C_(U4*,tb.ptr),  tb.used }; }
#define tb_scope(tb)     for(U4 tbs_once=0;tbs_once==0;++tbs_once,tb_emit(tb,tape_exit))

FI_ void tb_scope_run_end(TapeBuilder* tb) { tb_emit(tb,tape_exit); tape_run(tb_slice(tb[0])); }
#define tb_scope_run(tb) for(U4 tbs_once=0;tbs_once==0;++tbs_once,tb_scope_run_end(tb))
#pragma endregion Tape Drive

#pragma region Macro Mips Atom Components
/* ---------------------------------------------------------------------------
 *  MACRO ATOM Components (Reusable Assembly Components)
 *  These do NOT yield. They are expanded inline inside Tape Atoms.
 * ---------------------------------------------------------------------------*/

// The 'Yield' sequence for Tape Atoms (mac_yield).
//   - mac_yield() is the safe default for atom-endings: 4 words, BD-slot of jr is mandatory nop.
//   - mac_yield_load() + mac_yield_tail():
//     - unconditional branch: mac_yield_load fills the branch's BD-slot (replaces a nop);
//     - mac_yield_tail runs at the branch target (does NOT re-load R_AtomJmp).

atom_dbg_skip MipsAtomComp_(ac_yield) {
	load_word(R_AtomJmp, R_TapePtr, 0),
	add_ui_self(         R_TapePtr, S_(MipsCode)),
	jump_reg( R_AtomJmp), nop,
};

atom_dbg_skip MipsAtomComp_(ac_yield_load) {
	load_word(R_AtomJmp, R_TapePtr, 0),
};

atom_dbg_skip MipsAtomComp_(ac_yield_tail) {
	add_ui_self(R_TapePtr, S_(MipsCode)),
	jump_reg(  R_AtomJmp), nop,
};

#pragma endregion Macro Atom Components

#pragma region Mips Atom Builder
// This helps with runtime procedural authoring of mips atoms.

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

#define mipsatom_from_builder(ab) (Slice_MipsCode){ab.start, ab.used}
#pragma endregion Mips Atom Builder

#pragma region Baked Mips Atoms
// These atoms are resolved at compile time and are (usually) statically linked readonly data.

#pragma endregion Baked Mips Atoms
