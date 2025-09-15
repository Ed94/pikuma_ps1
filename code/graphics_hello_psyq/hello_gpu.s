// .include "./toolchain/pcsx-redux/src/mips/common/crt0/crt0.s"

.include "./asmdd/dsl.s"
.include "./asmdd/math.s"
.include "./asmdd/io.s"
.include "./asmdd/gp.s"

# DrawEnv_Packed { U32 tag; U32 code[15]; }
.equ DrawEnv_Packed_tag,  0
.equ DrawEnv_Packed_code, DrawEnv_Packed_tag + U32
.equ DrawEnv_Packed,      64
# DrawEnv { Rect_S16 clip; Vec_2S16 ofs; Rect_S16 tw; U16 tpage; U8 dtd; U8 dfe; U8 tme; U8 r0,g0,b0; DR_ENV dr_env; }
.equ DrawEnv_clip_area,             /* 0  */ Rect_S16       * 0
.equ DrawEnv_drawing_offset,        /* 8  */ A2_S16         * 0 + Rect_S16
.equ DrawEnv_texture_window,        /* 12 */ Rect_S16       * 0 + A2_S16   + DrawEnv_drawing_offset
.equ DrawEnv_texture_page,          /* 20 */ S16            * 0 + Rect_S16 + DrawEnv_texture_window
.equ DrawEnv_flag_dither,           /* 22 */ byte           * 0 + S16      + DrawEnv_texture_page
.equ DrawEnv_flag_draw_on_display,  /* 23 */ byte           * 0 + byte     + DrawEnv_flag_dither
.equ DrawEnv_enable_auto_clear,     /* 24 */ byte           * 0 + byte     + DrawEnv_flag_draw_on_display
.equ DrawEnv_initial_bg_color,      /* 25 */ RGB8           * 0 + byte     + DrawEnv_enable_auto_clear
.equ DrawEnv_dr_env,                /* 28 */ DrawEnv_Packed * 0 + RGB8     + DrawEnv_initial_bg_color
.equ DrawEnv,                       /* 92 */ DrawEnv_dr_env + DrawEnv_Packed
# DisplayEnv { Rect_S16 disp; Rect_S16 screen; U8 isinter; U8 isrgb24; U8 pad[2]; }
.equ DisplayEnv_display_area, Rect_S16 * 0
.equ DisplayEnv_screen,       Rect_S16 * 0 + Rect_S16 + DisplayEnv_display_area
.equ DisplayEnv_vinterlace,   byte     * 0 + Rect_S16 + DisplayEnv_screen
.equ DisplayEnv_color24,      byte     * 0 + byte     + DisplayEnv_vinterlace
.equ DisplayEnv_pad0,         byte     * 0 + byte     + DisplayEnv_color24
.equ DisplayEnv_pad1,         byte     * 0 + byte     + DisplayEnv_pad0
.equ DisplayEnv,              DisplayEnv_pad1 + byte
# DoubleBuffer { DrawEnv draw[2]; DisplayEnv display[2]; }
.equ DoubleBuffer_draw,      0
.equ DoubleBuffer_draw_0,    (DrawEnv    * 0)
.equ DoubleBuffer_draw_1,    (DrawEnv    * 1)
.equ DoubleBuffer_display,   (DrawEnv    * 2)
.equ DoubleBuffer_display_0, (DisplayEnv * 0) + DoubleBuffer_display
.equ DoubleBuffer_display_1, (DisplayEnv * 1) + DoubleBuffer_display
.equ DoubleBuffer,           (DisplayEnv * 2) + DoubleBuffer_display
# Screen Constants
.equ ScreenRes_X,       320
.equ ScreenRes_Y,       240
.equ ScreenRes_CenterX, (ScreenRes_X >> 1)
.equ ScreenRes_CenterY, (ScreenRes_Y >> 1)

.equ SMemory_screen_buf,        DoubleBuffer * 0
.equ SMemory_active_screen_buf, S16          * 0 + DoubleBuffer

