/* ============================================================================
 *  duffle DSL Suffix Conventions
 *  ============================================================================
 *
 *  Every mnemonic in this header follows the same suffix grammar:
 *
 *  Primitive commands: gp0_cmd_poly_f3 = 0x20    (byte opcode)
 *  Packed 32-bit cmd:  gp0_word_poly_f3(r, g, b) (32-bit, shifted)
 *
 *  Type ordering: domain?_(direction)?_action_target_modifier_type?
 *  Examples: add_ui             (add + unsigned + immediate)
 *            add_s              (add + signed, R-type implicit)
 *            shift_lleft        (shift + logical + left)
 *            shift_aright       (shift + arithmetic + right)
 *            call_reg(rs)       (call + register, $ra implicit)
 *            gte_mv_to_data_r   (gte + mv + to + data + register)
 *            gte_lw_v0_xy(base) (gte + lw + v0 + xy)
 *            load_upper_i       (load-upper + immediate, unique verb)
 *
 *  --- GPU-domain layer cake ---
 *  Every gp.h macro follows the same 4-layer composition as mips.h and gte.h:
 *    4. Semantic encoders      gp0_word_poly_f3(r,g,b)
 *    3. Composite encoders     enc_color_word(cmd, r, g, b)
 *    2. Per-field encoders     enc_gp0_color_r(r), enc_gp0_color_g(g), ...
 *    1. Bitfield layout consts gp0_color_red_shift = 0, gp0_color_red_mask = 0xFF
 *    0. Opcode IDs             gp0_cmd_poly_f3 = 0x20
 *
 *  Vendor mnemonics (gte_mtc2, gte_mfc2, etc.) are NOT in this header.
 *  They live in the opt-in `gp_vendor_sym.h` for users who prefer the
 *  PSYQ-style names.
 * ============================================================================ */

#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "math.h"
#	include "mips.h"
#endif

#pragma region GPU Ports & Commands
/* ============================================================================
 *  Hardware MMIO Addresses
 *  ============================================================================
 *
 *  PSX GPU has two 32-bit ports in the I/O register region at KSEG2
 *  0x1F800000+. GP0 (offset 0x10) is the data port (commands + params).
 *  GP1 (offset 0x14) is the control port (status, ctrl writes).
 * ============================================================================ */
/* IO base address (KSEG2 0x1F800000+ for the I/O register region).
 * The 16-bit upper half `IO_BASE_ADDR_HI16` is the form used by
 * tape-side macros that pin a register to hold the IO base and access
 * ports via offsets — `lui $reg, 0x1F80` (1 word) then `sw $data, GPIO_PORT*_OFFSET($reg)` (1 word). 
 * Mirrors the `IO_BASE_ADDR equ 0x1F80` + `gpio_port0 equ 0x1810` pattern from graphics_hello/gp.s. */
enum {
    IO_BASE_ADDR      = 0x1F800000,  /* full 32-bit I/O region base */
    IO_BASE_ADDR_HI16 = 0x1F80,      /* fits in a single `lui $reg, 0x1F80` */

    /* Offsets from IO_BASE_ADDR to each port. Used by tape-side macros
     * that pin a register to IO_BASE_ADDR and access ports via offsets:
     *   sw $data, GPIO_PORT0_OFFSET($io_base)   ; write GP0
     *   sw $data, GPIO_PORT1_OFFSET($io_base)   ; write GP1 */
    GPIO_PORT0_OFFSET = 0x1810,
    GPIO_PORT1_OFFSET = 0x1814,

    HW_GP0_ADDR = (IO_BASE_ADDR_HI16 << 16) | GPIO_PORT0_OFFSET,
    HW_GP1_ADDR = (IO_BASE_ADDR_HI16 << 16) | GPIO_PORT1_OFFSET,
};

#define HW_GP0 C_(U4 V_*, HW_GP0_ADDR)
#define HW_GP1 C_(U4 V_*, HW_GP1_ADDR)

#define gp0_send(word) (HW_GP0[0] = (word))
#define gp1_send(word) (HW_GP1[0] = (word))

/* ============================================================================
 *  GP0 command byte constants + Layer 1 (GPU bitfield shifts)
 *  ============================================================================
 *
 *  8-bit GP0 opcodes (the upper byte of a primitive's first word). These are the BYTE only.
 *  The layer-1 bitfield-layout constants live in the same enum block
 *  so the encoder can reference them by name. 
 *  NO macro body past this point uses a raw shift or raw mask. 
 *  Every shift/width/mask is named here, named once. 
 *  Mirrors the OPCODE_SHIFT / RS_SHIFT / REG_MASK convention from mips.h.
 * ============================================================================ */
enum {
    gp0_cmd_Nop             = 0x00,

    /* Cache management */
    gp0_cmd_ClearCache      = 0x01,
    gp0_cmd_FillVram        = 0x02,
    gp0_cmd_CopyVram        = 0x80,
    gp0_cmd_CopyVramChained = 0x81,
    gp0_cmd_ReadVram        = 0xC0,

