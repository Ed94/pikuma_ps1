.psx
.create "./build/hellogpu.bin", 0x80010000

.include "./code/graphics_hello/dsl.s"

; Entry Point of Code
.org 0x80010000

; IO PORT
IO_BASE_ADDR equ 0x1F80 ; IO Ports Memory map base address

; GPU Registers
gpio_port0 equ 0x1810 ; 1F801810h-Write GP0: Send GP0 Commands/Packets (Rendering and VRAM Access)
gpio_port1 equ 0x1814 ; 1F801814h-Write GP1: Send GP1 Commands (Display Control) (and DMA Control)

; GPU Command Format: [7:8] Command (8-bit), [0:6] Paraemter (24-bit)

gcmd_offset equ 24

gp_Reset equ 0x0 << gcmd_offset

; On:  0x0
; Off: 0x1
gp_DisplayEnabled  equ (0x03 << gcmd_offset)  | 0x0
gp_DisplayDisabled equ (0x03 << gcmd_offset)  | 0x1

; GP1(08h) - Display mode
; 0-1   Horizontal Resolution 1     (0=256, 1=320, 2=512, 3=640) ;GPUSTAT.17-18
; 2     Vertical Resolution         (0=240, 1=480, when Bit5=1)  ;GPUSTAT.19
; 3     Video Mode                  (0=NTSC/60Hz, 1=PAL/50Hz)    ;GPUSTAT.20
; 4     Display Area Color Depth    (0=15bit, 1=24bit)           ;GPUSTAT.21
; 5     Vertical Interlace          (0=Off, 1=On)                ;GPUSTAT.22
; 6     Horizontal Resolution 2     (0=256/320/512/640, 1=368)   ;GPUSTAT.16
; 7     Flip screen horizontally    (0=Off, 1=On, v1 only)       ;GPUSTAT.14
; 8-23  Not used (zero)
@DisplayMode equ 0x08
gp_DisplayMode_320x240_15bit_NTSC equ @DisplayMode << gcmd_offset | 0x0 << 7 | 0x0 << 6 | 0x0 << 5 | 0x0 << 4 | 0x0 << 3 | 0x0 << 2 | 0x1

; GP1(06h) - Horizontal Display range (on Screen)
; X2 = X1 + pixels * cycles_per_pix
; 0  - 11 X1 (260h + 0)       ; 12bit ; \ counted in video clock units,
; 12 - 23 X2 (260h + 320 * 8) ; 12bit ; / relative to HSYNC
gp_HorizontalDisplayRange_3168_608 equ 0x06 << gcmd_offset | 0xC60 << 12 | 0x260

