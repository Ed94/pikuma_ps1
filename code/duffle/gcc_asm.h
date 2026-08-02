#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

/* ============================================================================
 * GCC INLINE ASM STATEMENT DSL
 * ============================================================================
 * A complete GCC inline-asm statement has up to 5 sections separated by `:`
 *   asm volatile ( "code template" : OUTPUTS : INPUTS : CLOBBERS : GOTO_LABELS );
 */

// Below are used purely for annotation.
#define asm_out     // OUTPUTS  section /* cannot be used with asm_words */
#define asm_in      // INPUTS   section /* can be appended onto after asm_words for pinned registers */
#define asm_clobber // CLOBBERS section

// Pinned Registers after asm_words list (Semantic marker)
// We aren't starting a new offical section, its just a continuation of the input section.
//  asm_words(...)            // ".words " code word ids... : : code_words...
//  asm_rpins, r_use(r0), ...  // , pinned registers...
//  asm_clobber: 
#define asm_rpins

/* --- Logic & Control Flow --- */

/* Annotation for the 'Goto' section of 'asm volatile goto'.
 * Allows you to jump from assembly directly to a C label. */
#define asm_goto // Annotate the last `:` in an asm expression.

/* `asm_words(...)` dispatches into `_INL_<count>` to emit up to 99 encoded
 * instruction words. This is the "compiled-instruction" form of `asm_code`.
 *
 * Result is a 2-colon body WITHOUT the final clobber section:
 *   ".word %c0, %c1, ..." : --- empty   --- : "i"(p0), "i"(p1), ...
 *   |------ code --------| |--- outputs ---| |------- inputs -------|
 * 
 * Use it inside `asm volatile( ... )` like so:
 *   asm volatile(
 *       asm_words(w0, w1, w3)
 *       asm_clobber: clobbers
 *   )
 * which expands to:
 *   asm volatile(".word %c0, %c1, %c2" 
 *       asm_out:     // empty outputs
 *       asm_in:      "i"(w0), "i"(w1), "i"(w2)
 *       asm_clobber: "$2", "$8", ...
 *   )
 */
#define asm_words(...) m_expand(glue(GCC_ASM_INL_, GCC_ASM_COUNT_ARGS(__VA_ARGS__))(__VA_ARGS__))
// Very nasty macro expansion. See the Cruft pragma region after all the DSL defines

/* reg_str(n) — Stringify an integer register id into the GCC asm string form (e.g. 12 → "$12").
 * Use this anywhere GCC's parser expects a literal string identifying a register: clobber lists,
 * asm templates, etc. The two-level macro is the standard preprocessor idiom for forcing one level of expansion before stringify —
 * without it, `#n` would stringify the macro name `R_T4` to `"R_T4"` instead of expanding `R_T4` to its value first.
 *
 * For declaring a register variable bound to a specific GPR, use the `rgcc(n)` bundle from gcc_asm.h instead —
 * it adds the `__asm__()` qualifier around the string.
 *
 *   register V3_S2* p0 __asm__(reg_str(R_T4)) = ...;        // verbose
 *   register V3_S2* p0 rgcc(R_T4) = ...;                    // bundled
 *
 *   asm volatile("nop" : : : reg_str(R_RA), "memory");      // clobber list */
#define rlit_stringfy(n)  "$" stringify(n)
#define rlit_tmpl(n)      rlit_stringfy(tmpl(n,Code))
#define rlit(n)           rlit_tmpl(n)

/* ------------------------------------------------------------------------ *
 *  rgcc(n) — GCC-specific bundle for register-variable declarations.
 *
 *  Produces `__asm__(reg_str(tmpl(n, MipsCode)))` at expansion time. 
 *  The `tmpl(n, MipsCode)` indirection derives the preprocessor-visible `_Code`
 *  form from the enum name (which the preprocessor can't expand on its own). 
 *  So a call is:                register V3_S2* p rgcc(R_T4)               = verts[0].ptr;
 *  expands (via tmpl) to:       register V3_S2* p __asm__(rlit(R_T4_Code)) = verts[0].ptr;
 *  which (via reg_str) becomes: register V3_S2* p __asm__("$12")           = verts[0].ptr;
 *
 *  Why bundle the `__asm__()` wrapper?
 *  - The integer R_T4 (= 12, via R_T4_Code) already indicates the register.
 *  - The string "$12" is derived from it via reg_str, so they cannot drift apart.
 *  - Spelling `__asm__(reg_str(R_T4_Code))` at every call site is noise.
 *
 *  tmpl defined in dsl.h (token-paste glue). 
 *  rgcc define here (gcc_asm.h) because the `__asm__` keyword is GCC-specific. 
 *  Anyone porting to a different compiler's asm dialect overrides rgcc,
 *  and the integer→string derivation in rlit can be retargeted in one place.
 *
 *  For clobber lists and asm-template strings, use the bare `rlit(R_T4_Code)`.
 * ------------------------------------------------------------------------ */
#define rgcc(n) __asm__(rlit(n))

/* rgcc_ref(n) — GCC operand-reference form "%N". Not currently used by the placeholder-pun macros
 * (the .word bodies are fully baked at compile time and have no runtime operand references),
 * but kept here for completeness in case a future asm template needs to refer to a runtime input by position.
 * Mirror of rgcc but produces "%N" instead of "$N". */
#define rgcc_ref_(n)   "%" #n
#define rgcc_ref(n)    rgcc_ref_(n)

