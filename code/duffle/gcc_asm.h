#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#endif

/* ============================================================================
 * INLINE ASSEMBLY BLOB DISPATCHER (UP TO 99 INSTRUCTIONS)
 * ============================================================================ */

/* --- 1. The Argument Counter --- */
#define _ASM_COUNT_ARGS_IMPL( \
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

#define _ASM_COUNT_ARGS(...) m_expand(_ASM_COUNT_ARGS_IMPL(__VA_ARGS__, \
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
 * NOTE: we use `%0`, `%1`, ... not `%c0`, `%c1`, ... because GCC's
 * asm-parser rejects `%cN` in this position with "invalid use of '%c'".
 * The `%cN` form is for printing *character* constants; for arbitrary
 * integer immediates (the only kind `"i"(...)` produces), the plain
 * `%N` form is the right one. Both expand to the bare immediate.
 */
#define _STR1  "%0"
#define _STR2  _STR1  ", %1"
#define _STR3  _STR2  ", %2"
#define _STR4  _STR3  ", %3"
#define _STR5  _STR4  ", %4"
#define _STR6  _STR5  ", %5"
#define _STR7  _STR6  ", %6"
#define _STR8  _STR7  ", %7"
#define _STR9  _STR8  ", %8"
#define _STR10 _STR9  ", %9"
#define _STR11 _STR10 ", %10"
#define _STR12 _STR11 ", %11"
#define _STR13 _STR12 ", %12"
#define _STR14 _STR13 ", %13"
#define _STR15 _STR14 ", %14"
#define _STR16 _STR15 ", %15"
#define _STR17 _STR16 ", %16"
#define _STR18 _STR17 ", %17"
#define _STR19 _STR18 ", %18"
#define _STR20 _STR19 ", %19"
#define _STR21 _STR20 ", %20"
#define _STR22 _STR21 ", %21"
#define _STR23 _STR22 ", %22"
#define _STR24 _STR23 ", %23"
#define _STR25 _STR24 ", %24"
#define _STR26 _STR25 ", %25"
#define _STR27 _STR26 ", %26"
#define _STR28 _STR27 ", %27"
#define _STR29 _STR28 ", %28"
#define _STR30 _STR29 ", %29"
#define _STR31 _STR30 ", %30"
#define _STR32 _STR31 ", %31"
#define _STR33 _STR32 ", %32"
#define _STR34 _STR33 ", %33"
#define _STR35 _STR34 ", %34"
#define _STR36 _STR35 ", %35"
#define _STR37 _STR36 ", %36"
#define _STR38 _STR37 ", %37"
#define _STR39 _STR38 ", %38"
#define _STR40 _STR39 ", %39"
#define _STR41 _STR40 ", %40"
#define _STR42 _STR41 ", %41"
#define _STR43 _STR42 ", %42"
#define _STR44 _STR43 ", %43"
#define _STR45 _STR44 ", %44"
#define _STR46 _STR45 ", %45"
#define _STR47 _STR46 ", %46"
#define _STR48 _STR47 ", %47"
#define _STR49 _STR48 ", %48"
#define _STR50 _STR49 ", %49"
#define _STR51 _STR50 ", %50"
#define _STR52 _STR51 ", %51"
#define _STR53 _STR52 ", %52"
#define _STR54 _STR53 ", %53"
#define _STR55 _STR54 ", %54"
#define _STR56 _STR55 ", %55"
#define _STR57 _STR56 ", %56"
#define _STR58 _STR57 ", %57"
#define _STR59 _STR58 ", %58"
#define _STR60 _STR59 ", %59"
#define _STR61 _STR60 ", %60"
#define _STR62 _STR61 ", %61"
#define _STR63 _STR62 ", %62"
#define _STR64 _STR63 ", %63"
#define _STR65 _STR64 ", %64"
#define _STR66 _STR65 ", %65"
#define _STR67 _STR66 ", %66"
#define _STR68 _STR67 ", %67"
#define _STR69 _STR68 ", %68"
#define _STR70 _STR69 ", %69"
#define _STR71 _STR70 ", %70"
#define _STR72 _STR71 ", %71"
#define _STR73 _STR72 ", %72"
#define _STR74 _STR73 ", %73"
#define _STR75 _STR74 ", %74"
#define _STR76 _STR75 ", %75"
#define _STR77 _STR76 ", %76"
#define _STR78 _STR77 ", %77"
#define _STR79 _STR78 ", %78"
#define _STR80 _STR79 ", %79"
#define _STR81 _STR80 ", %80"
#define _STR82 _STR81 ", %81"
#define _STR83 _STR82 ", %82"
#define _STR84 _STR83 ", %83"
#define _STR85 _STR84 ", %84"
#define _STR86 _STR85 ", %85"
#define _STR87 _STR86 ", %86"
#define _STR88 _STR87 ", %87"
#define _STR89 _STR88 ", %88"
#define _STR90 _STR89 ", %89"
#define _STR91 _STR90 ", %90"
#define _STR92 _STR91 ", %91"
#define _STR93 _STR92 ", %92"
#define _STR94 _STR93 ", %93"
#define _STR95 _STR94 ", %94"
#define _STR96 _STR95 ", %95"
#define _STR97 _STR96 ", %96"
#define _STR98 _STR97 ", %97"
#define _STR99 _STR98 ", %98"

