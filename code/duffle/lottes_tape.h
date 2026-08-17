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
 * It behaves as one of the simplest runtime harnesses ontop of a host-enviornment's execution engine 
 * to author and compose programs with. From here various conventions can be further applied. 
 * To make things easier  to understand it may be better to focus on what this ABI does not have. 
 * It does not have have any branching within the tape but relative branches within atoms or between atoms.
 * Branching nearly is always downstream. Automatic stack usage is non-existent.
 * Push/Pop, FIFO, or Arena/Bump data structures are used by atoms explicitly.
 * In it's current form with the C11 macro DSL, the user also has fullfill manual register allocation per atom.
 * 
 * One of the remarkable things about utilizing this ABI is its essentially interopable with CPUs, GPUs, FPGA, 
 * or, basically anything from the 5th generation consoles and onward.
 * The ABI directly reflects how all computational hardware must be architected in order to execute 
 * digital logic effectively on current era tech.
 * On the PS1 we don't have access to a few features like multi-threading, speculative execution, or L3 cache;
 * but, we can set the foundation for legoing whats required for eventually expanding this ABI's paradigm 
 * and core atoms to take those newer hardware features into account. For example, you can easily expand 
 * this to support wave-based execution model on a PS2 or PS3. Not having a stack or 
 * automatic register allocation means the user cannot ignore excessive argument shuffle across workload or
 * waves and thier phases. Crossing ABI boundaries to other runtimes that do has obviouss penalties.
 * 
 * Learning data-oriented code becomes a natural progression. Your not fighting a stack-based procedural 
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
// - R_RA: Return address register
// Needed by ac_yield but can be used as atom scratch:
// - R_T8: Will be used as the atom jump register.

// All allocatable registers for mips atoms:

	// TODO(Ed): Make this the R_AtomJmp register since its better to clobber across atoms.
	R_TScratchVolatile = R_AT, // This one is reserved for psuedo instructions, but you can technically use it.

	R_TScratch0  = R_T0,
	R_TScratch1  = R_T1,
	R_TScratch2  = R_T2,
	R_TScratch3  = R_T3,
	R_TScratch4  = R_T4,
	R_TScratch5  = R_T5,
	R_TScratch6  = R_T6,
	R_TScratch7  = R_T7,
	R_TScratch8 =  R_T8, // Clobbered by the yield on a per-atom boundary.
	R_TScratch10 = R_V0, // Tend to be used with gte DMAs
	R_TScratch11 = R_V1, // Tend to be used with gte DMAs
	// Note(Ed): We can technically clobber these, but don't unless we hit a bottleneck.
	// A 0-2
	// S 0-7
};

typedef U2 Reg; // Register parameter used with atom or atom component procedures
#define Reg_(type) tmpl(Reg,type) // Just a way to template register allocations of C-struct types.

typedef U4 const MipsCode; // Underlying type to mips asm words.
typedef Slice_(MipsCode);

typedef U4 const MipsAtom; // Underlying type to a mips atom defnition 
typedef Slice_(MipsAtom); 
// Sometimes a user will define a bundle of atoms that represent a procedure of work as:
//   MipsAtom* <identifier>[...];
// Unfortuantely if using slice_from_array it will make the slice's pointer: MipsAtom** so this enforce its defined as MipsAtom*
// TODO(Ed): Alternatively we can make the MipsAtom an opaque pointer to the atom... so that the proc returns 'MipsAtom'.
#define atombundle_from_array(array) (Slice_MipsAtom){.ptr=array[0],.len=Array_len(array)}

// Underlying type to an ptr to an array of mips asm words that must terminate with an ac_yield.
#define MipsAtom_(sym) MipsCode sym [] align_(4) =

// Used for atoms with value-args
//   internal MipsAtom* X_proc(AtomArena_R aa, args) MipsAtom_Proc_(X, aa, { body })
// expands to:
//   internal MipsAtom* X_proc(AtomArena_R aa, args) { MipsCode atom_comp_code[] align_(4) = { body }; return atomarena_push(aa, slice_from_array(MipsCode, atom_comp_code)); }
// The atom name is derived by the Lua metaprogram from the preceding
// `MipsAtom* X_proc(...)` declaration (backward walk from the macro site,
// strips the `_proc` suffix).
#define MipsAtom_Proc_(aa, ...) { MipsCode atom_comp_code[] align_(4) = __VA_ARGS__; return atomarena_push(aa, slice_from_array(MipsCode, atom_comp_code)); }