    /* Polygons */
    gp0_cmd_poly_f3         = 0x20,  /* Flat Triangle           */
    gp0_cmd_poly_ft3        = 0x24,  /* Flat Textured Triangle  */
    gp0_cmd_poly_g3         = 0x30,  /* Gouraud Triangle        */
    gp0_cmd_poly_gt3        = 0x34,  /* Gouraud Textured Tri    */
    gp0_cmd_poly_f4         = 0x28,  /* Flat Quad               */
    gp0_cmd_poly_ft4        = 0x2C,  /* Flat Textured Quad      */
    gp0_cmd_poly_g4         = 0x38,  /* Gouraud Quad            */
    gp0_cmd_poly_gt4        = 0x3C,  /* Gouraud Textured Quad   */

    /* Lines */
    gp0_cmd_line_f2         = 0x40,
    gp0_cmd_line_g2         = 0x50,

    /* Sprites + Tiles + Rects */
    gp0_cmd_sprt_1          = 0x64,
    gp0_cmd_sprt_8          = 0x74,
    gp0_cmd_sprt_16         = 0x7C,
    gp0_cmd_tile_1          = 0x60,
    gp0_cmd_tile_8          = 0x68,
    gp0_cmd_tile_16         = 0x70,

    /* State setters (not drawing primitives; set render context). */
    gp0_cmd_DrawModeSetting      = 0xE1,  /* TPage / draw-mode (semi-trans, dither, etc.) */
    gp0_cmd_SetTextureWindow     = 0xE2,
    gp0_cmd_SetDrawArea_TopLeft  = 0xE3,
    gp0_cmd_SetDrawArea_BotRight = 0xE4,
    gp0_cmd_SetDrawOffset        = 0xE5,
    gp0_cmd_SetMaskBit           = 0xE6,

    /* bitfield shifts / widths / masks ----
     * Generic GP0/GP1 command byte (upper 8 bits of every word sent to either port). */
    gp0_cmd_shift = 24,
    gp0_cmd_width =  8,
    gp0_cmd_mask  = 0xFF,

    /* Color word layout (lives in Poly_F3.color, Poly_G4.c0..c3, etc.):
     *   bits 31..24 = command byte
     *   bits 23..16 = BLUE
     *   bits 15..08 = GREEN
     *   bits 07..00 = RED     (PSX GPU is BGR, NOT RGB) */
    gp0_color_cmd_shift   = 24, gp0_color_cmd_width   = 8, gp0_color_cmd_mask   = 0xFF,
    gp0_color_blue_shift  = 16, gp0_color_blue_width  = 8, gp0_color_blue_mask  = 0xFF,
    gp0_color_green_shift =  8, gp0_color_green_width = 8, gp0_color_green_mask = 0xFF,
    gp0_color_red_shift   =  0, gp0_color_red_width   = 8, gp0_color_red_mask   = 0xFF,
};

/* ============================================================================
 *  Layer 1.5 (per-field encoders) + Layer 2 (composite) + Layer 3 (semantic GP0 word builders)
 *  ============================================================================
 *
 *  Layer 1.5 encoders take one field's value, mask it to its own width,
 *  and shift it to its own position. 
 *  Mirrors `enc_op` / `enc_rs` / `enc_rt` in mips.h and `enc_gte_sf` / `enc_gte_mx` in gte.h. 
 *  Layer-2 composite encoders OR the per-field encoders together; layer-3 semantic macros delegate to the composites.
 *  No raw shifts or magic numbers in any macro body below this point.
 * ============================================================================ */

/* ---- Layer 1.5: per-field encoders ---- */
#define enc_gp0_cmd(cmd)       (((cmd) & gp0_cmd_mask)         << gp0_cmd_shift)

#define enc_gp0_color_cmd(cmd) (((cmd) & gp0_color_cmd_mask)   << gp0_color_cmd_shift)
#define enc_gp0_color_r(r)     (((r)   & gp0_color_red_mask)   << gp0_color_red_shift)
#define enc_gp0_color_g(g)     (((g)   & gp0_color_green_mask) << gp0_color_green_shift)
#define enc_gp0_color_b(b)     (((b)   & gp0_color_blue_mask)  << gp0_color_blue_shift)

/* ---- Layer 2: composite encoders ---- */
#define enc_color_word(cmd, r, g, b) (enc_gp0_color_cmd(cmd) | enc_gp0_color_r(r) | enc_gp0_color_g(g) | enc_gp0_color_b(b))

#define enc_gp0_cmd_word(cmd) (enc_gp0_cmd(cmd))

/* ---- Layer 3: semantic GP0 word builders ---- */

/* Pre-baked color+command words for all 8 polygon variants.
 * Mirrors `load_word` / `add_ui` / `jump_reg` style in mips.h. */
#define gp0_word_poly_f3(r,g,b)  enc_color_word(gp0_cmd_poly_f3,  (r),(g),(b))
#define gp0_word_poly_ft3(r,g,b) enc_color_word(gp0_cmd_poly_ft3, (r),(g),(b))
#define gp0_word_poly_g3(r,g,b)  enc_color_word(gp0_cmd_poly_g3,  (r),(g),(b))
#define gp0_word_poly_gt3(r,g,b) enc_color_word(gp0_cmd_poly_gt3, (r),(g),(b))
#define gp0_word_poly_f4(r,g,b)  enc_color_word(gp0_cmd_poly_f4,  (r),(g),(b))
#define gp0_word_poly_ft4(r,g,b) enc_color_word(gp0_cmd_poly_ft4, (r),(g),(b))
#define gp0_word_poly_g4(r,g,b)  enc_color_word(gp0_cmd_poly_g4,  (r),(g),(b))
#define gp0_word_poly_gt4(r,g,b) enc_color_word(gp0_cmd_poly_gt4, (r),(g),(b))

