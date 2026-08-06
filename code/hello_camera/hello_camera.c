#pragma region Vendors
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
// #include "libgpu.h"
// #include "libetc.h"
// #include "libgte.h"
#pragma endregion Vendors

#pragma region Duffle Headers
#	include "duffle/gen/macs.h"
#	include "duffle/gen/offsets.h"

#include "duffle/word_count.metadata.h"

#include "duffle/dsl.h"
#include "duffle/memory.h"
#include "duffle/math.h"

#include "duffle/gcc_asm.h"
#include "duffle/mips.h"
#include "duffle/gp.h"
#include "duffle/gte.h"
#include "duffle/pad.h"

#include "duffle/dsl.atom.h"
#include "duffle/lottes_tape.h"

#include "duffle/psyq.h"
#pragma endregion Duffle Headers

#pragma region Duffle TUs
#include "duffle/math.atom.c"
#include "duffle/mips.atom.c"
#include "duffle/gte.atom.c"
#include "duffle/gp.atom.c"
#include "duffle/pad.atom.c"
#include "duffle/psyq.atom.c"
#pragma endregion Duffle TUs

#pragma region Hello Camera Headers
#	include "gen/macs.h"
#	include "gen/offsets.h"

#include "hello_camera.h"
#pragma endregion Hello Camera Headers

#pragma region Hello Joypad TUs
#include "hello_camera.atom.c"
#pragma endregion Hello Joypad TUs

enum { 
	Scratchpad_Len = 1024, 
	MemTape_Len    = 512,
};
typedef Struct_(SMemory) {
	PrimitiveArena          primitives;
	A2_OrderingTable_Buffer ordering_tbl;
	DoubleBuffer            screen_buf;
	S4                      active_buf_id;

	U4 MemTape[MemTape_Len];

	M3_S2 tform_world;

	Ent_Cube  cube;
	Ent_Floor floor;

	PadBiosRaw pad_raw[2];
	PadState   pad[2];

	U4_V scratchpad; // d-cache
};
global SMemory smem;
extern SMemory smem;

I_ B1* prim__alloc(U4 type_width, Str8 type_name) {
	gknown PrimitiveArena* pa  = & smem.primitives;
	gknown B1*             buf = (B1*) r_(smem.primitives.buf)[smem.active_buf_id];
	assert(pa->used + type_width < PrimitiveBuff_Len);
	B1* next  = buf + pa->used;
	pa->used += type_width;
	return next;
}
#define prim_alloc(type) (type*)prim__alloc(S_(type), slit( stringify(type)))

/* Uses ONE 8-byte frame allocated via the compiler's standard prologue.
 * The 4 wasted-arg words for B(12h) InitPAD2 live at [SP+0..15] but are not explicitly allocated.
 * The compiler handles the MIPS O32 "wasted stack" convention for us by treating the B-call as a 4-arg call.
 *
 * The buffer pointers are passed as arguments so the compiler keeps them in callee-saved registers;
 * The B(12h) asm volatile block does NOT clobber those registers (it clobbers only the volatile GPRs + the B-table arg registers explicitly).
 * The C-level writes after the call re-load the pointers from their callee-saved homes.
 *
 * The clobber list for both B-calls names the full BIOS destroy set documented in kernelbios.md:167-174 (R1..R15, R24..R25, R31, HI/LO).
 * The kernel-ABI "volatile GPRs" subset is clb_system; the rest of the destroy set is enumerated explicitly here. */
