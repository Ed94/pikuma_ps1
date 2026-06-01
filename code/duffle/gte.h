#ifdef INTELLISENSE_DIRECTIVES
#	pragma once
#	include "dsl.h"
#	include "math.h"
#endif

/* C2 data registers */

#define C2_VXY0  0
#define C2_VZ0   1
#define C2_VXY1  2
#define C2_VZ1   3
#define C2_VXY2  4
#define C2_VZ2   5
#define C2_RGB   6
#define C2_OTZ   7
#define C2_IR0   8
#define C2_IR1   9
#define C2_IR2  10
#define C2_IR3  11
#define C2_SXY0 12
#define C2_SXY1 13
#define C2_SXY2 14
#define C2_SXYP 15
#define C2_SZ0  16
#define C2_SZ1  17
#define C2_SZ2  18
#define C2_SZ3  19
#define C2_MAC0 24
#define C2_MAC1 25
#define C2_MAC2 26
#define C2_FLAG 31

/* C2 control registers */

#define C2_RT11RT12  0
#define C2_RT13RT21  1
#define C2_RT22RT23  2
#define C2_RT31RT32  3
#define C2_RT33_TRX  4
#define C2_TRY_TRZ   5
#define C2_OFX_OFY   18   /* (low = OFX, high = OFY) */
#define C2_H_SF      20

/* Command codes (low 6 bits) */

#define CMD_RTPS  0x01
#define CMD_RTPT  0x02
#define CMD_NCLIP 0x06
#define CMD_OP    0x0C
#define CMD_DPCS  0x10
#define CMD_INTPL 0x11
#define CMD_MVMVA 0x09
#define CMD_AVSZ3 0x2D
#define CMD_AVSZ4 0x2E