/* Cache management — bare-cmd words (no color/range payload). */
#define gp0_word_clear_cache() enc_gp0_cmd_word(gp0_cmd_ClearCache)
#define gp0_word_fill_vram()   enc_gp0_cmd_word(gp0_cmd_FillVram)
#define gp0_word_copy_vram()   enc_gp0_cmd_word(gp0_cmd_CopyVram)
#define gp0_word_read_vram()   enc_gp0_cmd_word(gp0_cmd_ReadVram)

/* ============================================================================
 *  GP1 command byte constants + Layer 1 (display-mode + range + draw-area bitfield shifts)
 *  ============================================================================
 *
 *  GP1 status bits are read from HW_GP1; ctrl writes use GP1 commands
 *  packed into 32-bit words (cmd byte in the upper 8 bits via
 *  `enc_gp0_cmd(cmd)` — never a raw shift).
 * ============================================================================ */
enum {
    gp1_cmd_Reset                  = 0x00,
    gp1_cmd_ResetCmdBuffer         = 0x01,
    gp1_cmd_AcknowledgeIRQ         = 0x02,
    gp1_cmd_DisplayEnable          = 0x03,
    gp1_cmd_DMADirection           = 0x04,
    gp1_cmd_StartDisplayArea       = 0x05,
    gp1_cmd_HorizontalDisplayRange = 0x06,
    gp1_cmd_VerticalDisplayRange   = 0x07,
    gp1_cmd_DisplayMode            = 0x08,
    /* Note: GP1 only has commands 0x00..0x08. 
		 * The state-setter commands (SetTextureWindow, * SetDrawArea*, 
		 * SetDrawOffset, SetMaskBit) live in the GP0 enum as * 0xE1..0xE6. 
		 * DrawArea word builders are below as GP0s * macros 
		 * (since they emit GP0 commands). */

    /* ---- Display-mode payload flags (per PSX-SPX §"GP1 Display Mode").
     * Bit positions match the encoder shifts below; values are the
     * *payload* bits only (the cmd byte is OR'd in by enc_gp1_disp_mode_word). */
    gp1_disp_HRes_256   = 0x0,
    gp1_disp_HRes_320   = 0x1,
    gp1_disp_HRes_512   = 0x2,
    gp1_disp_HRes_640   = 0x3,
    gp1_disp_VRes_240   = 0x0,
    gp1_disp_VRes_480   = 0x1,
    gp1_disp_Color15    = 0x0,
    gp1_disp_Color24    = 0x1,
    gp1_disp_VInterlace = 0x1,

    /* ---- Layer 1: GP1 display-mode + range + draw-area shifts/masks ---- */
    gp1_disp_hres_shift      =  0, gp1_disp_hres_width      = 2, gp1_disp_hres_mask      = 0x3,
    gp1_disp_vres_shift      =  2, gp1_disp_vres_width      = 1, gp1_disp_vres_mask      = 0x1,
    gp1_disp_color_shift     =  4, gp1_disp_color_width     = 1, gp1_disp_color_mask     = 0x1,
    gp1_disp_interlace_shift =  5, gp1_disp_interlace_width = 1, gp1_disp_interlace_mask = 0x1,

    /* GP1 horizontal display range: bits 0..11 = X2, bits 12..23 = X1 */
    gp1_hrange_x1_shift = 12, gp1_hrange_x1_width = 12, gp1_hrange_x1_mask = 0xFFF,
    gp1_hrange_x2_shift =  0, gp1_hrange_x2_width = 12, gp1_hrange_x2_mask = 0xFFF,

    /* GP1 vertical display range: bits 0..9 = Y2, bits 10..19 = Y1 */
    gp1_vrange_y1_shift = 10, gp1_vrange_y1_width = 10, gp1_vrange_y1_mask = 0x3FF,
    gp1_vrange_y2_shift =  0, gp1_vrange_y2_width = 10, gp1_vrange_y2_mask = 0x3FF,

    /* GP1 draw area (top-left or bottom-right): bits 0..9 = X, bits 10..19 = Y
     * (10-bit signed — caller pre-signs and masks with the named mask) */
    gp1_draw_x_shift =  0, gp1_draw_x_width = 10, gp1_draw_x_mask = 0x3FF,
    gp1_draw_y_shift = 10, gp1_draw_y_width = 10, gp1_draw_y_mask = 0x3FF,
};

/* ---- Layer 1.5: GP1 per-field encoders ---- */
#define enc_gp1_disp_hres(h)      (((h) & gp1_disp_hres_mask)     << gp1_disp_hres_shift)
#define enc_gp1_disp_vres(v)      (((v) & gp1_disp_vres_mask)     << gp1_disp_vres_shift)
#define enc_gp1_disp_color(c)     (((c) & gp1_disp_color_mask)    << gp1_disp_color_shift)
#define enc_gp1_disp_interlace(i) (((i) & gp1_disp_interlace_mask << gp1_disp_interlace_shift)