// Used for components with no args (e.g., ac_load_tri_indices) or identifier-args (hardcoded register names).
//   MipsAtomComp_(ac_X) { body }
// expands to:
//   MipsCode ac_X[] align_(4) = { body };
#define MipsAtomComp_(sym) MipsCode sym [] align_(4) =

// Used for components with value-args (mandatory `ab` (atom-builder) arg).
//   FI_ void ac_X(MipsAtomBuilder_R ab, args) MipsAtomComp_Proc_(ab, { body })
// expands to:
//   FI_ void ac_X(MipsAtomBuilder_R ab, args) {
//       MipsCode atom_comp_code[] align_(4) = { body };
//       atombuilder_push(ab, slice_from_array(MipsCode, atom_comp_code));
//   }
// The body must NOT include mac_yield() (the parent atom yields).
// The component name is derived by the Lua metaprogram from the preceding `FI_ Slice_MipsCode ac_X(...)` declaration (backward walk from the macro site).
// Inline-only callers (the generated `mac_<name>` aliases) skip the `ab` arg via metaprogram filtering; escape callers (ac_<name> invoked as a function) pass a long-lived builder.
#define MipsAtomComp_Proc_(ab, ...) { MipsCode atom_comp_code[] align_(4) = __VA_ARGS__; atombuilder_push(ab, slice_from_array(MipsCode, atom_comp_code)); }

// Used for trivial mappings from one atom component proc to the command of a more baser (meant for type-mapping)
#define MipsAtomComp_ProcMap_(ab, base_command) atom_dbg_skip MipsAtomComp_Proc_(ab, {base_command })

/* Line-table anchor: gcc only adds a file to the .debug_line file table when the contains line-numbered content.
	Files containing only atoms and atom components.
   Place `ATOM_FILE_LINE_MARKER();` once at file scope in any `.atom.c` that defines atoms.
	 Macro expands to a file-scope `internal U4 const` declaration keeps the file in the line table.
	 The constant is in `.rodata` so the linker may eliminate it.
	 Two-level concat + `__LINE__` suffix makes the identifier unique per call site
	 (identifier embeds the source line, so duplicates across `#include`d files don't collide). */
#define ATOM_FILE_DEBUGGER_LINE_MARKER(file_name) internal U4 const tmpl(atom_file_debugger_line_marker,file_name) = 0

typedef Slice_MipsAtom Tape;

/* The 'Exit' Atom */
atom_dbg_skip MipsAtom_(tape_exit) { jump_reg(R_RA), nop };

// TODO(Ed): When we have a substantial workload/throughput, profile each of these to see impact at ABI boundaries.

