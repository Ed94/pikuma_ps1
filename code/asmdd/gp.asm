# GPU Registers
.equiv gpio_port0, 0x1810 # 1F801810h-Write GP0: Send GP0 Commands/Packets (Rendering and VRAM Access)
.equiv gpio_port1, 0x1814 # 1F801814h-Write GP1: Send GP1 Commands (Display Control) (and DMA Control)

# GPU Command Format: [7:8] Command (8-bit), [0:6] Paraemter (24-bit)

.equiv gcmd_offset, 24

.equiv gcmd_Reset,       0b000
.equiv gcmd_Polygon,     0b001
.equiv gcmd_Line,        0b010
.equiv gcmd_Rect,        0b011
.equiv gcmd_VM_to_VM,    0b100
.equiv gcmd_CPU_to_VM,   0b101
.equiv gcmd_VM_to_CPU,   0b110
.equiv gcmd_Environment, 0b111

.equiv gcmd_SetDrawMode,          0xE1
.equiv gcmd_SetTextureWindow,     0xE2
.equiv gcmd_SetDrawArea_TopLeft,  0xE3
.equiv gcmd_SetDrawArea_BotRight, 0xE4
.equiv gcmd_SetDrawOffset,        0xE5
.equiv gcmd_SetMaskBit,           0xE6

.equiv gcmd_ResetCommandBuffer,      0x01
.equiv gcmd_AcknowledgeGPUInterrupt, 0x02
.equiv gcmd_DisplayEnable,           0x03
.equiv gcmd_DMA_Request,             0x04
.equiv gcmd_DispArea_Start,          0x05
.equiv gcmd_HorizontalDisplayRange,  0x06
.equiv gcmd_VerticalDisplayRange,    0x07
.equiv gcmd_DisplayMode,             0x08

.equiv gcmd_SetVramSize, 0x09

.equiv gp_Reset, gcmd_Reset << gcmd_offset

# GP1(03h) - Display Enable
# On:  0x0
# Off: 0x1
.equiv gp_DisplayEnabled,  gcmd_DisplayEnable << gcmd_offset | 0x0
.equiv gp_DisplayDisabled, gcmd_DisplayEnable << gcmd_offset | 0x1

# GP1(04h) - DMA Direction / Data Request
# 0-1  DMA Direction (0=Off, 1=FIFO, 2=CPUtoGP0, 3=GPUREADtoCPU) ;GPUSTAT.29-30
# 2-23 Not used (zero)
.equiv gp_DMA_FIFO,       1
.equiv gp_DMA_CPU_to_GPU, 2
.equiv gp_DMA_GPU_to_CPU, 3
.equiv gp_DMA_Request,    gcmd_DMA_Request << gcmd_offset

# GP1(06h) - Horizontal Display range (on Screen)
# X2 = X1 + pixels * cycles_per_pix
# 0  - 11 X1 (260h + 0)       ; 12bit ; \ counted in video clock units,
# 12 - 23 X2 (260h + 320 * 8) ; 12bit ; / relative to HSYNC
.equiv gp_HorizontalDisplayRange_3168_608, gcmd_HorizontalDisplayRange << gcmd_offset | 0xC60 << 12 | 0x260

# GP1(07h) - Vertical Display range (on Screen)
# 0  - 9  Y1 (NTSC = 88h - (240 / 2), (PAL = A3h - (288 / 2))  ; \ scanline numbers on screen,
# 10 - 19 Y2 (NTSC = 88h + (240 / 2), (PAL = A3h + (288 / 2))  ; / relative to VSYNC
# 20 - 23 Not used (zero)
.equiv gp_VerticalDiplayRange,         gcmd_VerticalDisplayRange << gcmd_offset
.equiv gp_VerticalDisplayRange_264_24, gp_VerticalDiplayRange | 264 << 10 | 24
.equiv gp_VerticalDisplayRange_504_24, gp_VerticalDiplayRange | 504 << 10 | 24

