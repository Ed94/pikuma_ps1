; IO PORT
IO_BASE_ADDR equ 0x1F80 ; IO Ports Memory map base address

; GPU Registers
gpio_port0 equ 0x1810 ; 1F801810h-Write GP0: Send GP0 Commands/Packets (Rendering and VRAM Access)
gpio_port1 equ 0x1814 ; 1F801814h-Write GP1: Send GP1 Commands (Display Control) (and DMA Control)

; GPU Command Format: [7:8] Command (8-bit), [0:6] Paraemter (24-bit)

gcmd_offset equ 24

gp_Reset equ 0x0 << gcmd_offset

; GP1(03h) - Display Enable
; On:  0x0
; Off: 0x1
gp_DisplayEnabled  equ 0x03 << gcmd_offset | 0x0
gp_DisplayDisabled equ 0x03 << gcmd_offset | 0x1

; GP1(04h) - DMA Direction / Data Request
; 0-1  DMA Direction (0=Off, 1=FIFO, 2=CPUtoGP0, 3=GPUREADtoCPU) ;GPUSTAT.29-30
; 2-23 Not used (zero)
gp_DMA_FIFO        equ 1
gp_DMA_CPU_to_GPU  equ 2
gp_DMA_GPU_to_CPU  equ 3
gp_DMA_Request     equ 0x04 << gcmd_offset

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
; Sets the drawing area corners. The Render commands GP0(20h..7Fh) 
; are automatically clipping any pixels that are outside of this region.
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

; GP0(A0h) - Copy Rectangle (CPU to VRAM)
; Transfers data from CPU to frame buffer. 
; If the number of halfwords to be sent is odd, an extra halfword should be sent, 
; as packets consist of 32bits words. The transfer is affected by Mask setting.
; 1st  Command           (Cc000000h)
; 2nd  Destination Coord (YyyyXxxxh)  ;Xpos counted in halfwords
; 3rd  Width+Height      (YsizXsizh)  ;Xsiz counted in halfwords
; ...  Data              (...)      <--- usually transferred via DMA
gp_Blit_VM_VM  equ 0x80 << gcmd_offset
gp_Blit_CPU_VM equ 0xA0 << gcmd_offset
gp_Blit_VM_CPU equ 0xC0 << gcmd_offset

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

gp_pixel equ (2 * byte)
gp_vec2  equ word

.macro gp_push_pak, port, reg_scratch, packet
	load_imm   reg_scratch, packet
	store_word reg_scratch, port 
.endmacro
.macro gcmd_push, port, reg_scratch, cmd
	load_imm   reg_scratch, cmd
	store_word reg_scratch, port 
.endmacro

.org 0x80010000 + 3000

.func gp_draw_tri_flat ;(
	gp_draw_tri_flat__sp_size equ (3 * gp_vec2)
	@@io_offset equ rarg_0 ; io_offset: word
	@@color     equ rarg_1 ; color:     word
	@@verts     equ $sp    ; verts:     [3]gp_vec2
;)
	@@vert_id equ rtmp_1
	@@cmd     equ rtmp_2
	load_imm   @@cmd, gp_Polygon
	or         @@cmd, @@cmd, @@color
	store_word @@cmd, gpio_port0(@@io_offset)
	load_word  @@vert_id, 0 * gp_vec2(@@verts) :: nop :: store_word @@vert_id, gpio_port0(@@io_offset)
	load_word  @@vert_id, 1 * gp_vec2(@@verts) :: nop :: store_word @@vert_id, gpio_port0(@@io_offset)
	load_word  @@vert_id, 2 * gp_vec2(@@verts) :: nop :: store_word @@vert_id, gpio_port0(@@io_offset)
	jump_reg rret_addr :: nop
.endfunc

.func gp_draw_tri_gouraud ;(
	@@io_offset equ rarg_0
	@@color     equ rarg_1
	@@color_2   equ rstatic_1
	@@color_3   equ rstatic_2
	@@vert_1    equ rarg_2
	@@vert_2    equ rarg_3
	@@vert_3    equ rstatic_0
;)
	@@cmd equ rtmp_2
	load_imm @@cmd, gp_Polygon | gp_Poly_ShadeGourand
	or       @@cmd, @@cmd, @@color
	store_word @@cmd,     gpio_port0(@@io_offset)
	store_word @@vert_1,  gpio_port0(@@io_offset)
	store_word @@color_2, gpio_port0(@@io_offset)
	store_word @@vert_2,  gpio_port0(@@io_offset)
	store_word @@color_3, gpio_port0(@@io_offset)
	store_word @@vert_3,  gpio_port0(@@io_offset)
	jump_reg rret_addr :: nop
.endfunc