/* Utilizing cascading operand strings to compress the payload */
#define _OP10 "i"(p0),"i"(p1),"i"(p2),"i"(p3),"i"(p4),"i"(p5),"i"(p6),"i"(p7),"i"(p8),"i"(p9)
#define _OP20 _OP10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15),"i"(p16),"i"(p17),"i"(p18),"i"(p19)
#define _OP30 _OP20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25),"i"(p26),"i"(p27),"i"(p28),"i"(p29)
#define _OP40 _OP30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35),"i"(p36),"i"(p37),"i"(p38),"i"(p39)
#define _OP50 _OP40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45),"i"(p46),"i"(p47),"i"(p48),"i"(p49)
#define _OP60 _OP50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55),"i"(p56),"i"(p57),"i"(p58),"i"(p59)
#define _OP70 _OP60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65),"i"(p66),"i"(p67),"i"(p68),"i"(p69)
#define _OP80 _OP70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75),"i"(p76),"i"(p77),"i"(p78),"i"(p79)
#define _OP90 _OP80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85),"i"(p86),"i"(p87),"i"(p88),"i"(p89)

/* --- The AST Generators (1 to 99) --- */
#define _INL_1(p0)                               ".word " _STR1 : : "i"(p0)
#define _INL_2(p0,p1)                            ".word " _STR2 : : "i"(p0),"i"(p1)
#define _INL_3(p0,p1,p2)                         ".word " _STR3 : : "i"(p0),"i"(p1),"i"(p2)
#define _INL_4(p0,p1,p2,p3)                      ".word " _STR4 : : "i"(p0),"i"(p1),"i"(p2),"i"(p3)
#define _INL_5(p0,p1,p2,p3,p4)                   ".word " _STR5 : : "i"(p0),"i"(p1),"i"(p2),"i"(p3),"i"(p4)
#define _INL_6(p0,p1,p2,p3,p4,p5)                ".word " _STR6 : : "i"(p0),"i"(p1),"i"(p2),"i"(p3),"i"(p4),"i"(p5)
#define _INL_7(p0,p1,p2,p3,p4,p5,p6)             ".word " _STR7 : : "i"(p0),"i"(p1),"i"(p2),"i"(p3),"i"(p4),"i"(p5),"i"(p6)
#define _INL_8(p0,p1,p2,p3,p4,p5,p6,p7)          ".word " _STR8 : : "i"(p0),"i"(p1),"i"(p2),"i"(p3),"i"(p4),"i"(p5),"i"(p6),"i"(p7)
#define _INL_9(p0,p1,p2,p3,p4,p5,p6,p7,p8)       ".word " _STR9 : : "i"(p0),"i"(p1),"i"(p2),"i"(p3),"i"(p4),"i"(p5),"i"(p6),"i"(p7),"i"(p8)
#define _INL_10(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9)   ".word " _STR10 : : _OP10

