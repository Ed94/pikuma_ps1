#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

/* PSX button bit positions — 1:1 with PSX-SPX docs at docs/psx-spx/docs/controllersandmemorycards.md:405-421.
 * Wire is active-low (0 = pressed).
 * The decoder atom computes buttons = (~raw_buttons) & 0xFFFF; 
 * active-low-to-active-high inversion is applied bit-by-bit. */
typedef Enum_(U2, PadBtns) {
	Bit_(Pad_Select,    0),
	Bit_(Pad_L3,        1),
	Bit_(Pad_R3,        2),
	Bit_(Pad_Start,     3),
	Bit_(Pad_Up,        4),
	Bit_(Pad_Right,     5),
	Bit_(Pad_Down,      6),
	Bit_(Pad_Left,      7),
	Bit_(Pad_L2,        8),
	Bit_(Pad_R2,        9),
	Bit_(Pad_L1,       10),
	Bit_(Pad_R1,       11),
	Bit_(Pad_Triangle, 12),
	Bit_(Pad_Circle,   13),
	Bit_(Pad_Cross,    14),
	Bit_(Pad_Square,   15),
};

enum {
	PadId_Offset = 4,

	Pad0 = 0 << PadId_Offset,
	Pad1 = 1 << PadId_Offset,
};

#define pad0_(btn_id) (btn_id << Pad0)
#define pad1_(btn_id) (btn_id << Pad1)

/* =============================================================================
 * BIOS pad-buffer subsystem: docs/psx-spx/docs/kernelbios.md (B(12h) + B(13h))
 * ============================================================================= */

enum {
	PAD_BIOS_RAW_SIZE = 0x22,
};
// BIOS pad buffer layout (docs/psx-spx/docs/kernelbios.md (InitPAD2 returns 0x22 = 34 bytes per port)).
// Bytes 0..7 are the named snapshot region; bytes 8..33 are reserved (the BIOS writes the buffer raw; we only read bytes 0..7 via O_(PadBiosRaw, ...)).
typedef Struct_(PadBiosRaw) {
	U1    status;  /* offset 0   (PadRawStatus_Ok / PadRawStatus_Timeout) */
	U1    id;      /* offset 1   (PadRawId_Digital / PadRawId_AnalogStick / 0x7x AnalogPad) */
	U2    buttons; /* offset 2-3 (active-low 16-bit button map) */
	V2_U1 right;   /* offset 4-5 (right stick x, y) */
	V2_U1 left;    /* offset 6-7 (left  stick x, y) */
	U1    reserved[PAD_BIOS_RAW_SIZE - 8]; /* offset 8..33 */
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

/* Distinct from the game-facing PadStatus enum: PadRawStatus_Ok and PadRawStatus_Timeout are raw BIOS values;
 * PadStatus_* are game-facing post-decode states. PadUnknownId_Sentinel is written by the decoder 
 * when the controller id does not match any known controller type.
 * PadAxisCentered_Word: Four-byte 0x80 pattern used to clear / center 
 * four byte axes at PadState.left_x through PadState.right_y. */
typedef Enum_(U1, PadRawStatus) {
	PadRawStatus_Ok      = 0x00,
	PadRawStatus_Timeout = 0xFF,
};
typedef Enum_(U1, PadRawId) {
	PadRawId_Digital           = 0x41,
	PadRawId_AnalogStick       = 0x53,
	PadRawId_AnalogPadMask     = 0xF0,
	PadRawId_AnalogPadValue    = 0x70,
};
typedef Enum_(U1, PadUnknownId) {
	PadUnknownId_Sentinel      = 0xFF,
};
typedef Enum_(U4, PadAxisCentered) {
	PadAxis_Centered_Hi   = 0x8080,
	PadAxis_Centered_Lo   = 0x8080,
	PadAxis_Centered_Word = 0x80808080U,
};
typedef Enum_(U1, PadDeadZone) {
	PadDeadZone_LowBound  = 0x70,  /* left_x <  LowBound  → active;  delta = 0x80 - left_x > 0 (rightward pull) */
	PadDeadZone_Center    = 0x80,  /* analog rest position; left_x == Center → delta = 0 (no rotation) */
	PadDeadZone_HighBound = 0x90,  /* left_x >  HighBound → active;  delta = 0x80 - left_x < 0 (leftward pull) */
};


typedef Struct_(PadAxes) {
	V2_U1  left;  /* offset 8-9 */
	V2_U1  right; /* offset 10-11 */
};
// Field order is chosen so that the 4 axes (left_x, left_y, right_x, right_y)
// form a contiguous 4-byte block at offset 8, allowing a single `store_word` to clear-or-write all 4 axes in one MIPS instruction.
typedef Struct_(PadState) {
	PadStatus status;   /* offset 0,    (U4) */
	PadBtns   buttons;  /* offset 4,    */
	U1        id;       /* offset 6,    */
	byte_pad(1);        /* offset 7,  explicit pad to align the axes block */
	union {
		A2_V2_U1 axes;    /* offset 8-11 store_target (4-byte aligned)*/
		struct {
			V2_U1  left;    /* offset 8-9 */
			V2_U1  right;   /* offset 10-11 */
		};
	};
};
