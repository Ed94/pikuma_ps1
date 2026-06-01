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

/* --- 2. String Concatenation Helpers --- */
#define _STR1  "%c0"
#define _STR2  _STR1  ", %c1"
#define _STR3  _STR2  ", %c2"
#define _STR4  _STR3  ", %c3"
#define _STR5  _STR4  ", %c4"
#define _STR6  _STR5  ", %c5"
#define _STR7  _STR6  ", %c6"
#define _STR8  _STR7  ", %c7"
#define _STR9  _STR8  ", %c8"
#define _STR10 _STR9  ", %c9"
#define _STR11 _STR10 ", %c10"
#define _STR12 _STR11 ", %c11"
#define _STR13 _STR12 ", %c12"
#define _STR14 _STR13 ", %c13"
#define _STR15 _STR14 ", %c14"
#define _STR16 _STR15 ", %c15"
#define _STR17 _STR16 ", %c16"
#define _STR18 _STR17 ", %c17"
#define _STR19 _STR18 ", %c18"
#define _STR20 _STR19 ", %c19"
#define _STR21 _STR20 ", %c20"
#define _STR22 _STR21 ", %c21"
#define _STR23 _STR22 ", %c22"
#define _STR24 _STR23 ", %c23"
#define _STR25 _STR24 ", %c24"
#define _STR26 _STR25 ", %c25"
#define _STR27 _STR26 ", %c26"
#define _STR28 _STR27 ", %c27"
#define _STR29 _STR28 ", %c28"
#define _STR30 _STR29 ", %c29"
#define _STR31 _STR30 ", %c30"
#define _STR32 _STR31 ", %c31"
#define _STR33 _STR32 ", %c32"
#define _STR34 _STR33 ", %c33"
#define _STR35 _STR34 ", %c34"
#define _STR36 _STR35 ", %c35"
#define _STR37 _STR36 ", %c36"
#define _STR38 _STR37 ", %c37"
#define _STR39 _STR38 ", %c38"
#define _STR40 _STR39 ", %c39"
#define _STR41 _STR40 ", %c40"
#define _STR42 _STR41 ", %c41"
#define _STR43 _STR42 ", %c42"
#define _STR44 _STR43 ", %c43"
#define _STR45 _STR44 ", %c44"
#define _STR46 _STR45 ", %c45"
#define _STR47 _STR46 ", %c46"
#define _STR48 _STR47 ", %c47"
#define _STR49 _STR48 ", %c48"
#define _STR50 _STR49 ", %c49"
#define _STR51 _STR50 ", %c50"
#define _STR52 _STR51 ", %c51"
#define _STR53 _STR52 ", %c52"
#define _STR54 _STR53 ", %c53"
#define _STR55 _STR54 ", %c54"
#define _STR56 _STR55 ", %c55"
#define _STR57 _STR56 ", %c56"
#define _STR58 _STR57 ", %c57"
#define _STR59 _STR58 ", %c58"
#define _STR60 _STR59 ", %c59"
#define _STR61 _STR60 ", %c60"
#define _STR62 _STR61 ", %c61"
#define _STR63 _STR62 ", %c62"
#define _STR64 _STR63 ", %c63"
#define _STR65 _STR64 ", %c64"
#define _STR66 _STR65 ", %c65"
#define _STR67 _STR66 ", %c66"
#define _STR68 _STR67 ", %c67"
#define _STR69 _STR68 ", %c68"
#define _STR70 _STR69 ", %c69"
#define _STR71 _STR70 ", %c70"
#define _STR72 _STR71 ", %c71"
#define _STR73 _STR72 ", %c72"
#define _STR74 _STR73 ", %c73"
#define _STR75 _STR74 ", %c74"
#define _STR76 _STR75 ", %c75"
#define _STR77 _STR76 ", %c76"
#define _STR78 _STR77 ", %c77"
#define _STR79 _STR78 ", %c78"
#define _STR80 _STR79 ", %c79"
#define _STR81 _STR80 ", %c80"
#define _STR82 _STR81 ", %c81"
#define _STR83 _STR82 ", %c82"
#define _STR84 _STR83 ", %c83"
#define _STR85 _STR84 ", %c84"
#define _STR86 _STR85 ", %c85"
#define _STR87 _STR86 ", %c86"
#define _STR88 _STR87 ", %c87"
#define _STR89 _STR88 ", %c88"
#define _STR90 _STR89 ", %c89"
#define _STR91 _STR90 ", %c90"
#define _STR92 _STR91 ", %c91"
#define _STR93 _STR92 ", %c92"
#define _STR94 _STR93 ", %c93"
#define _STR95 _STR94 ", %c94"
#define _STR96 _STR95 ", %c95"
#define _STR97 _STR96 ", %c96"
#define _STR98 _STR97 ", %c97"
#define _STR99 _STR98 ", %c98"

