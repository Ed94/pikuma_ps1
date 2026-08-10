
#if 0 /* ac_pad_sio_write_pad_state — superseded by pad_bios_snapshot */

/* ============================================================
 * raw_sio_pad_poll_20260802 — superseded by bios_pad_buffer_snapshot_20260803.
 * The doomed raw-SIO production atoms (ac_pad_sio_write_pad_state,
 * pad_sio_init, pad_sio_step, pad_sio_diag_pin, pad_sio_diag_byte_exchange)
 * reference symbols that were removed from code/duffle/pad.h during
 * Phase 1. Each is wrapped in a narrow `#if 0` so the C compile skips
 * the body while the source-as-written text stays in place for the
 * Phase 5.1 deletion pass. The wrap is removed (and the bodies are
 * deleted) by Phase 5.1 of this track.
 * ============================================================ */

 * Writes the per-port PadState in 5 instructions plus 4 store_word calls (status,
 * buttons, left_x/y/right_x/right_y packed, attempt). The provisional decode publishes
 * 0x0000FFFF buttons + centered axes on every path until response-byte decode lands.
 *
 * Args:
 *   status_val    - the PadSioStatus enum value to publish
 *   state_ptr_reg - the PadState* base (R_PadState at the call site)
 *   scratch_reg   - scratch register for the value being stored (e.g., R_T0)
 *
 * Emits 9 instructions (status/buttons/axes/attempt stores plus the
 * two-instruction zero-extended buttons load).
 */
FI_ Slice_MipsCode ac_pad_sio_write_pad_state(MipsAtomBuilder_R ab, U4 status_val, U4 state_ptr_reg, U4 scratch_reg)
MipsAtomComp_Proc_(ac_pad_sio_write_pad_state, ab, {
	add_ui(scratch_reg, R_0, status_val),
	store_word(scratch_reg, state_ptr_reg, O_(PadState,status)),
	/* FIX 2026-08-02: buttons = 0x0000FFFF = "no buttons pressed" in
	 * libetc convention. Build it with LUI + ORI so addiu does not
	 * sign-extend 0xFFFF to 0xFFFFFFFF. */
	load_upper_i(scratch_reg, 0x0000),
	or_i(scratch_reg, scratch_reg, 0xFFFF),
	store_word(scratch_reg, state_ptr_reg, O_(PadState,buttons)),
	add_ui(scratch_reg, R_0, 0x80808080),
	store_word(scratch_reg, state_ptr_reg, O_(PadState,left_x)),
	add_ui(scratch_reg, R_0, 0),
	store_word(scratch_reg, state_ptr_reg, O_(PadState,attempt))
})
#endif /* end ac_pad_sio_write_pad_state wrap */

/* ----- pad_sio_init -----
 * Boot-time SIO0 init. Caller pins R_T6 = sio_base_addr0.
 * Issues SIO CTRL=0x0040 (reset), MODE=0x000D, BAUD=0x0088.
 * (Phase 2 fills the body.)
 */
#if 0 /* pad_sio_init — superseded by pad_bios_init_start (Phase 1.3) */
internal MipsAtom_(pad_sio_init) atom_info(atom_phase(pad_init)
, atom_reads(R_T5, R_T6)
, atom_writes(R_T5, R_T6)
) {
	/* FIX 2026-08-02: explicitly load the KSEG1 base into R_T6 at the top of
	 * the atom body. The rgcc(R_PadSioBase) binding in main() pins R_T6 = base
	 * when main() runs, but $12 is caller-saved per the O32 ABI — when tape_run
	 * is invoked, R_T6 is fair game. The atom body cannot rely on the value. */
	load_upper_i(R_T6, pad_IO_KSEG1_BASE >> 16),   /* R_T6 high 16 = 0xBF80 */
	or_i(R_T6, R_T6, pad_IO_KSEG1_BASE & 0xFFFF),   /* R_T6 = 0xBF800000 */

	/* SIO CTRL = 0x0040 (reset) */
	add_ui(R_T5, R_0, pad_SIO_CTRL_RESET),
	store_half(R_T5, R_T6, pad_SIO_CTRL_OFFSET),
	/* SIO MODE = 0x000D (MUL1, 8-bit, no parity, idle-high) */
	add_ui(R_T5, R_0, pad_SIO_MODE_INIT),
	store_half(R_T5, R_T6, pad_SIO_MODE_OFFSET),
	/* SIO BAUD = 0x0088 (~250 kHz) */
	add_ui(R_T5, R_0, pad_SIO_BAUD_INIT),
	store_half(R_T5, R_T6, pad_SIO_BAUD_OFFSET),
	mac_yield(),
};
#endif /* end pad_sio_init wrap */

