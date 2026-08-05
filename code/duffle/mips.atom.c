#ifdef INTELLISENSE_DIRECTIVES
#	include "gen/macs.h"
#	include "gen/offsets.h"
#	include "lottes_tape.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(mips_atom_c);

#pragma region Baked Atoms

enum {
	bios_flushcache = 0x44,
	bios_table_addr = 0xA0,
};

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
	add_ui(rstack_ptr, rstack_ptr, -MipsStackAlignment), // sp -= 8
	store_word(rret_addr, rstack_ptr, S_(U4)),           // sw  $ra,   4($sp) 
	add_ui(rret_0, rdiscard, bios_flushcache),           // addiu $a0, $0, 0x44 
	add_ui(rtmp_0, rdiscard, bios_table_addr),           // addiu $t0, $0, 0xA0 
	jump_link(rtmp_0, rret_addr), nop,                   // jalr  $t0, $ra, BD slot
	load_word(rret_addr, rstack_ptr, S_(U4)),            // lw   $ra, 4($sp) 
	jump_reg(rret_addr),                                 // jr   $ra 
	add_ui(rstack_ptr, rstack_ptr, MipsStackAlignment),  // sp += 8 (BD) 
	mac_yield(),
};

#pragma endregion Baked Atoms