NI_ void pad_bios_init_start(PadBiosRaw* raw0, PadBiosRaw* raw1)
{
	/* Pin raw0 + raw1 to $a0 + $a1 via rgcc; the B(12h) call uses these directly.
	 * The `(void)` casts mark them as unread after the call so the compiler doesn't need to move them back. */
	register PadBiosRaw* p0 rgcc(R_A0) = raw0;
	register PadBiosRaw* p1 rgcc(R_A1) = raw1;
	(void)p0; (void)p1;

	// TODO(Ed): Properly annotate the raw values in the inline asm instructions.
	// Use enums.

	/* B(12h) InitPAD2(raw0, 0x22, raw1, 0x22)
	 *   $a0 = raw0 (rgcc-bound; survives the sequence below)
	 *   $a1 = raw1 (preserved into $a2 before $a1 is overwritten)
	 *   $a2 = raw1 (moved from $a1; survives $a1's overwrite)
	 *   $a3 = 0x22 (immediate)
	 *   $t1 = 0x12 (function number)
	 *   $t2 = 0xB0 (BIOS B-table address) */
	asm volatile(
		asm_words(
			or_u(    rarg_2, rarg_1, rdiscard), /* $a2 = $a1 = raw1 */
			add_ui(  rarg_1, rdiscard, 0x22),   /* $a1 = 0x22 */
			add_ui(  rarg_3, rdiscard, 0x22),   /* $a3 = 0x22 */
			add_ui(  rtmp_1, rdiscard, 0x12),   /* $t1 = 0x12 */
			add_ui(  rtmp_2, rdiscard, 0xB0),   /* $t2 = 0xB0 */
			call_reg(rtmp_2),                   /* jalr $t2, $ra */
			nop                                 /* BD slot */
		)
		asm_rpins, r_use(p0), r_use(p1)
		asm_clobber: 
			rlit(R_AT), 
			rlit(R_V0), rlit(R_V1), 
			rlit(R_T0), rlit(R_T1), rlit(R_T2), rlit(R_T3), rlit(R_T4),
			rlit(R_T5), rlit(R_T6), rlit(R_T7), rlit(R_T8), rlit(R_T9),
			rlit(R_RA),
			clb_mem_drain
	);

	/* The C-level writes re-load the pointers via the parameter names and write 0xFF to each 
	 * buffer's status byte to mark the initial-state hazard documented in kernelbios.md:1621-1624. */
	u1_v(raw0)[0] = 0xFF;
	u1_v(raw1)[0] = 0xFF;

	/* B(13h) StartPAD2() — no args. The BIOS preserves $sp. */
	asm volatile(
		asm_words(
			add_ui(  rtmp_1, rdiscard, 0x13), /* $t1 = 0x13 */
			add_ui(  rtmp_2, rdiscard, 0xB0), /* $t2 = 0xB0 (re-load) */
			call_reg(rtmp_2),                 /* jalr $t2, $ra */
			nop                               /* BD slot */
		)
		asm_clobber:
			rlit(R_AT),
			rlit(R_V0), rlit(R_V1),
			rlit(R_T0), rlit(R_T1), rlit(R_T2), rlit(R_T3), rlit(R_T4),
			rlit(R_T5), rlit(R_T6), rlit(R_T7), rlit(R_T8), rlit(R_T9),
			rlit(R_RA),
			clb_mem_drain
	);
}

GCC_OPTIMIZATION_DISABLE
void update(PrimitiveArena* pa, U4* ordering_buf) 
{
	TapeBuilder tb = tb_make(slice_ut_arr(smem.MemTape));

	if (1) // Pad Input
	{
		tb.used = 0; tb_scope_run(& tb) {
			/* BIOS-owned polling: per-frame snapshot of both ports. */
			tb_emit_(pad_bios_snapshot);
				tb_data_(raw, & smem.pad_raw[0]);
				tb_data_(state, & smem.pad[0]);
			tb_emit_(pad_bios_snapshot);
				tb_data_(raw,   & smem.pad_raw[1]);
				tb_data_(state, & smem.pad[1]);
			/* Per-frame rotation apply: consume pad[0].buttons + pad[0].left_x */
			tb_emit_(pad_apply_input);
				tb_data_(state,     & smem.pad[0]);
				tb_data_(cube_rot,  & smem.cube.rot);
				tb_data_(floor_rot, & smem.floor.rot);
		}
	}

	orderingtbl_clear_reverse(ordering_buf, OrderingTbl_Len);

	// Update the position based on acceleration and velocity
	gknown V3_S4_R pos = & smem.cube.pos;
	gknown V3_S4_R vel = & smem.cube.vel;
	gknown V3_S4_R acc = & smem.cube.accel;
	add_v3s4(vel, acc[0]);
	add_v3s4_fp(pos, vel[0]);
	// vel->x += acc->x;
	// vel->y += acc->y;
	// vel->z += acc->z;
	// pos->x += vel->x;
	// pos->y += vel->y;
	// pos->z += vel->z;

	if (pos->y + 150 > smem.floor.pos.y) vel->y *= -1;

	// Prep
	S4 nclip = 0;
	S4 orderingtbl_z = 0;
	A2_S2 p;    //???
	S4 flag; //????


	// Draw cube
	if (1)
	{
		m3s2_rotation   (& smem.cube.rot,    & smem.tform_world);
		m3s2_translation(& smem.tform_world, & smem.cube.pos);
		m3s2_scale      (& smem.tform_world, & smem.cube.scale);
		gte_matrix_set_rotation   (& smem.tform_world);
		gte_matrix_set_translation(& smem.tform_world);

		U4 prim_base   = u4_(pa->buf[smem.active_buf_id]);
		U4 prim_cursor = prim_base + pa->used;

		tb.used = 0; tb_scope(& tb) {
			tb_emit(& tb, rbind_cube_g4_face);
				tb_data(& tb, prim_cursor);
				tb_data(& tb, u4_(smem.cube.faces));
				tb_data(& tb, u4_(smem.cube.verts));
				tb_data(& tb, u4_(ordering_buf));

			for (U4 i = 0; i < Cube_num_faces; i++) {
				// Two triangles per quad face: (x,y,z) and (x,z,w)
				tb_emit(& tb, cube_g4_face);
			}

			tb_emit(& tb, sync_primitive_arena);
				tb_data(& tb, u4_(& pa->used));
				tb_data(& tb, prim_base);
		}
		tape_run(tb_slice(tb));

		// smem.cube.rot.y += 30;
	}
	// Draw floor
	if (1)
	{
		m3s2_rotation   (& smem.floor.rot,   & smem.tform_world);
		m3s2_translation(& smem.tform_world, & smem.floor.pos);
		m3s2_scale      (& smem.tform_world, & smem.floor.scale);

		U4 prim_base   = u4_(pa->buf[smem.active_buf_id]);
		U4 prim_cursor = prim_base + pa->used;

		// TODO(Ed): We should do a bounds check beforehand to confirm pa can hold all tris?
		// The tape atoms in-flight should not need to care.

		// Prepare the tape. (Push protocol to tape)
		tb.used = 0; tb_scope(& tb) {
			tb_emit(& tb, set_gte_world);
				tb_data(& tb, u4_(& smem.tform_world));

			tb_emit(& tb, rbind_floor_f3_face);
			// TODO(Ed): Just use a single context struct ref
				tb_data(& tb, prim_cursor);
				tb_data(& tb, u4_(smem.floor.faces));
				tb_data(& tb, u4_(smem.floor.verts));
				tb_data(& tb, u4_(ordering_buf));
			for (U4 i = 0; i < Floor_num_faces; i++) {
				tb_emit(& tb, floor_f3_face);
			}
			// After floor_f3_face iterations complete, the primitive arena's used counter needs updating.
			tb_emit(& tb, sync_primitive_arena);
				tb_data(& tb, u4_(& pa->used));
				tb_data(& tb, prim_base);
		}
		tape_run(tb_slice(tb));// Fire off the tape.

		// C-side state (pa->used) has already been updated by the tape!
		// smem.floor.rot.y += 5;
	}
}
GCC_OPTIMIZATION_ENABLE