/* --- 3. The Blob Generators (1 to 99) --- */
#define _B1(c, p0) \
    __asm__ volatile (".word " _STR1 : : "i"(p0) : c)
#define _B2(c, p0, p1) \
    __asm__ volatile (".word " _STR2 : : "i"(p0), "i"(p1) : c)
#define _B3(c, p0, p1, p2) \
    __asm__ volatile (".word " _STR3 : : "i"(p0), "i"(p1), "i"(p2) : c)
#define _B4(c, p0, p1, p2, p3) \
    __asm__ volatile (".word " _STR4 : : "i"(p0), "i"(p1), "i"(p2), "i"(p3) : c)
#define _B5(c, p0, p1, p2, p3, p4) \
    __asm__ volatile (".word " _STR5 : : "i"(p0), "i"(p1), "i"(p2), "i"(p3), "i"(p4) : c)
#define _B6(c, p0, p1, p2, p3, p4, p5) \
    __asm__ volatile (".word " _STR6 : : "i"(p0), "i"(p1), "i"(p2), "i"(p3), "i"(p4), "i"(p5) : c)
#define _B7(c, p0, p1, p2, p3, p4, p5, p6) \
    __asm__ volatile (".word " _STR7 : : "i"(p0), "i"(p1), "i"(p2), "i"(p3), "i"(p4), "i"(p5), "i"(p6) : c)
#define _B8(c, p0, p1, p2, p3, p4, p5, p6, p7) \
    __asm__ volatile (".word " _STR8 : : "i"(p0), "i"(p1), "i"(p2), "i"(p3), "i"(p4), "i"(p5), "i"(p6), "i"(p7) : c)
#define _B9(c, p0, p1, p2, p3, p4, p5, p6, p7, p8) \
    __asm__ volatile (".word " _STR9 : : "i"(p0), "i"(p1), "i"(p2), "i"(p3), "i"(p4), "i"(p5), "i"(p6), "i"(p7), "i"(p8) : c)
#define _B10(c, p0, p1, p2, p3, p4, p5, p6, p7, p8, p9) \
    __asm__ volatile (".word " _STR10 : : "i"(p0), "i"(p1), "i"(p2), "i"(p3), "i"(p4), "i"(p5), "i"(p6), "i"(p7), "i"(p8), "i"(p9) : c)

/* Utilizing cascading operand strings to compress the rest of the lines */
#define _I10 "i"(p0),"i"(p1),"i"(p2),"i"(p3),"i"(p4),"i"(p5),"i"(p6),"i"(p7),"i"(p8),"i"(p9)
#define _I20 _I10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15),"i"(p16),"i"(p17),"i"(p18),"i"(p19)
#define _I30 _I20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25),"i"(p26),"i"(p27),"i"(p28),"i"(p29)
#define _I40 _I30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35),"i"(p36),"i"(p37),"i"(p38),"i"(p39)
#define _I50 _I40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45),"i"(p46),"i"(p47),"i"(p48),"i"(p49)
#define _I60 _I50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55),"i"(p56),"i"(p57),"i"(p58),"i"(p59)
#define _I70 _I60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65),"i"(p66),"i"(p67),"i"(p68),"i"(p69)
#define _I80 _I70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75),"i"(p76),"i"(p77),"i"(p78),"i"(p79)
#define _I90 _I80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85),"i"(p86),"i"(p87),"i"(p88),"i"(p89)

#define _B11(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10) \
    __asm__ volatile (".word " _STR11 : : _I10,"i"(p10) : c)
#define _B12(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11) \
    __asm__ volatile (".word " _STR12 : : _I10,"i"(p10),"i"(p11) : c)
#define _B13(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12) \
    __asm__ volatile (".word " _STR13 : : _I10,"i"(p10),"i"(p11),"i"(p12) : c)