/* Tape Runner (Default) */
FI_ void tape_run(Tape tape) { register U4* tape_ptr rgcc(R_TapePtr) = u4_r(tape.ptr); asm volatile(
	asm_words(
		  load_word(  R_AtomJmp, R_TapePtr, 0) /* Bootstrap the first jump */
		, add_ui_self(R_TapePtr, S_(MipsAtom)) /* Advance tape */
		, call_reg(   R_AtomJmp)               /* jalr $t8 */
		, BdSlot_ nop                          /* Branch delay slot */
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
		, call_reg(   R_AtomJmp)               /* jalr $t8 */
		, BdSlot_ nop                          /* Branch delay slot */
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
FI_ TapeBuilder tb_make(Slice mem) { return (TapeBuilder){ u4_(mem.ptr), mem.len, 0 }; }  /* capacity in elements (matches used units) */

FI_ void tb_emit(TapeBuilder* tb, MipsAtom* atom) { u4_r(tb->ptr)[tb->used] = u4_(atom); ++ tb->used; }
FI_ void tb_data(TapeBuilder* tb, U4        data) { u4_r(tb->ptr)[tb->used] = u4_(data); ++ tb->used; }
#define tb_emit_(atom)        tb_emit(& tb, atom)
#define tb_data_(field, data) tb_data(& tb, u4_(data))

FI_ void tb_emit_bundle(TapeBuilder_R tb, Slice_MipsAtom atoms) { mem_copy(u4_(tb->ptr), u4_(atoms.ptr), S_slice(atoms)); tb->used += atoms.len; }

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

atom_dbg_skip MipsAtomComp_(ac_yield) {
	load_word(R_AtomJmp, R_TapePtr, 0),
	add_ui_self(         R_TapePtr, S_(MipsCode)),
	jump_reg( R_AtomJmp), BdSlot_ nop,
};

atom_dbg_skip MipsAtomComp_(ac_yield_load) {
	load_word(R_AtomJmp, R_TapePtr, 0),
};

atom_dbg_skip MipsAtomComp_(ac_yield_tail) {
	add_ui_self(R_TapePtr, S_(MipsCode)),
	jump_reg( R_AtomJmp),
	BdSlot_ nop,
};

#pragma endregion Macro Atom Components

#pragma region Atom Builder
// This helps with runtime procedural authoring of mips atoms.

typedef Struct_(FMipsAtom512) { U4 data[512]; U4 used; };

// FArena Related
typedef Relative_(FArena) Struct_(AtomBuilder) { U4 start; U4 capacity; U4 used; };

// Usual way to resolve an atom after the bulder is done.
#define atom_from_atombuilder(ab) C_(MipsAtom*, (ab).start)

FI_ void atombuilder_push(AtomBuilder_R ab, Slice_MipsCode code) {
	assert(ab->capacity - ab->used - code.len);
	U4 dest = ab->start + ab->used * S_(MipsCode); U4 size = S_slice(code);
	mem_copy(dest, u4_(code.ptr), size); ab->used += size;
}
#define atombuilder_push_mac(ab, mac) atombuilder_push(ab, slice_arg_from_array(Slice_MipsCode, mac))

// When done authoring, utilize this to cap-off the atom (if not utilizing a MipsAtom_Proc).
FI_ void atombuilder_end(AtomBuilder_R ab) { atombuilder_push(ab, slice_from_array(MipsCode, ac_yield)); }

FI_ void tb_emit_atombuilder(TapeBuilder_R tb, AtomBuilder_R ab) { tb_emit(tb, atom_from_atombuilder(ab[0])); }
#pragma endregion Mips Atom Builder

#pragma region Atom Arena
// Just a dedicated FArena that is meant to mem_copy and return atom definitions made with MipsAtom_Proc_

typedef Relative_(FArena) Struct_(AtomArena) { U4 start; U4 capacity; U4 used; };

#define atomarena_unused_start(ab) ((ab).start + (ab).used)
FI_ void atomarena_init(AtomArena_R arena, Slice mem) {  assert(arena != nullptr);
	arena->start    = u4_(mem.ptr);
	arena->capacity = mem.len;
	arena->used     = 0;
}
FI_ AtomArena atomarena_make(Slice mem) { AtomArena a; atomarena_init(& a, mem); return a; }
FI_ MipsAtom* atomarena_push(AtomArena_R aa, Slice_MipsCode code) {
	assert(aa->capacity - aa->used - code.len);
	U4 dest = atomarena_unused_start(aa[0]); U4 size = S_slice(code);
	mem_copy(dest, u4_(code.ptr), size); aa->used += size;
	return C_(MipsAtom*, dest);
}
FI_ void atomarena_reset(AtomArena_R aa) { aa->used = 0; }
#pragma endregion Atom Arena

#pragma region RegFile (Register File Allocator)
// A specialized allocator utilized to help the user track which registers are bound to values
// that must be preserved for the arena's bounds.
// TODO(Ed): Technically we can do this at comp-time with the metaprogram, but we may have namespace conflicts.
// Unless we follow a convention for #define <Scope_Prefix> or something per register allocation boundary.

/* ABI + tape reserves that are never handed out by alloc. */
U4 const regfile_abi_mask =
	(1u << R_0)  | (1u << R_AT)  |
	(1u << R_K0) | (1u << R_K1)  |
	(1u << R_GP) | (1u << R_SP)  |
	(1u << R_FP) | (1u << R_RA)  |
	(1u << R_T8) | (1u << R_T9); /* AtomJmp + TapePtr */

typedef Struct_(RegFile) {
	A2_U2 GPR;
	A2_U2 GTE;
};
#define regfile(pin_mask) {.GPR={u4_lo(pin_mask), u4_hi(pin_mask)} }
FI_ void regfile_init(RegFile_R rf) {
	/* pack the 32-bit ABI mask into the two U2s */
	rf->GPR[0] = u4_lo(regfile_abi_mask);
	rf->GPR[1] = u4_hi(regfile_abi_mask);
	rf->GTE[0] = rf->GTE[1] = 0;
}
FI_ RegFile regfile_make(void) { RegFile rf; regfile_init(& rf); return rf; }

typedef Struct_(RegFile_RInfo) {
	U2_R section;
	U2   mask;
	B2   occupied;
};
FI_ RegFile_RInfo regfile_rinfo(A2_U2 file, Reg r_id) {
	U2   s_id     = r_id >> 4;
	U2_R section  = & file[s_id];
	U2   mask     = u2_(1u << (r_id & 15));
	B2   occupied = (section[0] & mask) != 0;
	return (RegFile_RInfo){section, mask, occupied};
}
FI_ Reg regfile__alloc_helper(A2_U2 file, Reg r_id) {
	Reg result = 0; RegFile_RInfo info = regfile_rinfo(file, r_id);
	if (info.occupied == false) {
		info.section[0] |= info.mask;
		result = r_id;
	}
	return result; 
}
I_ Reg regfile_alloc(RegFile_R rf) {
	U2 allocated = 0;
	for index_iter(Reg, r_id, R_T0, <=, R_T7) {
		allocated = regfile__alloc_helper(rf->GPR, r_id); Jmp_nZero_(allocated,resolved);
	}
	allocated = regfile__alloc_helper(rf->GPR, R_V0); Jmp_nZero_(allocated,resolved);
	allocated = regfile__alloc_helper(rf->GPR, R_V1);
	assert(allocated != 0);
resolved: return allocated;
}
FI_ Reg regfile_pin(RegFile_R rf, Reg r_id) {
	RegFile_RInfo info = regfile_rinfo(rf->GPR, r_id);
	assert(info.occupied == false);
	info.section[0] |= info.mask;
	return r_id;
}
FI_ void regfile_pin_mask(RegFile_R rf, U4 mask) {
	B4 occupied = u4_r(rf->GPR)[0] & mask;
	assert(occupied == false);
	u4_r(rf->GPR)[0] |= mask;
}
FI_ void regfile_free_mask(RegFile_R rf, U4 mask) {
	if (regfile_abi_mask & mask) return;
	u4_r(rf->GPR)[0] &= ~mask;
}
FI_ void regfile_free_reg(RegFile_R rf, Reg r_id) {
	/* never free the ABI set */
	if (regfile_abi_mask & (1u << r_id)) return;
	RegFile_RInfo info = regfile_rinfo(rf->GPR, r_id);
	info.section[0] &= ~info.mask;
}
FI_ void regfile_reset(RegFile_R rf) {
	rf->GPR[0] = u4_lo(regfile_abi_mask);
	rf->GPR[1] = u4_hi(regfile_abi_mask);
}
FI_ void regfile_reset_to_mask(RegFile_R rf, U4 mask) {
	rf->GPR[0] = u4_lo(mask);
	rf->GPR[1] = u4_hi(mask);
}
#pragma endregion RegFileArena (Register File Allocator)

#pragma region Mips Atom Procs
/* RegUse structs are a convention to organize register allocations for a mips atom procedure.
	Unlike the usual enum-based declarations, they provide a namespaced scope 
	and have view types via union declarations.
*/
#define RegUse_(proc_name) (tmpl(RegUse,proc_name))

	typedef Struct_(RegUse_example_atom_proc) {
		Reg const ro_register; // Scratch base carrier.
		Reg usual_modifiable;
		union { Reg view_1, view_2, view_3; } t1;
	};
	internal MipsAtom* example_atom_proc(AtomArena_R aa, U2 offset, RegUse_example_atom_proc r) 
	MipsAtom_Proc_(aa, {
		add_si(r.usual_modifiable, r.ro_register, offset),
		or_u(r.t1.view_1, r.ro_register, 0),
		branch_lt_zero(r.t1.view_1, atom_offset(example_atom_proc, skip)), BdSlot_ nop,
		li_s(r.t1.view_2, 100),
	atom_label(skip)
		add_si(r.t1.view_3, r.usual_modifiable, 10),
		mac_yield(),
	})

#pragma endregion Mips Atom Procs

#pragma region Baked Mips Atoms
// These atoms are resolved at compile time and are (usually) statically linked readonly data.

#pragma endregion Baked Mips Atoms