/* --- Register Constraint Aliases (for Pinned Variables) --- */

#define r_use(var)  "r"(var)         /* General Purpose Register */
#define r_set(var)  "=r"(var)        /* Write-only output */
#define r_mod(var)  "+r"(var)        /* Read-write */
#define r_imm(val)  "i"(val)         /* Immediate / Constant */
/* Memory: Forces GCC to sync the variable to RAM before the asm runs.
 * Essential for DMA buffers or when the hardware reads from memory. */
#define r_mem(var) "m"(var)
#define r_imm(val) "i"(val) /* Immediate: Forces a compile-time constant. */
#define r_fpu(var) "f"(var) /* FPU (PS2/MIPS III/IV): Use for COP1 floating point registers. */
#define r_acc(var) "a"(var) /* Accumulator: Use for HI/LO register results (multiplication/division). */

#define clb_mem_drain "memory"

// C Preprocessor Iterative Expansion Jank
#pragma region Cruft

/* --- 1. The Argument Counter --- */
#define GCC_ASM_COUNT_ARGS_IMPL( \
    _1, _2, _3, _4, _5, _6, _7, _8, _9, _10, \
    _11,_12,_13,_14,_15,_16,_17,_18,_19,_20, \
    _21,_22,_23,_24,_25,_26,_27,_28,_29,_30, \
    _31,_32,_33,_34,_35,_36,_37,_38,_39,_40, \
    _41,_42,_43,_44,_45,_46,_47,_48,_49,_50, \
    _51,_52,_53,_54,_55,_56,_57,_58,_59,_60, \
    _61,_62,_63,_64,_65,_66,_67,_68,_69,_70, \
    _71,_72,_73,_74,_75,_76,_77,_78,_79,_80, \
    _81,_82,_83,_84,_85,_86,_87,_88,_89,_90, \
    _91,_92,_93,_94,_95,_96,_97,_98,_99, N, ...) N

#define GCC_ASM_COUNT_ARGS(...) m_expand(GCC_ASM_COUNT_ARGS_IMPL(__VA_ARGS__, \
    99, 98, 97, 96, 95, 94, 93, 92, 91, 90, \
    89, 88, 87, 86, 85, 84, 83, 82, 81, 80, \
    79, 78, 77, 76, 75, 74, 73, 72, 71, 70, \
    69, 68, 67, 66, 65, 64, 63, 62, 61, 60, \
    59, 58, 57, 56, 55, 54, 53, 52, 51, 50, \
    49, 48, 47, 46, 45, 44, 43, 42, 41, 40, \
    39, 38, 37, 36, 35, 34, 33, 32, 31, 30, \
    29, 28, 27, 26, 25, 24, 23, 22, 21, 20, \
    19, 18, 17, 16, 15, 14, 13, 12, 11, 10, \
    9,  8,  7,  6,  5,  4,  3,  2,  1,  0))

/* --- 2. String Concatenation Helpers --- *
 * NOTE: we use `%0`, `%1`, ... not `%c0`, `%c1`, ... because GCC's asm-parser rejects `%cN` in this position with "invalid use of '%c'".
 * The `%cN` form is for printing *character* constants; for arbitrary integer immediates (the only kind `"i"(...)` produces),
 * the plain `%N` form is the right one. Both expand to the bare immediate.
 */
