// .include "./toolchain/pcsx-redux/src/mips/common/crt0/crt0.s"

.include "./asmdd/dsl.s"
.include "./asmdd/math.s"
.include "./asmdd/io.s"
.include "./asmdd/gp.s"

# DrawEnv_Packed { U32 tag; U32 code[15]; }
.equ DrawEnv_Packed_tag,    0
.equ DrawEnv_Packed_code,   4
.equ sizeof_DrawEnv_Packed, 64
# DrawEnv {
#     Rect_S16 clip_area;
#     A2_S16   drawwing_offset;
#     Rect_S16 texture_page;
#     BYTE     flag_dither;
#     BYTE     flag_draw_on_display;
#     BYTE     enable_auto_clear;
#     RGB8     initial_bg_color;
#     // 2 bytes padding
#     DrawEnv_Packed dr_env;
# };
.equ DrawEnv_clip_area,            0
.equ DrawEnv_drawwing_offset,      8
.equ DrawEnv_texture_page,         12
.equ DrawEnv_flag_dither,          20
.equ DrawEnv_flag_draw_on_display, 21
.equ DrawEnv_enable_auto_clear,    22
.equ DrawEnv_initial_bg_color,     23
.equ DrawEnv_dr_env,               28
.equ sizeof_DrawEnv,               92
# DisplayEnv {
#     Rect_S16 display_area;
#     Rect_S16 screen;
#     BYTE     vinterlace;
#     BYTE     color24;
#     BYTE     pad0;
#     BYTE     pad1;
# };
.equ DisplayEnv_display_area, 0
.equ DisplayEnv_screen,       8
.equ DisplayEnv_vinterlace,   16
.equ DisplayEnv_color24,      17
.equ DisplayEnv_pad0,         18
.equ DisplayEnv_pad1,         19
.equ sizeof_DisplayEnv,       20
# DoubleBuffer {
#     DrawEnv    draw[2];
#     DisplayEnv display[2];
# };
.equ DoubleBuffer_draw,      0
.equ DoubleBuffer_draw_0,    0
.equ DoubleBuffer_draw_1,    92  # 0 + sizeof_DrawEnv
.equ DoubleBuffer_display,   184 # 92 * 2
.equ DoubleBuffer_display_0, 184
.equ DoubleBuffer_display_1, 204 # 184 + sizeof_DisplayEnv
.equ sizeof_DoubleBuffer,    224
# Screen Constants
.equ ScreenRes_X,       320
.equ ScreenRes_Y,       240
.equ ScreenRes_CenterX, (ScreenRes_X >> 2)
.equ ScreenRes_CenterY, (ScreenRes_Y >> 2)


.global gp_screen_init
.type gp_screen_init, @function
gp_screen_init:
	.equiv rio_offset, rtmp_0
	load_imm rtmp_0, IO_BASE_ADDR
	#define gp0 gpio_port0(rio_offset)
	#define gp1 gpio_port1(rio_offset)

	gcmd_push gp1, rtmp_1, gp_Reset
	gcmd_push gp1, rtmp_1, gp_DisplayEnabled
	jump_reg  rret_addr; nop

.Lgp_screen_init_end:
.size gp_screen_init, . - gp_screen_init