; GP1(07h) - Vertical Display range (on Screen)
; 0  - 9  Y1 (NTSC = 88h - (240 / 2), (PAL = A3h - (288 / 2))  ; \ scanline numbers on screen,
; 10 - 19 Y2 (NTSC = 88h + (240 / 2), (PAL = A3h + (288 / 2))  ; / relative to VSYNC
; 20 - 23 Not used (zero)
gp_VerticalDisplayRange_264_24 equ 0x07 << gcmd_offset | 264 << 10 | 24

;GP0(E1h) - Draw Mode setting (aka "Texpage")
; 0 - 3   Texture page X Base       (N * 64)  (ie. in 64-halfword steps)                       ; GPUSTAT.0-3
; 4       Texture page Y Base 1     (N * 256) (ie. 0, 256, 512 or 768)                         ; GPUSTAT.4
; 5 - 6   Semi-transparency         (0 = B / 2 + F / 2, 1 = B + F, 2 = B - F, 3 = B + F / 4)   ; GPUSTAT.5-6
; 7 - 8   Texture page colors       (0 = 4 bit, 1 = 8bit, 2 = 15bit, 3 = Reserved)             ; GPUSTAT.7-8
; 9       Dither 24bit to 15bit     (0=Off / strip LSBs, 1 = Dither Enabled)                   ; GPUSTAT.9
; 10      Drawing to display area   (0=Prohibited, 1=Allowed)                                  ; GPUSTAT.10
; 11      Texture page Y Base 2     (N * 512) (only for 2 MB VRAM)                             ; GPUSTAT.15
; 12      Textured Rectangle X-Flip (BIOS does set this bit on power-up...?)
; 13      Textured Rectangle Y-Flip (BIOS does set it equal to GPUSTAT.13...?)
; 14 - 23 Not used (should be 0)
; 24 - 31 Command  (E1h)
gp_ModeSetting_DrawAllowed equ 10
gp_ModeSetting_DipArea     equ 0xE1 << gcmd_offset | 0x1 << gp_ModeSetting_DrawAllowed

; GP0(E3h) - Set Drawing Area top left (X1,Y1)
; GP0(E4h) - Set Drawing Area bottom right (X2,Y2)
; Sets the drawing area corners. The Render commands GP0(20h..7Fh) are automatically clipping any pixels that are outside of this region.
; 0  - 9   X-coordinate (0..1023)
; 10 - 18  Y-coordinate (0..511)   ; \ on v0 GPU (max 1 MB VRAM)
; 19 - 23  Not used (zero)         ; /
; 10 - 19  Y-coordinate (0..1023)  ; \ on v2 GPU (max 2 MB VRAM)
; 20 - 23  Not used (zero)         ; /
; 24 - 31  Command  (Exh)
gp_SetArea_TopLeft     equ 0xE3 << gcmd_offset
gp_SetArea_BottomRight equ 0xE4 << gcmd_offset

; GP0(E5h) - Set Drawing Offset (X,Y)
; 0-9    X-coordinate (0..1023)
; 10-18  Y-coordinate (0..511)   ;\on v0 GPU (max 1 MB VRAM)
; 19-23  Not used (zero)         ;/
; 10-19  Y-coordinate (0..1023)  ;\on v2 GPU (max 2 MB VRAM)
; 20-23  Not used (zero)         ;/
; 24-31  Command  (Exh)
gp_SetOffset equ 0xE5 << gcmd_offset

; GPU Memory Transfer Commands

; GP0(02h) Fill Vram
; GP0(02h) - Fill Rectangle in VRAM
; 1st  Color+Command     (CcBbGgRrh)  ;24bit RGB value (see note)
; 2nd  Top Left Corner   (YyyyXxxxh)  ;Xpos counted in halfwords, steps of 10h
; 3rd  Width+Height      (YsizXsizh)  ;Xsiz counted in halfwords, steps of 10h
 ; Fills the area in the frame buffer with the value in RGB. 
 ; Horizontally the filling is done in 16-pixel (32-bytes) units (see below masking/rounding).
 ; The "Color" parameter is a 24bit RGB value, however, the actual fill data is 16bit: 
 ; The hardware automatically converts the 24bit RGB value to 15bit RGB (with bit15=0).
 ; Fill is NOT affected by the Mask settings (acts as if Mask.Bit0,1 are both zero).
gp_RectFillVM  equ 0x02 << gcmd_offset

; GPU Render Polygon Commands

; When the upper 3 bits of the first GP0 command are set to 1 (001), 
; then the command can be decoded using the following bitfield:
; bit number   value   meaning
; 31-29        001     polygon render
; 28           1/0     gouraud / flat shading
; 27           1/0     4 / 3 vertices
; 26           1/0     textured / untextured
; 25           1/0     semi-transparent / opaque
; 24           1/0     raw texture / modulation
; 23-0         rgb     first color value.
gp_Poly_FirstColor   equ          0
gp_Poly_RawTexture   equ 1    << 24
gp_Poly_SemiTrans    equ 1    << 25
gp_Poly_Textured     equ 1    << 26
gp_Poly_Quad         equ 1    << 27
gp_Poly_Tri          equ 0    << 27
gp_Poly_ShadeFlat    equ 0    << 28
gp_Poly_ShadeGourand equ 1    << 28
gp_Polygon           equ 1    << 29

gp_Quad equ gp_Polygon | gp_Poly_Quad

gp_b10_X equ 0
gp_b10_Y equ 10
gp_b16_X equ 0
gp_b16_Y equ 16

.macro gp_push_pak, port, packet, reg_scratch
	load_imm   reg_scratch, packet
	store_word reg_scratch, port 
.endmacro
.macro gcmd_push, port, cmd, reg_scratch
	load_imm   reg_scratch, cmd
	store_word reg_scratch, port 
.endmacro

Color_RedFF          equ 0x0000FF
Color_22             equ 0x222222
Color_PS_CadmiumRed  equ 0x2400DF
Color_PS_GoldenPoppy equ 0x00C3F3
Color_PS_CelticBlue  equ 0x723F00

Display_Width      equ 320
Display_Height     equ 239
Display_HalfWidth  equ 320 / 2
Display_HalfHeight equ 240 / 2

main:
	reg_io_offset equ rtmp_0
	load_uimm rtmp_0, IO_BASE_ADDR

; Setup Display Control
; 1. GP1: Reset GPU
	load_imm   rtmp_1, gp_Reset                  ; 00 = Reset GPU
	store_word rtmp_1, gpio_port1(reg_io_offset) ; Writing to GP1
; 2. GP1: Display Enable
	load_imm   rtmp_1, gp_DisplayEnabled
	store_word rtmp_1, gpio_port1(reg_io_offset)  ; Write to GP1
; 3. GP1: Dispaly Mode (320x240, 15-bit, NTSC)
	load_imm   rtmp_1, gp_DisplayMode_320x240_15bit_NTSC
	store_word rtmp_1, gpio_port1(reg_io_offset) ; Write to GP1
; 4. GP1: Horizontal Range
	load_imm   rtmp_1, gp_HorizontalDisplayRange_3168_608
	store_word rtmp_1, gpio_port1(reg_io_offset)
; 5. GP1: Vertical Range
	load_imm   rtmp_1, gp_VerticalDisplayRange_264_24
	store_word rtmp_1, gpio_port1(reg_io_offset)
; Setup VRAM Access
; 1. GP0: Drawing mode settings
	load_imm   rtmp_1, gp_ModeSetting_DipArea
	store_word rtmp_1, gpio_port0(reg_io_offset)
; 2. GP0: Drawing area Top-Left
	load_imm   rtmp_1, gp_SetArea_TopLeft | 0 << gp_b10_Y | 0 << gp_b10_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
; 3. GP0: Drawing area Bottom-Right
	load_imm   rtmp_1, gp_SetArea_BottomRight | Display_Height << gp_b10_Y | Display_Width << gp_b10_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
; 4. GP0: Drawing area offset X & Y
	load_imm   rtmp_1, gp_SetOffset | 0 << gp_b10_Y | 0 << gp_b10_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
; Clear the screen
; 1. GP0: Fill rectangle on display area
	load_imm   rtmp_1, gp_RectFillVM | Color_22
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, 0 << gp_b16_Y | 0 << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, Display_Height << gp_b16_Y | Display_Width << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
; Draw a flat-shaded quad
	load_imm   rtmp_1, gp_Quad | Color_PS_CelticBlue
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 *  15 + Display_HalfHeight << gp_b16_Y |    0 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 *  24 + Display_HalfHeight << gp_b16_Y |  100 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 * -30 + Display_HalfHeight << gp_b16_Y | -100 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 * -50 + Display_HalfHeight << gp_b16_Y |   55 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
; Draw a flat-shaded triangle
; 1. GP0: Send packets to GP0 to draw a triangle
	load_imm   rtmp_1, gp_Polygon | Color_PS_GoldenPoppy
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 * 100 + Display_HalfHeight << gp_b16_Y | -100 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 *  20 + Display_HalfHeight << gp_b16_Y |   20 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 *  50 + Display_HalfHeight << gp_b16_Y |   30 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
	; Bonus traingle
	load_imm   rtmp_1, gp_Polygon | Color_PS_CadmiumRed
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 *   50 + Display_HalfHeight << gp_b16_Y | -100 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 *    0 + Display_HalfHeight << gp_b16_Y |   20 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)
	load_imm   rtmp_1, -1 * -100 + Display_HalfHeight << gp_b16_Y |   30 + Display_HalfWidth << gp_b16_X
	store_word rtmp_1, gpio_port0(reg_io_offset)

idle:
	jump idle :: nop

.close