#define GCC_ASM_W1                  "%0"
#define GCC_ASM_W2   GCC_ASM_W1   ", %1"
#define GCC_ASM_W3   GCC_ASM_W2   ", %2"
#define GCC_ASM_W4   GCC_ASM_W3   ", %3"
#define GCC_ASM_W5   GCC_ASM_W4   ", %4"
#define GCC_ASM_W6   GCC_ASM_W5   ", %5"
#define GCC_ASM_W7   GCC_ASM_W6   ", %6"
#define GCC_ASM_W8   GCC_ASM_W7   ", %7"
#define GCC_ASM_W9   GCC_ASM_W8   ", %8"
#define GCC_ASM_W10  GCC_ASM_W9   ", %9"
#define GCC_ASM_W11  GCC_ASM_W10  ", %10"
#define GCC_ASM_W12  GCC_ASM_W11  ", %11"
#define GCC_ASM_W13  GCC_ASM_W12  ", %12"
#define GCC_ASM_W14  GCC_ASM_W13  ", %13"
#define GCC_ASM_W15  GCC_ASM_W14  ", %14"
#define GCC_ASM_W16  GCC_ASM_W15  ", %15"
#define GCC_ASM_W17  GCC_ASM_W16  ", %16"
#define GCC_ASM_W18  GCC_ASM_W17  ", %17"
#define GCC_ASM_W19  GCC_ASM_W18  ", %18"
#define GCC_ASM_W20  GCC_ASM_W19  ", %19"
#define GCC_ASM_W21  GCC_ASM_W20  ", %20"
#define GCC_ASM_W22  GCC_ASM_W21  ", %21"
#define GCC_ASM_W23  GCC_ASM_W22  ", %22"
#define GCC_ASM_W24  GCC_ASM_W23  ", %23"
#define GCC_ASM_W25  GCC_ASM_W24  ", %24"
#define GCC_ASM_W26  GCC_ASM_W25  ", %25"
#define GCC_ASM_W27  GCC_ASM_W26  ", %26"
#define GCC_ASM_W28  GCC_ASM_W27  ", %27"
#define GCC_ASM_W29  GCC_ASM_W28  ", %28"
#define GCC_ASM_W30  GCC_ASM_W29  ", %29"
#define GCC_ASM_W31  GCC_ASM_W30  ", %30"
#define GCC_ASM_W32  GCC_ASM_W31  ", %31"
#define GCC_ASM_W33  GCC_ASM_W32  ", %32"
#define GCC_ASM_W34  GCC_ASM_W33  ", %33"
#define GCC_ASM_W35  GCC_ASM_W34  ", %34"
#define GCC_ASM_W36  GCC_ASM_W35  ", %35"
#define GCC_ASM_W37  GCC_ASM_W36  ", %36"
#define GCC_ASM_W38  GCC_ASM_W37  ", %37"
#define GCC_ASM_W39  GCC_ASM_W38  ", %38"
#define GCC_ASM_W40  GCC_ASM_W39  ", %39"
#define GCC_ASM_W41  GCC_ASM_W40  ", %40"
#define GCC_ASM_W42  GCC_ASM_W41  ", %41"
#define GCC_ASM_W43  GCC_ASM_W42  ", %42"
#define GCC_ASM_W44  GCC_ASM_W43  ", %43"
#define GCC_ASM_W45  GCC_ASM_W44  ", %44"
#define GCC_ASM_W46  GCC_ASM_W45  ", %45"
#define GCC_ASM_W47  GCC_ASM_W46  ", %46"
#define GCC_ASM_W48  GCC_ASM_W47  ", %47"
#define GCC_ASM_W49  GCC_ASM_W48  ", %48"
#define GCC_ASM_W50  GCC_ASM_W49  ", %49"
#define GCC_ASM_W51  GCC_ASM_W50  ", %50"
#define GCC_ASM_W52  GCC_ASM_W51  ", %51"
#define GCC_ASM_W53  GCC_ASM_W52  ", %52"
#define GCC_ASM_W54  GCC_ASM_W53  ", %53"
#define GCC_ASM_W55  GCC_ASM_W54  ", %54"
#define GCC_ASM_W56  GCC_ASM_W55  ", %55"
#define GCC_ASM_W57  GCC_ASM_W56  ", %56"
#define GCC_ASM_W58  GCC_ASM_W57  ", %57"
#define GCC_ASM_W59  GCC_ASM_W58  ", %58"
#define GCC_ASM_W60  GCC_ASM_W59  ", %59"
#define GCC_ASM_W61  GCC_ASM_W60  ", %60"
#define GCC_ASM_W62  GCC_ASM_W61  ", %61"
#define GCC_ASM_W63  GCC_ASM_W62  ", %62"
#define GCC_ASM_W64  GCC_ASM_W63  ", %63"
#define GCC_ASM_W65  GCC_ASM_W64  ", %64"
#define GCC_ASM_W66  GCC_ASM_W65  ", %65"
#define GCC_ASM_W67  GCC_ASM_W66  ", %66"
#define GCC_ASM_W68  GCC_ASM_W67  ", %67"
#define GCC_ASM_W69  GCC_ASM_W68  ", %68"
#define GCC_ASM_W70  GCC_ASM_W69  ", %69"
#define GCC_ASM_W71  GCC_ASM_W70  ", %70"
#define GCC_ASM_W72  GCC_ASM_W71  ", %71"
#define GCC_ASM_W73  GCC_ASM_W72  ", %72"
#define GCC_ASM_W74  GCC_ASM_W73  ", %73"
#define GCC_ASM_W75  GCC_ASM_W74  ", %74"
#define GCC_ASM_W76  GCC_ASM_W75  ", %75"
#define GCC_ASM_W77  GCC_ASM_W76  ", %76"
#define GCC_ASM_W78  GCC_ASM_W77  ", %77"
#define GCC_ASM_W79  GCC_ASM_W78  ", %78"
#define GCC_ASM_W80  GCC_ASM_W79  ", %79"
#define GCC_ASM_W81  GCC_ASM_W80  ", %80"
#define GCC_ASM_W82  GCC_ASM_W81  ", %81"
#define GCC_ASM_W83  GCC_ASM_W82  ", %82"
#define GCC_ASM_W84  GCC_ASM_W83  ", %83"
#define GCC_ASM_W85  GCC_ASM_W84  ", %84"
#define GCC_ASM_W86  GCC_ASM_W85  ", %85"
#define GCC_ASM_W87  GCC_ASM_W86  ", %86"
#define GCC_ASM_W88  GCC_ASM_W87  ", %87"
#define GCC_ASM_W89  GCC_ASM_W88  ", %88"
#define GCC_ASM_W90  GCC_ASM_W89  ", %89"
#define GCC_ASM_W91  GCC_ASM_W90  ", %90"
#define GCC_ASM_W92  GCC_ASM_W91  ", %91"
#define GCC_ASM_W93  GCC_ASM_W92  ", %92"
#define GCC_ASM_W94  GCC_ASM_W93  ", %93"
#define GCC_ASM_W95  GCC_ASM_W94  ", %94"
#define GCC_ASM_W96  GCC_ASM_W95  ", %95"
#define GCC_ASM_W97  GCC_ASM_W96  ", %96"
#define GCC_ASM_W98  GCC_ASM_W97  ", %97"
#define GCC_ASM_W99  GCC_ASM_W98  ", %98"