.equ CF_Shadow, 16

.extern ResetGraph
.equ ResetGraph_mode, rarg_0

.extern SetDispMask
.equ SetDispMask_mask, rarg_0

.extern PutDispEnv
.extern PutDrawEnv
.equ PutDispEnv_env, rarg_0
.equ PutDrawEnv_env, rarg_0

.extern SetDefDispEnv
.equ SetDefDispEnv_env, rarg_0
.equ SetDefDispEnv_x,   rarg_1
.equ SetDefDispEnv_y,   rarg_2
.equ SetDefDispEnv_w,   rarg_3
.equ SetDefDispEnv_h,   CF_Shadow
.set SetDefDispEnv_sp_size, CF_Shadow + S32

.extern SetDefDrawEnv
.equ SetDefDrawEnv_env, rarg_0
.equ SetDefDrawEnv_x,   rarg_1
.equ SetDefDrawEnv_y,   rarg_2
.equ SetDefDrawEnv_w,   rarg_3
.equ SetDefDrawEnv_h,   CF_Shadow
.set SetDefDrawEnv_sp_size, CF_Shadow + S32

.extern SetGeomOffset
.equ SetGeomOffset_x, rarg_0
.equ SetGeomOffset_y, rarg_1

.extern SetGeomScreen
.equ SetGeomScreen_h, rarg_0

