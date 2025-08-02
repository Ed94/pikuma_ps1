.psx
.create "exercise1.bin", 0x80010000

; Entry Point of Code
.org 0x80010000

; Constant declaration
BASE_ADDR equ 0x0000


; Symbol Alias Table

; Instructions
load_imm equ li

; Registers
rtemp_0 equ $t0
rtemp_1 equ $t1
rtemp_2 equ $t2

.macro test,dst_reg,value
	li dst_reg,value
.endmacro

.macro test2,reg
	li reg,0xA000
.endmacro

.macro myli,dest,value
   .if value & ~0xFFFF
      ori   dest,r0,value
   .elseif (value & 0xFFFF8000) == 0xFFFF8000
      addiu dest,r0,value & 0xFFFF
   .elseif (value & 0xFFFF) == 0
      lui   dest,value >> 16
   .else
      lui   dest,value >> 16 + (value & 0x8000 != 0)
      addiu dest,dest,value & 0xFFFF
   .endif
.endmacro

.macro store_word, src_reg, dst_address
	sw src_reg, dst_address
.endmacro

Main:
	myli $t0, 0xA000
	li rtemp_1, 0xA100     ; $t1 = 0xA100
	li rtemp_2, 0x11111111 ; $t2 = 0x11111111

Loop:
	sw   $t2, BASE_ADDR($t0) ; Store byte at 0x0000 + t0
	addi $t0, $t0, 4         ; ++ t0
	blt  $t0, $t1, Loop      ; while (t0 < t1) keep looping

.close
