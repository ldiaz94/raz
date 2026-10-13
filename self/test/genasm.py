#!/usr/bin/env python3
"""Writes the files the assembler of X64 is tested on, into the directory
given: valid.raz, a long run of instructions of every kind the assembler
knows, and one small file for each error it reports. Each ends in `end`,
as a code procedure's body does. Fixed seed: the same files each run."""
import random, sys, os

random.seed(7)
out = sys.argv[1]
os.makedirs(out, exist_ok=True)

R64 = "rax rcx rdx rbx rsp rbp rsi rdi r8 r9 r10 r11 r12 r13 r14 r15".split()
R32 = "eax ecx edx ebx esp ebp esi edi r8d r9d r10d r11d r12d r13d r14d r15d".split()
R16 = "ax cx dx bx sp bp si di r8w r9w r10w r11w r12w r13w r14w r15w".split()
R8 = "al cl dl bl spl bpl sil dil r8b r9b r10b r11b r12b r13b r14b r15b".split()
BY = {8: R64, 4: R32, 2: R16, 1: R8}
PRE = {8: "qword ", 4: "dword ", 2: "word ", 1: "byte "}
XM = ["xmm%d" % i for i in range(16)]
CC = "o no b ae e ne be a s ns p np l ge le g c nae nc nb z nz na nbe nge nl ng nle".split()


def reg(size=8):
    return random.choice(BY[size])


def mem(size=0):
    k = random.randrange(8)
    b = random.choice(R64)
    i = random.choice([r for r in R64 if r != "rsp"])
    d = random.choice([0, 8, -8, 127, -128, 128, 4096, -4096, 100000])
    s = random.choice([1, 2, 4, 8])
    p = PRE[size] if size else ""
    if k == 0:
        t = "[%s]" % b
    elif k == 1:
        t = "[%s + %d]" % (b, abs(d)) if d >= 0 else "[%s - %d]" % (b, -d)
    elif k == 2:
        t = "[%s + %s * %d]" % (b, i, s)
    elif k == 3:
        t = "[%s + %s * %d + %d]" % (b, i, s, abs(d)) if d >= 0 else "[%s + %s * %d - %d]" % (b, i, s, -d)
    elif k == 4:
        t = "[%s + %s]" % (b, i)
    elif k == 5:
        t = "[%s + 0]" % b
    elif k == 6:
        t = "[rsp + %d]" % abs(d)
    else:
        t = "[%s - %d]" % (b, abs(d) + 1)
    return p + t


def imm(size):
    if size == 1:
        return str(random.choice([0, 1, -1, 127, 255, -128, 77]))
    if size == 2:
        return str(random.choice([0, 1, -1, 300, 32767, -32768, 255, 65535]))
    return str(random.choice([0, 1, -1, 127, 128, -128, -129, 100000, -100000, 2147483647, -2147483648, 4294967295]))


def size():
    return random.choice([1, 2, 4, 8])


lines = []


def emit(s):
    lines.append("    " + s + ";")