/* Utilizing cascading operand strings to compress the payload */
#define GCC_ASM_I1(p0)       "i"(p0)
#define GCC_ASM_I2(p0,  ...) "i"(p0), GCC_ASM_I1( __VA_ARGS__)
#define GCC_ASM_I3(p0,  ...) "i"(p0), GCC_ASM_I2( __VA_ARGS__)
#define GCC_ASM_I4(p0,  ...) "i"(p0), GCC_ASM_I3( __VA_ARGS__)
#define GCC_ASM_I5(p0,  ...) "i"(p0), GCC_ASM_I4( __VA_ARGS__)
#define GCC_ASM_I6(p0,  ...) "i"(p0), GCC_ASM_I5( __VA_ARGS__)
#define GCC_ASM_I7(p0,  ...) "i"(p0), GCC_ASM_I6( __VA_ARGS__)
#define GCC_ASM_I8(p0,  ...) "i"(p0), GCC_ASM_I7( __VA_ARGS__)
#define GCC_ASM_I9(p0,  ...) "i"(p0), GCC_ASM_I8( __VA_ARGS__)
#define GCC_ASM_I10(p0, ...) "i"(p0), GCC_ASM_I9( __VA_ARGS__)
#define GCC_ASM_I11(p0, ...) "i"(p0), GCC_ASM_I10(__VA_ARGS__)
#define GCC_ASM_I12(p0, ...) "i"(p0), GCC_ASM_I11(__VA_ARGS__)
#define GCC_ASM_I13(p0, ...) "i"(p0), GCC_ASM_I12(__VA_ARGS__)
#define GCC_ASM_I14(p0, ...) "i"(p0), GCC_ASM_I13(__VA_ARGS__)
#define GCC_ASM_I15(p0, ...) "i"(p0), GCC_ASM_I14(__VA_ARGS__)
#define GCC_ASM_I16(p0, ...) "i"(p0), GCC_ASM_I15(__VA_ARGS__)
#define GCC_ASM_I17(p0, ...) "i"(p0), GCC_ASM_I16(__VA_ARGS__)
#define GCC_ASM_I18(p0, ...) "i"(p0), GCC_ASM_I17(__VA_ARGS__)
#define GCC_ASM_I19(p0, ...) "i"(p0), GCC_ASM_I18(__VA_ARGS__)
#define GCC_ASM_I20(p0, ...) "i"(p0), GCC_ASM_I19(__VA_ARGS__)
#define GCC_ASM_I21(p0, ...) "i"(p0), GCC_ASM_I20(__VA_ARGS__)
#define GCC_ASM_I22(p0, ...) "i"(p0), GCC_ASM_I21(__VA_ARGS__)
#define GCC_ASM_I23(p0, ...) "i"(p0), GCC_ASM_I22(__VA_ARGS__)
#define GCC_ASM_I24(p0, ...) "i"(p0), GCC_ASM_I23(__VA_ARGS__)
#define GCC_ASM_I25(p0, ...) "i"(p0), GCC_ASM_I24(__VA_ARGS__)
#define GCC_ASM_I26(p0, ...) "i"(p0), GCC_ASM_I25(__VA_ARGS__)
#define GCC_ASM_I27(p0, ...) "i"(p0), GCC_ASM_I26(__VA_ARGS__)
#define GCC_ASM_I28(p0, ...) "i"(p0), GCC_ASM_I27(__VA_ARGS__)
#define GCC_ASM_I29(p0, ...) "i"(p0), GCC_ASM_I28(__VA_ARGS__)
#define GCC_ASM_I30(p0, ...) "i"(p0), GCC_ASM_I29(__VA_ARGS__)
#define GCC_ASM_I31(p0, ...) "i"(p0), GCC_ASM_I30(__VA_ARGS__)
#define GCC_ASM_I32(p0, ...) "i"(p0), GCC_ASM_I31(__VA_ARGS__)
#define GCC_ASM_I33(p0, ...) "i"(p0), GCC_ASM_I32(__VA_ARGS__)
#define GCC_ASM_I34(p0, ...) "i"(p0), GCC_ASM_I33(__VA_ARGS__)
#define GCC_ASM_I35(p0, ...) "i"(p0), GCC_ASM_I34(__VA_ARGS__)
#define GCC_ASM_I36(p0, ...) "i"(p0), GCC_ASM_I35(__VA_ARGS__)
#define GCC_ASM_I37(p0, ...) "i"(p0), GCC_ASM_I36(__VA_ARGS__)
#define GCC_ASM_I38(p0, ...) "i"(p0), GCC_ASM_I37(__VA_ARGS__)
#define GCC_ASM_I39(p0, ...) "i"(p0), GCC_ASM_I38(__VA_ARGS__)
#define GCC_ASM_I40(p0, ...) "i"(p0), GCC_ASM_I39(__VA_ARGS__)
#define GCC_ASM_I41(p0, ...) "i"(p0), GCC_ASM_I40(__VA_ARGS__)
#define GCC_ASM_I42(p0, ...) "i"(p0), GCC_ASM_I41(__VA_ARGS__)
#define GCC_ASM_I43(p0, ...) "i"(p0), GCC_ASM_I42(__VA_ARGS__)
#define GCC_ASM_I44(p0, ...) "i"(p0), GCC_ASM_I43(__VA_ARGS__)
#define GCC_ASM_I45(p0, ...) "i"(p0), GCC_ASM_I44(__VA_ARGS__)
#define GCC_ASM_I46(p0, ...) "i"(p0), GCC_ASM_I45(__VA_ARGS__)
#define GCC_ASM_I47(p0, ...) "i"(p0), GCC_ASM_I46(__VA_ARGS__)
#define GCC_ASM_I48(p0, ...) "i"(p0), GCC_ASM_I47(__VA_ARGS__)
#define GCC_ASM_I49(p0, ...) "i"(p0), GCC_ASM_I48(__VA_ARGS__)
#define GCC_ASM_I50(p0, ...) "i"(p0), GCC_ASM_I49(__VA_ARGS__)
#define GCC_ASM_I51(p0, ...) "i"(p0), GCC_ASM_I50(__VA_ARGS__)
#define GCC_ASM_I52(p0, ...) "i"(p0), GCC_ASM_I51(__VA_ARGS__)
#define GCC_ASM_I53(p0, ...) "i"(p0), GCC_ASM_I52(__VA_ARGS__)
#define GCC_ASM_I54(p0, ...) "i"(p0), GCC_ASM_I53(__VA_ARGS__)
#define GCC_ASM_I55(p0, ...) "i"(p0), GCC_ASM_I54(__VA_ARGS__)
#define GCC_ASM_I56(p0, ...) "i"(p0), GCC_ASM_I55(__VA_ARGS__)
#define GCC_ASM_I57(p0, ...) "i"(p0), GCC_ASM_I56(__VA_ARGS__)
#define GCC_ASM_I58(p0, ...) "i"(p0), GCC_ASM_I57(__VA_ARGS__)
#define GCC_ASM_I59(p0, ...) "i"(p0), GCC_ASM_I58(__VA_ARGS__)
#define GCC_ASM_I60(p0, ...) "i"(p0), GCC_ASM_I59(__VA_ARGS__)
#define GCC_ASM_I61(p0, ...) "i"(p0), GCC_ASM_I60(__VA_ARGS__)
#define GCC_ASM_I62(p0, ...) "i"(p0), GCC_ASM_I61(__VA_ARGS__)
#define GCC_ASM_I63(p0, ...) "i"(p0), GCC_ASM_I62(__VA_ARGS__)
#define GCC_ASM_I64(p0, ...) "i"(p0), GCC_ASM_I63(__VA_ARGS__)
#define GCC_ASM_I65(p0, ...) "i"(p0), GCC_ASM_I64(__VA_ARGS__)
#define GCC_ASM_I66(p0, ...) "i"(p0), GCC_ASM_I65(__VA_ARGS__)
#define GCC_ASM_I67(p0, ...) "i"(p0), GCC_ASM_I66(__VA_ARGS__)
#define GCC_ASM_I68(p0, ...) "i"(p0), GCC_ASM_I67(__VA_ARGS__)
#define GCC_ASM_I69(p0, ...) "i"(p0), GCC_ASM_I68(__VA_ARGS__)
#define GCC_ASM_I70(p0, ...) "i"(p0), GCC_ASM_I69(__VA_ARGS__)
#define GCC_ASM_I71(p0, ...) "i"(p0), GCC_ASM_I70(__VA_ARGS__)
#define GCC_ASM_I72(p0, ...) "i"(p0), GCC_ASM_I71(__VA_ARGS__)
#define GCC_ASM_I73(p0, ...) "i"(p0), GCC_ASM_I72(__VA_ARGS__)
#define GCC_ASM_I74(p0, ...) "i"(p0), GCC_ASM_I73(__VA_ARGS__)
#define GCC_ASM_I75(p0, ...) "i"(p0), GCC_ASM_I74(__VA_ARGS__)
#define GCC_ASM_I76(p0, ...) "i"(p0), GCC_ASM_I75(__VA_ARGS__)
#define GCC_ASM_I77(p0, ...) "i"(p0), GCC_ASM_I76(__VA_ARGS__)
#define GCC_ASM_I78(p0, ...) "i"(p0), GCC_ASM_I77(__VA_ARGS__)
#define GCC_ASM_I79(p0, ...) "i"(p0), GCC_ASM_I78(__VA_ARGS__)
#define GCC_ASM_I80(p0, ...) "i"(p0), GCC_ASM_I79(__VA_ARGS__)
#define GCC_ASM_I81(p0, ...) "i"(p0), GCC_ASM_I80(__VA_ARGS__)
#define GCC_ASM_I82(p0, ...) "i"(p0), GCC_ASM_I81(__VA_ARGS__)
#define GCC_ASM_I83(p0, ...) "i"(p0), GCC_ASM_I82(__VA_ARGS__)
#define GCC_ASM_I84(p0, ...) "i"(p0), GCC_ASM_I83(__VA_ARGS__)
#define GCC_ASM_I85(p0, ...) "i"(p0), GCC_ASM_I84(__VA_ARGS__)
#define GCC_ASM_I86(p0, ...) "i"(p0), GCC_ASM_I85(__VA_ARGS__)
#define GCC_ASM_I87(p0, ...) "i"(p0), GCC_ASM_I86(__VA_ARGS__)
#define GCC_ASM_I88(p0, ...) "i"(p0), GCC_ASM_I87(__VA_ARGS__)
#define GCC_ASM_I89(p0, ...) "i"(p0), GCC_ASM_I88(__VA_ARGS__)
#define GCC_ASM_I90(p0, ...) "i"(p0), GCC_ASM_I89(__VA_ARGS__)
#define GCC_ASM_I91(p0, ...) "i"(p0), GCC_ASM_I90(__VA_ARGS__)
#define GCC_ASM_I92(p0, ...) "i"(p0), GCC_ASM_I91(__VA_ARGS__)
#define GCC_ASM_I93(p0, ...) "i"(p0), GCC_ASM_I92(__VA_ARGS__)
#define GCC_ASM_I94(p0, ...) "i"(p0), GCC_ASM_I93(__VA_ARGS__)
#define GCC_ASM_I95(p0, ...) "i"(p0), GCC_ASM_I94(__VA_ARGS__)
#define GCC_ASM_I96(p0, ...) "i"(p0), GCC_ASM_I95(__VA_ARGS__)
#define GCC_ASM_I97(p0, ...) "i"(p0), GCC_ASM_I96(__VA_ARGS__)
#define GCC_ASM_I98(p0, ...) "i"(p0), GCC_ASM_I97(__VA_ARGS__)
#define GCC_ASM_I99(p0, ...) "i"(p0), GCC_ASM_I98(__VA_ARGS__)