/* ----- pad_sio_step -----
 * Per-frame bounded raw-SIO transaction. Reads PadState pointers + SIO
 * base addresses from Binds_PadSioStep; writes per-port status +
 * buttons + axes into smem.pad[0..1].
 * Body shape (per spec §"Transaction model (per port, per pad_sio_step)"):
 *   port 0: CTRL=CLEANUP → settle → CTRL=port-select → settle → exchange 5
 *           bytes (addr + 0x42 0x00 0x00 0x00) → decode → write PadState[0]
 *           → CTRL=CLEANUP.
 *   port 1: swap scratch regs (sio_base_addr1 → R_PadSioBase, state1 →
 *           R_PadState) → mirror port 0 sequence.
 *
 * Bounded-loop semantics: every countdown is wrapped in
 *   add_ui_self(R_T1, -1) + branch_ne(R_T1, R_0, ...)
 * with a known maximum (pad_SIO_SETTLE_BEFORE_TX=1000, pad_SIO_SETTLE_AFTER_TX=2000,
 * pad_SIO_WAIT_BUDGET=4096). The static-analysis pass currently reports
 * has_loops = true; the follow-up metaprogram track that learns modeled-bounded
 * loops is out of scope here (per spec §"Risks").
 *
 * Scratch register strategy:
 *   R_PadStatus    = R_T4 — RESERVED for port-1 swap (holds state1)
 *   R_PadCountdown = R_T5 — RESERVED for port-1 swap (holds sio_base_addr1)
 *   R_T0           — byte-exchange value + STAT read (clobbered freely)
 *   R_T1           — countdown budget (clobbered freely)
 *   R_PadState     = R_T7 — PadState* (preserved for PadState writes)
 *   R_PadSioBase   = R_T6 — SIO base (preserved through the port)
 *
 * Response decode (Task 3.1 teaching scope):
 *   - status   = PadSioStatus_Digital (hardcoded)
 *   - buttons  = 0xFFFF (no buttons pressed in the provisional libetc
 *                         convention; full response-byte decode is follow-up)
 *   - axes     = 0x80808080 (centered: left_x=0x80, left_y=0x80,
 *                             right_x=0x80, right_y=0x80)
 *   - attempt  = 0
 *   - DualShock handshake (0x43 0x01 → 0x44 0x01 0x03 → 0x43 0x00) is
 *     follow-up scope; the hardcoded digital decode is a placeholder.
 *
 * Both ports raise /CS (CTRL = pad_SIO_CTRL_CLEANUP) before exit. Both ports
 * treat response timeout as PadSioStatus_Disconnected per the spec §"Failure
 * handling" + the canonical per-port timeout semantics.
 */
