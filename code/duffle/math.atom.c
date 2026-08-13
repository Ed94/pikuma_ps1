#ifdef INTELLISENSE_DIRECTIVES
#	include "gen/macs.h"
#	include "gen/offsets.h"
#	include "math.h"
#	include "lottes_tape.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(math_atom_c);

#pragma region MACs (Mips Atom Component)

FI_ Slice_MipsCode ac_load_v2s2(AtomBuilder_R ab, U4 rs_x, U4 rs_y, U4 r_base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_load_v2s2, ab, {
	load_half( rs_x, r_base, offset + O_(V3_S2,x)),
	load_half( rs_y, r_base, offset + O_(V3_S2,y)),
})

FI_ Slice_MipsCode ac_store_v2s2(AtomBuilder_R ab, U4 rt_x, U4 rt_y, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_store_v2s2, ab, {
	store_half(rt_x, base, offset + O_(V2_S2,x)),
	store_half(rt_y, base, offset + O_(V2_S2,y)),
})

FI_ Slice_MipsCode ac_load_v3s4(AtomBuilder_R ab, U4 rs_x, U4 rs_y, U4 rs_z, U4 r_base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_load_v3s4, ab, {
	load_word( rs_x, r_base, offset + O_(V3_S4,x)),
	load_word( rs_y, r_base, offset + O_(V3_S4,y)),
	load_word( rs_z, r_base, offset + O_(V3_S4,z)),
})
// TODO(Ed): we could generate these mappings properly..
#define ac_load_p3s4 ac_load_v3s4
#define mac_load_p3s4 mac_load_v3s4

FI_ Slice_MipsCode ac_store_v3s4(AtomBuilder_R ab, U4 rt_x, U4 rt_y, U4 rt_z, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_store_v3s4, ab, {
	store_word(rt_x, base, offset + O_(V3_S4,x)),
	store_word(rt_y, base, offset + O_(V3_S4,y)),
	store_word(rt_z, base, offset + O_(V3_S4,z)),
})
// TODO(Ed): we could generate these mappings properly..
#define ac_store_p3s4 ac_store_v3s4
#define mac_store_p3s4 mac_store_v3s4

FI_ Slice_MipsCode ac_sub_v3s4(AtomBuilder_R ab, U4 rds_x, U4 rds_y, U4 rds_z, U4 rt_x,  U4 rt_y,  U4 rt_z) atom_dbg_skip MipsAtomComp_Proc_(ac_sub_v3s4, ab, {
	sub_s(rds_x, rds_x, rt_x),
	sub_s(rds_y, rds_y, rt_y),
	sub_s(rds_z, rds_z, rt_z),
})

FI_ Slice_MipsCode ac_store_rects2(AtomBuilder_R ab, U4 rt_x, U4 rt_y, U4 rt_width, U4 rt_height, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ac_store_rects2, ab, {
	store_half(rt_x,      base, offset + O_(Rect_S2,x)),
	store_half(rt_y,      base, offset + O_(Rect_S2,y)),
	store_half(rt_width,  base, offset + O_(Rect_S2,width)),
	store_half(rt_height, base, offset + O_(Rect_S2,height)),
})

#pragma endregion MACs (Mips Atom Component)
