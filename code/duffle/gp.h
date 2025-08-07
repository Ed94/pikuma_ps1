#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "math.h"
#endif

typedef def_enum(U32, gp_Commands) {
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

#define gpio_port0 0x1810
#define gpio_port1 0x1814

#define gcmd_offset 24

#define gp_Reset (gcmd_Reset << gcmd_offset)

#define gp_DisplayEnabled  (gcmd_DisplayEnable << gcmd_offset | 0x0)
#define gp_DisplayDisabled (gcmd_DisplayEnable << gcmd_offset | 0x1)

#define gp_DMA_FIFO       1
#define gp_DMA_CPU_to_GPU 2
#define gp_DMA_GPU_to_CPU 3
#define gp_DMA_Request    (gcmd_DMA_Request << gcmd_offset)

#define gp_HorizontalDisplayRange_3168_608 (gcmd_HorizontalDisplayRange << gcmd_offset | 0xC60 << 12 | 0x260)

#define gp_VerticalDiplayRange         (gcmd_VerticalDisplayRange << gcmd_offset)
#define gp_VerticalDisplayRange_264_24 (gp_VerticalDiplayRange | 264 << 10 | 24)
#define gp_VerticalDisplayRange_504_24 (gp_VerticalDiplayRange | 504 << 10 | 24)

#define gp_DisplayMode     (gcmd_DisplayMode << gcmd_offset)
#define gp_Disp_HRes_256   (0x0)
#define gp_Disp_HRes_320   (0x1)
#define gp_Disp_HRes_512   (0x2)
#define gp_Disp_HRes_640   (0x3)
#define gp_Disp_VRes_240   (0x0 << 2)
#define gp_Disp_VRes_480   (0x1 << 2)
#define gp_Disp_Color15    (0x0 << 4)
#define gp_Disp_Color24    (0x1 << 4)
#define gp_Disp_VInterlace (0x1 << 5)
#define gp_DisplayMode_320x240_15bit_NTSC (gp_DisplayMode | gp_Disp_HRes_320 | gp_Disp_VRes_240 | gp_Disp_Color15)
#define gp_DisplayMOde_640x480_24bbp_NTSC (gp_DisplayMode | gp_Disp_HRes_640 | gp_Disp_VRes_480 | gp_Disp_Color24 | gp_Disp_VInterlace)

#define gp_DrawMode_DrawAllowed 10
#define gp_SetDrawMode_DrawAllowed (gcmd_SetDrawMode << gcmd_offset | 0x1 << gp_DrawMode_DrawAllowed)

#define gp_SetArea_TopLeft     (gcmd_SetDrawArea_TopLeft  << gcmd_offset)
#define gp_SetArea_BottomRight (gcmd_SetDrawArea_BotRight << gcmd_offset)

typedef def_struct(RGB8) { BYTE r; BYTE g; BYTE b; };

typedef BYTE gp_Pixel16[1];
typedef BYTE gp_Pixel24[3];

#define gp_b10_X 0
#define gp_b10_Y 10
#define gp_b16_X 0
#define gp_b16_Y 16 

typedef def_struct(gp_Vec2) { U16 y; U16 x; };

void gp_screen_init(void) __asm__("gp_screen_init");