#define _B14(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13) \
    __asm__ volatile (".word " _STR14 : : _I10,"i"(p10),"i"(p11),"i"(p12),"i"(p13) : c)
#define _B15(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14) \
    __asm__ volatile (".word " _STR15 : : _I10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14) : c)
#define _B16(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15) \
    __asm__ volatile (".word " _STR16 : : _I10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15) : c)
#define _B17(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16) \
    __asm__ volatile (".word " _STR17 : : _I10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15),"i"(p16) : c)
#define _B18(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17) \
    __asm__ volatile (".word " _STR18 : : _I10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15),"i"(p16),"i"(p17) : c)
#define _B19(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18) \
    __asm__ volatile (".word " _STR19 : : _I10,"i"(p10),"i"(p11),"i"(p12),"i"(p13),"i"(p14),"i"(p15),"i"(p16),"i"(p17),"i"(p18) : c)
#define _B20(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19) \
    __asm__ volatile (".word " _STR20 : : _I20 : c)

#define _B21(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20) \
    __asm__ volatile (".word " _STR21 : : _I20,"i"(p20) : c)
#define _B22(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21) \
    __asm__ volatile (".word " _STR22 : : _I20,"i"(p20),"i"(p21) : c)
#define _B23(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22) \
    __asm__ volatile (".word " _STR23 : : _I20,"i"(p20),"i"(p21),"i"(p22) : c)
#define _B24(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23) \
    __asm__ volatile (".word " _STR24 : : _I20,"i"(p20),"i"(p21),"i"(p22),"i"(p23) : c)
#define _B25(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24) \
    __asm__ volatile (".word " _STR25 : : _I20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24) : c)
#define _B26(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25) \
    __asm__ volatile (".word " _STR26 : : _I20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25) : c)
#define _B27(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26) \
    __asm__ volatile (".word " _STR27 : : _I20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25),"i"(p26) : c)
#define _B28(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27) \
    __asm__ volatile (".word " _STR28 : : _I20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25),"i"(p26),"i"(p27) : c)
#define _B29(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28) \
    __asm__ volatile (".word " _STR29 : : _I20,"i"(p20),"i"(p21),"i"(p22),"i"(p23),"i"(p24),"i"(p25),"i"(p26),"i"(p27),"i"(p28) : c)
#define _B30(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29) \
    __asm__ volatile (".word " _STR30 : : _I30 : c)

#define _B31(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30) \
    __asm__ volatile (".word " _STR31 : : _I30,"i"(p30) : c)
#define _B32(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31) \
    __asm__ volatile (".word " _STR32 : : _I30,"i"(p30),"i"(p31) : c)
#define _B33(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32) \
    __asm__ volatile (".word " _STR33 : : _I30,"i"(p30),"i"(p31),"i"(p32) : c)
#define _B34(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33) \
    __asm__ volatile (".word " _STR34 : : _I30,"i"(p30),"i"(p31),"i"(p32),"i"(p33) : c)
#define _B35(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34) \
    __asm__ volatile (".word " _STR35 : : _I30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34) : c)
#define _B36(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35) \
    __asm__ volatile (".word " _STR36 : : _I30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35) : c)
#define _B37(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36) \
    __asm__ volatile (".word " _STR37 : : _I30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35),"i"(p36) : c)
#define _B38(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37) \
    __asm__ volatile (".word " _STR38 : : _I30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35),"i"(p36),"i"(p37) : c)
#define _B39(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38) \
    __asm__ volatile (".word " _STR39 : : _I30,"i"(p30),"i"(p31),"i"(p32),"i"(p33),"i"(p34),"i"(p35),"i"(p36),"i"(p37),"i"(p38) : c)
#define _B40(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39) \
    __asm__ volatile (".word " _STR40 : : _I40 : c)

#define _B41(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40) \
    __asm__ volatile (".word " _STR41 : : _I40,"i"(p40) : c)
#define _B42(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41) \
    __asm__ volatile (".word " _STR42 : : _I40,"i"(p40),"i"(p41) : c)
#define _B43(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42) \
    __asm__ volatile (".word " _STR43 : : _I40,"i"(p40),"i"(p41),"i"(p42) : c)
#define _B44(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43) \
    __asm__ volatile (".word " _STR44 : : _I40,"i"(p40),"i"(p41),"i"(p42),"i"(p43) : c)
