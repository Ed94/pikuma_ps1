// word_count.metadata.h
// Single source of truth for instruction-word counts.
// Used by C (to define compile-time constants) AND Python (to count positions).
//
// Format: WORD_COUNT(MACRO_NAME, COUNT)
// One line per macro that appears in your atom sources.
//
// This file is encoding-macros-only. 
// The auto-generated component macros (mac_X) live in the source directory's own gen/macs.h (per-directory aggregation; included separately by the unity build).
// The unity build should include THIS file and the .macs.h file in the same TU, with both wrapped 
// (or the include guard order handled) to avoid WORD_COUNT redeclaration.
//
// To regenerate: hand-count the instructions in each macro definition.
// (You'll only need to do this once per macro — they don't change often.)
#define WORD_COUNT(name, count)  enum { words_##name = (count) };

WORD_COUNT(nop,                              1)
WORD_COUNT(atom_label,                        0)
WORD_COUNT(atom_offset,                       0)
WORD_COUNT(load_upper_i,                     1)
WORD_COUNT(jump_reg,                         1)
WORD_COUNT(jump_link,                        1)
WORD_COUNT(call_reg,                         1)
WORD_COUNT(call_addr,                        1)
WORD_COUNT(branch_le_zero,                   1)
WORD_COUNT(branch_equal,                     1)
WORD_COUNT(branch_ne,                        1)
WORD_COUNT(add_ui,                           1)
WORD_COUNT(set_lt_u,                         1)
WORD_COUNT(set_lt_s,                         1)
WORD_COUNT(set_lt_si,                        1)
WORD_COUNT(set_lt_ui,                        1)
WORD_COUNT(load_word,                        1)
WORD_COUNT(load_half_u,                      1)
WORD_COUNT(load_byte_u,                      1)
WORD_COUNT(store_word,                       1)
WORD_COUNT(store_byte,                       1)
WORD_COUNT(add_ui_self,                      1)
WORD_COUNT(add_u_self,                       1)
WORD_COUNT(add_u,                            1)
WORD_COUNT(or_i,                             1)
WORD_COUNT(or_i_self,                        1)
WORD_COUNT(or_u,                             1)
WORD_COUNT(or_u_self,                        1)
WORD_COUNT(nor_u,                            1)
WORD_COUNT(shift_lleft,                      1)
WORD_COUNT(shift_lleft_self,                 1)
WORD_COUNT(shift_lright,                     1)
WORD_COUNT(shift_aright,                     1)
WORD_COUNT(mask_upper,                       2)
WORD_COUNT(gte_mv_from_data_r,               1)
WORD_COUNT(gte_mv_from_ctrl_r,               1)
WORD_COUNT(gte_mv_to_data_r,                 1)
WORD_COUNT(gte_mv_to_ctrl_r,                 1)
WORD_COUNT(gte_sw,                           1)
WORD_COUNT(gte_cmdw_rtpt,                    1)
WORD_COUNT(gte_cmdw_nclip,                   1)
WORD_COUNT(gte_avg_sort_z3,                  1)
WORD_COUNT(gte_cmdw_sqr,                     1)
WORD_COUNT(gte_cmdw_gpf,                     1)
WORD_COUNT(shift_lleft_var,                  1)
WORD_COUNT(shift_aright_var,                 1)
WORD_COUNT(li_s,                             1)
WORD_COUNT(and_i,                            1)
WORD_COUNT(add_si,                           1)
WORD_COUNT(branch_lt_zero,                   1)
WORD_COUNT(sub_s,                            1)
WORD_COUNT(sub_u,                            1)
WORD_COUNT(nop2,                             2)

#undef WORD_COUNT