#define _INL_11(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10) ".word " _STR11 : : _OP10,"i"(p10)
#define _INL_12(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11) ".word " _STR12 : : _OP10,"i"(p10),"i"(p11)
#define _INL_13(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12) ".word " _STR13 : : _OP10,"i"(p10),"i"(p11),"i"(p12)
#define _INL_14(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13) ".word " _STR14 : : _OP10,"i"(p10),"i"(p11),"i"(p12),"i"(p13)
#define _INL_15(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14) ".word " _STR15 : : _OP10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14)
#define _INL_16(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15) ".word " _STR16 : : _OP10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15)
#define _INL_17(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16) ".word " _STR17 : : _OP10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15),"i"(p16)
#define _INL_18(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17) ".word " _STR18 : : _OP10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15),"i"(p16),"i"(p17)
#define _INL_19(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18) ".word " _STR19 : : _OP10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15),"i"(p16),"i"(p17),"i"(p18)
#define _INL_20(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19) ".word " _STR20 : : _OP20

#define _INL_21(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20) ".word " _STR21 : : _OP20,"i"(p20)
#define _INL_22(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21) ".word " _STR22 : : _OP20,"i"(p20),"i"(p21)
#define _INL_23(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22) ".word " _STR23 : : _OP20,"i"(p20),"i"(p21),"i"(p22)
#define _INL_24(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23) ".word " _STR24 : : _OP20,"i"(p20),"i"(p21),"i"(p22),"i"(p23)
#define _INL_25(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24) ".word " _STR25 : : _OP20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24)
#define _INL_26(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25) ".word " _STR26 : : _OP20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25)
#define _INL_27(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26) ".word " _STR27 : : _OP20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25),"i"(p26)
#define _INL_28(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27) ".word " _STR28 : : _OP20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25),"i"(p26),"i"(p27)
#define _INL_29(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28) ".word " _STR29 : : _OP20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25),"i"(p26),"i"(p27),"i"(p28)
#define _INL_30(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29) ".word " _STR30 : : _OP30

#define _INL_31(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30) ".word " _STR31 : : _OP30,"i"(p30)
#define _INL_32(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31) ".word " _STR32 : : _OP30,"i"(p30),"i"(p31)
#define _INL_33(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32) ".word " _STR33 : : _OP30,"i"(p30),"i"(p31),"i"(p32)
#define _INL_34(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33) ".word " _STR34 : : _OP30,"i"(p30),"i"(p31),"i"(p32),"i"(p33)
#define _INL_35(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34) ".word " _STR35 : : _OP30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34)
#define _INL_36(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35) ".word " _STR36 : : _OP30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35)
#define _INL_37(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36) ".word " _STR37 : : _OP30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35),"i"(p36)
#define _INL_38(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37) ".word " _STR38 : : _OP30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35),"i"(p36),"i"(p37)
#define _INL_39(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38) ".word " _STR39 : : _OP30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35),"i"(p36),"i"(p37),"i"(p38)
#define _INL_40(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39) ".word " _STR40 : : _OP40

#define _INL_41(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40) ".word " _STR41 : : _OP40,"i"(p40)
#define _INL_42(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41) ".word " _STR42 : : _OP40,"i"(p40),"i"(p41)
#define _INL_43(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42) ".word " _STR43 : : _OP40,"i"(p40),"i"(p41),"i"(p42)
#define _INL_44(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43) ".word " _STR44 : : _OP40,"i"(p40),"i"(p41),"i"(p42),"i"(p43)
#define _INL_45(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44) ".word " _STR45 : : _OP40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44)
#define _INL_46(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45) ".word " _STR46 : : _OP40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45)
#define _INL_47(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46) ".word " _STR47 : : _OP40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45),"i"(p46)
#define _INL_48(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47) ".word " _STR48 : : _OP40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45),"i"(p46),"i"(p47)
#define _INL_49(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48) ".word " _STR49 : : _OP40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45),"i"(p46),"i"(p47),"i"(p48)
#define _INL_50(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49) ".word " _STR50 : : _OP50

