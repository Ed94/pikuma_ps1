#ifdef INTELLISENSE_DIRECTIVES
#		include "gen/macs.h"
#		include "gen/offsets.h"
#	include "mips.h"
#	include "dsl.atom.h"
#	include "lottes_tape.h"
#	include "pad.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(pad_atom_c);

#pragma region Baked Atoms

/* ----- pad_bios_snapshot -----
 * Per-frame snapshot of one BIOS pad buffer into PadState.
 * Decoder (branch ladder on raw[0] status + raw[1] id):
 *   1. raw[0] == 0xFF         -> Disconnected (buttons=0, axes=0x80)
 *   2. raw[0]==0 && raw[1]==0 -> Pending      (buttons=0, axes=0x80)
 *   3. raw[1] == 0x41         -> Digital      (buttons normalized; axes=0x80)
 *   4. raw[1] == 0x53         -> AnalogStick  (buttons normalized; axes from raw[4..7])
 *   5. raw[1] in 0x7x         -> AnalogPad    (buttons normalized; axes from raw[4..7])
 *   6. else                   -> Unsupported  (buttons=0, axes=0x80)
 *
 * Buttons normalization: byte_swap16((~raw_buttons) & 0xFFFF).
 *   raw_buttons    = load_half_u(raw, 2) = raw[2] | (raw[3] << 8).
 *   byte_swap16(x) = (x >> 8) | (x << 8); nor(x, R_0) = ~x. store_half truncates to 16 bits so the upper-16 mask is implicit in the store.
 *
 * Register use (atom-local; no wave-context touched):
 *   R_T0 = raw base      (kept throughout; axes loads read raw[4..7] from R_T0)
 *   R_T1 = state base    (kept throughout; all stores go through R_T1)
 *   R_T2 = raw[0] status (alive across the disc/pending/id dispatch, then dead)
 *   R_T3 = raw[1] id     (alive across the id dispatch, then dead)
 *   R_T4 = scratch       (shifts, compares, immediate loads, store values)
 *   R_T5 = scratch       (parallel lui+ori for the 0x80808080 axes constant + byte-swap target)
 */