.global gp_screen_init_asm
.type gp_screen_init_asm, @function
gp_screen_init_asm:
	.equiv rio_offset, rtmp_0
	load_imm rtmp_0, IO_BASE_ADDR
	#define gp0 gpio_port0(rio_offset)
	#define gp1 gpio_port1(rio_offset)

	def_cf_sp_size 0x18; // Should be enough for all calls within this proc, for some reason SetDefDispEnv needs the offset to be CF_Shadow..
	stack_alloc cf_ssize
	store_word rret_addr, 0($sp)

	// Note(Ed): Cannot be used psyq manages things related to vblank and other things so the api must be called instead
	// gcmd_push gp1, rtmp_1, gp_Reset          // ResetGraph(0)
	// gcmd_push gp1, rtmp_1, gp_DisplayEnabled // SetDispMask(1)
	load_imm ResetGraph_mode,  gp_Reset; jump_nlink ResetGraph
	load_imm SetDispMask_mask, 1;        jump_nlink SetDispMask

		// First buffer area
			load_addr rtmp_0, static_mem; add_ui SetDefDispEnv_env, rtmp_0, SMemory_screen_buf + DoubleBuffer_display_0
			move      SetDefDispEnv_x, $zero
			move      SetDefDispEnv_y, $zero 
			load_imm  SetDefDispEnv_w, ScreenRes_X
			load_imm  rtmp_0, ScreenRes_Y; store_word rtmp_0, SetDefDispEnv_h($sp)
		jump_nlink SetDefDispEnv
			load_addr rtmp_0, static_mem; add_ui SetDefDrawEnv_env, rtmp_0, SMemory_screen_buf + DoubleBuffer_draw_0
			move      SetDefDrawEnv_x, $zero
			load_imm  SetDefDrawEnv_y, ScreenRes_Y
			load_imm  SetDefDrawEnv_w, ScreenRes_X
			load_imm  rtmp_0, ScreenRes_Y; store_word rtmp_0, SetDefDrawEnv_h($sp)
		jump_nlink SetDefDrawEnv
		// Second buffer area
			load_addr rtmp_0, static_mem; add_ui SetDefDispEnv_env, rtmp_0, SMemory_screen_buf + DoubleBuffer_display_1
			move      SetDefDispEnv_x, $zero
			load_imm  SetDefDispEnv_y, ScreenRes_Y
			load_imm  SetDefDispEnv_w, ScreenRes_X
			load_imm  rtmp_0, ScreenRes_Y; store_word rtmp_0, SetDefDispEnv_h($sp)
		jump_nlink SetDefDispEnv
			load_addr rtmp_0, static_mem; add_ui SetDefDrawEnv_env, rtmp_0, SMemory_screen_buf + DoubleBuffer_draw_1
			move      SetDefDrawEnv_x, $zero
			move      SetDefDrawEnv_y, $zero 
			load_imm  SetDefDrawEnv_w, ScreenRes_X
			load_imm  rtmp_0, ScreenRes_Y; store_word rtmp_0, SetDefDrawEnv_h($sp)
		jump_nlink SetDefDrawEnv

	// Set the back/drawing buffer
	load_imm   rtmp_1, true
	load_addr  rtmp_0, static_mem; // At SMemory_screen_buf
	store_word rtmp_1, DoubleBuffer_draw_0 + DrawEnv_enable_auto_clear(rtmp_0)
	store_word rtmp_1, DoubleBuffer_draw_1 + DrawEnv_enable_auto_clear(rtmp_0)

	// Set background clear color
	move rtmp_1, $zero; load_imm rtmp_2, 63; load_imm rtmp_3, 127
	// 63, 0, 127
	store_byte rtmp_2, DoubleBuffer_draw_0 + DrawEnv_initial_bg_color + RGB8_r(rtmp_0)
	store_byte rtmp_1, DoubleBuffer_draw_0 + DrawEnv_initial_bg_color + RGB8_g(rtmp_0)
	store_byte rtmp_3, DoubleBuffer_draw_0 + DrawEnv_initial_bg_color + RGB8_b(rtmp_0)
	// 127, 63, 0
	store_byte rtmp_3, DoubleBuffer_draw_1 + DrawEnv_initial_bg_color + RGB8_r(rtmp_0)
	store_byte rtmp_2, DoubleBuffer_draw_1 + DrawEnv_initial_bg_color + RGB8_g(rtmp_0)
	store_byte rtmp_1, DoubleBuffer_draw_1 + DrawEnv_initial_bg_color + RGB8_b(rtmp_0)
	load_addr  rtmp_0, static_mem; store_word rtmp_1, SMemory_active_screen_buf(rtmp_0)

		load_addr rtmp_1, static_mem; load_half rtmp_1, SMemory_active_screen_buf(rtmp_1); // rtmp_1  = active_screen_buffer
		load_imm  rtmp_2, DisplayEnv; mult_u rtmp_1, rtmp_2; mov_from_low rtmp_2           // rtmp_2  = DisplayEnv.type_size * active_screen_Buffer (rtmp_1)
		add_ui    rtmp_2, rtmp_2, DoubleBuffer_display                                     // rtmp_2 += DoubleBuffer.display
		load_addr rtmp_0, static_mem; add_u PutDispEnv_env, rtmp_0, rtmp_2                 // rarg_0  = rtmp_0 (screen_buffer) + rtmp_2 (.display[active_screen-buffer])
	jump_nlink PutDispEnv
		load_addr rtmp_1, static_mem; load_half rtmp_1, SMemory_active_screen_buf(rtmp_1);
		load_imm  rtmp_2, DrawEnv; mult_u rtmp_1, rtmp_2; mov_from_low rtmp_2;
		add_ui rtmp_2, rtmp_2, DoubleBuffer_draw
		load_addr rtmp_0, static_mem; add_u PutDrawEnv_env, rtmp_0, rtmp_2
	jump_nlink PutDrawEnv

	// Initialize and setup the GTE geometry offsets
	jump_nlink InitGeom
		load_imm SetGeomOffset_x, ScreenRes_CenterX
		load_imm SetGeomOffset_y, ScreenRes_CenterY
	jump_nlink SetGeomOffset
		load_imm SetGeomScreen_h, ScreenRes_CenterX
	jump_nlink SetGeomScreen

	load_word     rret_addr, 0($sp)
	stack_release cf_ssize
	jump_reg rret_addr;
.Lgp_screen_init_end:
.size gp_screen_init_asm, . - gp_screen_init_asm
