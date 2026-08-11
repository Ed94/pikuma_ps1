#ifdef INTELLISENSE_DIRECTIVES
#		include "gen/macs.h"
#		include "gen/offsets.h"
#	include "mips.h"
#	include "dsl.atom.h"
#	include "lottes_tape.h"
#	include "pad.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(pad_atom_c);

#pragma region MACs (Mips Atom Components)

FI_ Slice_MipsCode ac_pad_set_centered_axes(AtomBuilder_R ab, U4 r_state, U4 r_scratch) atom_dbg_skip MipsAtomComp_Proc_(ac_pad_set_centered_axes, ab, {
    load_upper_i(r_scratch, (PadAxis_Centered_Word >> 16) & 0xFFFF),
    or_i_self(   r_scratch,  PadAxis_Centered_Word        & 0xFFFF),
    store_word(  r_scratch, r_state, O_(PadState,axes)),
})

FI_ Slice_MipsCode ac_pad_set_id_byte(AtomBuilder_R ab, U1 r_state, U1 r_id, U1 id_value) atom_dbg_skip MipsAtomComp_Proc_(ac_pad_set_id_byte, ab, {
    add_ui(    r_id, R_0, id_value),
    store_byte(r_id, r_state, O_(PadState,id)),
})

FI_ Slice_MipsCode ac_pad_set_status(AtomBuilder_R ab, U4 r_tmp, U1 r_state, U4 pad_status) atom_dbg_skip MipsAtomComp_Proc_(ac_pad_set_status, ab, {
    add_ui(    r_tmp, R_0, pad_status),
    store_word(r_tmp, r_state, O_(PadState,status)),
})

/* Invert r_buttons (active-low → active-high) and store to PadState.buttons.
 * r_buttons must already be loaded (the caller is responsible for filling the load-delay slot of
 * the preceding load_half_u with an instruction that doesn't read r_buttons). */
FI_ Slice_MipsCode ac_pad_store_inverted_buttons(AtomBuilder_R ab, U1 r_buttons, U1 r_pad_state) atom_dbg_skip MipsAtomComp_Proc_(ac_pad_store_inverted_buttons, ab, {
    nor_u(       r_buttons, r_buttons, R_0),
    store_half(  r_buttons, r_pad_state, O_(PadState,   buttons)),
})