#define _INL_51(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50) ".word " _STR51 : : _OP50,"i"(p50)
#define _INL_52(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51) ".word " _STR52 : : _OP50,"i"(p50),"i"(p51)
#define _INL_53(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52) ".word " _STR53 : : _OP50,"i"(p50),"i"(p51),"i"(p52)
#define _INL_54(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53) ".word " _STR54 : : _OP50,"i"(p50),"i"(p51),"i"(p52),"i"(p53)
#define _INL_55(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54) ".word " _STR55 : : _OP50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54)
#define _INL_56(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55) ".word " _STR56 : : _OP50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55)
#define _INL_57(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56) ".word " _STR57 : : _OP50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55),"i"(p56)
#define _INL_58(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57) ".word " _STR58 : : _OP50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55),"i"(p56),"i"(p57)
#define _INL_59(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58) ".word " _STR59 : : _OP50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55),"i"(p56),"i"(p57),"i"(p58)
#define _INL_60(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59) ".word " _STR60 : : _OP60

#define _INL_61(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60) ".word " _STR61 : : _OP60,"i"(p60)
#define _INL_62(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61) ".word " _STR62 : : _OP60,"i"(p60),"i"(p61)
#define _INL_63(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62) ".word " _STR63 : : _OP60,"i"(p60),"i"(p61),"i"(p62)
#define _INL_64(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63) ".word " _STR64 : : _OP60,"i"(p60),"i"(p61),"i"(p62),"i"(p63)
#define _INL_65(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64) ".word " _STR65 : : _OP60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64)
#define _INL_66(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65) ".word " _STR66 : : _OP60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65)
#define _INL_67(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66) ".word " _STR67 : : _OP60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65),"i"(p66)
#define _INL_68(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67) ".word " _STR68 : : _OP60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65),"i"(p66),"i"(p67)
#define _INL_69(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68) ".word " _STR69 : : _OP60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65),"i"(p66),"i"(p67),"i"(p68)
#define _INL_70(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69) ".word " _STR70 : : _OP70

#define _INL_71(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70) ".word " _STR71 : : _OP70,"i"(p70)
#define _INL_72(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71) ".word " _STR72 : : _OP70,"i"(p70),"i"(p71)
#define _INL_73(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72) ".word " _STR73 : : _OP70,"i"(p70),"i"(p71),"i"(p72)
#define _INL_74(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73) ".word " _STR74 : : _OP70,"i"(p70),"i"(p71),"i"(p72),"i"(p73)
#define _INL_75(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74) ".word " _STR75 : : _OP70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74)
#define _INL_76(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75) ".word " _STR76 : : _OP70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75)
#define _INL_77(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76) ".word " _STR77 : : _OP70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75),"i"(p76)
#define _INL_78(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77) ".word " _STR78 : : _OP70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75),"i"(p76),"i"(p77)
#define _INL_79(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78) ".word " _STR79 : : _OP70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75),"i"(p76),"i"(p77),"i"(p78)
#define _INL_80(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79) ".word " _STR80 : : _OP80

#define _INL_81(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80) ".word " _STR81 : : _OP80,"i"(p80)
#define _INL_82(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81) ".word " _STR82 : : _OP80,"i"(p80),"i"(p81)
#define _INL_83(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82) ".word " _STR83 : : _OP80,"i"(p80),"i"(p81),"i"(p82)
#define _INL_84(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83) ".word " _STR84 : : _OP80,"i"(p80),"i"(p81),"i"(p82),"i"(p83)
#define _INL_85(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84) ".word " _STR85 : : _OP80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84)
#define _INL_86(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85) ".word " _STR86 : : _OP80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85)
#define _INL_87(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86) ".word " _STR87 : : _OP80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85),"i"(p86)
#define _INL_88(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87) ".word " _STR88 : : _OP80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85),"i"(p86),"i"(p87)
#define _INL_89(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88) ".word " _STR89 : : _OP80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85),"i"(p86),"i"(p87),"i"(p88)
#define _INL_90(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89) ".word " _STR90 : : _OP90