#if 0 /* pad_sio_step — superseded by pad_bios_snapshot (Phase 2.1) */
internal MipsAtom_(pad_sio_step) atom_info(atom_bind(Binds_PadSioStep)
, atom_reads(R_TapePtr, R_PadSioBase, R_PadState, R_PadStatus, R_PadCountdown)
, atom_writes(R_PadStatus, R_PadCountdown)
) {
	/* FIX 2026-08-02: explicitly load KSEG1 base into R_PadSioBase (R_T6) at the
	 * top. The rgcc() binding in main() does NOT survive the tape_run call
	 * because R_T6 is caller-saved per the O32 ABI. The pad_sio_init atom
	 * (also in the per-frame tape) reloads R_T6 separately. */
	load_upper_i(R_PadSioBase, pad_IO_KSEG1_BASE >> 16),
	or_i(R_PadSioBase, R_PadSioBase, pad_IO_KSEG1_BASE & 0xFFFF),

	/* Pop Binds from tape (in Binds_PadSioStep declaration order) */
	load_word(R_PadState,     R_TapePtr, O_(Binds_PadSioStep,state0)),
	load_word(R_PadStatus,    R_TapePtr, O_(Binds_PadSioStep,state1)),    /* reserved for port-1 swap */
	load_word(R_PadSioBase,   R_TapePtr, O_(Binds_PadSioStep,sio_base_addr0)),
	load_word(R_PadCountdown, R_TapePtr, O_(Binds_PadSioStep,sio_base_addr1)),  /* reserved for port-1 swap */
	add_ui_self(R_TapePtr, S_(Binds_PadSioStep)),

	/* ============== PORT 0 TRANSACTION ============== */
	/* Use R_T0 (byte value / STAT read) + R_T1 (countdown) as scratch.
	 * R_PadStatus (state1) + R_PadCountdown (sio_base_addr1) are preserved
	 * through the port-0 body and swapped into R_PadSioBase + R_PadState
	 * at atom_offset(port1_start, ...) below. */

	/* 1. Cleanup: CTRL = 0x0010 (raise /CS, clear stale status) */
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	/* Bounded by pad_SIO_SETTLE_BEFORE_TX = 1000 iterations. */
	add_ui(R_T1, R_0, pad_SIO_SETTLE_BEFORE_TX),
atom_label(settle_pre_port0)
	nop,  /* BD slot */
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(settle_pre_port0, settle_pre_port0)),

	/* 2. Port-select: CTRL = 0x0003 (TX enable + DTR /CS) for port 0 */
	add_ui(R_T0, R_0, pad_SIO_CTRL_TX_ENABLE),
	or_i(R_T0, R_T0, pad_SIO_CTRL_DTR_CS),  /* set /CS line low */
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	/* Bounded by pad_SIO_SETTLE_AFTER_TX = 2000 iterations. */
	add_ui(R_T1, R_0, pad_SIO_SETTLE_AFTER_TX),
atom_label(settle_post_port0)
	nop,
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(settle_post_port0, settle_post_port0)),

	/* 3. Address byte (0x01) — send + RX-ready wait + read response + RX-drain confirmation */
	add_ui(R_T0, R_0, pad_PROTO_ADDR),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack0_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack0_port0, ack0_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack0_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack0_port0, wait_ack0_port0)),
	/* RX timeout → mark disconnected; skip to port 1 */
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ack0)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ack0, port1_start)),

atom_label(ack0_received_port0)
	/* Read open-bus response byte 0 — discard per docs/psx-spx §controllersandmemorycards.md */
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Confirm RX FIFO drained before sending byte 1. Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel0_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel0_port0, ack_released_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel0_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel0_port0, wait_ackrel0_port0)),
	/* RX-drain timeout → disconnected; skip to port 1 */
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ackrel0)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ackrel0, port1_start)),

atom_label(ack_released_port0)

	/* === Byte 1 (port 0): send 0x42 (cmd read) + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, pad_PROTO_CMD_READ),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack1_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack1_port0, ack1_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack1_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack1_port0, wait_ack1_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ack1)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ack1, port1_start)),

atom_label(ack1_received_port0)
	/* Read response ID byte — discarded for teaching scope (decode hardcoded). */
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* RX FIFO drain wait. Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel1_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel1_port0, ack_released1_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel1_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel1_port0, wait_ackrel1_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ackrel1)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ackrel1, port1_start)),