#pragma endregion MACs (Mips Atom Components)

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
	R_PadState  = R_T1 atom_reg atom_type(PadState*),
	R_RawStatus = R_T2 atom_reg,
	R_RawId     = R_T3 atom_reg,
};
typedef Struct_(Binds_PadBiosSnapshot) {
    PadBiosRaw* raw;
    PadState*   state;
};
internal MipsAtom_(pad_bios_snapshot) atom_info(atom_bind(Binds_PadBiosSnapshot)
, atom_reads( R_PadRaw, R_PadState, R_RawStatus, R_RawId)
, atom_writes(R_PadRaw, R_PadState, R_RawStatus, R_RawId)
) {
	/* === Bind consumption: T0 = raw, T1 = state, advance R_TapePtr by 8. */
	load_word(R_PadRaw,   R_TapePtr, O_(Binds_PadBiosSnapshot,raw)),
	load_word(R_PadState, R_TapePtr, O_(Binds_PadBiosSnapshot,state)),
	add_ui_self(          R_TapePtr, S_(Binds_PadBiosSnapshot)),

	/* === Read raw[0] (status) + raw[1] (id) */
	load_byte_u(R_RawStatus, R_PadRaw, O_(PadBiosRaw,status)),
	load_byte_u(R_RawId,     R_PadRaw, O_(PadBiosRaw,id)),

atom_label(snap_root) /* === Case 1: Disconnected (status == 0xFF). */
	add_ui(R_T4, R_0, PadRawStatus_Timeout), branch_ne(R_RawStatus, R_T4, atom_offset(snap_root, skip_disconnected)),
	/* BD-slot: pre-compute PadStatus_Disconnected. Branch reads R_T4=0xFF in EX before this WB completes.
	 * If branch NOT taken (fall through to pending/id_dispatch), R_T4 is overwritten by the next case body's add_ui — harmless. */

atom_label(disconnected) /* === Disconnected body. */
	mac_pad_set_status(R_T4,  R_PadState, PadStatus_Disconnected),
	store_half(        R_0,   R_PadState, O_(PadState,buttons)),
	mac_pad_set_centered_axes(R_PadState, R_T4),
	mac_pad_set_id_byte(R_PadState, R_RawId, PadRawStatus_Timeout),
	jump_rel(atom_offset(disconnected, snap_end)),
		/* BD-slot: load next atom's entry point (replaces the nop).
		 * Always jumps to snap_end, where mac_yield_tail() transfers control to R_AtomJmp without re-loading it. */
		mac_yield_load(),
atom_label(skip_disconnected)

	/* === Case 2: Pending (status == 0 && id == 0)
	 * Combined check: if (status | id) != 0 then skip to id_dispatch. Falls through to the Pending case only when both are zero. */
	or_u_self(R_RawStatus, R_RawId), branch_ne(R_RawStatus, R_0, atom_offset(case_2, id_dispatch)),
	/* BD-slot: pre-compute PadStatus_Pending. Branch reads R_RawStatus in EX before this WB completes.
	 * If branch NOT taken (fall through to id_dispatch), R_T4 is overwritten by the digital/analog body add_ui - harmless. */

atom_label(pending) /* === Pending body (status=0, id=0 — pre-IRQ-empty buffer). */
	mac_pad_set_status(R_T4,  R_PadState, PadStatus_Pending),
	store_half(        R_0,   R_PadState, O_(PadState,buttons)),
	mac_pad_set_centered_axes(R_PadState, R_T4),
	store_byte(R_RawId, R_PadState, O_(PadState,id)),
	jump_rel(atom_offset(pending, snap_end)),
		mac_yield_load(),

atom_label(id_dispatch) /* === Case 3-6: ID dispatch */
	add_ui(R_T4, R_0, PadRawId_Digital), branch_ne(R_RawId, R_T4, atom_offset(id_dispatch, try_analog_stick)),
	/* BD-slot: pre-compute PadStatus_Digital. Branch reads R_RawId in EX before this WB completes.
	 * If branch NOT taken (fall through to try_analog_stick), R_T4 is overwritten by the analog body add_ui. */

	/* === Digital body (status, buttons normalize, axes=0x80, id, branch.
	 * R_T5 holds the 0x80808080 axes constant (loaded into the load-delay slot of the buttons-load).
	 * R_T5 is then "dead" — only consumed at the analog_pad range check downstream. */
	mac_pad_set_status(R_T4, R_PadState, PadStatus_Digital),
	load_half_u(       R_T4, R_PadRaw, O_(PadBiosRaw, buttons)), /* R_T4 = raw_buttons; */
	load_upper_i(R_T5, PadAxis_Centered_Hi), or_i_self(R_T5, PadAxis_Centered_Lo), /* fills the buttons-load's delay slot (doesn't read R_T4) */
	mac_pad_store_inverted_buttons(R_T4, R_PadState),            /* R_T4 settled: nor + sh writes ~raw_buttons to state.buttons */
	store_word(R_T5,    R_PadState, O_(PadState, axes)),         /* single sw writes the 4-byte axes block at offset 8 (left_x, left_y, right_x, right_y) */
	mac_pad_set_id_byte(R_PadState, R_T4, PadRawId_Digital),

	jump_rel(atom_offset(id_dispatch, snap_end)),
		mac_yield_load(),

atom_label(try_analog_stick) /* === Case 4: AnalogStick (id == 0x53)*/
	add_ui(R_T4, R_0, PadRawId_AnalogStick), branch_ne(R_RawId, R_T4, atom_offset(try_analog_stick, try_analog_pad)),
	/* BD-slot: pre-compute PadStatus_AnalogStick. Branch reads R_RawId in EX before this WB completes.
	 * If branch NOT taken (fall through to try_analog_pad), R_T4 is overwritten by the analog_pad body add_ui. */

atom_label(analog_stick) /* === AnalogStick body
	* R_T5 holds left_xy (loaded into the load-delay slot of the buttons-load via the left-axis load_half_u).
	* R_T4 holds right_xy (loaded into the load-delay slot of the left-load).
	* R_T5 is then "dead" — reused for the id-byte value load in mac_pad_write_id_byte.
	* The buttons invert+store happens BEFORE R_T4 is overwritten by the right_xy load. */
	mac_pad_set_status(R_T4, R_PadState, PadStatus_AnalogStick),
	load_half_u(       R_T4, R_PadRaw, O_(PadBiosRaw,buttons)),  /* R_T4 = raw_buttons; delay slot at the next instruction */
	load_half_u(       R_T5, R_PadRaw, O_(PadBiosRaw,left)),     /* fills the buttons-load's delay slot (doesn't read R_T4) */
	mac_pad_store_inverted_buttons(R_T4, R_PadState),            /* R_T4 settled: nor + sh writes ~raw_buttons to state.buttons */
	load_half_u( R_T4,  R_PadRaw,   O_(PadBiosRaw,right)),       /* fills R_T5's load-delay slot (doesn't read R_T5); overwrites R_T4 (was buttons) with right_xy */
	store_half(  R_T5,  R_PadState, O_(PadState,  left)),
	store_half(  R_T4,  R_PadState, O_(PadState,  right)),
	mac_pad_set_id_byte(R_PadState, R_T5, PadRawId_AnalogStick),
	jump_rel(atom_offset(analog_stick, snap_end)),
		mac_yield_load(),

atom_label(try_analog_pad) /* === Case 5-6: AnalogPad (id & 0xF0 == 0x70) */
	and_i(    R_T4, R_RawId, PadRawId_AnalogPadMask),
	add_ui(   R_T5, R_0,     PadRawId_AnalogPadValue),
	branch_ne(R_T4, R_T5, atom_offset(try_analog_pad, try_unsupported)),
	/* BD-slot: pre-compute PadStatus_AnalogPad. Branch reads R_T4 in EX before this WB completes.
	 * If branch NOT taken (fall through to try_unsupported), R_T4 is overwritten by the unsupported body add_ui. */

atom_label(analog_pad) /* === AnalogPad body
	* Same shape as AnalogStick with AnalogPad status. R_T5 holds left_xy (it's dead on this path).
	* The id byte is raw id from the BIOS buffer (R_RawId already holds raw[1]).
	* Buttons invert + store happens before R_T4 is overwritten by the right_xy load. */
	mac_pad_set_status(R_T4, R_PadState, PadStatus_AnalogPad),
	load_half_u(       R_T4, R_PadRaw, O_(PadBiosRaw,buttons)), /* R_T4 = raw_buttons; delay slot at the next instruction */
	load_half_u(       R_T5, R_PadRaw, O_(PadBiosRaw,left)),    /* fills the buttons-load's delay slot (doesn't read R_T4) */
	mac_pad_store_inverted_buttons(R_T4, R_PadState),           /* R_T4 settled: nor + sh writes ~raw_buttons to state.buttons */
	load_half_u(R_T4,    R_PadRaw,   O_(PadBiosRaw,right)),     /* fills R_T5's load-delay slot (doesn't read R_T5); overwrites R_T4 with right_xy */
	store_half( R_T5,    R_PadState, O_(PadState,  left)),
	store_half( R_T4,    R_PadState, O_(PadState,  right)),
	store_byte( R_RawId, R_PadState, O_(PadState,  id)),

	jump_rel(atom_offset(analog_pad, snap_end)),
		mac_yield_load(),

atom_label(try_unsupported) /* === Case 7: Unsupported — fall through from the AnalogPad range-check miss. */
	add_ui(    R_T4, R_0, PadStatus_Unsupported),
	store_word(R_T4, R_PadState, O_(PadState,status)),
	store_half(R_0,  R_PadState, O_(PadState,buttons)),
	mac_pad_set_centered_axes(R_PadState, R_T4),
	mac_pad_set_id_byte(R_PadState, R_RawId, PadUnknownId_Sentinel),
	/* Fall through to snap_end. */

atom_label(no_jump_fallthrough)
	mac_yield_load(),

atom_label(snap_end)
	/* NOT mac_yield() — R_AtomJmp was already loaded in the BD-slot of the case-exit branch. */
	mac_yield_tail(),
};

#pragma endregion Baked Atoms