#define _INL_91(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90) ".word " _STR91 : : _OP90,"i"(p90)
#define _INL_92(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91) ".word " _STR92 : : _OP90,"i"(p90),"i"(p91)
#define _INL_93(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92) ".word " _STR93 : : _OP90,"i"(p90),"i"(p91),"i"(p92)
#define _INL_94(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93) ".word " _STR94 : : _OP90,"i"(p90),"i"(p91),"i"(p92),"i"(p93)
#define _INL_95(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94) ".word " _STR95 : : _OP90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94)
#define _INL_96(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94,p95) ".word " _STR96 : : _OP90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94),"i"(p95)
#define _INL_97(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94,p95,p96) ".word " _STR97 : : _OP90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94),"i"(p95),"i"(p96)
#define _INL_98(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94,p95,p96,p97) ".word " _STR98 : : _OP90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94),"i"(p95),"i"(p96),"i"(p97)
#define _INL_99(p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94,p95,p96,p97,p98) ".word " _STR99 : : _OP90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94),"i"(p95),"i"(p96),"i"(p97),"i"(p98)

/* ============================================================================
 * AST BUILDERS — assemble a complete inline-asm block
 * ============================================================================
 *
 * A complete GCC inline-asm statement has up to 4 sections separated by `:`:
 *
 *   asm volatile ( "code" : OUTPUTS : INPUTS : CLOBBERS );
 *
 * Every section-builder below prepends the `:` separator that GCC requires,
 * so you can compose them inline without thinking about punctuation. The
 * master `asm_block(...)` then wraps the four sections in `asm volatile (...)`.
 *
 *   asm_block(
 *       asm_code( "..." ),
 *       asm_out  ( "=r"(x), "+m"(y) ),   // optional
 *       asm_in   ( "r"(a),  "m"(b)  ),   // optional
 *       asm_clb  ( "$8", "memory"  )    // optional
 *   );
 *
 * Common idioms (kept for back-compat / terseness):
 *
 *   asm_blob(asm_inline(...), asm_clobber(...))   // 2-section, no I/O
 *   asm_block(asm_inline(...), , , )              // 4-section, empty
 */

/* `asm_code` is a passthrough — it does NOT prepend a colon, since the code
 * section is always the first (no separator needed before it). The format
 * string + `"i"(...)` operand list are produced by `asm_inline(...)` and
 * just pass through unchanged. */
#define asm_code(...)         __VA_ARGS__

/* `asm_out`  prepends `:` — separates code/outputs/inputs/clobbers */
#define asm_out(...)          : __VA_ARGS__
/* `asm_in`   prepends `:` */
#define asm_in(...)           : __VA_ARGS__
/* `asm_clb`  prepends `:` */
#define asm_clb(...)          : __VA_ARGS__

/* `asm_clobber` is the legacy single-section name. Kept for existing
 * call-sites that put inputs *before* clobbers and want both as one colon-
 * prefixed block (i.e. the user wrote `: "r"(x) ... : "..."` by hand). */
#define asm_clobber(...)      : __VA_ARGS__

/* `asm_inline(...)` dispatches into `_INL_<count>` to emit up to 99 encoded
 * instruction words. This is the "compiled-instruction" form of `asm_code`.
 *
 * Result is a 2-colon body WITHOUT the final clobber section:
 *   ".word %c0, %c1, ..." : : "i"(p0), "i"(p1)
 *   |----- code -----|   |--- empty ---|  |------- inputs -------|
 *
 * Use it inside `asm volatile( ... )` like so:
 *
 *   asm volatile(
 *       asm_inline(w0, w1, w3)
 *       : clobbers
 *   )
 *
 * which expands to:
 *
 *   asm volatile(
 *       ".word %c0, %c1, %c2" : : "i"(w0), "i"(w1), "i"(w2)
 *       : "$2", "$8", ...
 *   )
 *
 * 3 colons total. Always valid. */