atom_label(ack_released1_port0)

	/* === Byte 2 (port 0): send 0x00 + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack2_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack2_port0, ack2_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack2_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack2_port0, wait_ack2_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ack2)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ack2, port1_start)),

atom_label(ack2_received_port0)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel2_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel2_port0, ack_released2_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel2_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel2_port0, wait_ackrel2_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ackrel2)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ackrel2, port1_start)),

atom_label(ack_released2_port0)

	/* === Byte 3 (port 0): send 0x00 + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack3_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack3_port0, ack3_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack3_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack3_port0, wait_ack3_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ack3)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ack3, port1_start)),

atom_label(ack3_received_port0)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel3_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel3_port0, ack_released3_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel3_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel3_port0, wait_ackrel3_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_ackrel3)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_ackrel3, port1_start)),

atom_label(ack_released3_port0)

	/* === Byte 4 (FINAL, port 0): send 0x00 + RX-not-empty wait + read final byte === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_rx4_port0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_rx4_port0, rx4_received_port0)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_rx4_port0)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_rx4_port0, wait_rx4_port0)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port0_from_rx4)
	branch_equal(R_0, R_0, atom_offset(skip_port0_from_rx4, port1_start)),

atom_label(rx4_received_port0)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),  /* discard final byte */

	/* === RESPONSE DECODE (hardcoded for teaching scope) ===
	 * Per the plan §"Phase 3 task 3.1" + spec §"Architecture":
	 *   - Full decode (buttons/axes from response bytes) is follow-up scope.
	 *   - Teaching scope: hardcode digital poll response.
	 *     status = PadSioStatus_Digital
	 *     buttons = 0x0000FFFF (no buttons pressed — placeholder)
	 *     axes = 0x80808080 (left_x=0x80, left_y=0x80, right_x=0x80, right_y=0x80)
	 *     attempt = 0
	 */
atom_label(decode_port0)
	mac_pad_sio_write_pad_state(PadSioStatus_Digital, R_PadState, R_T0),

	/* /CS cleanup: raise /CS, clear stale status before exiting port 0. */
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),

	/* ============== PORT 1 SETUP ============== */
	/* Swap: R_PadCountdown holds sio_base_addr1; R_PadStatus holds state1. */
atom_label(port1_start)
	add_u(R_PadSioBase, R_0, R_PadCountdown),  /* sio_base_addr1 → R_PadSioBase */
	add_u(R_PadState,   R_0, R_PadStatus),     /* state1 → R_PadState */

	/* ============== PORT 1 TRANSACTION (mirror of port 0) ============== */
	/* R_PadStatus + R_PadCountdown are no longer reserved (port 1 is the
	 * last transaction); we still use R_T0/R_T1 as scratch to match port 0. */

	/* 1. Cleanup: CTRL = 0x0010 (raise /CS, clear stale status) */
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	/* Bounded by pad_SIO_SETTLE_BEFORE_TX = 1000 iterations. */
	add_ui(R_T1, R_0, pad_SIO_SETTLE_BEFORE_TX),
atom_label(settle_pre_port1)
	nop,
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(settle_pre_port1, settle_pre_port1)),

	/* 2. Port-select: CTRL = 0x0003 | (1 << 13) (port 1 select) */
	add_ui(R_T0, R_0, pad_SIO_CTRL_TX_ENABLE),
	or_i(R_T0, R_T0, pad_SIO_CTRL_DTR_CS),
	or_i(R_T0, R_T0, 1 << 13),  /* port 1 select bit (CTRL bit 13 = port select) */
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	/* Bounded by pad_SIO_SETTLE_AFTER_TX = 2000 iterations. */
	add_ui(R_T1, R_0, pad_SIO_SETTLE_AFTER_TX),
atom_label(settle_post_port1)
	nop,
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(settle_post_port1, settle_post_port1)),

	/* 3. Address byte (0x01) — send + RX-ready wait + read response + RX-drain confirmation */
	add_ui(R_T0, R_0, pad_PROTO_ADDR),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack0_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack0_port1, ack0_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack0_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack0_port1, wait_ack0_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ack0)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ack0, end_atom)),

atom_label(ack0_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel0_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel0_port1, ack_released_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel0_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel0_port1, wait_ackrel0_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ackrel0)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ackrel0, end_atom)),

