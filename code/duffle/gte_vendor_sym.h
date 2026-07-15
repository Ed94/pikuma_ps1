/* ============================================================================
 *  duffle DSL — GTE Vendor Mnemonics (opt-in)
 *  ============================================================================
 *
 *  Provides the textbook MIPS assembly mnemonics for the GTE/COP2 instructions as thin aliases to the canonical duffle macros in gte.h.
 *  The duffle names are primary; this header is for users who prefer the textbook mnemonics.
 *
 *  USAGE:   #include "duffle/gte_vendor_sym.h"   // after gte.h
 *
 *  Mapping (vendor -> duffle):
 *    Transfers (move GPR <-> GTE control/data register):
 *      gte_mfc2  -> gte_mv_from_data_r   (move from coprocessor 2 data reg)
 *      gte_mtc2  -> gte_mv_to_data_r     (move to coprocessor 2 data reg)
 *      gte_cfc2  -> gte_mv_from_ctrl_r   (move from coprocessor 2 control reg)
 *      gte_ctc2  -> gte_mv_to_ctrl_r     (move to coprocessor 2 control reg)
 *
 *    Data load/store (load/store word to coprocessor 2 data register):
 *      gte_lwc2(rt, base, off)  -> gte_lw(rt, base, off)
 *      gte_swc2(rt, base, off)  -> gte_sw(rt, base, off)
 *      (the lower-level vector variants gte_lw_v0_xy etc. don't have
 *      vendor mnemonics; they're already gte_-prefixed and short)
 * ============================================================================ */

#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "gte.h"
#endif

#ifndef DUFFLE_GTE_VENDOR_SYM_H
#define DUFFLE_GTE_VENDOR_SYM_H

/* Transfers (move GPR <-> GTE control/data register) */
#define gte_mfc2(rt, rd)  gte_mv_from_data_r((rt), (rd))
#define gte_mtc2(rt, rd)  gte_mv_to_data_r((rt), (rd))
#define gte_cfc2(rt, rd)  gte_mv_from_ctrl_r((rt), (rd))
#define gte_ctc2(rt, rd)  gte_mv_to_ctrl_r((rt), (rd))

/* Data load/store (load/store word to coprocessor 2 data register) */
#define gte_lwc2(rt, base, off)  gte_lw((rt), (base), (off))
#define gte_swc2(rt, base, off)  gte_sw((rt), (base), (off))

#endif