for n in range(900):
    k = random.randrange(40)
    sz = size()
    if k < 6:
        op = random.choice("add or adc sbb and sub xor cmp".split())
        f = random.randrange(5)
        if f == 0:
            emit("%s %s, %s" % (op, reg(sz), reg(sz)))
        elif f == 1:
            emit("%s %s, %s" % (op, reg(sz), mem(sz if random.random() < .5 else 0)))
        elif f == 2:
            emit("%s %s, %s" % (op, mem(sz if random.random() < .5 else 0), reg(sz)))
        elif f == 3:
            emit("%s %s, %s" % (op, reg(sz), imm(sz)))
        else:
            emit("%s %s, %s" % (op, mem(sz), imm(sz)))
    elif k < 10:
        f = random.randrange(5)
        if f == 0:
            emit("mov %s, %s" % (reg(sz), reg(sz)))
        elif f == 1:
            emit("mov %s, %s" % (reg(sz), mem()))
        elif f == 2:
            emit("mov %s, %s" % (mem(), reg(sz)))
        elif f == 3:
            v = random.choice([0, 5, -5, 2147483647, 4294967295, 4294967296, -2147483649, 123456789012345])
            emit("mov %s, %d" % (reg(8 if sz >= 4 else sz) if sz >= 4 else reg(sz), v if sz == 8 else (v % 65536 if sz == 2 else v % 256 if sz == 1 else v % 4294967296)))
        else:
            emit("mov %s, %s" % (mem(sz), imm(sz)))
    elif k == 10:
        emit("test %s, %s" % (reg(sz), random.choice([reg(sz), imm(sz) if sz != 1 else "1"])))
    elif k == 11:
        emit("xchg %s, %s" % (random.choice([reg(sz), mem()]), reg(sz)))
    elif k == 12:
        emit("%slock %s %s, %s" % ("", random.choice(["cmpxchg", "xadd"]), mem(), reg(sz)))
    elif k == 13:
        emit("lea %s, %s" % (reg(random.choice([2, 4, 8])), mem()))
    elif k == 14:
        op = random.choice(["movzx", "movsx"])
        emit("%s %s, %s" % (op, reg(random.choice([2, 4, 8])), random.choice([mem(random.choice([1, 2])), reg(random.choice([1, 2]))])))
    elif k == 15:
        emit("movsxd %s, %s" % (reg(8), random.choice([mem(4), reg(4)])))
    elif k == 16:
        emit("%s %s" % (random.choice("not neg mul imul div idiv inc dec".split()), random.choice([reg(sz), mem(sz)])))
    elif k == 17:
        emit("imul %s" % ", ".join([reg(sz if sz > 1 else 4), random.choice([reg(sz if sz > 1 else 4)] * 1 + [mem()])] + ([imm(sz if sz > 1 else 4)] if random.random() < .4 else [])).replace("%", "%"))
    elif k == 18:
        op = random.choice("rol ror rcl rcr shl shr sal sar".split())
        emit("%s %s, %s" % (op, random.choice([reg(sz), mem(sz)]), random.choice([str(random.randrange(64)), "cl"])))
    elif k == 19:
        emit("%s %s" % (random.choice(["push", "pop"]), reg(8)))
    elif k == 20:
        op = random.choice(["call", "jmp"])
        emit("%s %s" % (op, random.choice([reg(8), mem()]) if op == "call" else mem()))
    elif k == 21:
        emit("set%s %s" % (random.choice(CC), random.choice([reg(1), mem(1)])))
    elif k == 22:
        emit("cmov%s %s, %s" % (random.choice(CC), reg(random.choice([2, 4, 8])), random.choice([reg(8), mem()])))
    elif k == 23:
        op = random.choice("sqrt add mul sub min div max".split()) + random.choice(["sd", "ss"])
        emit("%s %s, %s" % (op, random.choice(XM), random.choice([random.choice(XM), mem()])))
    elif k == 24:
        op = random.choice("punpcklbw punpcklwd pcmpeqb pand pandn por pxor paddb psubb".split())
        emit("%s %s, %s" % (op, random.choice(XM), random.choice([random.choice(XM), mem()])))
    elif k == 25:
        emit("pshufd %s, %s, %d" % (random.choice(XM), random.choice([random.choice(XM), mem()]), random.randrange(256)))
    elif k == 26:
        op = random.choice(["movdqu", "movdqa"])
        if random.random() < .5:
            emit("%s %s, %s" % (op, random.choice(XM), random.choice([random.choice(XM), mem()])))
        else:
            emit("%s %s, %s" % (op, mem(), random.choice(XM)))
    elif k == 27:
        emit("pmovmskb %s, %s" % (reg(4), random.choice(XM)))
    elif k == 28:
        emit("%s %s, %s" % (random.choice("bsf bsr tzcnt lzcnt popcnt".split()), reg(random.choice([4, 8])), random.choice([reg(8), mem()])))
    elif k == 29:
        op = random.choice(["movsd", "movss"])
        if random.random() < .5:
            emit("%s %s, %s" % (op, random.choice(XM), random.choice([random.choice(XM), mem()])))
        else:
            emit("%s %s, %s" % (op, mem(), random.choice(XM)))
    elif k == 30:
        op = random.choice(["movq", "movd"])
        if random.random() < .5:
            emit("%s %s, %s" % (op, random.choice(XM), random.choice([reg(8), mem()])))
        else:
            emit("%s %s, %s" % (op, random.choice([reg(8), mem()]), random.choice(XM)))
    elif k == 31:
        emit("%s %s, %s" % (random.choice(["ucomisd", "ucomiss"]), random.choice(XM), random.choice([random.choice(XM), mem()])))
    elif k == 32:
        emit("%s %s, %s" % (random.choice(["cvtsi2sd", "cvtsi2ss"]), random.choice(XM), random.choice([reg(random.choice([4, 8])), mem(random.choice([4, 8]))])))
    elif k == 33:
        emit("%s %s, %s" % (random.choice(["cvttsd2si", "cvttss2si"]), reg(random.choice([4, 8])), random.choice([random.choice(XM), mem()])))
    elif k == 34:
        emit("%s %s, %s" % (random.choice(["cvtsd2ss", "cvtss2sd"]), random.choice(XM), random.choice([random.choice(XM), mem()])))
    elif k == 35:
        emit(random.choice("ret leave syscall cpuid rdtsc pause nop ud2 int3 hlt cqo cdq mfence lfence sfence".split()))
    elif k == 36:
        emit("db " + ", ".join(str(random.choice([0, 1, 255, 128, 77, -1, -128])) for _ in range(random.randrange(1, 6))))
    elif k == 37:
        lines.append("  L%d:" % n)
        lines.append("    add rax, 1;")
        lines.append("    j%s L%d;" % (random.choice(CC), n))
        lines.append("    jmp L%d;" % n)
    elif k == 38:
        lines.append("    jmp F%d;" % n)
        lines.append("    nop;")
        lines.append("    j%s F%d;" % (random.choice(CC), n))
        lines.append("  F%d:" % n)
    else:
        emit("lock add %s, %s" % (mem(sz), reg(sz)))