#define enc_gp1_hrange_x1(x1) (((x1) & gp1_hrange_x1_mask) << gp1_hrange_x1_shift)
#define enc_gp1_hrange_x2(x2) (((x2) & gp1_hrange_x2_mask) << gp1_hrange_x2_shift)
#define enc_gp1_vrange_y1(y1) (((y1) & gp1_vrange_y1_mask) << gp1_vrange_y1_shift)
#define enc_gp1_vrange_y2(y2) (((y2) & gp1_vrange_y2_mask) << gp1_vrange_y2_shift)
#define enc_gp1_draw_x(x)     (((x)  & gp1_draw_x_mask)    << gp1_draw_x_shift)
#define enc_gp1_draw_y(y)     (((y)  & gp1_draw_y_mask)    << gp1_draw_y_shift)

/* ---- Layer 2: GP1 composite encoders ---- */
#define enc_gp1_disp_mode_word(h, v, c, i) (enc_gp0_cmd(gp1_cmd_DisplayMode)            | enc_gp1_disp_hres(h)  | enc_gp1_disp_vres(v) | enc_gp1_disp_color(c) | enc_gp1_disp_interlace(i))
#define enc_gp1_hrange_word(x1, x2)        (enc_gp0_cmd(gp1_cmd_HorizontalDisplayRange) | enc_gp1_hrange_x1(x1) | enc_gp1_hrange_x2(x2))
#define enc_gp1_vrange_word(y1, y2)        (enc_gp0_cmd(gp1_cmd_VerticalDisplayRange)   | enc_gp1_vrange_y1(y1) | enc_gp1_vrange_y2(y2))

/* ---- Layer 2: GP0 state-setter composite encoders ----
 * GP0(0xE3) SetDrawArea top-left and GP0(0xE4) SetDrawArea bottom-right
 * both use the same X/Y 10-bit signed payload as GP1 DisplayRange. */
#define enc_gp0_draw_area_tl_word(x, y)    (enc_gp0_cmd(gp0_cmd_SetDrawArea_TopLeft)  | enc_gp1_draw_x(x) | enc_gp1_draw_y(y))
#define enc_gp0_draw_area_br_word(x, y)    (enc_gp0_cmd(gp0_cmd_SetDrawArea_BotRight) | enc_gp1_draw_x(x) | enc_gp1_draw_y(y))

/* ---- Layer 3: GP1 semantic word builders ---- */
#define gp1_word_display_enable(on)                         (enc_gp0_cmd(gp1_cmd_DisplayEnable) | ((on) & 1))
#define gp1_word_display_disable()                          gp1_word_display_enable(0)
#define gp1_word_display_mode_320x240_15bit_ntsc            enc_gp1_disp_mode_word(gp1_disp_HRes_320, gp1_disp_VRes_240, gp1_disp_Color15, 0)
#define gp1_word_display_mode_640x480_24bit_ntsc_interlaced enc_gp1_disp_mode_word(gp1_disp_HRes_640, gp1_disp_VRes_480, gp1_disp_Color24, gp1_disp_VInterlace)

#define gp1_word_horizontal_range(x1, x2) enc_gp1_hrange_word((x1), (x2))
#define gp1_word_vertical_range(y1, y2)   enc_gp1_vrange_word((y1), (y2))

/* ---- Layer 3: GP0 state-setter semantic word builders ---- */
/* DrawArea: top-left = (X, Y), bottom-right = (X, Y) — X/Y in 10-bit signed.
 * Caller is responsible for sign-conversion before passing in. */
#define gp0_word_draw_area_top_left(x, y)     enc_gp0_draw_area_tl_word((x), (y))
#define gp0_word_draw_area_bottom_right(x, y) enc_gp0_draw_area_br_word((x), (y))

/* ============================================================================
 *  Pre-baked GPU state words
 *  ============================================================================
 *
 *  Common command words for boot-time GPU init and standard display configurations.
 * ============================================================================ */

/* ---- Display enable (1-bit payload on DisplayEnable cmd) ---- */
#define gp1_word_display_enabled   enc_gp0_cmd_word(gp1_cmd_DisplayEnable)
#define gp1_word_display_disabled (enc_gp0_cmd_word(gp1_cmd_DisplayEnable) | 1)

/* ---- DMA direction (2-bit payload on DMADirection cmd 0x04) ---- */
enum {
    gp1_dma_dir_Off            = 0,
    gp1_dma_dir_FIFO           = 1,
    gp1_dma_dir_CPU_to_GPU     = 2,
    gp1_dma_dir_GPUREAD_to_CPU = 3,
};
#define gp1_word_dma_direction(dir) (enc_gp0_cmd(gp1_cmd_DMADirection) | ((dir) & 0x3))

/* ---- Standard display ranges (NTSC + PAL pre-baked) ---- */
/* Horizontal range values are in video clock units (8 units/pixel); vertical range values are scanline numbers. */
enum {
    /* NTSC horizontal range: X1=608, X2=3168 */
    gp1_hrange_NTSC_x1 = 0x260,
    gp1_hrange_NTSC_x2 = 0xC60,
    /* PAL horizontal range (same as NTSC for most CRTs) */
    gp1_hrange_PAL_x1  = 0x260,
    gp1_hrange_PAL_x2  = 0xC60,