# GP1(08h) - Display mode
# 0-1   Horizontal Resolution 1     (0=256, 1=320, 2=512, 3=640) ;GPUSTAT.17-18
# 2     Vertical Resolution         (0=240, 1=480, when Bit5=1)  ;GPUSTAT.19
# 3     Video Mode                  (0=NTSC/60Hz, 1=PAL/50Hz)    ;GPUSTAT.20
# 4     Display Area Color Depth    (0=15bit, 1=24bit)           ;GPUSTAT.21
# 5     Vertical Interlace          (0=Off, 1=On)                ;GPUSTAT.22
# 6     Horizontal Resolution 2     (0=256/320/512/640, 1=368)   ;GPUSTAT.16
# 7     Flip screen horizontally    (0=Off, 1=On, v1 only)       ;GPUSTAT.14
# 8-23  Not used (zero)
.equiv gp_DisplayMode,     0x8 << gcmd_offset
.equiv gp_Disp_HRes_256,   0x0      
.equiv gp_Disp_HRes_320,   0x1      
.equiv gp_Disp_HRes_512,   0x2 
.equiv gp_Disp_HRes_640,   0x3
.equiv gp_Disp_VRes_240,   0x0 << 2 
.equiv gp_Disp_VRes_480,   0x1 << 2
.equiv gp_Disp_Color15,    0x0 << 4
.equiv gp_Disp_Color24,    0x1 << 4
.equiv gp_Disp_VInterlace, 0x1 << 5
.equiv gp_DisplayMode_320x240_15bit_NTSC, gp_DisplayMode | gp_Disp_HRes_320 | gp_Disp_VRes_240 | gp_Disp_Color15
.equiv gp_DisplayMOde_640x480_24bbp_NTSC, gp_DisplayMode | gp_Disp_HRes_640 | gp_Disp_VRes_480 | gp_Disp_Color24 | gp_Disp_VInterlace

# GP0(E1h) - Draw Mode setting (aka "Texpage")
#  0 - 3   Texture page X Base       (N * 64)  (ie. in 64-halfword steps)                       ; GPUSTAT.0-3
#  4       Texture page Y Base 1     (N * 256) (ie. 0, 256, 512 or 768)                         ; GPUSTAT.4
#  5 - 6   Semi-transparency         (0 = B / 2 + F / 2, 1 = B + F, 2 = B - F, 3 = B + F / 4)   ; GPUSTAT.5-6
#  7 - 8   Texture page colors       (0 = 4 bit, 1 = 8bit, 2 = 15bit, 3 = Reserved)             ; GPUSTAT.7-8
#  9       Dither 24bit to 15bit     (0=Off / strip LSBs, 1 = Dither Enabled)                   ; GPUSTAT.9
#  10      Drawing to display area   (0=Prohibited, 1=Allowed)                                  ; GPUSTAT.10
#  11      Texture page Y Base 2     (N * 512) (only for 2 MB VRAM)                             ; GPUSTAT.15
#  12      Textured Rectangle X-Flip (BIOS does set this bit on power-up...?)
#  13      Textured Rectangle Y-Flip (BIOS does set it equal to GPUSTAT.13...?)
#  14 - 23 Not used (should be 0)
#  24 - 31 Command  (E1h)
.equiv gp_SetDisplayMode_DrawAllowed, 10
.equiv gp_SetDisplayMode_DipArea,     gcmd_SetDrawMode << gcmd_offset | 0x1 << gp_SetDisplayMode_DrawAllowed

# GP0(E3h) - Set Drawing Area top left (X1,Y1)
# GP0(E4h) - Set Drawing Area bottom right (X2,Y2)
# Sets the drawing area corners. The Render commands GP0(20h..7Fh) 
# are automatically clipping any pixels that are outside of this region.
# 0  - 9   X-coordinate (0..1023)
# 10 - 18  Y-coordinate (0..511)   ; \ on v0 GPU (max 1 MB VRAM)
# 19 - 23  Not used (zero)         ; /
# 10 - 19  Y-coordinate (0..1023)  ; \ on v2 GPU (max 2 MB VRAM)
# 20 - 23  Not used (zero)         ; /
# 24 - 31  Command  (Exh)
.equiv gp_SetArea_TopLeft,     gcmd_SetDrawArea_TopLeft << gcmd_offset
.equiv gp_SetArea_BottomRight, gcmd_SetDrawArea_BotRight << gcmd_offset

