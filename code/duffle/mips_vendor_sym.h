/* ============================================================================
 *  duffle DSL — MIPS Vendor Mnemonics (opt-in)
 *  ============================================================================
 *
 *  Provides the textbook MIPS assembly mnemonics as thin aliases to the canonical duffle macros in mips.h.
 *  The duffle names are primary; this header is for users who prefer the textbook mnemonics.
 *
 *  USAGE:   #include "duffle/mips_vendor_sym.h"   // after mips.h
 *
 *  Mapping (vendor -> duffle):
 *    Shift family:
 *      sll  -> shift_lleft      (shift left logical)
 *      srl  -> shift_lright     (shift right logical)
 *      sra  -> shift_aright     (shift right arithmetic)
 *      (no sllv/srlv/srav; the shift macros take a literal shamt)
 *
 *    Jump family (1-arg / implicit-rd forms):
 *      jr   -> jump_reg         (jump register)
 *      j    -> jump              (jump to immediate address)
 *      jal  -> call_addr         (jump-and-link to immediate address)
 *      jalr -> call_reg          (jump-and-link to register, default $ra)
 *      (for the 2-arg `jalr rs, rd`, use `jump_link(rs, rd)` directly)
 * ============================================================================ */

#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "mips.h"
#endif

#ifndef DUFFLE_MIPS_VENDOR_SYM_H
#define DUFFLE_MIPS_VENDOR_SYM_H

/* Shift family */
#define sll  shift_lleft
#define srl  shift_lright
#define sra  shift_aright

/* Jump family (1-arg / implicit-$ra forms) */
#define jr   jump_reg
#define j    jump
#define jal  call_addr
#define jalr call_reg

#endif
