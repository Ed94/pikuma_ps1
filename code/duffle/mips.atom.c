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

FI_ Slice_MipsCode ac_shift_aright_v3_self(AtomBuilder_R ab, Reg dt_x, Reg dt_y, Reg dt_z, U2 shift_amount)
MipsAtomComp_Proc_( ab, {
	shift_aright(dt_x, dt_x, shift_amount),
	shift_aright(dt_y, dt_y, shift_amount),
	shift_aright(dt_z, dt_z, shift_amount),	
})

FI_ Slice_MipsCode ac_shift_aright_v3s4_self(AtomBuilder_R ab, Reg_(V3_S4) dt, U2 shift) MipsAtomComp_ProcMap_(ab, mac_shift_aright_v3_self(dt.x, dt.y, dt.z, shift))

FI_ Slice_MipsCode ac_shift_aright_var_v3(AtomBuilder_R ab
	, Reg rd_v0, Reg rd_v1, Reg rd_v2
	, Reg rs_v0, Reg rs_v1, Reg rs_v2
	, Reg r_shift)
MipsAtomComp_Proc_(ab, {
	shift_aright_var(rd_v0, rs_v0, r_shift),
	shift_aright_var(rd_v1, rs_v1, r_shift),
	shift_aright_var(rd_v2, rs_v2, r_shift),
})

FI_ Slice_MipsCode ac_shift_aright_var_v3_self(AtomBuilder_R ab, Reg rds_v0, Reg rds_v1, Reg rds_v2, Reg r_shift) 
atom_dbg_skip MipsAtomComp_Proc_(ab, {
	shift_aright_var(rds_v0, rds_v0, r_shift),
	shift_aright_var(rds_v1, rds_v1, r_shift),
	shift_aright_var(rds_v2, rds_v2, r_shift),
})

FI_ Slice_MipsCode ac_shift_aright_var_v3s4_self(AtomBuilder_R ab, Reg_(V3_S4) ds, Reg shift) MipsAtomComp_ProcMap_(ab, mac_shift_aright_var_v3_self(ds.x, ds.y, ds.z, shift))

#pragma endregion MACs (Mips Atom Components)

#pragma region Baked Atoms

/* Flushes the Instruction Cache (PSX A-function 0x44 via BIOS stub at 0xA0).
 * Sequence (per MIPS ABI; arguments in arg registers, RA pushed to stack):
 *   1. sp -= 8;  sw $ra, 4($sp)        ; save RA
 *   2. $a0 = bios_flushcache (arg0)
 *   3. $t0 = bios_table_addr           ; t0 = &BIOS A-function table
 *   4. jalr $t0, $ra                   ; call BIOS(flushcache)
 *      nop                             ; branch delay slot
 *   5. lw $ra, 4($sp)
 *   6. sp += 8                         ; load-delay
 *   7. jr $ra
 *      nop                             ; BD
 */

#if 0
// Note: Can't do this without having a way to do C-Runtime frame call from Tape ABI.
// Don't support this without adjusting scratchpad to save tape frame in some way.
internal MipsAtom_(mips_flush_icache) {
	add_ui(R_SP, R_SP, -MipsStackAlignment), // sp -= 8
	store_word(R_RA, R_SP, S_(U4)),           // sw  $ra,   4($sp) 
	add_ui(R_V0, R_0, bios_flushcache),           // addiu $a0, $0, 0x44 
	add_ui(R_T0, R_0, bios_table_addr),           // addiu $t0, $0, 0xA0 
	jump_link(R_T0, R_RA), nop,                   // jalr  $t0, $ra, BD slot
	load_word(R_RA, R_SP, S_(U4)),            // lw   $ra, 4($sp) 
	add_ui(R_SP, R_SP, MipsStackAlignment),  // sp += 8 (load-delay)
	jump_reg(R_RA), nop,                          // jr   $ra, BD slot
	// mac_yield(),
};
#endif

#pragma endregion Baked Atoms
