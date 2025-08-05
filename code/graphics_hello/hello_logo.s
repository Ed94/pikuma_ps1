.psx
.create "./build/hello_logo.bin", 0x80010000

.include "./code/graphics_hello/dsl.s"
.include "./code/graphics_hello/gp.s"

Color_RedFF           equ 0x0000FF
Color_22              equ 0x222222
Color_PS_CadmiumRed   equ 0x2400DF
Color_PS_CelticBlue   equ 0x723F00
Color_PS_GoldenPoppy  equ 0x00C3F3
Color_PS_PersianGreen equ 0x9FAC00

Display_Width      equ (640)
Display_Height     equ (480)
Display_HalfWidth  equ Display_Width  / 2
Display_HalfHeight equ Display_Height / 2

// TODO(Ed): Figure out an auto-region?
.org 0x80010000 + 4000

Image_SizeX    equ 640 * 3 / 2 ; 24bbp needs 1.5x
Image_SizeY    equ 480
Image_ByteSize equ Image_SizeX * Image_SizeY * gp_pixel24
Image:
	.incbin "./assets/logo.bin"

; Entry Point of Code
.org 0x80010000
main:
	reg_io_offset equ rtmp_0
	load_uimm rtmp_0, IO_BASE_ADDR

	gp0 equ gpio_port0(reg_io_offset)
	gp1 equ gpio_port1(reg_io_offset)

; Setup Display Control
	gcmd_push gp1, rtmp_1, gp_Reset
	gcmd_push gp1, rtmp_1, gp_DisplayEnabled
	gcmd_push gp1, rtmp_1, gp_DisplayMode | gp_Disp_Color24 | gp_Disp_VInterlace | gp_Disp_VRes_480 | gp_Disp_HRes_640
	// gcmd_push gp1, rtmp_1, gp_DisplayMode_320x240_15bit_NTSC
	// gcmd_push gp1, rtmp_1, gp_DisplayMode_640x480_24bbp_NTSC
	gcmd_push gp1, rtmp_1, gp_HorizontalDisplayRange_3168_608
	gcmd_push gp1, rtmp_1, gp_VerticalDisplayRange_504_24
	gcmd_push gp0, rtmp_1, gp_ModeSetting_DipArea
	gcmd_push gp0, rtmp_1, 		gp_SetArea_TopLeft     | 0              << gp_b10_Y | 0             << gp_b10_X
	gcmd_push gp0, rtmp_1, 		gp_SetArea_BottomRight | Display_Height << gp_b10_Y | Display_Width << gp_b10_X
	gcmd_push gp0, rtmp_1, 		gp_SetOffset           | 0              << gp_b10_Y | 0             << gp_b10_X

; Copy image contents to vram
	gcmd_push gp0, rtmp_1, gp_Blit_CPU_VM
	gcmd_push gp0, rtmp_1, 		0           << gp_b16_Y | 0           << gp_b16_X ; Top Left
	gcmd_push gp0, rtmp_1, 		Image_SizeY << gp_b16_Y | Image_SizeX << gp_b16_X ; Bottom Right
	; DMA commands
	@id         equ rtmp_2
	@img_cursor equ rtmp_3
		load_imm @id, Image_ByteSize
		shift_rl @id, @id, (word / 2)
		load_addr @img_cursor, Image
	loop_dma: 
		load_word  rtmp_1, (@img_cursor) 
		add_si @img_cursor, @img_cursor, word             ; @img_cursor ++ (delay slot filled)
		store_word rtmp_1, gp0                            ; @img_curor -> gp_dma_cpu_vm(word)
	branch_ne_zero @id, loop_dma :: add_ui @id, @id, -1 ; if != @id, 0 goto loop_dma :: -- @id (delay slot filled)

idle:
	jump idle :: nop

.close