    /* NTSC vertical range: Y1=24, Y2=264 */
    gp1_vrange_NTSC_y1 = 24,
    gp1_vrange_NTSC_y2 = 264,
    /* PAL vertical range: Y1=24, Y2=504 */
    gp1_vrange_PAL_y1  = 24,
    gp1_vrange_PAL_y2  = 504,
};

#define gp1_word_horizontal_range_ntsc enc_gp1_hrange_word(gp1_hrange_NTSC_x1, gp1_hrange_NTSC_x2)
#define gp1_word_horizontal_range_pal  enc_gp1_hrange_word(gp1_hrange_PAL_x1,  gp1_hrange_PAL_x2)
#define gp1_word_vertical_range_ntsc   enc_gp1_vrange_word(gp1_vrange_NTSC_y1, gp1_vrange_NTSC_y2)
#define gp1_word_vertical_range_pal    enc_gp1_vrange_word(gp1_vrange_PAL_y1,  gp1_vrange_PAL_y2)

/* ---- Draw-mode setting (TPage / draw-area allowance) ---- */
/* The "drawing enabled" word is the standard post-init state. */
enum {
    gp0_DrawMode_DrawToDispBit = 10,
};
#define gp0_word_draw_mode_drawing_allowed (enc_gp0_cmd(gp0_cmd_DrawModeSetting) | (1 << gp0_DrawMode_DrawToDispBit))

/* ---- DrawArea pre-baked at origin (0,0) and full screen (320x240) ---- */
#define gp0_word_draw_area_top_left_origin      enc_gp0_draw_area_tl_word(0, 0)
#define gp0_word_draw_area_bottom_right_320x240 enc_gp0_draw_area_br_word(320, 240)
#define gp0_word_draw_area_bottom_right_640x480 enc_gp0_draw_area_br_word(640, 480)

#pragma endregion GPU Ports & Commands

#pragma region GPU Status
/* ============================================================================
 *  GPU status register bits
 *  ============================================================================
 *  Read from HW_GP1; the lower bits are DMA-block-size (variable-width).
 * ============================================================================ */
enum {
    gp1_Status_BitReady          = 31,
    gp1_Status_BitSendingDMA     = 25,
    gp1_Status_DMABlockSizeShift =  0,
};

#define gp1_status_is_ready()       ((HW_GP1[0] >> gp1_Status_BitReady)      & 1)
#define gp1_status_is_sending_dma() ((HW_GP1[0] >> gp1_Status_BitSendingDMA) & 1)
#pragma endregion GPU Status

#pragma region Primitives
/* ============================================================================
 *  Primitive structs (8 polygon variants + tag)
 *  ============================================================================
 *
 *  Each struct follows the GPU-documented memory layout for the corresponding primitive command. 
 *  The PolyTag is the OT-link header; the rest of the struct is the primitive's body.
 *
 *  The current working layouts match the existing demo 
 *  (floor_tri uses Poly_F3; cube_tri uses Poly_G4). 
 *  They are NOT necessarily byte-identical to the PSX-SPX reference layout. 
 *  The demo layout uses color+vertex interleaving that doesn't match the standard PSX SDK file format. 
 *  For PSX-SDK file compatibility, the textured variants (FT*, GT*) would need layout adjustments.
 * ============================================================================ */

/* ---------- RGB8 (3-byte packed color) ---------- */
typedef Struct_(RGB8) { B1 r; B1 g; B1 b; };
#define rgb8(r,g,b) ((RGB8){r,g,b})

/* ---------- PolyTag (the OT-link header; 1 word) ---------- */
enum {
    PolyTag_len_bits  =  8,
    PolyTag_addr_bits = 24,
};
typedef Struct_(PolyTag) {
	union {
		U4 code;
		struct {
			U4 addr: 24;
			U4 len:  8;
		};
	};
};

/* DSL cast convention: every cast uses `C_()`, every pointer qualifier is `R_` (restrict) or `V_` (volatile).
 * No raw C-style casts. RHS values are assumed to be `U4` — caller passes a `U4` directly. */
#define set_len(tag,v)  (C_(PolyTag_R,tag)->len  = u4_(v))
#define set_addr(tag,v) (C_(PolyTag_R,tag)->addr = u4_(v))
/* `set_code` is no longer in the new PolyTag design — the code byte lives
 *  in the primitive body (e.g. `((Poly_F3*)(p))->code`), not in the tag.
 *  Use the typed primitive structs (Poly_F3, Poly_G4, etc.) and the `set_poly_*` setters, 
 *  which set both the tag's length and the code. */
#define get_len(tag)  C_(U4,C_(PolyTag_R,tag)->len)
#define get_addr(tag) C_(U4,C_(PolyTag_R,tag)->addr)

/* ---------- Poly_F3 (Flat Triangle; 5 words) ---------- */
typedef Struct_(Poly_F3) {
    U4   tag;
    RGB8 color;
    B1   code;
    union {
        struct { V2_S2 p0; V2_S2 p1; V2_S2 p2; };
        A3_V2_S2 points;
    };
};

/* ---------- Poly_F4 (Flat Quad; 6 words) ---------- */
typedef Struct_(Poly_F4) {
    U4   tag;
    RGB8 color;
    B1   code;
    union {
        struct { V2_S2 p0; V2_S2 p1; V2_S2 p2; V2_S2 p3; };
        A4_V2_S2 points;
    };
};

