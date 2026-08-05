#ifdef INTELLISENSE_DIRECTIVES
#	include "gen/macs.h"
#	include "gen/offsets.h"
#	include "math.h"
#	include "lottes_tape.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(math_atom_c);

#pragma region MACs (Mips Atom Component)

FI_ Slice_MipsCode ac_load_v2s2(U4 rs_x, U4 rs_y, U4 r_base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_load_v2s2, {
	load_half( rs_x, r_base, O_(V3_S2,x)),
	load_half( rs_y, r_base, O_(V3_S2,y)),
})

FI_ Slice_MipsCode ac_store_v2s2(U4 rt_x, U4 rt_y, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_store_v2s2, {
	store_half(rt_x, base, offset + O_(V2_S2,x)),
	store_half(rt_y, base, offset + O_(V2_S2,y)),
})

FI_ Slice_MipsCode ac_store_rects2(U4 rt_x, U4 rt_y, U4 rt_width, U4 rt_height, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_store_rects2, {
	store_half(rt_x,      base, offset + O_(Rect_S2,x)),
	store_half(rt_y,      base, offset + O_(Rect_S2,y)),
	store_half(rt_width,  base, offset + O_(Rect_S2,width)),
	store_half(rt_height, base, offset + O_(Rect_S2,height)),
})

#pragma endregion MACs (Mips Atom Component)
