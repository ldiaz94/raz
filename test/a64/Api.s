// Encode.raz's calls of A64, one line each in its order, in Apple's
// syntax: the instructions each call must make. expect.sh assembles it.
// moves
movz x0, #0
movz x1, #0x1234
movz x2, #0x1234, lsl #16
movn x3, #0
movn x4, #1, lsl #16
orr x5, xzr, #0x00ff00ff00ff00ff
movz x6, #0xdef0 ; movk x6, #0x9abc, lsl #16 ; movk x6, #0x5678, lsl #32 ; movk x6, #0x1234, lsl #48
movn x7, #0xa987 ; movk x7, #0x1234, lsl #32
orr x8, xzr, #0x100000001
orr x9, xzr, #0x5555555555555555
movz x10, #0x8000, lsl #48
movn x11, #0x8000, lsl #48
orr x12, xzr, #0xffffffff
movz x13, #0xabcd ; movk x13, #0xffff, lsl #32
orr x0, xzr, x1
add sp, x29, #0
add x29, sp, #0
// two registers
add x0, x1, x2
adds x3, x4, x5
sub x6, x7, x8
subs x9, x10, x11
and x12, x13, x14
orr x15, x16, x17
eor x19, x20, x21
ands x22, x23, x24
bic x25, x26, x27
orn x28, x29, x30
add x0, x1, x2, lsl #3
sub x3, x4, x5, asr #63
orr x6, x7, x8, ror #1
// immediates
add x0, x1, #4095
add x0, x1, #1, lsl #12
add sp, sp, #16
sub sp, sp, #0x123, lsl #12
sub x0, x1, #8
sub x2, x3, #0x12, lsl #12 ; sub x2, x2, #0x345
movz x16, #0x4567 ; movk x16, #0x123, lsl #16 ; add x4, sp, x16, uxtx
movz x16, #0x2345 ; movk x16, #0x1, lsl #16 ; adds x5, x6, x16, uxtx
and x0, x1, #0xff
orr sp, x1, #0xf0
movz x16, #0x1234 ; eor x2, x3, x16
subs xzr, x0, x1
cmp sp, #32
cmn x2, #5
movz x16, #0x1001 ; movk x16, #0x100, lsl #16 ; subs xzr, x3, x16, uxtx
tst x4, x5
tst x6, #1
tst x7, #0x8000000000000000
neg x0, x1
mvn x2, x3
// shifts and fields
lsl x0, x1, x2
lsr x3, x4, x5
asr x6, x7, x8
ror x9, x10, x11
lsl w3, w4, w5
lsl x0, x1, #3
lsr x0, x1, #63
asr x2, x3, #1
ror x4, x5, #7
lsl w6, w7, #31
ror w8, w9, #16
ubfm x0, x1, #0, #63
ubfx x0, x1, #8, #8
sbfx x2, x3, #0, #32
sxtb x0, w1
sxth x2, w3
sxtw x4, w5
uxtb w6, w7
uxth w8, w9
mov w10, w11
// multiply, divide, select, count
mul x0, x1, x2
madd x3, x4, x5, x6
msub x7, x8, x9, x10
smulh x0, x1, x2
umulh x3, x4, x5
sdiv x3, x4, x5
udiv x6, x7, x8
csel x0, x1, x2, eq
csinc x3, x4, x5, ne
csneg x6, x7, x8, lt
cset x9, gt
clz x0, x1
clz w2, w3
rbit x4, x5
// loads and stores
ldr x0, [x1]
ldr x0, [x1, #32760]
movz x16, #0x8000 ; ldr x2, [x3, x16]
ldur x4, [x5, #-8]
ldur x4, [x5, #-256]
ldur x6, [x7, #3]
ldrb w8, [x9, #4095]
ldrsb x10, [x11, #4]
ldrh w12, [x13, #8190]
ldrsh x14, [x15, #6]
ldr w0, [sp, #16380]
ldrsw x1, [x2, #4]
ldursb x3, [x4, #-1]
str x0, [x1, #8]
str w2, [sp]
sturh w3, [x4, #1]
strb w5, [x6, #4095]
str xzr, [x7]
ldr x0, [x1, x2, lsl #3]
ldrsb x3, [x4, x5]
ldr w6, [x7, x8, lsl #2]
strh w9, [x10, x11, lsl #1]
str x12, [x13, x14]
ldr x0, [sp], #16
str x1, [sp, #-16]!
str w2, [x3, #-256]!
ldrb w4, [x5], #255
ldr d0, [x1, #8]
ldr s2, [x3, #4]
ldr q4, [x5, #32]
str q6, [sp, #65520]
stur d7, [x8, #-4]
str s9, [x10]
stp x29, x30, [sp, #-16]!
ldp x29, x30, [sp], #16
stp x19, x20, [sp, #504]
ldp x21, x22, [x1, #-512]
// atomics and the system's
ldaddal x1, x0, [x2]
ldaddal w3, w4, [x5]
swpal x6, x7, [x8]
swpal w9, w10, [x11]
casal x12, x13, [x14]
casal w15, w16, [x17]
dmb ish
svc #0x80
svc #0
brk #1
brk #0xf000
// reals
fmul d0, d1, d2
fdiv d0, d1, d2
fadd d0, d1, d2
fsub d0, d1, d2
fmax d0, d1, d2
fmin d0, d1, d2
fadd s3, s4, s5
fmov d0, d1
fabs d0, d1
fneg d0, d1
fsqrt d0, d1
fsqrt s6, s7
fcvt d0, s1
fcvt s2, d3
fcmp d0, d1
fcmp s2, s3
fcmp d4, #0.0
fcmp s5, #0.0
scvtf d0, x1
scvtf s2, x3
ucvtf d4, x5
fcvtzs x0, d1
fcvtzu x2, s3
fmov d0, x1
fmov s2, w3
fmov x4, d5
fmov w6, s7
cnt v16.8b, v17.8b
addv b18, v19.8b
// addresses, calls
adr x0, .
adr x1, .-4
adr x2, .+1048572
adrp x0, _glob@PAGE ; add x0, x0, _glob@PAGEOFF
adrp x16, _glob@PAGE ; ldr x1, [x16, _glob@PAGEOFF]
adrp x16, _glob@PAGE ; str w2, [x16, _glob@PAGEOFF]
adrp x16, _glob@PAGE ; ldr d3, [x16, _glob@PAGEOFF]
adrp x16, _glob@PAGE ; str s4, [x16, _glob@PAGEOFF]
adrp x16, _byte@PAGE ; add x16, x16, _byte@PAGEOFF ; ldr x5, [x16]
bl _proc1
b _proc1
bl Lstart
blr x5
br x6
ret
// jumps within the procedure
b.eq L1
cbz x3, L1
cbnz x4, L1
tbnz x5, #3, .+8 ; b L1
tbz x6, #40, .+8 ; b L1
b L1
L1:
Ltop:
orr x0, xzr, x1
b.ne Ltop
b Ltop
b L2
b.lo L2
b L2
L2:
orr x1, xzr, x2
.p2align 4
// the farthest
b.ne Lfar
cbz x1, Lfar
.p2align 20
Lfar:
b.eq Lstart