/* ---------- Poly_G3 (Gouraud Triangle; 7 words) ---------- */
typedef Struct_(Poly_G3) {
    U4    tag; RGB8 c0; B1 code;
    V2_S2 p0;  RGB8 c1; B1 pad1;
    V2_S2 p1;  RGB8 c2; B1 pad2;
    V2_S2 p2;
};

/* ---------- Poly_G4 (Gouraud Quad; 9 words) ---------- */
typedef Struct_(Poly_G4) {
    U4    tag; RGB8 c0; B1 code;
    V2_S2 p0;  RGB8 c1; B1 pad1;
    V2_S2 p1;  RGB8 c2; B1 pad2;
    V2_S2 p2;  RGB8 c3; B1 pad3;
    V2_S2 p3;
};

/* ---------- Poly_FT3 (Flat Textured Triangle; placeholder layout) ---------- */
/* TODO(Ed): verify the textured-variant layout against PSX-SPX when needed. */
typedef Struct_(Poly_FT3) {
    U4   tag;
    RGB8 color;
    B1   code;
    U4   tpage;
    U4   clut;
    V2_S2 p0; U1 u0; U1 v0;
    V2_S2 p1; U1 u1; U1 v1;
    V2_S2 p2; U1 u2; U1 v2;
};

/* ---------- Poly_FT4 (Flat Textured Quad) ---------- */
typedef Struct_(Poly_FT4) {
    U4   tag;
    RGB8 color;
    B1   code;
    U4   tpage;
    U4   clut;
    V2_S2 p0; U1 u0; U1 v0;
    V2_S2 p1; U1 u1; U1 v1;
    V2_S2 p2; U1 u2; U1 v2;
    V2_S2 p3; U1 u3; U1 v3;
};

/* ---------- Poly_GT3 (Gouraud Textured Triangle) ---------- */
typedef Struct_(Poly_GT3) {
    U4    tag; RGB8 c0; B1 code;
    V2_S2 p0;  RGB8 c1; B1 pad1;
    V2_S2 p1;  RGB8 c2; B1 pad2;
    V2_S2 p2;
    U4    tpage;
    U4    clut;
    V2_S2 tp0; U1 u0; U1 v0;
    V2_S2 tp1; U1 u1; U1 v1;
    V2_S2 tp2; U1 u2; U1 v2;
};

/* ---------- Poly_GT4 (Gouraud Textured Quad) ---------- */
typedef Struct_(Poly_GT4) {
    U4    tag; RGB8 c0; B1 code;
    V2_S2 p0;  RGB8 c1; B1 pad1;
    V2_S2 p1;  RGB8 c2; B1 pad2;
    V2_S2 p2;  RGB8 c3; B1 pad3;
    V2_S2 p3;
    U4    tpage;
    U4    clut;
    V2_S2 tp0; U1 u0; U1 v0;
    V2_S2 tp1; U1 u1; U1 v1;
    V2_S2 tp2; U1 u2; U1 v2;
    V2_S2 tp3; U1 u3; U1 v3;
};

/* ---------- Primitive setters (C-level) ----------
 * DSL cast convention: every cast via C_(), every pointer via R_/V_. */
#define set_poly_f3(p)  set_len(p, 4),  C_(Poly_F3_R, p)->code = gp0_cmd_poly_f3
#define set_poly_ft3(p) set_len(p, 7),  C_(Poly_FT3_R,p)->code = gp0_cmd_poly_ft3
#define set_poly_g3(p)  set_len(p, 6),  C_(Poly_G3_R, p)->code = gp0_cmd_poly_g3
#define set_poly_gt3(p) set_len(p, 9),  C_(Poly_GT3_R,p)->code = gp0_cmd_poly_gt3
#define set_poly_f4(p)  set_len(p, 5),  C_(Poly_F4_R, p)->code = gp0_cmd_poly_f4
#define set_poly_ft4(p) set_len(p, 9),  C_(Poly_FT4_R,p)->code = gp0_cmd_poly_ft4
#define set_poly_g4(p)  set_len(p, 8),  C_(Poly_G4_R, p)->code = gp0_cmd_poly_g4
#define set_poly_gt4(p) set_len(p, 12), C_(Poly_GT4_R,p)->code = gp0_cmd_poly_gt4

/* ---------- Ordering table ops ---------- */
#define orderingtbl_add_primitive(ot, p)       set_addr(p,  get_addr(ot)), set_addr(ot, p)
#define orderingtbl_add_primitives(ot, p0, p1) set_addr(p1, get_addr(ot)), set_addr(ot, p0)

#pragma endregion Primitives

#pragma region TPage
/* ============================================================================
 *  Texture Page (TPage) bit layout
 *  ============================================================================
 *
 *  The TPage data word sent via GP0(0x2X) has:
 *    bits  0..3   = texture page X    (4 bits, 64-px units, 0..16)
 *    bit   4      = texture page Y    (1 bit,  64-px units, 0/1)
 *    bits  5..6   = semi-transparency (2 bits, 0..3)
 *    bits  7..8   = texture page colors (2 bits, 4bpp/8bpp/16bpp/2bpp-mixed)
 *    bit   9      = dither            (1 bit,  0/1)
 *    bit  10      = drawing to display area (1 bit)
 *    bit  11      = texture disable   (1 bit)
 *    bits 12..31  = reserved (zero)
 * ============================================================================ */