#define GCC_ASM_INL_1( a)      ".word " GCC_ASM_W1  : : GCC_ASM_I1( a)
#define GCC_ASM_INL_2( a, ...) ".word " GCC_ASM_W2  : : GCC_ASM_I2( a, __VA_ARGS__)
#define GCC_ASM_INL_3( a, ...) ".word " GCC_ASM_W3  : : GCC_ASM_I3( a, __VA_ARGS__)
#define GCC_ASM_INL_4( a, ...) ".word " GCC_ASM_W4  : : GCC_ASM_I4( a, __VA_ARGS__)
#define GCC_ASM_INL_5( a, ...) ".word " GCC_ASM_W5  : : GCC_ASM_I5( a, __VA_ARGS__)
#define GCC_ASM_INL_6( a, ...) ".word " GCC_ASM_W6  : : GCC_ASM_I6( a, __VA_ARGS__)
#define GCC_ASM_INL_7( a, ...) ".word " GCC_ASM_W7  : : GCC_ASM_I7( a, __VA_ARGS__)
#define GCC_ASM_INL_8( a, ...) ".word " GCC_ASM_W8  : : GCC_ASM_I8( a, __VA_ARGS__)
#define GCC_ASM_INL_9( a, ...) ".word " GCC_ASM_W9  : : GCC_ASM_I9( a, __VA_ARGS__)
#define GCC_ASM_INL_10(a, ...) ".word " GCC_ASM_W10 : : GCC_ASM_I10(a, __VA_ARGS__)
#define GCC_ASM_INL_11(a, ...) ".word " GCC_ASM_W11 : : GCC_ASM_I11(a, __VA_ARGS__)
#define GCC_ASM_INL_12(a, ...) ".word " GCC_ASM_W12 : : GCC_ASM_I12(a, __VA_ARGS__)
#define GCC_ASM_INL_13(a, ...) ".word " GCC_ASM_W13 : : GCC_ASM_I13(a, __VA_ARGS__)
#define GCC_ASM_INL_14(a, ...) ".word " GCC_ASM_W14 : : GCC_ASM_I14(a, __VA_ARGS__)
#define GCC_ASM_INL_15(a, ...) ".word " GCC_ASM_W15 : : GCC_ASM_I15(a, __VA_ARGS__)
#define GCC_ASM_INL_16(a, ...) ".word " GCC_ASM_W16 : : GCC_ASM_I16(a, __VA_ARGS__)
#define GCC_ASM_INL_17(a, ...) ".word " GCC_ASM_W17 : : GCC_ASM_I17(a, __VA_ARGS__)
#define GCC_ASM_INL_18(a, ...) ".word " GCC_ASM_W18 : : GCC_ASM_I18(a, __VA_ARGS__)
#define GCC_ASM_INL_19(a, ...) ".word " GCC_ASM_W19 : : GCC_ASM_I19(a, __VA_ARGS__)
#define GCC_ASM_INL_20(a, ...) ".word " GCC_ASM_W20 : : GCC_ASM_I20(a, __VA_ARGS__)
#define GCC_ASM_INL_21(a, ...) ".word " GCC_ASM_W21 : : GCC_ASM_I21(a, __VA_ARGS__)
#define GCC_ASM_INL_22(a, ...) ".word " GCC_ASM_W22 : : GCC_ASM_I22(a, __VA_ARGS__)
#define GCC_ASM_INL_23(a, ...) ".word " GCC_ASM_W23 : : GCC_ASM_I23(a, __VA_ARGS__)
#define GCC_ASM_INL_24(a, ...) ".word " GCC_ASM_W24 : : GCC_ASM_I24(a, __VA_ARGS__)
#define GCC_ASM_INL_25(a, ...) ".word " GCC_ASM_W25 : : GCC_ASM_I25(a, __VA_ARGS__)
#define GCC_ASM_INL_26(a, ...) ".word " GCC_ASM_W26 : : GCC_ASM_I26(a, __VA_ARGS__)
#define GCC_ASM_INL_27(a, ...) ".word " GCC_ASM_W27 : : GCC_ASM_I27(a, __VA_ARGS__)
#define GCC_ASM_INL_28(a, ...) ".word " GCC_ASM_W28 : : GCC_ASM_I28(a, __VA_ARGS__)
#define GCC_ASM_INL_29(a, ...) ".word " GCC_ASM_W29 : : GCC_ASM_I29(a, __VA_ARGS__)
#define GCC_ASM_INL_30(a, ...) ".word " GCC_ASM_W30 : : GCC_ASM_I30(a, __VA_ARGS__)
#define GCC_ASM_INL_31(a, ...) ".word " GCC_ASM_W31 : : GCC_ASM_I31(a, __VA_ARGS__)
#define GCC_ASM_INL_32(a, ...) ".word " GCC_ASM_W32 : : GCC_ASM_I32(a, __VA_ARGS__)
#define GCC_ASM_INL_33(a, ...) ".word " GCC_ASM_W33 : : GCC_ASM_I33(a, __VA_ARGS__)
#define GCC_ASM_INL_34(a, ...) ".word " GCC_ASM_W34 : : GCC_ASM_I34(a, __VA_ARGS__)
#define GCC_ASM_INL_35(a, ...) ".word " GCC_ASM_W35 : : GCC_ASM_I35(a, __VA_ARGS__)
#define GCC_ASM_INL_36(a, ...) ".word " GCC_ASM_W36 : : GCC_ASM_I36(a, __VA_ARGS__)
#define GCC_ASM_INL_37(a, ...) ".word " GCC_ASM_W37 : : GCC_ASM_I37(a, __VA_ARGS__)
#define GCC_ASM_INL_38(a, ...) ".word " GCC_ASM_W38 : : GCC_ASM_I38(a, __VA_ARGS__)
#define GCC_ASM_INL_39(a, ...) ".word " GCC_ASM_W39 : : GCC_ASM_I39(a, __VA_ARGS__)
#define GCC_ASM_INL_40(a, ...) ".word " GCC_ASM_W40 : : GCC_ASM_I40(a, __VA_ARGS__)
#define GCC_ASM_INL_41(a, ...) ".word " GCC_ASM_W41 : : GCC_ASM_I41(a, __VA_ARGS__)
#define GCC_ASM_INL_42(a, ...) ".word " GCC_ASM_W42 : : GCC_ASM_I42(a, __VA_ARGS__)
#define GCC_ASM_INL_43(a, ...) ".word " GCC_ASM_W43 : : GCC_ASM_I43(a, __VA_ARGS__)
#define GCC_ASM_INL_44(a, ...) ".word " GCC_ASM_W44 : : GCC_ASM_I44(a, __VA_ARGS__)
#define GCC_ASM_INL_45(a, ...) ".word " GCC_ASM_W45 : : GCC_ASM_I45(a, __VA_ARGS__)
#define GCC_ASM_INL_46(a, ...) ".word " GCC_ASM_W46 : : GCC_ASM_I46(a, __VA_ARGS__)
#define GCC_ASM_INL_47(a, ...) ".word " GCC_ASM_W47 : : GCC_ASM_I47(a, __VA_ARGS__)
#define GCC_ASM_INL_48(a, ...) ".word " GCC_ASM_W48 : : GCC_ASM_I48(a, __VA_ARGS__)
#define GCC_ASM_INL_49(a, ...) ".word " GCC_ASM_W49 : : GCC_ASM_I49(a, __VA_ARGS__)
#define GCC_ASM_INL_50(a, ...) ".word " GCC_ASM_W50 : : GCC_ASM_I50(a, __VA_ARGS__)
#define GCC_ASM_INL_51(a, ...) ".word " GCC_ASM_W51 : : GCC_ASM_I51(a, __VA_ARGS__)
#define GCC_ASM_INL_52(a, ...) ".word " GCC_ASM_W52 : : GCC_ASM_I52(a, __VA_ARGS__)
#define GCC_ASM_INL_53(a, ...) ".word " GCC_ASM_W53 : : GCC_ASM_I53(a, __VA_ARGS__)
#define GCC_ASM_INL_54(a, ...) ".word " GCC_ASM_W54 : : GCC_ASM_I54(a, __VA_ARGS__)
#define GCC_ASM_INL_55(a, ...) ".word " GCC_ASM_W55 : : GCC_ASM_I55(a, __VA_ARGS__)
#define GCC_ASM_INL_56(a, ...) ".word " GCC_ASM_W56 : : GCC_ASM_I56(a, __VA_ARGS__)
#define GCC_ASM_INL_57(a, ...) ".word " GCC_ASM_W57 : : GCC_ASM_I57(a, __VA_ARGS__)
#define GCC_ASM_INL_58(a, ...) ".word " GCC_ASM_W58 : : GCC_ASM_I58(a, __VA_ARGS__)
#define GCC_ASM_INL_59(a, ...) ".word " GCC_ASM_W59 : : GCC_ASM_I59(a, __VA_ARGS__)
#define GCC_ASM_INL_60(a, ...) ".word " GCC_ASM_W60 : : GCC_ASM_I60(a, __VA_ARGS__)
#define GCC_ASM_INL_61(a, ...) ".word " GCC_ASM_W61 : : GCC_ASM_I61(a, __VA_ARGS__)
#define GCC_ASM_INL_62(a, ...) ".word " GCC_ASM_W62 : : GCC_ASM_I62(a, __VA_ARGS__)
#define GCC_ASM_INL_63(a, ...) ".word " GCC_ASM_W63 : : GCC_ASM_I63(a, __VA_ARGS__)
#define GCC_ASM_INL_64(a, ...) ".word " GCC_ASM_W64 : : GCC_ASM_I64(a, __VA_ARGS__)
#define GCC_ASM_INL_65(a, ...) ".word " GCC_ASM_W65 : : GCC_ASM_I65(a, __VA_ARGS__)
#define GCC_ASM_INL_66(a, ...) ".word " GCC_ASM_W66 : : GCC_ASM_I66(a, __VA_ARGS__)
#define GCC_ASM_INL_67(a, ...) ".word " GCC_ASM_W67 : : GCC_ASM_I67(a, __VA_ARGS__)
#define GCC_ASM_INL_68(a, ...) ".word " GCC_ASM_W68 : : GCC_ASM_I68(a, __VA_ARGS__)
#define GCC_ASM_INL_69(a, ...) ".word " GCC_ASM_W69 : : GCC_ASM_I69(a, __VA_ARGS__)
#define GCC_ASM_INL_70(a, ...) ".word " GCC_ASM_W70 : : GCC_ASM_I70(a, __VA_ARGS__)
#define GCC_ASM_INL_71(a, ...) ".word " GCC_ASM_W71 : : GCC_ASM_I71(a, __VA_ARGS__)
#define GCC_ASM_INL_72(a, ...) ".word " GCC_ASM_W72 : : GCC_ASM_I72(a, __VA_ARGS__)
#define GCC_ASM_INL_73(a, ...) ".word " GCC_ASM_W73 : : GCC_ASM_I73(a, __VA_ARGS__)
#define GCC_ASM_INL_74(a, ...) ".word " GCC_ASM_W74 : : GCC_ASM_I74(a, __VA_ARGS__)
#define GCC_ASM_INL_75(a, ...) ".word " GCC_ASM_W75 : : GCC_ASM_I75(a, __VA_ARGS__)
#define GCC_ASM_INL_76(a, ...) ".word " GCC_ASM_W76 : : GCC_ASM_I76(a, __VA_ARGS__)
#define GCC_ASM_INL_77(a, ...) ".word " GCC_ASM_W77 : : GCC_ASM_I77(a, __VA_ARGS__)
#define GCC_ASM_INL_78(a, ...) ".word " GCC_ASM_W78 : : GCC_ASM_I78(a, __VA_ARGS__)
#define GCC_ASM_INL_79(a, ...) ".word " GCC_ASM_W79 : : GCC_ASM_I79(a, __VA_ARGS__)
#define GCC_ASM_INL_80(a, ...) ".word " GCC_ASM_W80 : : GCC_ASM_I80(a, __VA_ARGS__)
#define GCC_ASM_INL_81(a, ...) ".word " GCC_ASM_W81 : : GCC_ASM_I81(a, __VA_ARGS__)
#define GCC_ASM_INL_82(a, ...) ".word " GCC_ASM_W82 : : GCC_ASM_I82(a, __VA_ARGS__)
#define GCC_ASM_INL_83(a, ...) ".word " GCC_ASM_W83 : : GCC_ASM_I83(a, __VA_ARGS__)
#define GCC_ASM_INL_84(a, ...) ".word " GCC_ASM_W84 : : GCC_ASM_I84(a, __VA_ARGS__)
#define GCC_ASM_INL_85(a, ...) ".word " GCC_ASM_W85 : : GCC_ASM_I85(a, __VA_ARGS__)
#define GCC_ASM_INL_86(a, ...) ".word " GCC_ASM_W86 : : GCC_ASM_I86(a, __VA_ARGS__)
#define GCC_ASM_INL_87(a, ...) ".word " GCC_ASM_W87 : : GCC_ASM_I87(a, __VA_ARGS__)
#define GCC_ASM_INL_88(a, ...) ".word " GCC_ASM_W88 : : GCC_ASM_I88(a, __VA_ARGS__)
#define GCC_ASM_INL_89(a, ...) ".word " GCC_ASM_W89 : : GCC_ASM_I89(a, __VA_ARGS__)
#define GCC_ASM_INL_90(a, ...) ".word " GCC_ASM_W90 : : GCC_ASM_I90(a, __VA_ARGS__)
#define GCC_ASM_INL_91(a, ...) ".word " GCC_ASM_W91 : : GCC_ASM_I91(a, __VA_ARGS__)
#define GCC_ASM_INL_92(a, ...) ".word " GCC_ASM_W92 : : GCC_ASM_I92(a, __VA_ARGS__)
#define GCC_ASM_INL_93(a, ...) ".word " GCC_ASM_W93 : : GCC_ASM_I93(a, __VA_ARGS__)
#define GCC_ASM_INL_94(a, ...) ".word " GCC_ASM_W94 : : GCC_ASM_I94(a, __VA_ARGS__)
#define GCC_ASM_INL_95(a, ...) ".word " GCC_ASM_W95 : : GCC_ASM_I95(a, __VA_ARGS__)
#define GCC_ASM_INL_96(a, ...) ".word " GCC_ASM_W96 : : GCC_ASM_I96(a, __VA_ARGS__)
#define GCC_ASM_INL_97(a, ...) ".word " GCC_ASM_W97 : : GCC_ASM_I97(a, __VA_ARGS__)
#define GCC_ASM_INL_98(a, ...) ".word " GCC_ASM_W98 : : GCC_ASM_I98(a, __VA_ARGS__)
#define GCC_ASM_INL_99(a, ...) ".word " GCC_ASM_W99 : : GCC_ASM_I99(a, __VA_ARGS__)

#pragma endregion Cruft
