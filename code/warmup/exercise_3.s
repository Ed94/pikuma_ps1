.psx
.create "exercise_3.bin", 0x80010000

; Entry Point of Code
.org 0x80010000

; Constant declaration
BASE_ADDR equ 0x0000

; Symbol Alias Table

; Instructions
; Load
load_imm   equ li ; dst_reg, immeidate value
; Store
store_word equ sw ; src_reg, dst_address 
; Addition
add_s  equ add   ; dst_reg, reg_a, reg_b (signed)
add_u  equ add   ; dst_reg, reg_a, reg_b (unsigned)
add_si equ addi  ; dst_reg, src_reg, immediate value (signed)
add_ui equ addiu ; dst_reg, src_reg, immediate value (unsigned)
; Subtraction
sub_s equ sub    ; 
sub_u equ subu   ; 
; Branch
branch_equal    equ beq ; reg, value(reg, immediate), dst_label
branch_gt_equal equ bge ; reg, value(reg, immediate), dst_label
branch_lt       equ blt ; reg, value(reg, immediate), dst_label

; Registers
; Temporaries, may be changed by subroutines
rtemp_0 equ $t0
rtemp_1 equ $t1
rtemp_2 equ $t2

; /* C code: */
; main() {
;  int num;  // Assume num is loaded in $t0
;  int den;  // Assume den is loaded in $t1
;  int res;  // Assume res is loaded in $t2
;  num = 27; // Or any other number that we want
;  den = 3;  // Or any other number that we want
;  res = 0;
;  while (num >= den) {
;  num -= den;
;  res++;
;  }
; }

main:
; TODO:
; 1. Initialize $t0 to 27 (or any other value)
; 2. Initialize $t1 to 3 (or any other value)
; 3. Initialize $t2 (res) with 0
; 4. While ($t0 >= $t1) {
; 5. Subtract $t0-$t1 and store it back into $t0
; 6. Increment $t2
; 7. }
; Attempt:
	move     rtemp_2, $zero
	load_imm rtemp_0, 27
	load_imm rtemp_1, 3
	// load_imm rtemp_2, 0
	loop: :: branch_lt rtemp_0, rtemp_1, loop_break :: nop ; loop if < rtemp_0, rtemp_1 {
		sub_s  rtemp_0, rtemp_0, rtemp_1                   ;	-= rtemp_0, rtemp_1
		add_si rtemp_2, rtemp_2, 1                         ;	++ rtemp_2
	j loop :: loop_break:                                  ; }
.close