enum {
    /* ---- Layer 1: TPage bitfield shifts / widths / masks ---- */
    gp0_tpage_x_shift            =  0, gp0_tpage_x_width            =  4, gp0_tpage_x_mask            = 0xF,
    gp0_tpage_y_shift            =  4, gp0_tpage_y_width            =  1, gp0_tpage_y_mask            = 0x1,
    gp0_tpage_semi_trans_shift   =  5, gp0_tpage_semi_trans_width   =  2, gp0_tpage_semi_trans_mask   = 0x3,
    gp0_tpage_color_depth_shift  =  7, gp0_tpage_color_depth_width  =  2, gp0_tpage_color_depth_mask  = 0x3,
    gp0_tpage_dither_shift       =  9, gp0_tpage_dither_width       =  1, gp0_tpage_dither_mask       = 0x1,
    gp0_tpage_draw_to_disp_shift = 10, gp0_tpage_draw_to_disp_width =  1, gp0_tpage_draw_to_disp_mask = 0x1,
    gp0_tpage_tex_disable_shift  = 11, gp0_tpage_tex_disable_width  =  1, gp0_tpage_tex_disable_mask  = 0x1,

    /* TPage color-depth payload values (NOT bit positions — these go in
     * the 2-bit field at gp0_tpage_color_depth_shift). */
    gp0_tpage_color_4bpp  = 0x0,
    gp0_tpage_color_8bpp  = 0x1,
    gp0_tpage_color_16bpp = 0x2,

    /* TPage semi-transparency mode payload values (NOT bit positions). */
    gp0_tpage_semi_trans_none  = 0x0,
    gp0_tpage_semi_trans_alpha = 0x1,
    gp0_tpage_semi_trans_add   = 0x2,
    gp0_tpage_semi_trans_sub   = 0x3,
};

/* ---- Layer 1.5: TPage per-field encoders. Mirrors enc_gte_sf/mx/v in gte.h. ---- */
#define enc_gp0_tpage_x(x)            (((x) & gp0_tpage_x_mask)            << gp0_tpage_x_shift)
#define enc_gp0_tpage_y(y)            (((y) & gp0_tpage_y_mask)            << gp0_tpage_y_shift)
#define enc_gp0_tpage_semi_trans(s)   (((s) & gp0_tpage_semi_trans_mask)   << gp0_tpage_semi_trans_shift)
#define enc_gp0_tpage_color_depth(c)  (((c) & gp0_tpage_color_depth_mask)  << gp0_tpage_color_depth_shift)
#define enc_gp0_tpage_dither(d)       (((d) & gp0_tpage_dither_mask)       << gp0_tpage_dither_shift)
#define enc_gp0_tpage_draw_to_disp(d) (((d) & gp0_tpage_draw_to_disp_mask) << gp0_tpage_draw_to_disp_shift)
#define enc_gp0_tpage_tex_disable(t)  (((t) & gp0_tpage_tex_disable_mask)  << gp0_tpage_tex_disable_shift)

/* ---- Layer 2: TPage composite encoder. Mirrors enc_gte_cmdw in gte.h ---- */
#define enc_gp0_tpage_word(x, y, semi_trans, color_depth, dither, draw_to_disp, tex_disable) \
    (enc_gp0_tpage_x(x)                       \
   | enc_gp0_tpage_y(y)                       \
   | enc_gp0_tpage_semi_trans(semi_trans)     \
   | enc_gp0_tpage_color_depth(color_depth)   \
   | enc_gp0_tpage_dither(dither)             \
   | enc_gp0_tpage_draw_to_disp(draw_to_disp) \
   | enc_gp0_tpage_tex_disable(tex_disable))

typedef Struct_(TexturePage) { U4 raw; };

/* ---- Layer 3: TPage semantic word builder ---- */
#define gp0_word_tpage(x, y, semi_trans, color_depth, dither, draw_to_disp, tex_disable) \
    enc_gp0_tpage_word((x), (y), (semi_trans), (color_depth), (dither), (draw_to_disp), (tex_disable))
#pragma endregion TPage

#pragma region CLUT
/* ============================================================================
 *  CLUT (Color Look-Up Table) semantics
 *  ============================================================================
 * 
 *  CLUT is loaded into VRAM by sending a GP0 command whose payload is:
 *    bits  0..5   = Y in 16-px units (palette row)
 *    bits  6..14  = X in 16-px units (palette column)
 *    bits 15..23  = reserved (zero)
 *    bits 24..31  = command byte — 0x20 (4bpp load) or 0x25 (8bpp load)
 * ============================================================================ */
enum {
    /* ---- Layer 1: CLUT bitfield shifts / widths / masks ---- */
    gp0_clut_y_shift = 0, gp0_clut_y_width = 6, gp0_clut_y_mask = 0x3F,
    gp0_clut_x_shift = 6, gp0_clut_x_width = 9, gp0_clut_x_mask = 0x1FF,
    /* CLUT-load cmd-byte variants — the upper byte of the GP0 word. */
    gp0_clut_cmd_Load4bpp = 0x20,
    gp0_clut_cmd_Load8bpp = 0x25,
};