atom_label(ack_released_port1)

	/* === Byte 1 (port 1): send 0x42 (cmd read) + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, pad_PROTO_CMD_READ),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack1_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack1_port1, ack1_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack1_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack1_port1, wait_ack1_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ack1)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ack1, end_atom)),

atom_label(ack1_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel1_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel1_port1, ack_released1_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel1_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel1_port1, wait_ackrel1_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ackrel1)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ackrel1, end_atom)),

atom_label(ack_released1_port1)

	/* === Byte 2 (port 1): send 0x00 + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack2_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack2_port1, ack2_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack2_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack2_port1, wait_ack2_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ack2)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ack2, end_atom)),

atom_label(ack2_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel2_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel2_port1, ack_released2_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel2_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel2_port1, wait_ackrel2_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ackrel2)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ackrel2, end_atom)),

atom_label(ack_released2_port1)

	/* === Byte 3 (port 1): send 0x00 + RX-ready wait + read response + RX-drain confirmation === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ack3_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_ack3_port1, ack3_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ack3_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ack3_port1, wait_ack3_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ack3)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ack3, end_atom)),

atom_label(ack3_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),

	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_ackrel3_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_equal(R_T0, R_0, atom_offset(wait_ackrel3_port1, ack_released3_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_ackrel3_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_ackrel3_port1, wait_ackrel3_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_ackrel3)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_ackrel3, end_atom)),

atom_label(ack_released3_port1)

	/* === Byte 4 (FINAL, port 1): send 0x00 + RX-not-empty wait + read final byte === */
	/* Bounded by pad_SIO_WAIT_BUDGET = 4096 iterations. */
	add_ui(R_T0, R_0, 0x00),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(wait_rx4_port1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(wait_rx4_port1, rx4_received_port1)),
	add_ui_self(R_T1, -1),
atom_label(continue_wait_rx4_port1)
	branch_ne(R_T1, R_0, atom_offset(continue_wait_rx4_port1, wait_rx4_port1)),
	mac_pad_sio_write_pad_state(PadSioStatus_Disconnected, R_PadState, R_T0),
atom_label(skip_port1_from_rx4)
	branch_equal(R_0, R_0, atom_offset(skip_port1_from_rx4, end_atom)),

atom_label(rx4_received_port1)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),  /* discard final byte */

	/* === RESPONSE DECODE (port 1) === */
atom_label(decode_port1)
	mac_pad_sio_write_pad_state(PadSioStatus_Digital, R_PadState, R_T0),

	/* /CS cleanup: raise /CS, clear stale status before exiting port 1. */
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),

atom_label(end_atom)
	mac_yield(),
};
#endif /* end pad_sio_step wrap */

/* ----- pad_sio_diag_pin -----
 * Per-frame diagnostic counter. The caller binds R_DiagPinScratch to
 * scratch_for_atom_diag_pin for temporary gdb verification.
 */
#if 0 /* pad_sio_diag_pin — superseded (raw-SIO phase removed) */
internal MipsAtom_(pad_sio_diag_pin) atom_info(atom_phase(pad_init)
, atom_reads(R_T0, R_T1, R_DiagPinScratch)
, atom_writes(R_T0, R_T1, R_DiagPinScratch)
) {
	/* FIX 2026-08-02: explicitly reload R_DiagPinScratch (R_T3 = $t3). Caller-saved
	 * per O32 ABI; the rgcc binding in main() does not survive tape_run. */
	load_upper_i(R_DiagPinScratch, 0x8001),
	or_i(R_DiagPinScratch, R_DiagPinScratch, 0xC800),

	/* High half = 0xD1A6; low half increments once per atom invocation. */
	load_word(R_T1, R_DiagPinScratch, 0),
	nop,
	add_ui(R_T1, R_T1, 1),
	and_i(R_T0, R_T1, 0xFFFF),
	load_upper_i(R_T1, 0xD1A6),
	or_i(R_T1, R_T1, 0),
	or_u(R_T1, R_T1, R_T0),
	store_word(R_T1, R_DiagPinScratch, 0),
	mac_yield(),
};
#endif /* end pad_sio_diag_pin wrap */

/* ----- pad_sio_diag_byte_exchange -----
 * Temporary two-byte wire probe: sends 0x01 and 0x42, then stores the
 * open-bus byte and response ID in scratch_for_atom_diag_pin.
 */