#define _B45(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44) \
    __asm__ volatile (".word " _STR45 : : _I40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44) : c)
#define _B46(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45) \
    __asm__ volatile (".word " _STR46 : : _I40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45) : c)
#define _B47(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46) \
    __asm__ volatile (".word " _STR47 : : _I40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45),"i"(p46) : c)
#define _B48(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47) \
    __asm__ volatile (".word " _STR48 : : _I40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45),"i"(p46),"i"(p47) : c)
#define _B49(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48) \
    __asm__ volatile (".word " _STR49 : : _I40,"i"(p40),"i"(p41),"i"(p42),"i"(p43),"i"(p44),"i"(p45),"i"(p46),"i"(p47),"i"(p48) : c)
#define _B50(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49) \
    __asm__ volatile (".word " _STR50 : : _I50 : c)

#define _B51(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50) \
    __asm__ volatile (".word " _STR51 : : _I50,"i"(p50) : c)
#define _B52(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51) \
    __asm__ volatile (".word " _STR52 : : _I50,"i"(p50),"i"(p51) : c)
#define _B53(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52) \
    __asm__ volatile (".word " _STR53 : : _I50,"i"(p50),"i"(p51),"i"(p52) : c)
#define _B54(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53) \
    __asm__ volatile (".word " _STR54 : : _I50,"i"(p50),"i"(p51),"i"(p52),"i"(p53) : c)
#define _B55(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54) \
    __asm__ volatile (".word " _STR55 : : _I50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54) : c)
#define _B56(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55) \
    __asm__ volatile (".word " _STR56 : : _I50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55) : c)
#define _B57(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56) \
    __asm__ volatile (".word " _STR57 : : _I50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55),"i"(p56) : c)
#define _B58(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57) \
    __asm__ volatile (".word " _STR58 : : _I50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55),"i"(p56),"i"(p57) : c)
#define _B59(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58) \
    __asm__ volatile (".word " _STR59 : : _I50,"i"(p50),"i"(p51),"i"(p52),"i"(p53),"i"(p54),"i"(p55),"i"(p56),"i"(p57),"i"(p58) : c)
#define _B60(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59) \
    __asm__ volatile (".word " _STR60 : : _I60 : c)

#define _B61(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60) \
    __asm__ volatile (".word " _STR61 : : _I60,"i"(p60) : c)
#define _B62(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61) \
    __asm__ volatile (".word " _STR62 : : _I60,"i"(p60),"i"(p61) : c)
#define _B63(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62) \
    __asm__ volatile (".word " _STR63 : : _I60,"i"(p60),"i"(p61),"i"(p62) : c)
#define _B64(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63) \
    __asm__ volatile (".word " _STR64 : : _I60,"i"(p60),"i"(p61),"i"(p62),"i"(p63) : c)
#define _B65(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64) \
    __asm__ volatile (".word " _STR65 : : _I60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64) : c)
#define _B66(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65) \
    __asm__ volatile (".word " _STR66 : : _I60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65) : c)
#define _B67(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66) \
    __asm__ volatile (".word " _STR67 : : _I60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65),"i"(p66) : c)
#define _B68(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67) \
    __asm__ volatile (".word " _STR68 : : _I60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65),"i"(p66),"i"(p67) : c)
#define _B69(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68) \
    __asm__ volatile (".word " _STR69 : : _I60,"i"(p60),"i"(p61),"i"(p62),"i"(p63),"i"(p64),"i"(p65),"i"(p66),"i"(p67),"i"(p68) : c)
#define _B70(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69) \
    __asm__ volatile (".word " _STR70 : : _I70 : c)

#define _B71(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70) \
    __asm__ volatile (".word " _STR71 : : _I70,"i"(p70) : c)
#define _B72(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71) \
    __asm__ volatile (".word " _STR72 : : _I70,"i"(p70),"i"(p71) : c)
#define _B73(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72) \
    __asm__ volatile (".word " _STR73 : : _I70,"i"(p70),"i"(p71),"i"(p72) : c)
#define _B74(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73) \
    __asm__ volatile (".word " _STR74 : : _I70,"i"(p70),"i"(p71),"i"(p72),"i"(p73) : c)
#define _B75(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74) \
    __asm__ volatile (".word " _STR75 : : _I70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74) : c)
#define _B76(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75) \
    __asm__ volatile (".word " _STR76 : : _I70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75) : c)