/* ---- Layer 1.5: CLUT per-field encoders ---- */
#define enc_gp0_clut_x(x) (((x) & gp0_clut_x_mask) << gp0_clut_x_shift)
#define enc_gp0_clut_y(y) (((y) & gp0_clut_y_mask) << gp0_clut_y_shift)

/* ---- Layer 2: CLUT composite encoder ---- */
#define enc_gp0_clut_word(cmd, x, y) (enc_gp0_cmd(cmd) | enc_gp0_clut_x(x) | enc_gp0_clut_y(y))

/* ---- Layer 3: CLUT semantic word builders — one per depth variant,
 * named cmd-byte (no opaque ternary). ---- */
#define gp0_word_clut_load_4bpp(x, y) enc_gp0_clut_word(gp0_clut_cmd_Load4bpp, (x), (y))
#define gp0_word_clut_load_8bpp(x, y) enc_gp0_clut_word(gp0_clut_cmd_Load8bpp, (x), (y))
#pragma endregion CLUT

#pragma region TIM File Format
/* ============================================================================
 *  TIM file format constants and headers
 *  ============================================================================
 *
 *  TIM (Sony .TIM texture image) file structure:
 *    +0x00  U4 file_id (always 0x10 = TIM magic)
 *    +0x04  U4 version (always 0x00 for v1)
 *    +0x08  U4 flags   (bits 0..2 = type, bit 3 = has_CLUT)
 *    +0x0C  ... CLUT section (if flags & 0x8)
 *         +0x00 U4 clut_section_length
 *         +0x04 U2 clut_org_x
 *         +0x06 U2 clut_org_y
 *         +0x08 U2 num_colors
 *         +0x0A U2 depth_bpp
 *         +0x0C ... palette data
 *    ...   ... Pixel section
 *         +0x00 U4 px_section_length
 *         +0x04 U2 px_width
 *         +0x06 U2 px_height
 *         +0x08 ... pixel data
 *
 *  Future?: add `tim_load_to_vram(tim_ptr, vram_addr)` that
 *  emits the necessary GP0 commands. Stoppped for now at the
 *  struct + enum level.
 * ============================================================================ */
enum {
    tim_file_id_magic = 0x10,
    tim_type_4bpp     = 0x00,
    tim_type_8bpp     = 0x01,
    tim_type_16bpp    = 0x02,
    tim_type_32bpp    = 0x03,
    tim_type_mixed    = 0x04,
    tim_flag_has_clut = 0x08,
};

typedef Struct_(TIM_Header) {
    U4 file_id;       /* always 0x10 = "TIM" magic */
    U4 version;       /* ignored; always 0 */
    U4 flags;         /* bits 0..2 = type, bit 3 = has_clut */
};
typedef Struct_(TIM_SectionHeader) {
    U4 section_length;  /* bytes in this section including this header */
    U2 org_x;           /* origin in VRAM */
    U2 org_y;
    U2 width;           /* width in pixels */
    U2 height;          /* height in pixels */
};
#pragma endregion TIM File Format

#pragma region Tape-Side Macros
/* ============================================================================
 *  Tape-side GPU operations (NOT in this header)
 *  ============================================================================
 *
 *  No `mac_gp0_send` or related macros live in gp.h. Rationale: the
 *  Lottes tape model uses OT-DMA for primitive submission, so atom bodies
 *  write to main RAM (the OT/primitive buffer) and to GTE state — never
 *  directly to the GPU ports at 0x1F801810 / 0x1F801814. See
 *  `mac_format_f3_color`, `mac_insert_ot_tag`, `mac_gte_store_f3` in
 *  lottes_tape.h for the patterns atom bodies actually use.
 *
 *  If a feature need arises requires tape-side GPU port writes (e.g. DMA-kick to
 *  start GPU consumption of the OT, VBlank sync via GP1 status poll),
 *  the right home is `lottes_tape.h` alongside the rest of the `mac_*`
 *  family — the encoder infrastructure is already in place:
 *
 *    1. The caller pins a register to hold the IO base, e.g.
 *         register U4 r_io rgcc(R_T4) = IO_BASE_ADDR;
 *       The compiler emits `lui R_T4, IO_BASE_ADDR_HI16` outside the
 *       atom body (in the C prologue before tape_run).
 *
 *    2. The atom body uses `store_word(R_data, R_T4, GPIO_PORT0_OFFSET)`
 *       to write to GP0, and `store_word(R_data, R_T4, GPIO_PORT1_OFFSET)`
 *       to write to GP1. Both are preprocessor-encodable because R_T4 is
 *       a fixed register and the GPIO_PORT*_OFFSET constants fit in the
 *       `sw`'s 16-bit signed offset field. No placeholder-pun, no asm
 *       constraints, no hidden register choice. Same pattern as the
 *       old graphics_hello/hello_gp_routines.s `reg_io_offset`/`gcmd_push`
 *       convention.
 *
 *  This mirrors the existing tape-side wave-context discipline: the
 *  caller binds the IO-base register via `rgcc()`, the macro assumes
 *  the binding is in effect, and the encoding falls out at preprocessor
 *  time. No additional GPU-domain macro layer required.
 * ============================================================================ */
#pragma endregion Tape-Side Macros