enum {
	R_PadRaw    = R_T0 atom_reg atom_type(U1),
	R_PadState  = R_T1 atom_reg,
	R_RawStatus = R_T2 atom_reg,
	R_RawId     = R_T3 atom_reg,
};
typedef Struct_(Binds_PadBiosSnapshot) {
    PadBiosRaw* raw;
    PadState*   state;
};
internal MipsAtom_(pad_bios_snapshot) atom_info(atom_bind(Binds_PadBiosSnapshot)
, atom_reads( R_PadRaw, R_PadState, R_RawStatus, R_RawId, R_T4, R_T5, R_TapePtr)
, atom_writes(R_PadRaw, R_PadState, R_RawStatus, R_RawId, R_T4, R_T5, R_TapePtr)
) {
	/* === Bind consumption: T0 = raw, T1 = state, advance R_TapePtr by 8. */
	load_word(R_PadRaw,   R_TapePtr, O_(Binds_PadBiosSnapshot,raw)),
	load_word(R_PadState, R_TapePtr, O_(Binds_PadBiosSnapshot,state)),
	add_ui_self(          R_TapePtr, S_(Binds_PadBiosSnapshot)),

	/* === Read raw[0] (status) + raw[1] (id) */
	load_byte_u(R_RawStatus, R_PadRaw, 0),
	load_byte_u(R_RawId,     R_PadRaw, 1),

atom_label(snap_root) /* === Case 1: Disconnected (status == 0xFF). */
	add_ui(R_T4, R_0, 0xFF), branch_ne(R_RawStatus, R_T4, atom_offset(snap_root, skip_disconnected)),
	/* BD-slot: pre-compute PadStatus_Disconnected. Branch reads R_T4=0xFF in EX before this WB completes.
	 * If branch NOT taken (fall through to pending/id_dispatch), R_T4 is overwritten by the next case body's add_ui — harmless. */

atom_label(disconnected) /* === Disconnected body. */
	/* R_T4 = PadStatus_Disconnected from snap_root BD-slot. */
	store_word(R_T4, R_PadState, O_(PadState,status)),
	store_half(R_0,  R_PadState, O_(PadState,buttons)),
	/* axes = 0x80808080 (centered) — single sw writes the 4-byte axes block at offset 8 (left_x, left_y, right_x, right_y). */
	load_upper_i(R_T4, 0x8080), or_i_self(R_T4, 0x8080),
	store_word(  R_T4,    R_PadState, O_(PadState,left_x)),
	store_byte(  R_RawId, R_PadState, O_(PadState,id)),
	jump_rel(atom_offset(disconnected, snap_end)),
		/* BD-slot: load next atom's entry point (replaces the nop).
		 * The unconditional branch always jumps to snap_end, where mac_yield_tail()
		 * transfers control to R_AtomJmp without re-loading it. */
		mac_yield_load(),
atom_label(skip_disconnected)

	/* === Case 2: Pending (status == 0 && id == 0)
	 * Combined check: if (status | id) != 0 then skip to id_dispatch.
	 * Falls through to the Pending case only when both are zero. */
	or_u_self(R_RawStatus, R_RawId), branch_ne(R_RawStatus, R_0, atom_offset(case_2, id_dispatch)),
	/* BD-slot: pre-compute PadStatus_Pending. Branch reads R_RawStatus in EX before this WB completes.
	 * If branch NOT taken (fall through to id_dispatch), R_T4 is overwritten by the digital/analog body add_ui — harmless. */

atom_label(pending) /* === Pending body */
	/* R_T4 = PadStatus_Pending from case_2 BD-slot. */
	store_word(R_T4, R_PadState, O_(PadState,status)),
	store_half(R_0,  R_PadState, O_(PadState,buttons)),
	/* axes = 0x80808080 (centered) — single sw writes the 4-byte axes block at offset 8 (left_x, left_y, right_x, right_y). */
	load_upper_i(R_T4, 0x8080), or_i_self(R_T4, 0x8080),
	store_word(  R_T4,    R_PadState, O_(PadState,left_x)),
	store_byte(  R_RawId, R_PadState, O_(PadState,id)),
	jump_rel(atom_offset(pending, snap_end)),
		mac_yield_load(),

atom_label(id_dispatch) /* === Case 3-6: ID dispatch */
	add_ui(R_T4, R_0, 0x41), branch_ne(R_RawId, R_T4, atom_offset(id_dispatch, try_analog_stick)),
	/* BD-slot: pre-compute PadStatus_Digital. Branch reads R_RawId in EX before this WB completes.
	 * If branch NOT taken (fall through to try_analog_stick), R_T4 is overwritten by the analog body add_ui. */

	/* === Digital body (status, buttons normalize, axes=0x80, id, branch. */
	/* R_T4 = PadStatus_Digital from id_dispatch BD-slot. */
	store_word( R_T4, R_PadState, O_(PadState,status)),
	load_half_u(R_T4, R_PadRaw,   2 * S_(U1)),
	/* Fill R_T4's load-delay slot with the 0x80808080 axes constant into R_T5
	 * (R_T5 is dead on this path; it's only consumed at the analog_pad range check). */
	load_upper_i(R_T5, 0x8080), or_i_self(R_T5, 0x8080),
	nor_u(      R_T4, R_T4, R_0), /* raw_buttons is already in host bit order; no swap needed */
	store_half( R_T4, R_PadState, O_(PadState,buttons)),

	/* axes = 0x80808080 (centered) — single sw writes the 4-byte axes block at offset 8 (left_x, left_y, right_x, right_y). */
	store_word(  R_T5, R_PadState, O_(PadState,left_x)),
	add_ui(      R_T4, R_0, 0x41),
	store_byte(  R_T4, R_PadState, O_(PadState,id)),

	jump_rel(atom_offset(id_dispatch, snap_end)),
		mac_yield_load(),

atom_label(try_analog_stick) /* === Case 4: AnalogStick (id == 0x53)*/
	add_ui(R_T4, R_0, 0x53), branch_ne(R_RawId, R_T4, atom_offset(try_analog_stick, try_analog_pad)),
	/* BD-slot: pre-compute PadStatus_AnalogStick. Branch reads R_RawId in EX before this WB completes.
	 * If branch NOT taken (fall through to try_analog_pad), R_T4 is overwritten by the analog_pad body add_ui. */

atom_label(analog_stick) /* === AnalogStick body
	* Axes are loaded as two halfwords: raw[6..7] → left_xy (sh at offset 8), raw[4..5] → right_xy (sh at offset 10).
	* R_T5 holds left_xy / id-value in turn (it's dead on this path — only consumed at the analog_pad range check). */
	/* R_T4 = PadStatus_AnalogStick from try_analog_stick BD-slot. */
	store_word(  R_T4, R_PadState, O_(PadState,status)),
	load_half_u( R_T4, R_PadRaw,   2 * S_(U1)),           /* R_T4 = raw_buttons */
	load_half_u( R_T5, R_PadRaw,   6 * S_(U1)),           /* R_T5 = left_xy; fills R_T4's load-delay slot (doesn't read R_T4) */
	nor_u(       R_T4, R_T4, R_0),                        /* R_T4 = ~raw_buttons */
	store_half(  R_T4, R_PadState, O_(PadState,buttons)),
	load_half_u( R_T4, R_PadRaw,   4 * S_(U1)),           /* R_T4 = right_xy; fills R_T5's load-delay slot */
	store_half(  R_T5, R_PadState, O_(PadState,left_x)),  /* R_T5 settled, store left_xy */
	store_half(  R_T4, R_PadState, O_(PadState,right_x)),
	add_ui(      R_T5, R_0, 0x53),                        /* R_T5 = id value (clobbers left_xy, already stored) */
	store_byte(  R_T5, R_PadState, O_(PadState,id)),
	jump_rel(atom_offset(analog_stick, snap_end)),
		mac_yield_load(),

atom_label(try_analog_pad) /* === Case 5-6: AnalogPad (id & 0xF0 == 0x70) */
	and_i(    R_T4, R_RawId, 0xF0),
	add_ui(   R_T5, R_0,     0x70),
	branch_ne(R_T4, R_T5, atom_offset(try_analog_pad, try_unsupported)),
	/* BD-slot: pre-compute PadStatus_AnalogPad. Branch reads R_T4 in EX before this WB completes.
	 * If branch NOT taken (fall through to try_unsupported), R_T4 is overwritten by the unsupported body add_ui. */

atom_label(analog_pad) /* === AnalogPad body
	* Same shape as AnalogStick with AnalogPad status. R_T5 holds left_xy (it's dead on this path). */
	/* R_T4 = PadStatus_AnalogPad from try_analog_pad BD-slot. */
	store_word( R_T4, R_PadState, O_(PadState,status)),
	load_half_u(R_T4, R_PadRaw,   2 * S_(U1)),           /* R_T4 = raw_buttons */
	load_half_u(R_T5, R_PadRaw,   6 * S_(U1)),           /* R_T5 = left_xy; fills R_T4's load-delay slot */
	nor_u(      R_T4, R_T4, R_0),                        /* R_T4 = ~raw_buttons */
	store_half( R_T4, R_PadState, O_(PadState,buttons)),
	load_half_u(R_T4, R_PadRaw,   4 * S_(U1)),           /* R_T4 = right_xy; fills R_T5's load-delay slot */
	store_half( R_T5, R_PadState, O_(PadState,left_x)),  /* R_T5 settled, store left_xy */
	store_half( R_T4, R_PadState, O_(PadState,right_x)),
	store_byte( R_RawId, R_PadState, O_(PadState,id)),

	jump_rel(atom_offset(analog_pad, snap_end)),
		mac_yield_load(),

atom_label(try_unsupported) /* === Case 7: Unsupported — fall through from the AnalogPad range-check miss. */
	add_ui(    R_T4, R_0, PadStatus_Unsupported),
	store_word(R_T4, R_PadState, O_(PadState,status)),
	store_half(R_0,  R_PadState, O_(PadState,buttons)),
	/* axes = 0x80808080 (centered) — single sw writes the 4-byte axes block at offset 8 (left_x, left_y, right_x, right_y). */
	load_upper_i(R_T4, 0x8080), or_i_self(R_T4, 0x8080),
	store_word(  R_T4, R_PadState, O_(PadState,left_x)),
	add_ui(      R_T4, R_0, 0xFF),                      /* 0xFF sentinel: "unknown id" */
	store_byte(  R_T4, R_PadState, O_(PadState,id)),
	/* Fall through to snap_end. */

atom_label(no_jump_fallthrough)
	mac_yield_load(),

atom_label(snap_end)
	/* NOT mac_yield() — R_AtomJmp was already loaded in the BD-slot of the case-exit branch. */
	mac_yield_tail(),
};

#pragma endregion Baked Atoms
