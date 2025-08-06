.include "./toolchain/pcsx-redux/src/mips/common/crt0/crt0.s"

.include "./asmdd/dsl.asm"
.include "./asmdd/io.asm"
.include "./asmdd/gp.asm"

#.section .text.gp, "ax, @progbits"
#.align 2
.global gp_screen_init
.type gp_screen_init, @function
gp_screen_init:
	.equiv rio_offset, rtmp_0
	load_imm rtmp_0, IO_BASE_ADDR
	#define gp0 gpio_port0(rio_offset)
	#define gp1 gpio_port1(rio_offset)

	gcmd_push gp1, rtmp_1, gp_Reset
	nop; nop;
	gcmd_push gp1, rtmp_1, gp_DisplayEnabled
	jump_reg  rret_addr; nop

.Lgp_screen_init_end:
.size gp_screen_init, . - gp_screen_init
