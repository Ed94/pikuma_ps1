/* ============================================================================
 *  duffle DSL — GPU Vendor Mnemonics (opt-in)
 *  ============================================================================
 *
 *  Provides the PSYQ-style CamelCase aliases for the canonical duffle GPU
 *  primitive setters and OT operations. The duffle snake_case names are
 *  primary; this header is for users who prefer the PSYQ SDK function
 *  names from the legacy C API.
 *
 *  USAGE:   #include "duffle/gp_vendor_sym.h"   // after gp.h
 *
 *  Mapping (vendor -> duffle):
 *    Primitive setters (PSYQ SDK-style):
 *      setPolyF3  -> set_poly_f3
 *      setPolyF4  -> set_poly_f4
 *      setPolyG3  -> set_poly_g3
 *      setPolyG4  -> set_poly_g4
 *      setPolyFT3 -> set_poly_ft3
 *      setPolyFT4 -> set_poly_ft4
 *      setPolyGT3 -> set_poly_gt3
 *      setPolyGT4 -> set_poly_gt4
 *
 *    OT operations:
 *      AddPrim(ot, p)  -> orderingtbl_add_primitive(ot, p)
 *
 *  The gp0_cmd_* / gp1_cmd_* byte constants are already short and
 *  descriptive; no vendor alias is provided for them.
 *
 *  The vendor mnemonics are NOT registered with the duffle word-count
 *  metadata (word_counts.metadata.h). They expand to the duffle canonical
 *  macros which DO have word-count entries (the ones emitted by
 *  mac_format_f3_color / mac_gte_store_f3 / etc.). Verification: V13
 *  (objdump byte-identical) holds.
 *
 * ============================================================================ */

#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "gp.h"
#endif

#ifndef DUFFLE_GP_VENDOR_SYM_H
#define DUFFLE_GP_VENDOR_SYM_H

/* Primitive setters (PSYQ SDK-style) */
#define setPolyF3(p)    set_poly_f3(p)
#define setPolyF4(p)    set_poly_f4(p)
#define setPolyG3(p)    set_poly_g3(p)
#define setPolyG4(p)    set_poly_g4(p)
#define setPolyFT3(p)   set_poly_ft3(p)
#define setPolyFT4(p)   set_poly_ft4(p)
#define setPolyGT3(p)   set_poly_gt3(p)
#define setPolyGT4(p)   set_poly_gt4(p)

/* OT operations */
#define AddPrim(ot, p)  orderingtbl_add_primitive((ot), (p))

#endif
