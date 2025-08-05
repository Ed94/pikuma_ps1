.psx
.create "./build/hello_gouraud.bin", 0x80010000

.include "./code/graphics_hello/dsl.s"
.include "./code/graphics_hello/gp.s"

; Entry Point of Code
.org 0x80010000

Color_RedFF           equ 0x0000FF
Color_22              equ 0x222222
Color_PS_CadmiumRed   equ 0x2400DF
Color_PS_CelticBlue   equ 0x723F00
Color_PS_GoldenPoppy  equ 0x00C3F3
Color_PS_PersianGreen equ 0x9FAC00

Display_Width      equ 320
Display_Height     equ 239
Display_HalfWidth  equ 320 / 2
Display_HalfHeight equ 240 / 2

main:
	reg_io_offset equ rtmp_0
	load_uimm rtmp_0, IO_BASE_ADDR

	gp0 equ gpio_port0(reg_io_offset)
	gp1 equ gpio_port1(reg_io_offset)

; Setup Display Control
	gcmd_push gp1, rtmp_1, gp_Reset
	gcmd_push gp1, rtmp_1, gp_DisplayEnabled
	gcmd_push gp1, rtmp_1, gp_DisplayMode_320x240_15bit_NTSC
	gcmd_push gp1, rtmp_1, gp_HorizontalDisplayRange_3168_608
	gcmd_push gp1, rtmp_1, gp_VerticalDisplayRange_264_24
	gcmd_push gp0, rtmp_1, gp_ModeSetting_DipArea
	gcmd_push gp0, rtmp_1, 		gp_SetArea_TopLeft     | 0              << gp_b10_Y | 0             << gp_b10_X
	gcmd_push gp0, rtmp_1, 		gp_SetArea_BottomRight | Display_Height << gp_b10_Y | Display_Width << gp_b10_X
	gcmd_push gp0, rtmp_1, 		gp_SetOffset           | 0              << gp_b10_Y | 0             << gp_b10_X
	gcmd_push gp0, rtmp_1, gp_RectFillVM | Color_22
	gcmd_push gp0, rtmp_1, 		0              << gp_b16_Y | 0             << gp_b16_X
	gcmd_push gp0, rtmp_1, 		Display_Height << gp_b16_Y | Display_Width << gp_b16_X
; Draw a flat-shaded quad
	gcmd_push gp0, rtmp_1, gp_Quad | Color_PS_CelticBlue
	gcmd_push gp0, rtmp_1, 		 15 * -1 + Display_HalfHeight << gp_b16_Y |    0 + Display_HalfWidth << gp_b16_X
	gcmd_push gp0, rtmp_1, 		 24 * -1 + Display_HalfHeight << gp_b16_Y |  100 + Display_HalfWidth << gp_b16_X
	gcmd_push gp0, rtmp_1, 		-30 * -1 + Display_HalfHeight << gp_b16_Y | -100 + Display_HalfWidth << gp_b16_X
	gcmd_push gp0, rtmp_1, 		-50 * -1 + Display_HalfHeight << gp_b16_Y |   55 + Display_HalfWidth << gp_b16_X
; Draw a flat-shaded triangle
	gcmd_push gp0, rtmp_1, gp_Polygon | Color_PS_GoldenPoppy
	gcmd_push gp0, rtmp_1, 		100 * -1 + Display_HalfHeight << gp_b16_Y | -100 + Display_HalfWidth << gp_b16_X
	gcmd_push gp0, rtmp_1, 		 20 * -1 + Display_HalfHeight << gp_b16_Y |   20 + Display_HalfWidth << gp_b16_X
	gcmd_push gp0, rtmp_1, 		 50 * -1 + Display_HalfHeight << gp_b16_Y |   30 + Display_HalfWidth << gp_b16_X
	; Bonus traingle
	gcmd_push gp0, rtmp_1, gp_Polygon | Color_PS_CadmiumRed
	gcmd_push gp0, rtmp_1, 		  50 * -1 + Display_HalfHeight << gp_b16_Y | -100 + Display_HalfWidth << gp_b16_X
	gcmd_push gp0, rtmp_1, 		   0 * -1 + Display_HalfHeight << gp_b16_Y |   20 + Display_HalfWidth << gp_b16_X
	gcmd_push gp0, rtmp_1, 		-100 * -1 + Display_HalfHeight << gp_b16_Y |   30 + Display_HalfWidth << gp_b16_X
	; Gourand shaded triangle
	gcmd_push gp0, rtmp_1, gp_Polygon | gp_Poly_ShadeGourand | Color_PS_PersianGreen
	gcmd_push gp0, rtmp_1, 		-35 * -1 + Display_HalfHeight << gp_b16_Y |  145 + Display_HalfWidth << gp_b16_X
	gcmd_push gp0, rtmp_1, 0x00 << 16 | Color_PS_GoldenPoppy
	gcmd_push gp0, rtmp_1, 		  0 * -1 + Display_HalfHeight << gp_b16_Y |   50 + Display_HalfWidth << gp_b16_X
	gcmd_push gp0, rtmp_1, 0x00 << 16 | Color_PS_CadmiumRed
	gcmd_push gp0, rtmp_1, 		 40 * -1 + Display_HalfHeight << gp_b16_Y |   60 + Display_HalfWidth << gp_b16_X

idle:
	jump idle :: nop

.close