#define _B77(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76) \
    __asm__ volatile (".word " _STR77 : : _I70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75),"i"(p76) : c)
#define _B78(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77) \
    __asm__ volatile (".word " _STR78 : : _I70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75),"i"(p76),"i"(p77) : c)
#define _B79(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78) \
    __asm__ volatile (".word " _STR79 : : _I70,"i"(p70),"i"(p71),"i"(p72),"i"(p73),"i"(p74),"i"(p75),"i"(p76),"i"(p77),"i"(p78) : c)
#define _B80(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79) \
    __asm__ volatile (".word " _STR80 : : _I80 : c)

#define _B81(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80) \
    __asm__ volatile (".word " _STR81 : : _I80,"i"(p80) : c)
#define _B82(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81) \
    __asm__ volatile (".word " _STR82 : : _I80,"i"(p80),"i"(p81) : c)
#define _B83(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82) \
    __asm__ volatile (".word " _STR83 : : _I80,"i"(p80),"i"(p81),"i"(p82) : c)
#define _B84(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83) \
    __asm__ volatile (".word " _STR84 : : _I80,"i"(p80),"i"(p81),"i"(p82),"i"(p83) : c)
#define _B85(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84) \
    __asm__ volatile (".word " _STR85 : : _I80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84) : c)
#define _B86(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85) \
    __asm__ volatile (".word " _STR86 : : _I80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85) : c)
#define _B87(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86) \
    __asm__ volatile (".word " _STR87 : : _I80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85),"i"(p86) : c)
#define _B88(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87) \
    __asm__ volatile (".word " _STR88 : : _I80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85),"i"(p86),"i"(p87) : c)
#define _B89(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88) \
    __asm__ volatile (".word " _STR89 : : _I80,"i"(p80),"i"(p81),"i"(p82),"i"(p83),"i"(p84),"i"(p85),"i"(p86),"i"(p87),"i"(p88) : c)
#define _B90(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89) \
    __asm__ volatile (".word " _STR90 : : _I90 : c)

#define _B91(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90) \
    __asm__ volatile (".word " _STR91 : : _I90,"i"(p90) : c)
#define _B92(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91) \
    __asm__ volatile (".word " _STR92 : : _I90,"i"(p90),"i"(p91) : c)
#define _B93(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92) \
    __asm__ volatile (".word " _STR93 : : _I90,"i"(p90),"i"(p91),"i"(p92) : c)
#define _B94(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93) \
    __asm__ volatile (".word " _STR94 : : _I90,"i"(p90),"i"(p91),"i"(p92),"i"(p93) : c)
#define _B95(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94) \
    __asm__ volatile (".word " _STR95 : : _I90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94) : c)
#define _B96(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94,p95) \
    __asm__ volatile (".word " _STR96 : : _I90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94),"i"(p95) : c)
#define _B97(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94,p95,p96) \
    __asm__ volatile (".word " _STR97 : : _I90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94),"i"(p95),"i"(p96) : c)
#define _B98(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94,p95,p96,p97) \
    __asm__ volatile (".word " _STR98 : : _I90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94),"i"(p95),"i"(p96),"i"(p97) : c)
#define _B99(c,p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23,p24,p25,p26,p27,p28,p29,p30,p31,p32,p33,p34,p35,p36,p37,p38,p39,p40,p41,p42,p43,p44,p45,p46,p47,p48,p49,p50,p51,p52,p53,p54,p55,p56,p57,p58,p59,p60,p61,p62,p63,p64,p65,p66,p67,p68,p69,p70,p71,p72,p73,p74,p75,p76,p77,p78,p79,p80,p81,p82,p83,p84,p85,p86,p87,p88,p89,p90,p91,p92,p93,p94,p95,p96,p97,p98) \
    __asm__ volatile (".word " _STR99 : : _I90,"i"(p90),"i"(p91),"i"(p92),"i"(p93),"i"(p94),"i"(p95),"i"(p96),"i"(p97),"i"(p98) : c)

/* --- 4. The Final Exposed Macro --- */
#define _ASM_BLOB_DISPATCH(count) glue(_B, count)
#define asm_blob(clobbers, ...) m_expand(_ASM_BLOB_DISPATCH(_ASM_COUNT_ARGS(__VA_ARGS__))(clobbers, __VA_ARGS__))
