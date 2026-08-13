#ifdef INTELLISENSE_DIRECTIVES
#	include "dsl.h"
#	include "gcc_asm.h"
#	include "mips.h"
#	include "bios.h"
#	include "pad.h"
#endif

/* Uses ONE 8-byte frame allocated via the compiler's standard prologue.
 * 4 wasted-arg words for B(12h) InitPAD2 are at [SP+0..15] but are not explicitly allocated.
 * Compiler handles the MIPS O32 "wasted stack" convention for us by treating the B-call as a 4-arg call.
 *
 * The buffer pointers are passed as arguments so the compiler keeps them in callee-saved registers;
 * The B(12h) asm volatile block does NOT clobber those registers (it clobbers only the volatile GPRs + B-table arg registers explicitly).
 * The C-level writes after the call re-load the pointers from their callee-saved homes.
 *
 * The clobber list for both B-calls names the full BIOS destroy set documented in kernelbios.md:167-174 (R1..R15, R24..R25, R31, HI/LO).
 * The kernel-ABI "volatile GPRs" subset is clb_mem_drain; the rest of the destroy set is enumerated explicitly here. */
NI_ void pad_bios_init_start(PadBiosRaw* raw0, PadBiosRaw* raw1)
{
	/* Pin raw0 + raw1 to $a0 + $a1 via rgcc; the B(12h) call uses these directly.
	 * The `(void)` casts mark them as unread after the call so the compiler doesn't need to move them back. */
	register PadBiosRaw* p0 rgcc(R_A0) = raw0;
	register PadBiosRaw* p1 rgcc(R_A1) = raw1;
	(void)p0; (void)p1;

	// TODO(Ed): Properly annotate the raw values in the inline asm instructions.
	// Use enums.

	/* B(12h) InitPAD2(raw0, 0x22, raw1, 0x22)
	 *   $a0 = raw0 (rgcc-bound; survives the sequence below)
	 *   $a1 = raw1 (preserved into $a2 before $a1 is overwritten)
	 *   $a2 = raw1 (moved from $a1; survives $a1's overwrite)
	 *   $a3 = 0x22 (immediate)
	 *   $t1 = 0x12 (function number)
	 *   $t2 = 0xB0 (BIOS B-table address) */
	asm volatile(
		asm_words(
			or_u(    R_A2, R_A0, R_0),                 /* $a2 = $a1 = raw1 */
			add_ui(  R_A1, R_0, bios_pad_buffer_size), /* $a1 = 0x22 */
			add_ui(  R_A3, R_0, bios_pad_buffer_size), /* $a3 = 0x22 */
			add_ui(  R_T1, R_0, bios_init_pad_2),      /* $t1 = 0x12 */
			add_ui(  R_T2, R_0, bios_btable_addr),     /* $t2 = 0xB0 */
			call_reg(R_T2),                            /* jalr $t2, $ra */
			nop                                        /* BD slot */
		)
		asm_rpins, r_use(p0), r_use(p1)
		asm_clobber: 
			rlit(R_AT), 
			rlit(R_V0), rlit(R_V1), 
			rlit(R_T0), rlit(R_T1), rlit(R_T2), rlit(R_T3), rlit(R_T4),
			rlit(R_T5), rlit(R_T6), rlit(R_T7), rlit(R_T8), rlit(R_T9),
			rlit(R_RA),
			clb_mem_drain
	);

	/* The C-level writes re-load the pointers via the parameter names and write 0xFF to each 
	 * buffer's status byte to mark the initial-state hazard documented in kernelbios.md:1621-1624. */
	u1_v(raw0)[0] = 0xFF;
	u1_v(raw1)[0] = 0xFF;

	/* B(13h) StartPAD2() — no args. The BIOS preserves $sp. */
	asm volatile(
		asm_words(
			add_ui(  R_T1, R_0, bios_start_pad_2), /* $t1 = 0x13 */
			add_ui(  R_T2, R_0, bios_btable_addr), /* $t2 = 0xB0 (re-load) */
			call_reg(R_T2),                             /* jalr $t2, $ra */
			nop                                           /* BD slot */
		)
		asm_clobber:
			rlit(R_AT),
			rlit(R_V0), rlit(R_V1),
			rlit(R_T0), rlit(R_T1), rlit(R_T2), rlit(R_T3), rlit(R_T4),
			rlit(R_T5), rlit(R_T6), rlit(R_T7), rlit(R_T8), rlit(R_T9),
			rlit(R_RA),
			clb_mem_drain
	);
}
