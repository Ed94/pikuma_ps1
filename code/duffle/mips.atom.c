#ifdef INTELLISENSE_DIRECTIVES
#		include "gen/macs.h"
#		include "gen/offsets.h"
#	include "bios.h"
#	include "mips.h"
#	include "lottes_tape.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(mips_atom_c);

#pragma region MACs (Mips Atom Components)

FI_ Slice_MipsCode ac_load_word_imm(AtomBuilder_R ab, Reg dst, U4 imm)
atom_dbg_skip MipsAtomComp_Proc_(ab, {
	load_upper_i(dst, u4_hi(imm)),
	or_i_self(   dst, u4_lo(imm)),
})

#pragma endregion MACs (Mips Atom Components)

#pragma region Baked Atoms

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
	add_ui(R_SP, R_SP, -MipsStackAlignment), // sp -= 8
	store_word(R_RA, R_SP, S_(U4)),           // sw  $ra,   4($sp) 
	add_ui(R_V0, R_0, bios_flushcache),           // addiu $a0, $0, 0x44 
	add_ui(R_T0, R_0, bios_table_addr),           // addiu $t0, $0, 0xA0 
	jump_link(R_T0, R_RA), nop,                   // jalr  $t0, $ra, BD slot
	load_word(R_RA, R_SP, S_(U4)),            // lw   $ra, 4($sp) 
	jump_reg(R_RA),                                 // jr   $ra 
	add_ui(R_SP, R_SP, MipsStackAlignment),  // sp += 8 (BD) 
	mac_yield(),
};

#pragma endregion Baked Atoms
