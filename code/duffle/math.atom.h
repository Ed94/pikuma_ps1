#ifdef INTELLISENSE_DIRECTIVES
#	include "gen/macs.h"
#	include "gen/offsets.h"
#	include "math.h"
#	include "lottes_tape.h"
#endif

ATOM_FILE_DEBUGGER_LINE_MARKER(math_atom_c);

typedef Struct_(Reg_V3_S4) { Reg x, y, z; }; // Register allocation of a V3_S4
typedef Struct_(Reg_P3_S4) { Reg x, y, z; }; // Register allocation of a P3_S4

#pragma region MACs (Mips Atom Component)

FI_ Slice_MipsCode ac_load_v2s2(AtomBuilder_R ab, U4 rs_x, U4 rs_y, U4 r_base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	load_half( rs_x, r_base, offset + O_(V3_S2,x)),
	load_half( rs_y, r_base, offset + O_(V3_S2,y)),
})

FI_ Slice_MipsCode ac_store_v2s2(AtomBuilder_R ab, U4 rt_x, U4 rt_y, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	store_half(rt_x, base, offset + O_(V2_S2,x)),
	store_half(rt_y, base, offset + O_(V2_S2,y)),
})

FI_ Slice_MipsCode ac_load_word_v3(AtomBuilder_R ab, Reg tx, Reg ty, Reg tz, Reg base, U2 offset) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	load_word(tx, base, offset + OA_(U4,[0])),
	load_word(ty, base, offset + OA_(U4,[1])),
	load_word(tz, base, offset + OA_(U4,[2])),
})

FI_ Slice_MipsCode ac_load_v3s4(AtomBuilder_R ab, Reg_(V3_S4) transfer, Reg base, U2 offset) MipsAtomComp_ProcMap_(ab, mac_load_word_v3(transfer.x, transfer.y, transfer.z, base, offset))
FI_ Slice_MipsCode ac_load_p3s4(AtomBuilder_R ab, Reg_(P3_S4) transfer, Reg base, U2 offset) MipsAtomComp_ProcMap_(ab, mac_load_word_v3(transfer.x, transfer.y, transfer.z, base, offset))

FI_ Slice_MipsCode ac_store_word_v3(AtomBuilder_R ab, U4 tx, U4 ty, U4 tz, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	store_word(tx, base, offset + OA_(U4,[0])),
	store_word(ty, base, offset + OA_(U4,[1])),
	store_word(tz, base, offset + OA_(U4,[2])),
})

FI_ Slice_MipsCode ac_store_v3s4(AtomBuilder_R ab, Reg_(V3_S4) transfer, Reg base, U2 offset) MipsAtomComp_ProcMap_(ab, mac_store_word_v3(transfer.x, transfer.y, transfer.z, base, offset))
FI_ Slice_MipsCode ac_store_p3s4(AtomBuilder_R ab, Reg_(P3_S4) transfer, Reg base, U2 offset) MipsAtomComp_ProcMap_(ab, mac_store_word_v3(transfer.x, transfer.y, transfer.z, base, offset))

FI_ Slice_MipsCode ac_add_si_v3s4(AtomBuilder_R ab, Reg rt_x,  Reg rt_y,  Reg rt_z, Reg base, U2 offset)
atom_dbg_skip MipsAtomComp_Proc_(ab, {
	add_si(rt_x, base, O_(V3_S4,x)),
	add_si(rt_y, base, O_(V3_S4,y)),
	add_si(rt_z, base, O_(V3_S4,z)),
})

FI_ Slice_MipsCode ac_sub_v3s4(AtomBuilder_R ab, U4 rds_x, U4 rds_y, U4 rds_z, U4 rt_x,  U4 rt_y,  U4 rt_z) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	sub_s(rds_x, rds_x, rt_x),
	sub_s(rds_y, rds_y, rt_y),
	sub_s(rds_z, rds_z, rt_z),
})

FI_ Slice_MipsCode ac_store_rects2(AtomBuilder_R ab, U4 rt_x, U4 rt_y, U4 rt_width, U4 rt_height, U4 base, U4 offset) atom_dbg_skip MipsAtomComp_Proc_(ab, {
	store_half(rt_x,      base, offset + O_(Rect_S2,x)),
	store_half(rt_y,      base, offset + O_(Rect_S2,y)),
	store_half(rt_width,  base, offset + O_(Rect_S2,width)),
	store_half(rt_height, base, offset + O_(Rect_S2,height)),
})

#pragma endregion MACs (Mips Atom Component)
