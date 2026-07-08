// tape_atom.metadata.h
// Single source of truth for instruction-word counts.
// Used by C (to define compile-time constants) AND Python (to count positions).
//
// Format: WORD_COUNT(MACRO_NAME, COUNT)
// One line per macro that appears in your atom sources.
//
// To regenerate: hand-count the instructions in each macro definition.
// (You'll only need to do this once per macro — they don't change often.)
#define WORD_COUNT(name, count)  enum { words_##name = (count) };

WORD_COUNT(nop,                              1)
WORD_COUNT(load_upper_i,                     1)
WORD_COUNT(jump_reg,                         1)
WORD_COUNT(jump_link,                        1)
WORD_COUNT(call_reg,                         1)
WORD_COUNT(call_addr,                        1)
WORD_COUNT(branch_le_zero,                   1)
WORD_COUNT(branch_equal,                     1)
WORD_COUNT(add_ui,                           1)
WORD_COUNT(set_lt_u,                          1)
WORD_COUNT(set_lt_s,                          1)
WORD_COUNT(set_lt_si,                         1)
WORD_COUNT(set_lt_ui,                         1)
WORD_COUNT(load_ui,                          1)
WORD_COUNT(load_word,                        1)
WORD_COUNT(load_half_u,                      1)
WORD_COUNT(store_word,                       1)
WORD_COUNT(add_ui_self,                      1)
WORD_COUNT(add_u_self,                       1)
WORD_COUNT(add_u,                            1)
WORD_COUNT(or_i,                             1)
WORD_COUNT(or_u,                             1)
WORD_COUNT(shift_lleft,                      1)
WORD_COUNT(shift_lright,                     1)
WORD_COUNT(shift_aright,                     1)
WORD_COUNT(mask_upper,                       2)
WORD_COUNT(gte_mf,                           1)
WORD_COUNT(gte_mt,                           1)
WORD_COUNT(gte_ct,                           1)
WORD_COUNT(gte_sw,                           1)
WORD_COUNT(gte_cmdw_rtpt,                    1)
WORD_COUNT(gte_cmdw_nclip,                   1)
WORD_COUNT(gte_avg_sort_z3,                  1)
WORD_COUNT(mac_load_tri_indices,             3)
WORD_COUNT(mac_load_tri_verts,              18)
WORD_COUNT(mac_format_f3_color,              3)
WORD_COUNT(mac_gte_store_f3,                 3)
WORD_COUNT(mac_insert_ot_tag,               11)
WORD_COUNT(mac_yield,                        4)

#undef WORD_COUNT