void render(void) {
}

void gp_display_frame(DoubleBuffer* screen_buf, S4* active_buf_id, U4* ordering_buf, PrimitiveArena* pa) {
	draw_sync(0);
	vsync(0);
	displayenv_put(& r_(screen_buf->display)[active_buf_id[0] ]);
	drawenv_put   (& r_(screen_buf->draw)   [active_buf_id[0] ]);
	{
		draw_orderingtbl(ordering_buf + OrderingTbl_Len - 1);
		pa->used = 0;
	}
	active_buf_id[0] = ! active_buf_id[0]; // Swap current buffer
}

GCC_OPTIMIZATION_DISABLE
void hot_reload_entry(void)
{
	smem.primitives.used = 0;
	while (1) {
		gknown S4* active_buf_id  = & smem.active_buf_id;
		gknown U4* ordering_buf   = r_(smem.ordering_tbl)[active_buf_id[0]];
		gknown PrimitiveArena* pa = & smem.primitives;
		update(pa, ordering_buf);
		render();
		gp_display_frame(& smem.screen_buf, active_buf_id, ordering_buf, pa);
	}
}

int main(void)
{
	smem = (SMemory){0};
	smem.scratchpad = C_(U4_V, 0x1F800000);
	// smem.primitives.used = 0;
	// smem.active_buf_id   = 0;
	/*Persistent Entity Setup*/{
		ent_cube128_init(& smem.cube.verts, & smem.cube.faces); {
			Ent_Cube* cube = & smem.cube;
			cube->rot    = v3s2(0, 0, 0);
			cube->scale  = v3s4_fp_one();
			cube->accel  = v3s4(0, 1, 0);
			cube->pos    = v3s4(0, -400, 1800);
		}
		ent_floor_init(& smem.floor.verts, & smem.floor.faces); {
			Ent_Floor* floor = & smem.floor;
			floor->rot   = v3s2(0, 0, 0);
			floor->pos   = v3s4(0, 450, 1800);
			floor->scale = v3s4_fp_one();
		}
	}
	TapeBuilder tb = tb_make(slice_ut_arr(smem.MemTape)); {
		reset_graph(0);
		/* Direct BIOS: poll both ports during VBlank. */
		pad_bios_init_start(& smem.pad_raw[0], & smem.pad_raw[1]);
		/* Pinned registers for the GPU init atom. */
		register U4*           io_base_addr rgcc(R_IO_BaseAddr) = u4_r(IO_BASE_ADDR);
		register DoubleBuffer* screen_buf   rgcc(R_ScreenBuf)   = & smem.screen_buf;
		tb.used = 0; tb_scope_run(& tb) {
			tb_emit(& tb, screen_env_init);
			tb_emit(& tb, gp_screen_init);
		}
	}
	hot_reload_entry();
	return 0;
}
GCC_OPTIMIZATION_ENABLE