#define asm_inline(...)       m_expand(glue(_INL_, _ASM_COUNT_ARGS(__VA_ARGS__))(__VA_ARGS__))

/* reg_str(n) — Stringify an integer register id into the GCC asm
 * string form (e.g. 12 → "$12"). Use this anywhere GCC's parser
 * expects a literal string identifying a register: clobber lists,
 * asm templates, etc. The two-level macro is the standard preprocessor
 * idiom for forcing one level of expansion before stringify — without
 * it, `#n` would stringify the macro name `R_T4` to `"R_T4"` instead
 * of expanding `R_T4` to its value first.
 *
 * For declaring a register variable bound to a specific GPR, use the
 * `rgcc(n)` bundle from gcc_asm.h instead — it adds the `__asm__()`
 * qualifier around the string.
 *
 *   register V3_S2* p0 __asm__(reg_str(R_T4)) = ...;        // verbose
 *   register V3_S2* p0 rgcc(R_T4) = ...;                    // bundled
 *
 *   asm volatile("nop" : : : reg_str(R_RA), "memory");      // clobber list */
#define reg_str_(n)  "$" #n
#define reg_str(n)   reg_str_(n)

/* ------------------------------------------------------------------------ *
 *  rgcc(n) — GCC-specific bundle for register-variable declarations.
 *
 *  Produces `__asm__(reg_str(tmpl(n, Code)))` at expansion time. The
 *  `tmpl(n, Code)` indirection derives the preprocessor-visible `_Code`
 *  form from the enum name (which the preprocessor can't expand on
 *  its own). So a call like
 *
 *      register V3_S2* p rgcc(R_T4) = verts[0].ptr;
 *
 *  expands (via tmpl) to
 *
 *      register V3_S2* p __asm__(reg_str(R_T4_Code))
 *                                = verts[0].ptr;
 *
 *  which (via reg_str) becomes
 *
 *      register V3_S2* p __asm__("$12") = verts[0].ptr;
 *
 *  Why bundle the `__asm__()` wrapper?
 *    - The integer R_T4 (= 12, via R_T4_Code) is the canonical truth.
 *    - The string "$12" is derived from it via reg_str, so they
 *      cannot drift apart.
 *    - Spelling `__asm__(reg_str(R_T4_Code))` at every call site is
 *      noise. `rgcc(R_T4)` says what you mean.
 *
 *  The two-level form (rgcc_/rgcc) is the standard preprocessor idiom
 *  for forcing one level of expansion before the bundle's `__asm__`
 *  token is written; without it, `rgcc(R_T4)` would expand to
 *  `__asm__(reg_str(tmpl(R_T4, Code)))` but the inner `tmpl(R_T4, Code)`
 *  would token-paste prematurely.
 *
 *  Layering: reg_str lives in dsl.h (the integer-to-string primitive,
 *  compiler-agnostic in name). tmpl lives in dsl.h (the token-paste
 *  glue). rgcc lives here (gcc_asm.h) because the `__asm__` keyword
 *  is GCC-specific. Anyone porting to a different compiler's asm
 *  dialect overrides rgcc, and the integer→string derivation in
 *  reg_str can be retargeted in one place.
 *
 *  For clobber lists and asm-template strings, use the bare
 *  `reg_str(R_T4_Code)` — you don't want __asm__() there, you just
 *  want the string.
 * ------------------------------------------------------------------------ */
#define rgcc_(n)       __asm__(reg_str(tmpl(n, Code)))
#define rgcc(n)        rgcc_(n)

/* rgcc_ref(n) — GCC operand-reference form "%N". Not currently used
 * by the placeholder-pun macros (the .word bodies are fully baked
 * at compile time and have no runtime operand references), but kept
 * here for completeness in case a future asm template needs to refer
 * to a runtime input by position. Mirror of rgcc but produces "%N"
 * instead of "$N". */
#define rgcc_ref_(n)   "%" #n
#define rgcc_ref(n)    rgcc_ref_(n)
