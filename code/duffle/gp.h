#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "math.h"
#endif

typedef Enum_(U4, gp_Commands) {
	gcmd_Reset       = 0b000,
	gcmd_Polygon     = 0b001,
	gcmd_Line        = 0b010,
	gcmd_Rect        = 0b011,
	gcmd_VM_to_VM    = 0b100,
	gcmd_CPU_to_VM   = 0b101,
	gcmd_VM_to_CPU   = 0b110,
	gcmd_Environment = 0b111,

	gcmd_SetDrawMode          = 0xE1,
	gcmd_SetTextureWindow     = 0xE2,
	gcmd_SetDrawArea_TopLeft  = 0xE3,
	gcmd_SetDrawArea_BotRight = 0xE4,
	gcmd_SetDrawOffset        = 0xE5,
	gcmd_SetMaskBit           = 0xE6,

	gcmd_ResetCommandBuffer      = 0x01,
	gcmd_AcknowledgeGPUInterrupt = 0x02,
	gcmd_DisplayEnable           = 0x03,
	gcmd_DMA_Request             = 0x04,
	gcmd_DispArea_Start          = 0x05,
	gcmd_HorizontalDisplayRange  = 0x06,
	gcmd_VerticalDisplayRange    = 0x07,
	gcmd_DisplayMode             = 0x08,

	gcmd_SetVramSize             = 0x09,
};

enum {
	gpio_port_0 = 0x1810,
	gpio_port_1 = 0x1814,

	gcmd_offset = 24,

	gp_Reset = (gcmd_Reset << gcmd_offset),

	gp_DisplayEnabled  = (gcmd_DisplayEnable << gcmd_offset | 0x0),
	gp_DisplayDisabled = (gcmd_DisplayEnable << gcmd_offset | 0x1),

	gp_DMA_FIFO       = 1,
	gp_DMA_CPU_to_GPU = 2,
	gp_DMA_GPU_to_CPU = 3,
	gp_DMA_Request    = (gcmd_DMA_Request << gcmd_offset),

	gp_HorizontalDisplayRange_3168_608 = (gcmd_HorizontalDisplayRange << gcmd_offset | 0xC60 << 12 | 0x260),

	gp_VerticalDiplayRange         = (gcmd_VerticalDisplayRange << gcmd_offset),
	gp_VerticalDisplayRange_264_24 = (gp_VerticalDiplayRange | 264 << 10 | 24),
	gp_VerticalDisplayRange_504_24 = (gp_VerticalDiplayRange | 504 << 10 | 24),

	gp_DisplayMode                    = (gcmd_DisplayMode << gcmd_offset),
	gp_Disp_HRes_256                  = (0x0),
	gp_Disp_HRes_320                  = (0x1),
	gp_Disp_HRes_512                  = (0x2),
	gp_Disp_HRes_640                  = (0x3),
	gp_Disp_VRes_240                  = (0x0 << 2),
	gp_Disp_VRes_480                  = (0x1 << 2),
	gp_Disp_Color15                   = (0x0 << 4),
	gp_Disp_Color24                   = (0x1 << 4),
	gp_Disp_VInterlace                = (0x1 << 5),
	gp_DisplayMode_320x240_15bit_NTSC = (gp_DisplayMode | gp_Disp_HRes_320 | gp_Disp_VRes_240 | gp_Disp_Color15),
	gp_DisplayMOde_640x480_24bbp_NTSC = (gp_DisplayMode | gp_Disp_HRes_640 | gp_Disp_VRes_480 | gp_Disp_Color24 | gp_Disp_VInterlace),
	
	gp_DrawMode_DrawAllowed    = 10,
	gp_SetDrawMode_DrawAllowed = (gcmd_SetDrawMode << gcmd_offset | 0x1 << gp_DrawMode_DrawAllowed),

	gp_SetArea_TopLeft     = (gcmd_SetDrawArea_TopLeft  << gcmd_offset),
	gp_SetArea_BottomRight = (gcmd_SetDrawArea_BotRight << gcmd_offset),
};

typedef Struct_(RGB8) { B1 r; B1 g; B1 b; };
#define rgb8(r, g, b) (RGB8){ r, g, b }

typedef B1 gp_Pixel16[1];
typedef B1 gp_Pixel24[3];

enum {
	gp_b10_X = 0,
	gp_b10_Y = 10,
	gp_b16_X = 0,
	gp_b16_Y = 16,
};

typedef Struct_(gp_Vec2) { U2 y; U2 x; };

#if 1
void gp_screen_init(void) __asm__("gp_screen_init_asm");
#else
#define gp_screen_init() gp_screen_init_c11()
#endif



// TODO REVIEW:

/* --- GPU Command Semantics (GP0) --- */

#define GPU_CMD_CLEAR_CACHE 0x01
#define GPU_CMD_VRAM_FILL   0x02
#define GPU_CMD_VRAM_COPY   0x80
#define GPU_CMD_VRAM_READ   0xC0
#define GPU_CMD_POLY_F3     0x20 /* Flat Triangle */
#define GPU_CMD_POLY_FT3    0x24 /* Flat Textured Triangle */
#define GPU_CMD_POLY_G3     0x30 /* Gouraud Triangle */
#define GPU_CMD_POLY_GT3    0x34 /* Gouraud Textured Triangle */
#define GPU_CMD_POLY_F4     0x28 /* Flat Quad */
#define GPU_CMD_POLY_FT4    0x2C /* Flat Textured Quad */
#define GPU_CMD_POLY_G4     0x38 /* Gouraud Quad */
#define GPU_CMD_POLY_GT4    0x3C /* Gouraud Textured Quad */

/* --- Hardware MMIO Addresses --- */

#define HW_GP0_ADDR       0x1F801810 /* GPU Data Port */
#define HW_GP1_ADDR       0x1F801814 /* GPU Status/Control Port */