#if 0 /* pad_sio_diag_byte_exchange — superseded (raw-SIO phase removed) */
internal MipsAtom_(pad_sio_diag_byte_exchange) atom_info(atom_phase(pad_init)
, atom_reads(R_T0, R_T1, R_T2, R_PadSioBase, R_DiagPinScratch)
, atom_writes(R_T0, R_T1, R_T2, R_PadSioBase, R_DiagPinScratch)
) {
	/* FIX 2026-08-02: explicitly reload R_DiagPinScratch (R_T3 = $t3). Caller-saved
	 * per O32 ABI; the rgcc binding in main() does not survive tape_run. */
	load_upper_i(R_DiagPinScratch, 0x8001),
	or_i(R_DiagPinScratch, R_DiagPinScratch, 0xC800),

	/* FIX 2026-08-02: explicitly load KSEG1 base into R_PadSioBase (R_T6) at the
	 * top. The rgcc() binding in main() does NOT survive the tape_run call
	 * because R_T6 is caller-saved per the O32 ABI. */
	load_upper_i(R_PadSioBase, pad_IO_KSEG1_BASE >> 16),
	or_i(R_PadSioBase, R_PadSioBase, pad_IO_KSEG1_BASE & 0xFFFF),

	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	add_ui(R_T0, R_0, pad_SIO_CTRL_TX_ENABLE),
	or_i(R_T0, R_T0, pad_SIO_CTRL_DTR_CS),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),

	add_ui(R_T0, R_0, pad_PROTO_ADDR),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(diag_wait_ack0)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(diag_wait_ack0, diag_ack0_done)),
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(diag_wait_ack0, diag_wait_ack0)),
	add_ui(R_T0, R_0, 0xDEADAC01),
	store_word(R_T0, R_DiagPinScratch, 0),
	branch_equal(R_0, R_0, atom_offset(diag_timeout_ack0, diag_timeout)),
atom_label(diag_ack0_done)
	load_byte_u(R_T2, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T0, R_0, pad_PROTO_CMD_READ),
	store_byte(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	add_ui(R_T1, R_0, pad_SIO_WAIT_BUDGET),
atom_label(diag_wait_ack1)
	load_half_u(R_T0, R_PadSioBase, pad_SIO_STAT_OFFSET),
	nop,
	and_i(R_T0, R_T0, pad_SIO_STAT_RX_NOT_EMPTY),
	branch_ne(R_T0, R_0, atom_offset(diag_wait_ack1, diag_ack1_done)),
	add_ui_self(R_T1, -1),
	branch_ne(R_T1, R_0, atom_offset(diag_wait_ack1, diag_wait_ack1)),
	add_ui(R_T0, R_0, 0xDEADAC02),
	store_word(R_T0, R_DiagPinScratch, 0),
	branch_equal(R_0, R_0, atom_offset(diag_timeout_ack1, diag_timeout)),
atom_label(diag_ack1_done)
	load_byte_u(R_T0, R_PadSioBase, pad_SIO_DATA_OFFSET),
	nop,
	shift_lleft(R_T0, R_T0, 8),
	or_u(R_T2, R_T2, R_T0),
	store_word(R_T2, R_DiagPinScratch, 0),
atom_label(diag_success)
	branch_equal(R_0, R_0, atom_offset(diag_success, diag_done)),
	nop,
atom_label(diag_timeout_ack0)
	add_ui(R_T0, R_0, 0xDEADAC01),
	store_word(R_T0, R_DiagPinScratch, 0),
atom_label(diag_timeout_ack1)
	add_ui(R_T0, R_0, 0xDEADAC02),
	store_word(R_T0, R_DiagPinScratch, 0),
atom_label(diag_timeout)
	add_ui(R_T0, R_0, 0xDEADACFF),
	store_word(R_T0, R_DiagPinScratch, 0),
atom_label(diag_done)
	add_ui(R_T0, R_0, pad_SIO_CTRL_CLEANUP),
	store_half(R_T0, R_PadSioBase, pad_SIO_CTRL_OFFSET),
	mac_yield(),
};
#endif /* end pad_sio_diag_byte_exchange wrap */