open(os.path.join(out, "valid.raz"), "w").write("\n".join(lines) + "\n    end\n")

errors = {
    "empty": "",
    "badop": "foo rax;",
    "noinsn": "42;",
    "nosemi": "nop",
    "undefined": "jmp nowhere;",
    "twice": "a: nop; a: nop;",
    "toomany": "add rax, rbx, rcx, rdx;",
    "movimm": "mov 1, 2;",
    "movmm": "mov [rax], [rbx];",
    "addimm": "add 1, rax;",
    "pushmem": "push [rax];",
    "pushsmall": "push eax;",
    "badmem": "mov rax, [rsi * 4];",
    "badscale": "mov rax, [rsi + rdi * 3];",
    "nomem": "mov rax, [];",
    "unclosed": "mov rax, [rbx;",
    "shiftcl": "shl rax, dl;",
    "shiftimm": "shl 3, 1;",
    "lea": "lea rax, rbx;",
    "movzx": "movzx rax, rbx;",
    "movzx4": "movzx rax, dword [rbx];",
    "setsize": "sete rax;",
    "cmovimm": "cmove rax, 5;",
    "sse": "addsd rax, xmm1;",
    "sse1": "addsd xmm1;",
    "pshufd": "pshufd xmm1, xmm2;",
    "pand3": "pand xmm1, xmm2, 3;",
    "movdq": "movdqu rax, xmm1;",
    "pmov": "pmovmskb xmm1, rax;",
    "bits": "popcnt ax, bx;",
    "movsd": "movsd rax, xmm1;",
    "movq": "movq rax, rbx;",
    "ucomi": "ucomisd rax, xmm1;",
    "cvtsi": "cvtsi2sd rax, xmm1;",
    "cvtt": "cvttsd2si xmm1, xmm2;",
    "cvtss": "cvtss2sd rax, xmm1;",
    "plainops": "ret rax;",
    "dbrange": "db 256;",
    "dbneg": "db -129;",
    "imul1": "imul rax, 5;",
    "imulmem": "imul [rax], rbx;",
    "unary2": "not rax, rbx;",
    "unaryimm": "neg 5;",
    "inc": "inc 5;",
    "xchgimm": "xchg rax, 5;",
    "cmpxchg": "cmpxchg rax, 5;",
    "calli": "call 5;",
    "jmpimm": "jmp 5;",
    "labels65": "".join("l%d: nop; " % i for i in range(65)),
    "xmm16": "addsd xmm16, xmm1;",
    "noend": None,
}
for name, body in errors.items():
    if body is None:
        text = "    nop;\n"
    else:
        text = "    " + body + "\n    end\n"
    open(os.path.join(out, "err_%s.raz" % name), "w").write(text)
