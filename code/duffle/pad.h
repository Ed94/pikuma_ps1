#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif


enum {
	Bit_(Pad_L2,       0),
	Bit_(Pad_R2,       1),
	Bit_(Pad_L1,       2),
	Bit_(Pad_R1,       3),
	Bit_(Pad_Triangle, 4),
	Bit_(Pad_Circle,   5),
	Bit_(Pad_Cross,    6),
	Bit_(Pad_Square,   7),
	Bit_(Pad_Select,   8),
	Bit_(Unused_PadI,  9),
	Bit_(Unused_PadJ, 10),
	Bit_(Pad_Start,   11),
	Bit_(Pad_Up,      12),
	Bit_(Pad_Right,   13),
	Bit_(Pad_Down,    14),
	Bit_(Pad_Left,    15),
};

enum {
	PadId_Offset = 4,

	Pad0 = 0 << PadId_Offset,
	Pad1 = 1 << PadId_Offset,
};

#define pad0_(btn_id) (btn_id << Pad0)
#define pad1_(btn_id) (btn_id << Pad1)


/* ============================================================
 * SIO0 raw controller polling surface (Phase 1 scaffolding)
 * Source of truth: docs/psx-spx/docs/serialinterfacessio.md
 *                  docs/psx-spx/docs/controllersandmemorycards.md
 *                  https://github.com/Lameguy64/PSn00bSDK (spi.c)
 * ============================================================ */

enum {
	/* SIO0 register offsets relative to IOBASE 0xBF800000 */
	pad_SIO_DATA_OFFSET       = 0x1040,  /* 8-bit data (TX write / RX read) */
	pad_SIO_STAT_OFFSET       = 0x1044,  /* 16-bit status */
	pad_SIO_MODE_OFFSET       = 0x1048,  /* 16-bit mode */
	pad_SIO_CTRL_OFFSET       = 0x104A,  /* 16-bit control */
	pad_SIO_BAUD_OFFSET       = 0x104E,  /* 16-bit baud */

	/* SIO_CTRL bit flags */
	pad_SIO_CTRL_RESET        = 0x0040,  /* reset most SIO registers */
	pad_SIO_CTRL_TX_ENABLE    = 0x0001,  /* TX enable */
	pad_SIO_CTRL_DTR_CS       = 0x0002,  /* DTR drives /CS on controller */
	pad_SIO_CTRL_ACK          = 0x0010,  /* acknowledge / clear status */
	pad_SIO_CTRL_DSR_IRQ      = 0x1000,  /* enable /ACK IRQ (unused; polling) */

	/* SIO_STAT bit flags */
	pad_SIO_STAT_TX_READY     = 0x0001,
	pad_SIO_STAT_RX_NOT_EMPTY = 0x0002,
	pad_SIO_STAT_TX_IDLE      = 0x0004,
	pad_SIO_STAT_DSR_ACK      = 0x0080,

	/* SIO init values (per docs/psx-spx/docs/serialinterfacessio.md) */
	pad_SIO_MODE_INIT         = 0x000D,  /* MUL1, 8-bit, no parity, idle-high */
	pad_SIO_BAUD_INIT         = 0x0088,  /* ~250 kHz standard rate */
	pad_SIO_CTRL_CLEANUP      = 0x0010,  /* raise /CS + clear stale status */

	/* Controller protocol bytes (per docs/psx-spx/docs/controllersandmemorycards.md) */
	pad_PROTO_ADDR            = 0x01,
	pad_PROTO_CMD_READ        = 0x42,
	pad_PROTO_CMD_ENTERCFG    = 0x43,
	pad_PROTO_CMD_SETLED      = 0x44,
	pad_PROTO_PREFIX          = 0x5A,
	pad_PROTO_PREFIX_QUIRK    = 0x00,  /* DualShock: Analog-button swap after cfg */

	/* Controller response ID nibble (low 4 bits of ID byte) */
	pad_PROTO_ID_DIGITAL      = 0x41,
	pad_PROTO_ID_ANALOG_STK   = 0x53,
	pad_PROTO_ID_ANALOG       = 0x73,
	pad_PROTO_ID_CONFIG       = 0xF3,

	/* Per-state constants */
	pad_SIO_SETTLE_BEFORE_TX  = 1000,   /* iterations after CTRL=0x0010 */
	pad_SIO_SETTLE_AFTER_TX   = 2000,   /* iterations after CTRL=port_select */
	pad_SIO_WAIT_BUDGET       = 4096,   /* max iterations per /ACK or RX wait */
	pad_SIO_CFG_MAX_ATTEMPTS  = 3,      /* DualShock config retries before reject */
};

/* Pad status enum (per-port outcome) */
typedef Enum_(U4, PadSioStatus) {
	PadSioStatus_Disconnected,
	PadSioStatus_Digital,
	PadSioStatus_AnalogStick,
	PadSioStatus_Analog,
	PadSioStatus_ConfigRejected,
	PadSioStatus_Invalid,
	PadSioStatus_TxTimeout,
	PadSioStatus_RxTimeout,
	PadSioStatus_AckTimeout,
};

/* PadState — per-port runtime state */
typedef Struct_(PadState) {
	PadSioStatus status;
	U4           buttons;
	U1           left_x;
	U1           left_y;
	U1           right_x;
	U1           right_y;
	U4           attempt;
};

/* PadSioInit — boot-time C-side pointer table passed into the tape */
typedef Struct_(PadSioInit) {
	U4        sio_base_addr[2];
	PadState* pad_state_ptr[2];
};

/* Register aliases for the new atoms (post-2026-07-10 ABI) */
#ifndef atom_reg
#define atom_reg /* atom_reg: opt the preceding enum entry into the DWARF registry */
#endif

enum {
	R_PadSioBase   = R_T6 atom_reg,  /* caller-pinned IO_BASE_ADDR */
	R_PadState     = R_T7 atom_reg,  /* caller-pinned PadState* */
	R_PadStatus    = R_T4 atom_reg,  /* scratch for status reads */
	R_PadCountdown = R_T5 atom_reg,  /* scratch for countdown budget */
	R_DiagPinScratch = R_T3 atom_reg, /* raw_sio_pad_poll_20260802 — diag scratch address */
#define R_PadSioBase_Code       R_T6_Code
#define R_PadState_Code         R_T7_Code
#define R_PadStatus_Code        R_T4_Code
#define R_PadCountdown_Code     R_T5_Code
#define R_DiagPinScratch_Code  R_T3_Code
};

/* Address of SIO0 block in KSEG1 (the PS1-side uncached mirror) */
enum {
	pad_IO_KSEG1_BASE = 0xBF800000,
};