# GP0(E5h) - Set Drawing Offset (X,Y)
# 0-9    X-coordinate (0..1023)
# 10-18  Y-coordinate (0..511)   ;\on v0 GPU (max 1 MB VRAM)
# 19-23  Not used (zero)         ;/
# 10-19  Y-coordinate (0..1023)  ;\on v2 GPU (max 2 MB VRAM)
# 20-23  Not used (zero)         ;/
# 24-31  Command  (Exh)
.equiv gp_SetOffset, gcmd_SetDrawOffset << gcmd_offset

# GPU Memory Transfer Commands

# GP0(02h) Fill Vram
# GP0(02h) - Fill Rectangle in VRAM
# 1st  Color+Command     (CcBbGgRrh)  ;24bit RGB value (see note)
# 2nd  Top Left Corner   (YyyyXxxxh)  ;Xpos counted in halfwords, steps of 10h
# 3rd  Width+Height      (YsizXsizh)  ;Xsiz counted in halfwords, steps of 10h
#  Fills the area in the frame buffer with the value in RGB. 
#  Horizontally the filling is done in 16-pixel (32-bytes) units (see below masking/rounding).
#  The "Color" parameter is a 24bit RGB value, however, the actual fill data is 16bit: 
#  The hardware automatically converts the 24bit RGB value to 15bit RGB (with bit15=0).
#  Fill is NOT affected by the Mask settings (acts as if Mask.Bit0,1 are both zero).
.equiv gp_RectFillVM, 0x02 << gcmd_offset

# GP0(A0h) - Copy Rectangle (CPU to VRAM)
# Transfers data from CPU to frame buffer. 
# If the number of halfwords to be sent is odd, an extra halfword should be sent, 
# as packets consist of 32bits words. The transfer is affected by Mask setting.
# 1st  Command           (Cc000000h)
# 2nd  Destination Coord (YyyyXxxxh)  ;Xpos counted in halfwords
# 3rd  Width+Height      (YsizXsizh)  ;Xsiz counted in halfwords
# ...  Data              (...)      <--- usually transferred via DMA
.equiv gp_Blit_VM_VM,  gcmd_VM_to_VM  << gcmd_offset
.equiv gp_Blit_CPU_VM, gcmd_CPU_to_VM << gcmd_offset
.equiv gp_Blit_VM_CPU, gcmd_VM_to_CPU << gcmd_offset

# GPU Render Polygon Commands

# When the upper 3 bits of the first GP0 command are set to 1 (001), 
# then the command can be decoded using the following bitfield:
# bit number   value   meaning
# 31-29        001     polygon render
# 28           1/0     gouraud / flat shading
# 27           1/0     4 / 3 vertices
# 26           1/0     textured / untextured
# 25           1/0     semi-transparent / opaque
# 24           1/0     raw texture / modulation
# 23-0         rgb     first color value.
.equiv gp_Poly_FirstColor,         0
.equiv gp_Poly_RawTexture,   1 << 24
.equiv gp_Poly_SemiTrans,    1 << 25
.equiv gp_Poly_Textured,     1 << 26
.equiv gp_Poly_Quad,         1 << 27
.equiv gp_Poly_Tri,          0 << 27
.equiv gp_Poly_ShadeFlat,    0 << 28
.equiv gp_Poly_ShadeGourand, 1 << 28
.equiv gp_Polygon,           1 << 29

.equiv gp_Quad, gp_Polygon | gp_Poly_Quad

.equiv gp_b10_X, 0
.equiv gp_b10_Y, 10
.equiv gp_b16_X, 0
.equiv gp_b16_Y, 16

.equiv gp_pixel16, (2 * byte)
.equiv gp_pixel24, (3 * byte)
.equiv gp_vec2,    word

.macro gp_push_pak port, reg_scratch, packet
	load_imm   \reg_scratch, \packet
	store_word \reg_scratch, \port 
.endm
.macro gcmd_push port, reg_scratch, cmd
	load_imm   \reg_scratch, \cmd
	store_word \reg_scratch, \port
.endm
