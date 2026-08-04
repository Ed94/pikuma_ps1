#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

/* PSX button bit positions — 1:1 with PSX-SPX docs at docs/psx-spx/docs/controllersandmemorycards.md:405-421.
 * Wire is active-low (0 = pressed).
 * The decoder atom computes buttons = (~raw_buttons) & 0xFFFF; the active-low-to-active-high inversion is applied bit-by-bit. */
enum {
	Bit_(Pad_Select,  0),
	Bit_(Pad_L3,      1),
	Bit_(Pad_R3,      2),
	Bit_(Pad_Start,   3),
	Bit_(Pad_Up,      4),
	Bit_(Pad_Right,   5),
	Bit_(Pad_Down,    6),
	Bit_(Pad_Left,    7),
	Bit_(Pad_L2,      8),
	Bit_(Pad_R2,      9),
	Bit_(Pad_L1,     10),
	Bit_(Pad_R1,     11),
	Bit_(Pad_Triangle, 12),
	Bit_(Pad_Circle,  13),
	Bit_(Pad_Cross,   14),
	Bit_(Pad_Square,  15),
};

enum {
	PadId_Offset = 4,

	Pad0 = 0 << PadId_Offset,
	Pad1 = 1 << PadId_Offset,
};

#define pad0_(btn_id) (btn_id << Pad0)
#define pad1_(btn_id) (btn_id << Pad1)

/* ============================================================
 * BIOS pad-buffer subsystem: docs/psx-spx/docs/kernelbios.md (B(12h) + B(13h))
 * ============================================================ */

enum {
	PAD_BIOS_RAW_SIZE = 0x22,
};
typedef Struct_(PadBiosRaw) {
	U1 bytes[PAD_BIOS_RAW_SIZE];
};

typedef Enum_(U4, PadStatus) {
	PadStatus_Disconnected,
	PadStatus_Digital,
	PadStatus_AnalogStick,
	PadStatus_AnalogPad,
	PadStatus_Unsupported,
	PadStatus_Pending,
	PadStatus_Invalid,
};

/* PadState — per-port normalized runtime state.
 * Field order is chosen so that the 4 axes (left_x, left_y, right_x, right_y)
 * form a contiguous 4-byte block at offset 8, allowing a single `store_word` to clear-or-write all 4 axes in one MIPS instruction.
 * The struct size stays 12 bytes (unchanged from the prior order,
 * which left the C compiler to insert 1 byte of trailing pad to reach the 4-byte struct alignment). */
typedef Struct_(PadState) {
	PadStatus status;  /* offset 0,  size 4 (U4) */
	U2        buttons; /* offset 4,  size 2 */
	U1        id;      /* offset 6,  size 1 */
	U1        pad;     /* offset 7,  size 1 — explicit pad to align the axes block */
	U1        left_x;  /* offset 8,  size 1 — store_word target (4-byte aligned) */
	U1        left_y;  /* offset 9,  size 1 */
	U1        right_x; /* offset 10, size 1 */
	U1        right_y; /* offset 11, size 1 */
};
