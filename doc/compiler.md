# Reading the raz compiler

The compiler is twelve files of raz, about 12,800 lines of code (the
budget is 14,000). It is its own compiler: a release of it, the one
`BOOT` names, builds `src/`, and `make fixpoint` checks that what it
makes makes itself again, byte for byte. Each release was built by the
one before it, back to v0.19.0, which the Pascal compiler it was ported
from built; that compiler, the seed, is in git at v0.19.0 (`seed/`),
and a comment that names "the seed" means it. This guide walks through
the files in the order they are best read: from the
characters of a source file to the bytes of an executable. It assumes
you know the language from `doc/raz.md`, and enough x86-64 to read a
disassembly. The manual pages say the rest: `raz(1)` the command,
`raz-tutorial(7)` and `raz(7)` the language, and `raz-lib(3)` the
library, made from `lib/` by `tools/Doc.raz`.

| File | Lines | Code | What |
|---|---|---|---|
| `src/Diag.raz` | 423 | 325 | Messages: positions, source excerpts, colour, counts |
| `src/Scan.raz` | 1,170 | 966 | Symbols, literals, comments, positions |
| `src/Sym.raz` | 815 | 652 | Types, objects, scopes, layout |
| `src/Chunk.raz` | 364 | 280 | The compiled program: chunks, fixups, line notes |
| `src/X64.raz` | 1,621 | 1,330 | The instruction encoder, jumps within a procedure, the assembler |
| `src/Gen.raz` | 2,846 | 1,989 | The stack machine, for x86-64: values, operations, checks, calls, frames |
| `src/Item.raz` | 2,553 | 2,051 | Items: types, constants, variables, operators, conversions, calls |
| `src/Parse.raz` | 4,845 | 4,121 | Declarations, statements, expressions, built-ins, recovery, warnings |
| `src/Link.raz` | 408 | 316 | Tree shaking, layout, patching, the places |
| `src/Elf.raz` | 450 | 356 | Static and dynamic ELF, symbol table, line numbers |
| `src/Host.raz` | 103 | 52 | The system running the compiler |
| `src/Raz.raz` | 439 | 345 | The command line |

Every file opens with a comment that says what it is, what it depends
on and what it leaves out. Read those first; they are the map.

## The shape of it

There is one pass and no tree. The parser reads a construct and, in
the same breath, has the code generator emit its machine code. Nothing
is kept to be looked at again, except the declarations, which live in
the symbol table for as long as the compiler runs. An error is shown
at once and returned as an `ERROR` (`Scan.Failed`), which each routine
passes up with `try` to where the parser reads on, at the next
statement or declaration.

Three layers do it. `Parse.raz` knows the language's syntax. `Item.raz`
knows what the program means: each operand is an *item*, as in Wirth's
compilers, and the routines there check the items' types, fold
constants and work out where variables are. Neither knows the machine:
they drive a stack machine, `Gen.raz`, by its calls (push a value,
add the two on top, store the top in a variable, jump if it is false),
each with the kind of the value (a word, a 64-bit integer, an `F32`,
an `F64`). `Gen.raz` is the only one that knows x86-64; a port to
another machine is a new `Gen.raz`, with an encoder of its own in place
of `X64.raz`.

On x86-64 the stack lives in registers, as in Wirth's compilers
(Niklaus Wirth's Pascal and Oberon compilers): the value at depth `d`,
depth 0 being the bottom, is in register `d mod 4`, of `r8` to `r11`,
or of `xmm8` to `xmm11` for a real.
A value that needs a register a lower one holds *spills* it: stores it
in a frame slot, to free the register. A constant or an address in the
frame or of a chunk is only noted, until something needs it in a
register, so that it can be an instruction's operand. A
comparison, too, waits as a condition, so that `if` and `while` jump
on it directly. Which register a value goes in is settled
by its depth, so there is no register allocator for values, and every
access the program writes is one instruction, in the order written.
That is also why `VOLATILE` costs the compiler nothing: it never does
anything clever to begin with. A procedure's busiest variables, up to
five, live in registers that calls leave alone: the callee-saved ones
of System V, the calling convention of x86-64 Linux, which a called
procedure must give back as it found them (`rbx` and `r12` to `r15`).
Nothing but their own assignments can change them. Up to four reals
live in `xmm12` to `xmm15` (eight, with `xmm4` to `xmm7`, in a
procedure that calls nothing), each written to the frame as well and
loaded from there after a call, as System V has no xmm register that
a call leaves alone.

The output is a set of *chunks*: one for each procedure, each module
variable, each string. Code refers to other chunks through *fixups*,
which aren't resolved until the end. When everything is compiled, the
linker marks the chunks the entry point can reach, gives each an
address, patches the fixups, and the ELF writer puts them in a file.
Whatever nothing reaches never makes it into the executable.

All modules are compiled in one run, from source: there are no object
files, no symbol files, and nothing to keep up to date.

## Following one program

`raz Hello.raz` does this:

1. `Raz.raz` reads the command line and calls `compileMain`
   (`Parse.raz`).
2. `compileMain` imports `Rt` first, since every program needs it, and
   then compiles `Hello.raz` with `compileFile`.
3. `compileFile` opens the file in the scanner and parses the module.
   At `import Out;` it calls `importModule`, which finds `Out.raz` and
   compiles it there and then, saving and restoring the scanner (`Scan.saveScan`, `Scan.restoreScan`) and the
   scopes around it. So modules are finished in an order where each
   comes after those it imports; that is the order their bodies run.
4. Each procedure becomes a chunk of code; `Out.str("hello, world\n")`
   becomes a string chunk, a call, and a fixup to `Out.str`'s chunk.
5. Back in `Raz.raz`, `use` marks the modules the program uses; the
   entry point, `_start`, is written by `Gen.raz`'s `entryPoint` as one
   more chunk: save `argc` and `argv` and the address of the places
   (below), call every used module's body, call `main`, call `Rt.exit`.
6. `markLive` (`Link.raz`) marks what `_start` reaches; then
   `writeElf` (`Elf.raz`) has `Link.linkAll` place it and patch it, and
   writes headers, code, data, symbols and line numbers.

## A procedure, compiled

```
proc scale(a, b: I64): I64;
begin
    return a + b * 2;
end;
```

comes out as this (from `objdump -d -M intel`; `raz -S` shows the same
under each line of source, named by the compiler as it made them):

```
push   rbp                            ; enterBody: the frame
mov    rbp,rsp
sub    rsp,0x10                       ; its size, patched in by endProc
mov    r9,rsi                         ; b, at depth 1; a, at depth 0, and
shl    r9,0x1                         ;   the 2 are only noted; times 2
mov    r8,rdi                         ;   is a shift; a is loaded for +
add    r8,r9
mov    rax,r8                         ; return: the result
leave                                 ; no jump to here, as it is next
ret
```

`scale` calls nothing, so its parameters stay in `rdi` and `rsi`,
where they arrive (`keepArrived`): they are register variables that
cost nothing to keep. Every line of it can be traced to a routine in
`Gen.raz`: the moves are `loaded`'s, the shift and the add `op`'s, the
result `returnJump`'s, and the frame is `enterBody`'s and `endProc`'s.
It is not the fastest code. It is code whose every instruction you
can account for, which is the point.
## Better code, in one procedure

`Str.decode` reads one UTF-8 character from a slice of bytes, and for
plain ASCII it is done by its third line. It is called once for each
character a program prints, so its first lines are worth looking at.
Here is what `raz -S lib/Str.raz` says of them, before the work of
v0.7.0:

```
   102  proc decode*(s: []U8): (I32, INT);
             0  push rbp
             1  mov rbp, rsp
             4  sub rsp, 96
            11  xor eax, eax
            13  mov r10, -7
            20  mov [rbp + r10 * 8 - 24], rax
            25  add r10, 1
            29  jne 20
            35  mov [rbp - 80], rbx
            39  xor ebx, ebx
            41  mov [rbp - 72], r12
            45  xor r12d, r12d
            48  mov [rbp - 64], r13
            52  xor r13d, r13d
            55  mov [rbp - 56], r14
            59  xor r14d, r14d
            62  mov [rbp - 8], rdi
            66  mov [rbp - 24], rsi
            70  mov [rbp - 16], rdx
   105      if LEN(s) = 0 then return 0, 0; end;
            74  mov r8, [rbp - 16]
            78  cmp r8, 0
            82  jne 118
            88  xor r8d, r8d
            91  mov rcx, [rbp - 8]
            95  mov [rcx], r8d
            98  xor r8d, r8d
           101  mov rcx, [rbp - 8]
           105  mov [rcx + 8], r8
           109  mov rax, [rbp - 8]
           113  jmp 807
   106      c := I32(s[0]);
           118  xor r8d, r8d
           121  mov rax, r8
           124  cmp rax, [rbp - 16]
           128  jae 825
           134  add rax, [rbp - 24]
           138  mov r8, rax
           141  movzx r8d, byte [r8]
           145  movsxd r8, r8d
           148  mov rbx, r8
   107      if c < 80H then return c, 1;
           151  cmp rbx, 128
           158  jge 202
           164  mov r8, rbx
           167  mov rcx, [rbp - 8]
           171  mov [rcx], r8d
           174  mov r8, 1
           180  mov rcx, [rbp - 8]
           184  mov [rcx + 8], r8
           188  mov rax, [rbp - 8]
           192  jmp 807
           197  jmp 421
           202  cmp rbx, 192
           209  jge 256
```

and after:

```
   102  proc decode*(s: []U8): (I32, INT);
             0  push rbp
             1  mov rbp, rsp
             4  sub rsp, 64
            11  mov [rbp - 48], rbx
            15  xor ebx, ebx
            17  mov [rbp - 40], r12
            21  xor r12d, r12d
            24  mov [rbp - 32], r13
            28  xor r13d, r13d
            31  mov [rbp - 24], r14
            35  xor r14d, r14d
            38  mov [rbp - 16], rdi
            42  mov [rbp - 8], rsi
   105      if LEN(s) = 0 then return 0, 0; end;
            46  mov r8, [rbp - 8]
            50  test r8, r8
            53  jne 68
            59  xor edx, edx
            61  xor eax, eax
            63  jmp 595
   106      c := I32(s[0]);
            68  xor r8d, r8d
            71  cmp r8, [rbp - 8]
            75  jae 613
            81  add r8, [rbp - 16]
            85  movzx r8d, byte [r8]
            89  movsxd r8, r8d
            92  mov rbx, r8
   107      if c < 80H then return c, 1;
            95  cmp rbx, 128
           102  jge 121
           108  mov rdx, 1
           113  mov rax, rbx
           116  jmp 595
           121  cmp rbx, 192
           128  jge 149
```

What went, and the routine that took it away:

1. **The loop at 11 to 29**, which zeroed seven quadwords: the frame
   slots of the four variables, all of them in registers, and the slots
   the registers are saved in, which are written before they are read.
   Now a variable in a register has no slot, and only the locals in
   memory are zeroed (`placeLocals`, `useRegs`, `enterBody`).
2. **The hidden pointer**: the two results went through `rcx` to the
   caller's memory. Two words come back in `rax` and `rdx` now
   (`inTwoRegs`), so `return 0, 0` is two instructions; and the caller
   pops them straight into its variables (`pushWords`, `multiAssign`).
3. **`cmp r8, 0`** is `test r8, r8`, the same flags in fewer bytes
   (`cmpI`).
4. **Copies through `rax`**: `s[0]`'s address is worked out in the
   register it is used from (`indexSlice`), and a result is put in `rax`
   from where it is (`popTo`).
5. **The `jmp 421` after `return`**, which nothing could reach: a branch
   of an `if` that ends gets no jump past the others (`ifStatement`).

What is left is worth knowing too. The slice's two words still go to
the frame, since only single values live in registers; `movzx` then
`movsxd` reads a byte and makes an `I32` of it in two steps where one
would do; and the four registers are saved and restored on every call,
though this path uses one of them. Each could go, at the cost of lines
a reader would have to follow; v0.8.0 took the first, and the last
where the procedure calls nothing.

## Better code again, in v0.8.0

Each change below was measured on rat, a terminal emulator written in
raz, running its 26 MB workload, and on the kernels of `test/bench`,
against their twins built by FPC `-O2` (`make kernels`); one that
bought less than 2% on both was taken out again.

1. **Slices in registers.** `sum(s: []INT)` kept its slice in the
   frame, and read its pointer from there for each element:

   ```
   mov [rbp - 16], rdi       ; the prologue: s, to its slots
   mov [rbp - 8], rsi
   ...
   mov r9, r14               ; s[i], each time round
   shl r9, 3
   add r9, [rbp - 16]
   ```

   Now a slice whose address isn't taken can have two of the
   variables' registers, its pointer's and its length's
   (`o^.reg2`), chosen as a single value's is but for half its weight
   in each:

   ```
   mov r12, rdi
   mov r13, rsi
   ...
   mov r9, r14
   shl r9, 3
   add r9, r12
   ```

   Its item is at `bReg`, and its `Adr` names both registers (`hi`
   for the length's): `pushVar` reads either word (`regAt`),
   `indexSlice` and `slice` compare with the length's and add the
   pointer's, a failed check takes the length from its register
   (`inRegister`), and `copyTo` loads both. What wants a slice's
   memory, a comparison, `COPY` or `FILL`, has its words stored in a
   temporary first (`copyToTemp`). rat 5% faster, the heap sort 5%,
   the search 4%.

2. **Parameters left where they arrive.** `find(s, sub: []U8)` stored
   its first slice in its frame, or in two registers it saved and
   restored:

   ```
   mov [rbp - 40], r12       ; the caller's r12 and r13, saved
   mov [rbp - 32], r13
   mov r12, rdi              ; s, into them
   mov r13, rsi
   ```

   In a procedure that names no procedure, a procedure variable, `NEW`,
   `SYSCALL`, `COPY` or `FILL`, as `chooseRegs` sees reading ahead, the
   parameters that arrive in `rdi` and `rsi` stay there, which only a
   call or a copy needs: nothing is saved or moved, and `s[i]` is read
   through `rdi` itself (`keepArrived`). Where Gen needs them after
   all, to copy a record or compare two slices, it sets `lost`, and
   `body` compiles the procedure again with the parameters in
   callee-saved registers no variable has, or in memory (`unkeep`, in
   "Array parameters, measured"), as for a variable demoted. The trap report shows a parameter kept
   so: `Rt.fail` is given `rdi` and `rsi` as the failing code had
   them, and the signal handler takes them from the context the
   kernel saved. The search 9% faster, rat 1.5%, its text 0.7%
   smaller.

3. **Addresses and operands as the machine has them.** `t := t + s[i]`
   worked out the element's address, read the element into a register,
   and added that:

   ```
   mov r9, r12               ; i
   shl r9, 3
   add r9, rdi               ; s's pointer
   mov r9, [r9]
   mov r8, rbx               ; t
   add r8, r9
   ```

   Now an element of a slice in registers is only noted, as the
   operand `[rdi + r12 * 8]` (`lIdx`, made by `indexSlice`), and a
   variable in memory, or at an address noted, as the operand that
   reads it (`lMem`, made by `pushVar`): each is read where it is
   used, and `op`, `compare` and `jumpCmp` take an 8-byte one as their
   right operand as it is (`topInMem`):

   ```
   mov r8, rbx
   add r8, [rdi + r12 * 8]
   ```

   A value noted in memory must be read before anything can change
   it: before a call (`spillBelow`) and an atomic built-in (`atomic`),
   both through `readMems`. The heap sort 14% faster, the search 5%;
   rat within noise, its text 3.9% smaller. Loop tops aligned to 16
   bytes were tried with it, and taken out: the search lost 3%, and
   rat gained nothing.

   Then the left operand, as the machine has it: `t := t + s[i]` still
   went through a register of the stack,

   ```
   mov r8, rbx
   add r8, [rdi + r12 * 8]
   mov rbx, r8
   ```

   and `i`'s step as well. An assignment whose expression starts with
   its variable, in a register, and changes it by `+`, `-`, `|` or
   `xor`, naming it nowhere else (`changesItself`, read ahead in the
   statement), has Gen work the value out in the variable's own
   register (`inPlace`, `lInto`), and `Item.forStep` steps one so too:

   ```
   add r12, 1
   add rbx, [rdi + r12 * 8]
   ```

   That left the sum's loop four instructions, as FPC's are, and as
   slow as before, for it crossed a 64-byte line that the processor
   fetches decoded instructions in. The top of a `for` loop, which
   the code jumps to rather than runs into, now starts at a multiple
   of 32 bytes (`alignLoop`, `align` in X64), the no-ops before it
   never run. The sum 41% faster, the search 6%; rat within noise.

4. **`while` tested at the bottom.** A `while` loop tested its
   condition at the top and jumped back to it, two jumps a round, one
   taken each way:

   ```
   top:  cmp rbx, r13        ; while child < hi
         jge out
         ...                 ; the body
         jmp top
   out:
   ```

   Now the loop jumps to its test first, which comes after the body
   and jumps back to the top while the condition holds:

   ```
         jmp test
   top:  ...                 ; the body, at a multiple of 32 bytes
   test: cmp rbx, r13
         jl top
   ```

   One pass reads the condition before the body, so `whileStatement`
   compiles it where it is written, for its messages, takes its code
   back (`rewind`), and reads it again after the body (`saveScan`,
   `restoreScan`, in Scan). A constant condition, as in `while true`, is no
   test. The heap sort 3% faster, rat 2%; the search lost 7%, all of
   it to where its loops fell: without the top aligned it lost
   nothing, and rat gained nothing either.

5. **One table of lines, not two.** Rt had a table of its own in the
   places, 16 bytes a line note, beside the DWARF line table that gdb
   read, which wasn't loaded. Now the DWARF table, its columns added,
   is in the places, loaded, and Rt runs it (`row`, in `Rt.raz`) where
   it looked through its own; `.debug_line`'s section header points
   at it in rodata. Hello is 7 KB smaller, 28 KB; rat 17%, 505 KB.

All told, against v0.7.1, in user-space cycles: the heap sort 23%
fewer, the search 15%, the sum 41%, each now within 2% of FPC
`-O2`'s; rat 2.5% fewer cycles and 6% fewer instructions on its
workload. Every default program is 20 to 25% smaller.

## Better code for reals

Each change below was measured as v0.8.0's were, on rat and on the
kernels, two of which compute with reals: `Jacobi`, a sweep of a grid
of `F64`s, each point the mean of its four neighbours, and `NBody`,
bodies under gravity, with real variables, a square root and a
division in its inner loop.

1. **Reals on the stack in xmm registers.** A real on the value stack
   was held in an integer register, as its bits, and copied to `xmm0`
   and `xmm1` for each operation and back. The sweep's
   `0.25 * (s[k - 1] + s[k + 1] + s[k - N] + s[k + N])` was, for each
   addition and the product:

   ```
   mov r10, [r13 + r10 * 8]
   mov r9, [r13 + r9 * 8]
   movq xmm0, r9
   movq xmm1, r10
   addsd xmm0, xmm1
   movq r9, xmm0
   ...
   mov r10, r9
   mov r9, 4598175219545276416   ; 0.25, as its bits
   movq xmm0, r9
   movq xmm1, r10
   mulsd xmm0, xmm1
   movq r9, xmm0
   mov [rdi + r8 * 8], r9
   ```

   Now a real at depth `d` is held in `xmm8` to `xmm11`, in
   `XRegs[d mod 4]` (`regIn`): it is loaded and stored with `movsd`
   (`movss` for an `F32`; `xValueTo`, `popVar`), a constant is read
   from 8 bytes of read-only data (`realConst`), and an operation takes
   its right operand from memory as it is, as `op` does for an integer
   (`realOp`). A constant on the left of `+` or `*` is left on top by
   `Item.op2`, as their order doesn't matter, rather than
   swapped under the other operand and back:

   ```
   movsd xmm9, [r13 + r9 * 8]
   addsd xmm9, [r13 + r10 * 8]
   ...
   addsd xmm9, [r13 + r10 * 8]
   mulsd xmm9, [literal498]
   movsd [rdi + r8 * 8], xmm9
   ```

   `call` moves a real argument straight to its `xmm0` to `xmm7`, and
   takes a real result from `xmm0`; a comparison is `ucomisd` of the
   two registers; a conversion is done in the value's own registers.
   The registers from `xmm8` up carry no arguments, so that moving one
   argument to its register never overwrites another still to go; all
   xmm registers are the caller's to save, so a call spills the reals
   under it as it does the integers. Jacobi 251 ms to 129, NBody 375
   to 225; rat within noise.

2. **An element of an array as the machine has it.** That left
   NBody's reals waiting on their addresses: `x[i]`, of an array of
   the module, was worked out as an address, and the index copied
   from its register to be scaled:

   ```
   mov r8, rbx               ; i
   shl r8, 3
   lea r9, [NBody.x]
   add r8, r9
   movsd xmm8, [r8]
   ```

   Now an element of 1, 2, 4 or 8 bytes of an array in a chunk, with
   its index in a variable's register, is noted as the operand that
   reads it, its base the array's address, made in the value's own
   register; one in the frame has `rbp` as its base, whatever its
   index (`indexArray`, as `indexSlice` does for a slice in
   registers):

   ```
   lea r8, [NBody.x]
   movsd xmm8, [r8 + rbx * 8]
   ```

   A computed index in a chunk's array is added up as before, as it
   would need a third register. `checkIndex` compares a variable's
   register as it is (`peek`), not a copy. NBody 225 ms to 147; rat
   within noise.

3. **An offset as the machine has it.** The sweep's four neighbours,
   `s[i * N + j - 1]` and the others, each worked out its index in
   full, the constant added too:

   ```
   mov r9, r12               ; i * N + j - 1
   shl r9, 9
   add r9, rbx
   sub r9, 1
   ...
   mov r10, r12              ; (i - 1) * N + j
   sub r10, 1
   shl r10, 9
   add r10, rbx
   addsd xmm9, [r13 + r10 * 8]
   ```

   Now a word in a register may carry an offset not yet added (`off`,
   in `Entry`): `op` notes `x + c` and `x - c` there, carries it
   through `+` and `-`, and through `*` by a constant, as `(x + a) * k`
   is `x * k + a * k`. An element's operand takes it as its
   displacement (`indexOff`, for `indexSlice` and `indexArray`), and so
   does a field's through a pointer (`place`); anything else adds it
   where the value is read (`loaded`, `peek`, `valueTo`, with a `lea`,
   which leaves the flags alone). A value changed in place, `lInto`,
   carries none, and an index that is checked has it added first:

   ```
   mov r9, r12
   shl r9, 9
   add r9, rbx
   ...
   movsd xmm9, [r13 + r9 * 8 - 8]
   ...
   addsd xmm9, [r13 + r10 * 8 - 4096]
   ```

   Jacobi 129 ms to 106; rat 2% faster, within noise; the integer
   kernels unchanged.

4. **Real variables in xmm registers.** NBody's `dx`, `dy`, `dz` and
   `mag` lived in the frame, each assignment a store and each use a
   load, on the chain of operations that each round waits on:

   ```
   subsd xmm8, [r9 + r12 * 8]
   movsd [rbp - 8], xmm8     ; dx := x[i] - x[j]
   ...
   movsd xmm8, [rbp - 8]     ; dx * dx
   mulsd xmm8, [rbp - 8]
   ```

   Now `chooseRegs` gives the busiest reals of a procedure `xmm12` to
   `xmm15` (`XVarRegs`), as it gives the busiest integers `rbx` and
   `r12` to `r15`, and gen reads and writes them where they are: a
   real in a variable's register is `lHeld` or `lInto`, as an
   integer's is (`xValueTo`, `popVar`, `peek` for `realOp` and
   `compare`):

   ```
   subsd xmm8, [r9 + r12 * 8]
   movaps xmm13, xmm8
   ...
   movaps xmm8, xmm13
   mulsd xmm8, xmm13
   ```

   Each such variable has its slot too, which `popVar` writes as it
   writes the register (`movsd [rbp - 8], xmm13` after the `movaps`),
   off the chain the round waits on: the trap report finds the value
   there, as it finds any variable's, whether a check failed or a
   signal stopped the program, and `call` loads the register from it
   after each call (`xHome`, `homeOf`), as System V keeps no xmm
   register through one. A register number from `XmmVar`, 16, up is
   an xmm register's, so that `xmm12` isn't taken for `r12` where the
   parser counts its registers (`regsOf`, `regAt`). NBody 147 ms to
   116, and a copy of it without the call to `sqrt` 114 to 81; rat
   within noise. Storing the slot only before a call, and so showing
   nothing in the trap report, bought 3% more on that copy and nothing
   on NBody.

   A `var` parameter of a real holds the real's address, an integer:
   it takes one of `VarRegs`, not of `XVarRegs`, and a `var` slice's
   one, not two. Through 0.12.0 it was given an xmm register, which the
   prologue took for the integer register of its number, another
   variable's (`chooseRegs`).

All told, against v0.8.0: Jacobi 251 ms to 103, 3.1 times FPC
`-O2`'s time to 1.3; NBody 375 ms to 116, 4.4 times to 1.4; rat and
the integer kernels as they were. What is left of Jacobi is its index,
`i * N + j`, worked out five times a round, once for each element,
where FPC works it out three times: one pass keeps no expression to
share. What is left of
NBody is mostly its call to `Math.sqrt`, an instruction FPC puts in
place, with the spills and loads around it; then the `lea` of each
array's address, which FPC makes too, and the fifth real, `d2`, for
which there is no register. A comparison of reals still makes a
`BOOL` before it jumps, as `not (a < b)` isn't `a >= b` for a NaN;
neither kernel has one.
## Better code, for the compiler itself

The compiler, built by itself, took 684 ms for a program of 348,000
lines where the same compiler written in Pascal took 374: 1.8 times as
long. `perf` (`perf record`, `perf annotate`; raz keeps `rbp` frames and
a symbol table, so it reads the compiler as it reads any program) found
no hot spot, but a few habits of the code, each cheap to mend. The
compiler now takes about 500 ms, 1.4 times the Pascal one's, and its
own programs are no slower for it (`make kernels`). Each step below was
measured by cycles (`perf stat`), as timing alone is too noisy to see
1%.

1. **Small blocks cleared and copied by moves.** A record made by a
   literal was cleared with `rep stosb` and copied with `rep movsb`,
   which take some twenty cycles to start whatever the size: `x := {}`
   on a 112-byte `Item` was most of `makeItem`'s time. `copyBytes` did
   go by moves up to 64 bytes, but `zeroVar` never did. Now both take
   `MaxMoves`, 256 bytes, by moves: 16 bytes at a time through `xmm0`
   (`movdqu`), then 8, 4, 2 and 1 (`copyBytes`, `zeroBytes`). A copy of
   up to 64 bytes stays in words (`MaxWordMoves`): a record just made
   field by field is read back by loads as wide as its stores, and a
   16-byte load across two 8-byte stores waits for both to reach the
   cache (measured: `Scan.tokPos` doubled). The prologue's loop over
   the locals, a quadword an iteration, is now `pxor xmm8` and a row of
   `movdqu` stores, or a loop of 16 bytes for a frame of more than 256.
   `Parse.matchStatement` has a frame of 25 kilobytes, its table of
   labels, cleared at each `match`: that was 5% of the compiler's
   misses in the first-level cache, and is the largest left.

2. **A record literal made where it is wanted.** `return {f: a, b: c}`
   built the record in a temporary, cleared, and copied it behind the
   hidden pointer:

   ```
   lea rdi, [rbp - 32]       ; the temporary
   (clear it)
   mov [rbp - 32], r8        ; its fields
   ...
   lea rsi, [rbp - 32]       ; and copy it out
   mov rdi, [rbp - 8]
   mov rcx, [rsi] ...
   ```

   Now `oneStatement`, at `return`, says the literal is the whole of the result
   (`Item.literalInResult`), `tempOf` makes the item at `bSlot`, at the
   slot that holds the hidden pointer (`Gen.resultSlot`), and the
   fields go there: `mov rcx, [rbp - 8]; mov [rcx], r8`. A caller always
   passes a temporary of its own, so the fields can't alias what they
   are made from. And a literal clears only what its fields leave:
   `clearPadding` the words that hold padding, before the fields, and
   `clearMissing` the fields it gave no value, after them. `Scan.tokPos`,
   which the parser calls over and over, went from 33 instructions to 14.

3. **`p[i]` through a pointer as an operand.** An element of a slice in
   registers was only noted, `[rdi + r12 * 8]` (`lIdx`); an element
   through a pointer worked out its address, `i * 8`, then `+ p`:

   ```
   mov r9, r12               mov r8, [Sym.hashTab]
   shl r9, 3          now:   mov r8, [r8 + r12 * 8]
   mov r8, [Sym.hashTab]
   add r8, r9
   mov r8, [r8]
   ```

   `indexPtr` notes it as `lIdx` when at most one of the pointer and the
   index is in a register of the stack (the one the value then owns),
   and makes it with one `lea` otherwise.

4. **`try` with nothing to defer tests the error in its register.** The
   error was stored in a frame slot, loaded, tested, and loaded again
   to be returned:

   ```
   call f; mov r8, rax; mov [rbp - 160], r8; mov r8, [rbp - 160]
   test r8, r8; je ok; mov rax, [rbp - 160]; jmp exit
   ```

   Where no deferred statement is in force, `tryTest` tests the register
   the call's result is in and `tryReturnFrom` returns it from there:
   `call f; mov r8, rax; test r8, r8; je ok; mov rax, r8; jmp exit`.
   With a deferred statement the slot stays, as `runDefers` calls code
   that would take the register.

5. **A `var` parameter's address in a register.** `term(var x: Item)`
   loaded the pointer from its slot, `mov r8, [rbp - 8]`, at each use of
   `x`, `x.pos := ...` included. A parameter passed by its address (a
   `var` parameter, a record or an array) is now a candidate for a
   register as any variable is (`regFit`), and an item at `bPtr`
   names it: `place` is `[r12 + off]`, with no load, and `pushVar` notes
   it as `lMem`, so that it is read as an operand. The trap report
   doesn't show it (`varKind`). One in `rdi` or `rsi` of a procedure
   that calls nothing is kept there (`keepArrived`), as any parameter.

6. **Two small things in the code.** `lea r8, [r8]`, which `pushAdr`
   made of an address already in the register, is not made.
   `Scan.next` reads and steps through its text in two variables that
   live in registers while its loops run, and stores them back after:
   `cur.pos`, in memory, made each step wait for the store of the one
   before. And `Parse.chooseRegs`, which reads a procedure through once
   to count its variables' uses, stops looking names up for calls after
   the first that does.

The source changed too, where one routine had the habit. `Scan.lineCol`,
for the places the checks of a procedure are told in, counts from the
line last found, back or forward, where it counted back from the
current symbol's line each time; `curCol`, for the line table of each
statement, from the start of the symbol's line only; and the expression
levels note where they start as a number (`tokStart`, `spanFromAt`) in
place of a whole `Pos` that most never use.

What did not help, as it is as well to know: `check off;` for the whole
compiler (1%), a better hash for `Sym` (the old one keeps the names of
a scope near one another and is faster), putting `scope` next to `name`
in `Obj`, a cache of the names found by `chooseRegs`' look-ahead, and
passing `Item` to `adrOf` as a `var` parameter, so as not to copy it.
What is left is spread thinly: the procedure call overhead of many small
routines (`Gen.drop`, `X64.mem`, `Chunk.put1`, which an inliner
would remove), the reading of every procedure twice, and
a record parameter copied at each call that passes it on (`Mem`, in the
encoder).

## Cheap wins, measured

Each change below was measured on the kernels of `test/bench`, by the
instructions each runs (valgrind's `cachegrind`, which counts the
same every time) and by the best of fifteen runs of the old program and
the new, taken in turn; a kernel whose code didn't change moves by up
to 2% in time, which is the noise.

1. **A square root in place.** `Math.sqrt` is a code procedure of one
   instruction, and NBody's `mag := Dt / (d2 * Math.sqrt(d2))` called
   it, with all that a call costs a real: the reals on the stack
   spilled, the variables' xmm registers loaded again from their slots
   after it, as System V keeps none through one, and the procedure no
   longer a leaf:

   ```
   movsd [rbp - 64], xmm8    ; d2, spilled under the argument
   movsd xmm0, [rbp - 32]    ; the argument
   call Math.sqrt            ;   sqrtsd xmm0, xmm0; ret
   movsd xmm12, [rbp - 40]   ; mag, dx, dy, dz back from their slots
   movsd xmm13, [rbp - 8]
   ...
   ```

   Now a code procedure of one real whose body is `sqrtsd xmm0, xmm0`
   and `ret` (or `sqrtss`), as `codeBody` finds from its bytes
   (`Gen.oneRealOp`, kept in `inl`), is made in place: the argument
   computed as for a call, then the instruction on its own register
   (`realInPlace`, from `endCall`), and `chooseRegs` doesn't count it a
   call:

   ```
   movsd xmm9, [rbp - 32]
   sqrtsd xmm9, xmm9
   ```

   NBody 8.6% fewer instructions, 2.8% faster; the rest unchanged.

2. **An element of a module's array by its address.** x86 has no
   `rip + index`, so `x[i]`, of an array in a chunk, made the array's
   address in a register first, for each element, twice in
   `x[i] - x[j]`:

   ```
   lea r8, [NBody.x]
   lea r9, [NBody.x]
   movsd xmm8, [r8 + rbx * 8]
   subsd xmm8, [r9 + r12 * 8]
   ```

   But the executable is loaded where the linker placed it, below 2 GB,
   so the array's address fits a 32-bit displacement with no base
   register at all (`X.memAbs`, a `RIP` base with an index; its fixup
   holds the address itself, `Chunk.addAbsFixup`, not the distance from
   the field). `indexArray` notes such an element as it does one in the
   frame, whatever register its index is in:

   ```
   movsd xmm8, [NBody.x + rbx * 8]
   subsd xmm8, [NBody.x + r12 * 8]
   ```

   NBody 25% fewer instructions, 16% faster. Grep is 5% slower with
   the same code in its loops, only moved 96 bytes: where a loop falls
   changes its speed, as v0.8.0 found.

3. **A loop's limit in a register.** `for i := 0 to LEN(s) - 1`
   works out its limit once, in a frame slot, and compared `i` with
   the slot each round:

   ```
   add r12, 1
   add rbx, [rdi + r12 * 8]
   cmp r12, [rbp - 40]
   jl top
   ```

   `chooseRegs`, reading ahead, notes the `for` loops with no `for`
   inside them whose limit names something not a constant (`limitIn`,
   by their order in the procedure). If one of the five variable
   registers is left when the variables have theirs, it is kept for
   those limits (`limitK`; `regsOf` saves it as a variable's), and
   `forStatement` puts each such limit in a variable no one can name,
   in that register, which `forCmp` and `forNext` compare as any:

   ```
   cmp r12, r13
   jl top
   ```

   The sum 15% faster, in the same instructions. Search, whose `for` is
   compared once a round of its inner `while`, is 4% slower in a loop
   that didn't change, at the same address; why is not known.

4. **Four more registers for reals, where nothing calls.** NBody's
   fifth real, `d2`, had no register: XVarRegs had four, `xmm12` to
   `xmm15`. It was stored and loaded on the chain each round waits on:

   ```
   addsd xmm8, [literal1024]
   movsd [rbp - 32], xmm8    ; d2 := ...
   movsd xmm9, [rbp - 32]    ; Math.sqrt(d2)
   sqrtsd xmm9, xmm9
   movsd xmm8, [rbp - 32]    ; d2 * ...
   ```

   `xmm0` to `xmm7` carry a call's arguments, and nothing else of Gen's
   but `xmm0`; so in a procedure that calls nothing (`chooseRegs`'s
   `leaf`) and has at most four real parameters, which arrive in `xmm0`
   to `xmm3`, the reals may have `xmm4` to `xmm7` as well, the last four
   of XVarRegs (`xmax`; `xIndex` finds a register's slot):

   ```
   addsd xmm8, [literal1024]
   movaps xmm4, xmm8
   movsd [rbp - 32], xmm4
   movaps xmm9, xmm4
   sqrtsd xmm9, xmm9
   movaps xmm8, xmm4
   ```

   NBody 4% faster, in 1.4% more instructions: a load is a `movaps`
   now, and the slot is still written for the trap report.

All told, against v0.12.0, the best of thirty runs each: NBody 1.68
to 1.16 billion instructions and 202 ms to 151, now 1.05 times FPC
`-O2`'s time; the sum 163 ms to 148, as fast as FPC's; Lines 6%
faster; the rest within noise, Grep and Search too, whose losses above
came with their loops unchanged. Grep (1.14 times FPC's) and Jacobi (1.24) are where FPC is still
ahead. The compiler, built by itself, runs 0.9% fewer instructions on
the 348,000-line program, in the same time.

## Array parameters, measured

Two gaps in what the earlier sections built, found by timing loops
over arrays passed as parameters, which the library's `const`
convention (report 2026-10.33) made common.

1. **An array parameter's element as an operand.** `indexArray` noted
   an element as `[base + index * size]` (`lIdx`) for an array in the
   frame or a chunk, but an array reached through a pointer (`bPtr`,
   a `var` or `const` parameter whose address is in a register) was
   added up, though the pointer was in a register already. A sum over
   `const s: [N]INT`:

   ```
   mov r9, r12
   shl r9, 3
   lea r10, [rdi]     now:   add rbx, [rdi + r12 * 8]
   add r9, r10
   mov r9, [r9]
   add rbx, r9
   ```

   The pointer's register is the base, as `rbp` is for the frame. It
   is a variable's register, not one of the stack's, so the value
   owns only its index's, as for the frame. One in a frame slot
   (`bSlot`) is added up still: the pointer would need a register of
   its own. The sum over a `const` array 145 ms to 82, the speed of
   the sum over a slice; ChaCha's `quarter(var x: [16]U32; ...)` 560
   ms to 283 (2.0 times), in 58% fewer instructions.

2. **A parameter that loses `rdi` or `rsi` takes a free register.**
   A procedure that calls nothing keeps its parameters where they
   arrive (`keepArrived`); when it copies an array after all, `lost`
   sends them to memory for the second try at the body, though `rbx`
   and `r12` to `r15` may be free. `block(const st: [16]U32; var out:
   [16]U32)`, which starts `out := st`, loaded `out`'s pointer at
   each use:

   ```
   mov r8, [rbp - 16]
   mov r8d, [r8]             now:   mov r9d, [r13 + 16]
   mov r9, [rbp - 16]               mov r8d, [r13]
   mov r9d, [r9 + 16]               add r8, r9
   add r8, r9
   ```

   `unkeep` gives such a parameter the registers of `VarRegs` that
   `regsOf` finds free, one, or two for a slice, if it is used enough
   for a register by `chooseRegs`'s count; else it goes to memory as
   before. The prologue saves those registers and moves the parameter
   there, as it does for a procedure that calls. ChaCha's block with
   the copy 1,132 ms to 684, 35% fewer instructions.

## Inlining a procedure that only returns

A call of a procedure whose body is only `return e`, with no locals,
is made in place of the call, as the proposal "Inlining a procedure
that only returns" had it. One pass keeps no tree to copy, but it can
read source again, as `while` reads its condition again: `body` notes
such a procedure (`onlyReturns`), keeping in its `Obj` an `Inline`
(`Sym.raz`): the scanner's state at the `return`, its file, whether
its module makes checks, and whether `e` calls anything. `call` hands
a call of it to `inlined`, which:

1. reads and converts the arguments as for a call (`Item.passArg`),
   which leaves them on Gen's stack where `Gen.call` would take them;
2. pops them, the last on top first, into temporaries of the
   statement, so each is evaluated once and in order: a parameter by
   address (`var`, `const`, a record or an array) becomes a slot
   holding the address the call would pass (`ind`, as a parameter
   passed so is), a slice its two words, any other its value;
3. opens, in place of the caller's scopes, the procedure's module's
   and one of its own that names the parameters as those temporaries,
   puts the scanner back at the `return`, with the module, its file
   and its checks, and reads `e`;
4. loads the result, as a call's comes back and widening as one does,
   unless it is a condition, which stays one for `if` and `while` to
   jump on; and puts back what it changed. What `e` notes for the
   warnings was noted when the procedure was compiled, so its doubts
   are dropped, and no warning comes or goes.

Kept narrow: the result a single value (no slice, record or several),
no `try` in `e`, and not a procedure already being made in place, so
that a recursion ends in a call. A procedure of another module is made
in place as one of this module is, its source kept as every file's is,
for messages; so is one of a generic module's instance. A procedure
taken as a value, or called before its body is read, is called; its
body is compiled all the same, and tree shaking drops it if nothing
calls it. `chooseRegs` doesn't count a call of one whose `e` calls
nothing (`calls`), so the caller can stay a leaf.

```
proc isLower(c: U8): BOOL; begin return U8(c - 97) < 26; end;
...
while (i < LEN(s)) and isLower(s[i]) do INC(i); end;

before:  movzx edi, byte [r12 + rbx]     after:  movzx r8d, byte [r12 + rbx]
         call T.isLower                          mov [rbp - 50], r8b
         mov r8, rax                             movzx r8d, byte [rbp - 50]
         movzx r8d, r8b                          sub r8, 97
         test r8, r8                             movzx r8d, r8b
         jne loop                                cmp r8, 26
   (isLower: push rbp ... cmp r8, 26;            jb loop
    setb r8b; movzx r8d, r8b; mov rax, r8;
    leave; ret)
```

A word count of 16 MiB sixteen times with that test, 887 ms to 638
(586 with `check off`; 516 with the test written in place by hand);
test/bench's Grep, whose `zeros` and `lowest` only return, 268 ms to
199 (194 by hand). What is left is the store and load of each
temporary. The compiler built by itself runs 3% fewer instructions,
the same time, and is 17 KB larger.

What the trace and a debugger see: the procedure has no frame, so it
isn't in the trap report's list of calls, nor in gdb's backtrace; its
caller is, with the caller's variables. A failed check in `e` is told
at `e`'s line, in its file (Gen's `check` works out the place while
`e` is read, and `endFails` notes it in that file), and a gdb
breakpoint at that line stops on the failing code, and in the
procedure's own body if it is kept. A signal in `e` is told at the
caller's statement, as the line notes inside a statement are its own.
A test that wants the procedure's own frame calls it through a
procedure value (`test/run/KeptCheck.raz`).

## Diag.raz: messages

Every message the compiler prints is made here. A position, `Pos`, is a
file and a stretch of bytes in it; `error`, `warning` and `note` show it
as `file:line:column`, then the line of source with the stretch
underlined, and `help` adds a line of advice. Notes and help are shown
only with an error that was: not one at the place of the last, and not
one under `quiet`, which the parser sets (`setQuiet`) when an error
follows from another (see Parse.raz). The line and column are worked out
only when a message is printed (`locate`, `chars`), so positions cost
nothing while compiling. `addFile` keeps every source file the scanner
opens, so a note can show a line of any of them. A file may carry one
line to tell (`setOrigin`), shown once under the first message about
it: the parser gives a library's. `finish` prints the
count of errors and warnings and stops if there were errors; `fatal` is
for errors with no place in the source. A message is made by `say` from
a format and its arguments, and kept for good, since a message is made
only where it is about to be shown.

## Scan.raz: the scanner

The scanner turns bytes into symbols (`Sym`). The current symbol is in
`tok`, with its value in `ival` (integers and characters), `rval`
(reals), `id` (identifiers) or `strBytes`, the `slen` bytes of a string,
already decoded.

Read `next` first: it skips white space and comments (`comment`, which
counts nesting), then dispatches on the first character. `number`
handles decimal, `0FFH`-style hexadecimal and reals; `litChar` handles
one character of a literal, escapes included. `rawString` reads a raw
string, between backquotes, which has no escapes: first to the closing
backquote, counting lines and checking UTF-8 as a comment does, to find
the blanks before it; then line by line into `sbuf`, taking those
blanks off the start of each line if the string is indented (the
report's section 2), and leaving carriage returns out. `readReal` turns a real's
digits into the nearest `F64` exactly, as a fraction of two big integers
(`Big`), since a library's reader can be one bit off.
`zeroDigit` reads the text of the current string again, for a `\0` before a digit, which the parser warns of.

Identifiers are *interned*: `intern` puts each distinct name once in a
pool and hands back a small integer, so every later comparison of names
is a comparison of integers. The reserved words are interned first, in
the order of `Sym`, so a name's number tells at once whether it is a
reserved word.

Source is UTF-8, checked by `utf8` wherever a byte above 127 appears:
in strings, characters and comments. Anywhere else it is an error.

`tokPos` is the position of the current symbol, `spanFrom` the stretch
from a saved position to the end of the symbol before the current one,
and `missingPos` the place to say a symbol is missing: just after the
symbol before, when the current one starts a new line. Errors go through
`mark`, at the current symbol, `markAt`, at a position, or `markHelp`,
which adds a line of help; each reports the error (`Diag.error`) and
returns `Failed`, an `ERROR` the parser passes up with `try` to where it
goes on from (see Parse.raz). An error with notes is reported with
`Diag.error` and `Diag.note`, then returns `Failed` itself. A message
names what it found: `found` describes the current symbol and `symText`
spells an operator or reserved word, so that the parser's `expect` and
`expected` say `expected ";", found "end"`. `comment` notes where the
last comment ended: `commentBetween` says whether one stands between
the symbol before and the current one, and `commentClosed` whether one
ended just before a place. With them the parser's `foundNotes` shows
the symbol found when a comment put lines between it and the missing
one's place, and `commentNote` the end of a comment that closed just
before the error, which most likely quoted `*)`. Errors in the text itself
stop the compiler (`markBytes`, `lexError`): past a string left open,
the symbols can't be trusted. A slip from another language, such as `!=`
for `#`, is reported by `slip`, which reads on as if the right symbol
were written; not while the parser is `skipping` (`setSkipping`) what it
read once before an error. `saveScan` and `restoreScan` keep the
scanner's state while an imported module is compiled.

## Sym.raz: types, objects and scopes

Two records hold everything the compiler knows about a program.

`Type` is a type. Its `form` says what kind (`fInt`, `fPtr`, `fArray`,
`fRecord`, `fVariant`, `fProc`, and so on), and the other fields mean
what that form needs: `base` is what a pointer points at, an array or
slice holds, or a procedure returns; `fields` lists a record's fields,
a variant's cases, a procedure's parameters; `len` counts an array's
elements. `size` and `align` are worked out when the type is built, by
the C rules. `obj` is the declaration that named the type, if any.

`Obj` is anything a name can stand for: a constant, type, variable,
procedure, module, field, variant case or built-in (`cls`), and `pos`
is where its name is declared, for notes. Where it
lives is decided here too: a module variable's chunk, a local's frame
offset in `val`, a procedure's chunk.

Scopes are numbers. The universe is 0; each module, procedure, record
and match arm gets a new one from `newScope`. All objects of all scopes
sit in one open-addressed hash table, keyed by scope and name: `find`
looks in one scope, `lookup` in each open scope from the innermost out.
A lookup costs the same however big a program grows, which matters at a
million lines a second. After an error, `closest` looks through the
whole table for the name in reach spelled most like one not found
(`distance`), for "did you mean".

`same` and `alike` decide whether two types are the same: one
declaration for named types, built alike otherwise. `fingerprint` hashes
what a declaration exports, for the check that a module's files for
different targets agree. The universe, the basic types and built-in
procedures, is set up in the module's body.

Two routines can find an error: `insert`, for a name declared twice, and
`openScope`, for too many scopes. A name of an enumeration (`ofEnum`)
may share its scope with another declaration (report 2026-10.31): it is
reached through its type, `Elem.bold`, so `insert` keeps the other
declaration in the scope for the name alone; of two enumerations'
names it keeps the first, and notes the second as its `twin`, which
makes the name alone an error. Each shows it and returns
`Scan.Failed`, for the parser to pass up with `try`. A record's module
and an object's link, which the seed called `module` and `link`, are
`home` and `chain`, since those are reserved words here; `setCurModule`
is how the parser says which module it is in, as an exported variable
can't be set from outside.

## Chunk.raz: the compiled program

Code is written into one growing buffer, `text`, with `pc` its length;
strings and other constants go to `rodata`. A chunk (`Chunk`) records
its section, where its bytes start, how many, and the fixups it makes.
`beginChunk` and `endChunk` bracket a procedure; `setData` and `setBss`
make data chunks.

A *fixup* (`Fixup`) is a 32-bit field in the code that will hold the
distance to another chunk: a call's target, or a rip-relative address.
`addFixup` records one; `Link.raz` fills them in. A constant's addresses
are *data fixups*, `addDataFixup`'s: 64-bit fields in rodata that will
hold a chunk's address itself, since the executable is loaded where the
linker placed it. `noteLine` records which line and column of the source
the code from `pc` on belongs to, for gdb and for the places.
`externChunk` makes, once per C symbol, the quadword the dynamic loader
will fill with that symbol's address. `takeBack` and `rewindTo` undo the
end of what was made, for a body compiled a second time. What other
modules set in a chunk, such as `live` or `adr`, has a setter each
(`setLive`, `setAdr`), since an exported variable can't be set from
outside. None of this depends on the machine.

## X64.raz: machine code

The encoder is `opM` and `opR`: a prefix, the REX byte, the opcode, the
ModRM and SIB bytes and the displacement, for a register and a memory
operand (`Mem`) or two registers. Everything else (`movRR`, `load`,
`store`, `alu`, `sse`, ...) is a line or two that calls them with the
right opcode. Only the instructions the code generator uses are here.
Each was checked against `objdump` when it was written (`raz -S`
lists what the compiler made, and `objdump -d` reads the executable),
and every program `make check` runs uses them. `here` is
the address of the code being written, as an operand.

The assembler, `assemble`, reads a code procedure's instructions with
the scanner, Intel's syntax as NASM writes it, and encodes them with
`opM` and `opR`: `operand` reads a register, a memory operand or a
constant (by the parser's `asmConst`, handed in as a `ConstFn`: a whole
expression, or for a scale a single factor, so that `[rdi + rsi * 4 +
16]` doesn't read `4 + 16` as the scale), and a few tables give the
operations of a kind their opcodes (`Alus`, `Unaries`, `Shifts`,
`SseOps`, `Plain`; `PackedOps` the SSE2 integer operations on 16 bytes
at a time, with `movdqu`, `movdqa` and `pmovmskb` beside them, and
`BitOps` the bit scans and counts: `bsf`, `bsr`, `tzcnt`, `lzcnt`,
`popcnt`; `ShuffleOps` the same SSE operands with a three-byte opcode:
`pshufb`, `palignr`, `sha256rnds2`, `sha256msg1`, `sha256msg2`). A
kernel's instructions are there too, though the code generator never makes them: `cli`, `sti`, `iretq`, `swapgs`, `rdmsr`,
`wrmsr`, `wbinvd`, `cld` and `std` in `Plain`; `push` of a
constant (6A and a byte when it fits a signed byte, else 68 and four,
sign-extended to 64 bits); `lgdt`, `lidt`, `invlpg`, `xsave` and
`xrstor`, of one memory operand, in `MemOps`; `ltr` of a 16-bit
register; `mov` to and from `cr0`, `cr2`, `cr3`, `cr4` and `cr8` (an
operand of its own kind, `oCr`); and `in` and `out`, of `al`, `ax` or
`eax` and a port, a byte or `dx`. Each was checked against GNU `as`, and
`test/run/AsmKernel.raz` reads their bytes back. `opcode` writes the
three-byte opcodes, `0F 38` and `0F 3A`, whole, since `pshufb`'s last
byte is 00, where any other opcode ends at its last non-zero byte.
Labels are chains of jumps, as below. `db` gives bytes it doesn't
know. An error in an instruction is returned as an `ERROR`, which
`assemble` passes up. An offset that doesn't fit in 32 bits (`mem`)
can't be returned, since an operand has nowhere to give it: it is
shown, and the compile goes on to its end. `RegNames` and `CondNames`
are the names of the registers and conditions.

*When an instruction joins the assembler.* The report leaves the
instructions to the implementation, and `db` gives any other, which
stays the answer for an instruction no program uses twice. An
instruction joins when a program writes it in `db`, it is a member of
a family the tables already hold (a code in `PackedOps`, an entry in
`Plain`, `ShuffleOps`, ...), and its bytes are checked against GNU
`as` (`.intel_syntax noprefix`, read back with `objdump`) in a test in
`test/run/`, as `AsmKernel.raz` and `AsmSimd.raz` do, each form in
registers and in memory, with the extended registers. AES-NI,
`pclmulqdq` and AVX wait for a program. `sha256rnds2` takes `xmm0` as
its implied third operand, which may be written or left out, as GNU
`as` and NASM allow: `sha256rnds2 xmm1, xmm2, xmm0` and `sha256rnds2
xmm1, xmm2` are the same bytes; any other third operand is an error.

The listing, `raz -S`: with `listing` set (`setListing`), each routine
of the encoder says, with `say`, the instruction it is about to write,
as the assembler would read it; `list` prints the main module's live
procedures with each line of source (`lineText` in `Diag.raz`) and the
instructions under it. Nothing is disassembled: the listing is what the
encoder meant.

Jumps within a procedure don't wait for the linker. A label not yet
placed is a chain of the jumps to it, each jump's 32-bit field holding
the position of the one before (`jmp`, `jcc`); `fixLink` walks the
chain and patches each once the label's position is known. This is the
trick from Wirth's compilers, and it means a label is one integer.
`dropJumpTo` takes back a `jmp` just made to a label about to be
placed after it, so a `return` that ends a procedure doesn't jump to
the next instruction; the line notes made after it move back with it
(`takeBack`, in `Chunk.raz`).

## Gen.raz: the stack machine

This is the only unit that knows the machine. The calls it answers:

- values: `pushConst`, `pushAdr` (the address of a variable), `pushVar`
  (its value), `pushProc`, and `popVar`, which stores the value on top;
  `drop` and `swap`;
- operations on the values on top: `op`, `compare`, `neg`, `complement`,
  `notBool`, `narrow` (to a narrow integer's width), the conversions
  between integers and reals, `compareSeq` (of two slices), and copying:
  `copyBlock`, `copyTo`, `zeroVar`, and `copySlice` for `COPY`, a `rep
  movsb`, or a loop going down (`copyDown`) when the destination starts
  inside the source; the small ones by moves (`copyBytes`, `zeroBytes`);
  and `fillSlice` for `FILL` (`fillScalar`, `fillCopy`);
- jumps: `jump`, `jumpIf` (on a `BOOL`), `jumpCmp` (on two integers),
  `jumpOut` (`jumpCmp` from within an expression) and `condValue` for
  `and` and `or`, `fix` where the label is, and `joinJumps`;
- checks: `checkIndex`, `checkView`, `checkEnum`, and `indexSlice`, `slice` and
  `slicePtr`, which check as they make their address or slice; and
  `indexArray`, an element's address in an array in the frame, a
  chunk or behind a parameter's pointer, the index checked before;
- calls (`call`), frames (`beginProc`, `enterBody`, `returnJump`,
  `endProc`, the temporaries of `allocTemp`), deferred statements
  (`deferBegin`, `deferEnd`, `runDefer`), the built-ins that are
  instructions (`atomic`, `sysCall`, `fence`), and the program's entry
  point (`entryPoint`).

`COPY` must come out right when its two sides overlap (6.8 of the
report). `copySlice` once went backwards whenever the destination was
above the source, overlapping or not:

```
cmp rdi, rsi
jbe forwards
lea rsi, [rsi + rcx - 1]   ; the last byte of each
lea rdi, [rdi + rcx - 1]
std                        ; rep movsb runs down
rep movsb
cld
```

But a `rep movsb` going down gets none of the processor's fast copying:
it moves a byte at a time. Now only a destination that starts inside
the source, `rsi < rdi < rsi + rcx`, goes backwards, and by a loop of
words from the ends, then one of bytes for the last few
(`copyDown(8)`, `copyDown(1)`); a word is loaded whole before it is
stored, so the loop is right however near the two are:

```
cmp rdi, rsi
jbe forwards
lea rax, [rsi + rcx]
cmp rdi, rax
jae forwards               ; above, but past the source's end
add rsi, rcx               ; one past the ends
add rdi, rcx
words: cmp rcx, 8
jb bytes
sub rsi, 8
sub rdi, 8
sub rcx, 8
mov rax, [rsi]
mov [rdi], rax
jmp words
bytes: ...                 ; the same, by 1
```

Ten million copies between the two halves of a `[4096]U32`, upward:
576 ms to 71 at 10 elements, 10,900 to 410 at 1,000, as fast as
downward; and one a single element up inside itself, 539 to 57 and
10,800 to 1,600.

`FILL(d, x)` makes `d` a slice in the frame, as `COPY` does
(`Item.fillDest`), then `x`, of `d`'s element type, and stores it in
each element (`fillSlice`). An element of 1, 2, 4 or 8 bytes, a scalar,
goes into `rax`, a real's bits as an integer's, and is stored with
`rep stos` of its width. That takes some thirty cycles to start, twice
the time of ten stores, so a short slice is filled by a loop instead,
and an array of 16 elements or fewer by a store each (`fillScalar`):

```
mov rax, r8                ; x
mov rdi, [rbp - 48]        ; d's pointer and length
mov rcx, [rbp - 40]
cmp rcx, 16
jae many
test rcx, rcx
jz out
top: mov [rdi], eax
add rdi, 4
sub rcx, 1
jne top
jmp out
many: rep stosd
out:
```

A constant zero into an array is its bytes zeroed, by `zeroBytes`, as
a variable's are. Any other element, a record or an array, is copied
into `d[0]` from `x`'s address, then `d[0..n - 1]`'s bytes into
`d[1..n]`'s by `rep movsb`, forward (`fillCopy`): each byte it reads it
wrote `SIZE(T)` bytes before, so `d[0]` repeats through the rest.

```
mov rdx, [rbp - 40]        ; the length
test rdx, rdx
jz out
...                        ; copyBytes: d[0] := x, from [rsi]
mov rsi, [rbp - 48]        ; from d[0]
lea rdi, [rsi + 24]        ; to d[1], for a 24-byte record
lea rcx, [rdx - 1]
imul rcx, 24
rep movsb
out:
```

`x` is read once, before any element is written, so `FILL(a, a[3])`
fills `a` with what `a[3]` held. Ten million fills of a row of
`U32`s at one of 64 places in a `[4096]U32`, as rat paints a cell's
background, against the loop in a procedure of its own: 52 ms to 37 at 10
elements, 2,500 to 490 at 1,000.

At 10 it was 65 ms, slower than the loop, until `seqSlice`, which
gives `COPY`, `FILL` and a comparison their slices in the frame,
stopped copying a slice that is already a temporary of its own, as one
just cut is. It had copied every slice, lest `s` or `x` change a
variable it read, and so the pointer and length went through memory
twice before `rdi` and `rcx` had them:

```
mov [rbp - 48], rax        ; band[at..at + n], cut
lea rsi, [rbp - 48]
lea rdi, [rbp - 64]
mov rcx, [rsi]             ; copied
mov [rdi], rcx
mov rcx, [rsi + 8]
mov [rdi + 8], rcx
...
mov rdi, [rbp - 64]
mov rcx, [rbp - 56]
```

Now `rdi` and `rcx` are loaded from `[rbp - 48]` and `[rbp - 40]`.

A variable's place is an `Adr`: relative to the frame (`bFrame`), to a
chunk (`bGlobal`), to an address on the stack (`bStack`), or to one
held in a frame slot (`bSlot`, as a `var` parameter's is) or in a register
(`bPtr`, as one that has a register's is); plus `off`.
`place` turns it into an x64 memory operand, popping or loading the
address first, so that a variable is read or written with one
instruction.

The stack: `stack` notes where each value is, a constant (`lConst`), an
address not yet computed (`lAdr`, `adrMem`'s operand), an element's
address not yet computed (`lIdx`, an operand `[base + index * size]`), a
variable's value not yet read (`lMem`, at an operand), a register
variable's own register, read in place (`lHeld`), the value's own
register (`lReg`) or a frame slot (`lFrame`); `owner` says which value
each register holds, `lIdx` and `lMem` holding theirs when it is their
index. A word in a register may have an offset not yet added (`off`),
which an operand takes as its displacement. The value at depth `d`
belongs in `Regs[d mod 4]`, `r8` to `r11`: `rax`, `rdx` and `rcx`, which
division and shifts need, and `rsi` and `rdi`, which copying needs,
aren't among them. A real belongs in `XRegs[d mod 4]`, `xmm8` to
`xmm11`, which carry no arguments; each depth has the two registers, and
`owner` doesn't tell them apart (`regIn`, `regOf`). `claim` gives a
value its register, and `spill`s the lower one that holds it, when an
expression is deeper than the registers; `loaded` brings a value into
its register, from its constant, address or slot; `place` uses a noted
address as the operand itself, so that `popVar`, storing a constant, and
`incDec` are one instruction on memory: `DEC(n)` is `sub qword [rbp -
8], 1`. `top` is `loaded` for the value on top, and `target` the
register a new one is computed in. `drop` emits no code, and the dropped
value's register still holds it until the next push, which several
routines rely on. Before a call every value in a register is spilled
(`spillBelow`), since the call may change them, and so are the values
under a comparison that jumps out of an expression (`jumpOut`), which
both ways to its label must find in the same place. `pushed` counts the
quadwords on the machine's stack. A call needs `rsp` a multiple of 16,
so `call` pads by one quadword when `pushed` plus its stack arguments is
odd; in a deferred statement `pushed` starts at 1, for the return
address. `op` takes a constant on the right as it is, after moving one
on the left of `+`, `*`, `&`, `|` or `xor` there, and a power of two on
the right of `*`, `div` or `mod` becomes shifts (`divPow2`), since
`idiv` is slow; an element's size multiplies an index by a shift too
(`mulI`), as a shift takes one cycle and `imul` three. Narrow integers
are brought back to their width after each operation, which is how `U8`
arithmetic wraps; since they are computed in 64 bits, a shift's count is
cut to their width first, and `divTrap` makes the smallest value of one
divided by -1 fault as an `I64`'s does. A rotation, `ROL` and `ROR`
(`Gen.rotate`), is the one operation done at its value's own width,
`rol al, cl` and not `rol rax, cl`, so that the bits leaving one end of
a `U8` come back in at its other end; and its count needs no mask, as
x86 takes it modulo 32, or 64, and a byte's or a word's rotation then
goes round modulo 8 or 16 itself, the count modulo the width.

The counts of bits, `CLZ`, `CTZ` and `POPCOUNT`, are made with what
every x86-64 has, as `lzcnt`, `tzcnt` and `popcnt` came later and the
compiler doesn't ask which machine it is on. As a narrow integer's
bits above its width are zero, all of them count in 64 bits.
`countZeros` makes `CLZ` from `bsr`, the place of the highest one bit,
and `CTZ` from `bsf`, the place of the lowest; neither has a place to
give for 0, which they say by the zero flag, and 0 counts the whole
width. For a `U32`:

    CLZ(x)                      CTZ(x)
        bsr r, r                    bsf r, r
        jnz L                       jnz L
        mov r, -1                   mov r, 32
    L:  neg r                   L:
        add r, 31

`popCount` adds up the ones as `lib/Bytes.raz`'s `count` does, with
no loop: each two bits become the number of their ones, then each
four, then each byte, and a multiplication by `0101...H` adds the
eight bytes into the top one, in rax and rdx beside `x`'s register:

    mov rax, r; shr rax, 1; mov rdx, 5555...H; and rax, rdx; sub r, rax
    mov rax, r; shr rax, 2; mov rdx, 3333...H; and rax, rdx; and r, rdx; add r, rax
    mov rax, r; shr rax, 4; add r, rax; mov rdx, 0F0F...H; and r, rdx
    mov rdx, 0101...H; imul r, rdx; shr r, 56

`abs` makes `ABS` of a signed integer with no branch: it negates `x`
and takes back the copy it kept in rax if the negation is negative, as
it is for a positive `x`. The smallest value negates to itself, which
is negative, and so gives itself, as `-x` does, with no check, as `-x`
has none. A narrow value is negated in 64 bits, where its smallest
isn't the smallest, and cut back to its width after, as `neg` does:
-128 in an `I8` negates to 128, which in 8 bits is -128 again. A real
has its sign bit cleared in rax, as `neg` flips it; an unsigned integer
needs no code.

    ABS(x), an I32              ABS(x), an F64
        mov rax, r                  movq rax, x
        neg r                       btr rax, 63
        cmovs r, rax                movq x, rax
        movsxd r, r

Checks: `check` jumps, when the check fails, to code at the end of the
procedure (`endFails`), so that a check that holds is a jump not taken.
That code puts the values involved where `Rt.fail` wants them and calls
a stub for its kind of failure (`failStubs`, made by `entryPoint`),
which says the kind and passes the address it was called from, by which
`Rt` finds the place: the failing code has the place of the offending
expression (`lineCol` in `Scan.raz`), worked out when the check is
made, while the source read is the expression's, and noted in its
file, so that a check in a procedure made in place of its call is told
at that procedure's line. It leaves `rdi` and `rsi` as they
were, so that the stub can pass them on, for the trap report to show a
parameter kept in them. A check costs a compare and a jump where it
stands, and a dozen bytes out of the way. Code is aligned to 32 bytes,
the windows x86 fetches it in, so that where a procedure's loops fall
doesn't depend on what comes before it.

The stack has 256 places and a procedure may have 4,096 checks. Past
either, `newEntry` or `check` shows the error and goes on, since a push
or a check has nowhere to return it; the parser's `resetStack` makes the
stack right again. `endProc` returns its error (a frame too big) and
`codeProc` the assembler's.

What the machine catches, the code doesn't test for (report section 10,
appendix A): on x86-64 Linux a division by zero raises SIGFPE, a stack
overflow meets the guard page under the stack, a call to `nil` jumps to
an address never mapped, and so does a load or store within `NilPage`
bytes of address 0. `Rt`'s handlers say where and why. What is left is a
field of a `nil` pointer past that page: an item reached through `^` is
`deref` until `nilTest` (`Item.raz`) has it used, and Gen's `checkNil`
tests the pointer only if the use reaches past `NilPage`. A port whose
machine catches less tests for more, in its own `Gen.raz`: `Rt.fail`
stops for a nil pointer, a division by zero and a stack overflow as the
signals would.

Calls: the arguments are computed left to right onto the stack, where
they wait for `call`, as any values do: a constant, an address or a
variable in a register only noted, the rest in registers, or spilled by
a call in a later argument, so that it can't disturb them. `call` spills
what is under them, moves each into the register System V wants
(`valueTo`), `r8` and `r9` last since they may hold others, and aligns
the stack. A slice goes as its two words, in two registers or both on
the stack, as System V passes a struct of two integers, and the
procedure keeps them in its frame. A record passed by value goes as the
address of a copy. A result of two words, a slice or two single values
that aren't reals (`inTwoRegs`, in `Sym.raz`), comes back in rax and
rdx, as System V returns a struct of two integers: `return` leaves both
on the stack for `returnJump`. `call` leaves two results on the stack,
and stores a slice in a temporary of the caller's. Any other record, or
several results, come back in memory the caller provides, through a
hidden pointer in `rdi` (`behindPointer`, `resultTo`, `copyResult`). C
returns a struct of up to 16 bytes in `rax` and `rdx`; raz sends every
record through memory, and only a slice or two single values in
registers.

Frames: `beginProc` gives the parameters their slots; `enterBody` writes
the prologue, which zeroes the locals in memory (16 bytes a store: a row of
them, or a loop for more; there are none to zero in `scale`) but not the
temporaries, since each is written before it is read; `endProc` writes
the epilogue and patches the frame's size in. Within a statement,
scratch space comes from `allocTemp` and is given back by
`releaseTemps`; `allocPerm` reserves space for the whole procedure.
A result that holds an array (`Sym.holdsArray`), and a `const`
parameter's temporary that holds one (`constTemp`), is given an
`allocPerm` slot instead, so that it lives to the end of the procedure,
as the report says (section 8): a slice of it may be kept in a local.
Before, it was an `allocTemp` slot, and the next statement wrote over
it. Each call has a slot of its own, so the frame grows by each such
result; in a loop, one call's slot holds its latest result.

Register variables: the parser chooses them (`chooseRegs`, in
Parse.raz), then gives the locals left in memory their slots
(`placeLocals`), and tells Gen (`useRegs`) the registers, as bits of
`VarRegs`. A variable in a register has no slot of its own. Gen saves
the registers in slots a quadword each, after the locals and not zeroed,
as each is written first. The prologue saves them, zeroes them, and
moves a parameter into its register from the register or stack slot it
arrived in; the epilogue restores them. A slice may have two, its
pointer's and its length's (see "Better code again" above). A variable
in one is an item at `bReg`: `pushVar` notes it (`lHeld`) rather than
copying it, `peek` reads it in place where the value is only read, so `i
< n` is `cmp rbx, r12`, and `popVar` and `incDecReg` write it. Rt finds
the values for the trap report from the saves: each procedure's record
in the places says which it saved, and where (`saveMask`, `saveAt`). A
real takes one of `xmm12` to `xmm15` (`XVarRegs`, numbered from `XmmVar`
up, so that `xmm12` isn't taken for `r12`), which the prologue zeroes
and saves nothing for, and a slot as well, which `popVar` writes as it
writes the register (`xHome`): the trap report finds it there, and
`call` loads the register from it after each call, as System V has no
callee-saved xmm register.

## Item.raz: items

An operand is an *item* (`Item`), as in Wirth's compilers. Its `mode`
says what it is now:

- `mConst`: a value known to the compiler, in `val`;
- `mVar`: a variable, at `base`, `chunk` and `off`, which `adrOf` makes
  an `Adr` for Gen;
- `mStack`: a value on Gen's stack;
- `mWords`: the two results of a call, as rax and rdx brought them, on
  Gen's stack, the first under the second. `a, b := f(x)` brings the
  first to the top (`swap`) and pops each into its variable, so that
  nothing goes through memory; `return f(x)` leaves them for
  `returnJump`; anything else makes them a temporary (`copyToTemp`);
- `mCond`: a condition, as Wirth's compilers keep one: two integers on
  Gen's stack, compared by `rel` once something wants the result, and
  the jumps of `and` and `or` that land where it is false (`fj`) or true
  (`tj`); `condJump` makes it a jump, `value` a `BOOL`;
- `mProc`, `mType`, `mStr`, and a few more the parser needs.

An item also carries `pos`, the stretch of source it came from, which
the parser sets as it reads an expression; an error about an item is
reported there (`Scan.markAt(x.pos, ...)`), and one about two operands
across both (`Diag.join(x.pos, y.pos)`). `what` names an item for a
message: a constant without a type of its own as it is written
(`found 1.5`), anything else by its type.

An error is shown where it is found, by `Scan.markAt` and the others,
which return `Scan.Failed`. Every routine here that can find one returns
an `ERROR` as its last result, and the ones that call it pass it up with
`try`, to where the parser reads on.

Two routines move items towards the machine: `value` pushes an item's
value, and `address` a variable's address. Both leave the item saying it
is on the stack. An item nothing more is done with is given back to
`discard`.

Expressions: `op1` is called when the parser has seen an operator and
its left operand, `op2` when it has the right one. `op1` pushes the left
operand, unless it is a constant; for `and` and `or` it makes the left
one a condition (`makeCond`) and jumps past the right one, which `op2`
joins to it: `(a < b) and (c < d)` in an `if` is two compares and two
jumps, as `not` of a condition is the other comparison. A constant
left that decides the result, `false and y` or `true or y`, is the
constant itself: `op1` jumps over the right one's code, about to be
made, to a label `op2` places after it, so that `y` is never run, as
the report says. `op2` checks the
types, folds constants (`foldInt`, `foldReal`), and otherwise pushes the
right operand and has Gen do the operation; a constant on the left goes
on after the right, and the two `swap`. A set's operations are
operations on its bits (`setOp`). `=` and `#` on arrays, slices and
strings make a slice of each side (`seqSlice`) and have Gen compare them
right where the comparison stands: no call. `+` on two string constants
is `joinStr`, which makes one string of them, in a chunk of its own.

Variables: `deref`, `field`, `index` and `slice` turn an item for a
variable into an item for part of it, mostly by adding to `off`. An item
for another module's exported variable, or part of it, is `ro`: it isn't
a variable (`isVar`), and `notReadOnly` says why where one is wanted;
what it points at is. An array or record constant is a variable too, in
read-only data: `aggregateConst` (`Parse.raz`) reads its literal, part
by part in `constPart`, into the bytes of a chunk, as a string
constant's are; an address in it, of a string, an array constant, a
procedure or an `ERROR`, becomes a data fixup. A constant typed `[]T`
takes its length from its literal: `literalArray` makes the type
`[n]T`, as if `n` were written, with `n` counted ahead by
`literalLength`, which reads the literal once, counting the commas
outside any inner brackets, and goes back to its `[` (`saveScan`,
`restoreScan`), so `constPart` reads it as it reads any array's:

    const P: []I64 = [2, 3, 5];    (* read as *)    const P: [3]I64 = [2, 3, 5];

A variant in a constant, `const S: Shape = circle(1.0)` or one among
an array constant's elements, is read by `constCase`, not by
`expression`, which would make the code that builds a case: it finds
the case by its name (`qualIdent`), writes its number in the first 8
bytes, then each field at the offset the case gives it, by `constPart`,
leaving the rest zero, as a variable starts. A constant of a variant
type is then a variable in read-only data, as an array or record
constant is, and a `match` on it gives names that are only read.

With no element, `[]`, the type stays `[]T`, and the constant is 16
zero bytes in read-only data: the empty slice, `ptr` `nil` and `len` 0,
read as a slice variable is, so its `LEN` is no constant. `constPart`
takes `[]` for any slice part, and an empty slice constant named there,
by leaving the part's bytes zero:

    const E: []I64 = [];    (* read as the bytes of *)    var E: []I64;

A slice part written as an array literal is an array constant of its
own: `constPart` has `literalArray` make its type `[n]T`, and
`constChunk` read it into a chunk of its own, with no name, before the
constant around it is done; the part is then its address, a data fixup,
and its length, as for a named array constant. `constChunk` keeps the
outer constant's bytes aside while it reads the inner one, and puts the
inner one's fixups in `fixes` after the outer one's, taking them off
again when its chunk is made, so literals nest to any depth, in records
and variants too:

    const Rows: [][]INT = [[1, 2], [3]];    (* read as *)
    const R0: [2]INT = [1, 2];  R1: [1]INT = [3];  Rows: [][]INT = [R0, R1];

An `ERROR` constant is a chunk of read-only data, its message's length
and then its bytes, made by `errorChunk` (`Item.raz`) from a string;
the constant's `val` is that chunk plus one, so that `nil` is 0, and
errors compare by it. One whose value is another `ERROR` constant,
`const Short*: ERROR = PictBase.Short;`, takes that one's `val` in
`constDecl`, and no chunk: it is the same error, and `Short =
PictBase.Short` holds. Only a string makes a new one.

`makeItem` makes it an
`mVar` there that isn't `isVar`, so it is read, indexed, sliced and
passed, never changed. `index` and `slice` have Gen make the bounds
checks, unless the module says `check off;` (`checks`, set by
`setChecks`, which `compileFile` sets for each module), and `convert`
the check of an enumeration's position.

The frame: an item's `frame` says, for an array or record, that it lies
in the procedure's own frame (a local, a value parameter, which is a
copy even when passed by address, or a temporary; not a `var` or
`const` parameter, the caller's, even when that is a temporary of the
caller's statement), and for a slice,
that it points there. `makeItem` and `tempItem` set it; `field` and
`index` keep it for a part of the array, and drop it for an element of
a slice or a slice kept in a field, which may point anywhere; `deref`
drops it; `slice`, and `coerce` where an array becomes a slice, carry
it to the slice they make. `notOfFrame`, from `returnValue` and
`returnField`, refuses a returned slice that has it (report 7.3). It
sees only the expression: a slice put in a local slice variable first
has lost it, which the report leaves undefined (section 10).

Assignment and conversion: `coerce` makes a value fit the type it's
going to, or reports that it can't; it's where a string literal becomes
a slice, an array a slice, a `[]T` a `[]const T` (the same two words,
its type changed), an untyped constant a typed one, and an `INT`
an `I64` (`widens`), wherever it goes: a `for` loop's bounds, `INC`'s
step and several results pass through `coerce` too. An `INT` meeting
an `I64` in an operator is `op2`'s, which gives the result the `I64`;
`return f(x)` takes results that widen by `resultsFit`. None of it
makes code: an `INT` and an `I64` are the same 64 bits on x86-64, so
only the item's type changes.

A `U8`, `I8` or `I16` goes into an `INT`, and a `U8` or `U16` into a
`UINT`, by `smallWidens`, in `coerce` and `op2` alike (report 2026-10.31).
Gen keeps every integer on its stack extended to 64 bits as its type
says, `movzx` for a `U8` and `movsx` for an `I8`, so `coerce` loads the
value as its own type (`value`) and then changes only the type:

    before:  x is a U8 variable; the INT it is wanted as is an error
    after:   value(x) loads it, movzx r8d, byte [...]; x.typ := INT

What an operator gives doesn't widen, since it was computed in the
narrow type and may have wrapped: `op2`, `neg` and `complement` mark
their result `made`, which `coerce` and `op2` refuse (`madeNarrow`),
and `convert` clears, so that `U8(a + b)` widens. `return f(x)` passes
results on as they are, so `resultsFit` takes only `INT` to `I64`.
`assign` stores, or
copies records and arrays. `convert` is the written conversion, `T(x)`.
A `BOOL` converts to an integer (report 2026-10.36) as an integer
does, with no code of its own: its value is already 0 or 1, in a
variable's byte and where `value` makes a condition's (by `setcc` and
`movzx`, or 1 and 0 where `and` and `or` jump to), so `U64(a = b)` is
the compare and `setcc`, and a constant `BOOL`'s is folded. An integer to `BOOL` stays an error, with help
that says `x # 0`.

Views, `v.(T)` (report section 6.9): a view is the item of `v` with
`T` for its type. It is at the same place, so nothing is copied or
computed to make it: `mem[16].(I64) := n` compiles to the store
`mem[16] := n` would be, but of 8 bytes. What `view` and `indexView`
add is the checks:

- `viewable`: `v` is a variable (not a constant or a temporary; another
  module's is read only, by its `ro`), not volatile, and `T` is plain
  data (`notPlain`: integers, reals, pointers, and records and arrays
  of them alone);
- the room: `view` wants `T` to fit in `v`, which the compiler always
  knows; `indexView`, for `a[i].(T)`, wants `T` from `a[i]` to `a`'s
  end. `T` takes `k` elements (`elementsFor`), so in an array of `n`
  the index must be below `n - k + 1`: one unsigned compare
  (`Gen.checkView`) in place of `index`'s `i < n`, which a negative
  `i`, huge unsigned, fails too. A slice's length is known only as the
  program runs: `Gen.indexSlice` checks `i < len` as ever, then, with
  a view's `room` of `k - 1`, that `len - i`, which can't wrap once `i
  < len`, is more than `room` (`checkRoom`). A failed one is kind 7 of
  `Rt.fail`: "a view at index 9 runs past a length of 16".

The item is marked `view`, which keeps `ADR`, a `var` argument and a
slice from it (`noAddress`), as `odd` does for a field of a packed
record: a view may be misaligned. A variable kept in a register has no
bytes to view, so `becomeView` demotes it to memory as `address` does
(`demote`), and the procedure is compiled again. The parser sees a view
of an element only after the `]`: `designator` reads the index, then
looks past the `]` for `.(` (`viewNext`, by `Scan.saveScan` and
`restoreScan`), so that `indexView` has the index and the array
together.

Calls: `beginCall`, then `passArg` for each argument, then `endCall`,
which has Gen's `call` make the call. Each argument is left on Gen's
stack, a slice as its two words (`pushWords`).

A `const` parameter (report section 8) is a `var` one that is never
changed: its `Obj` has `isVar`, so Gen passes and reaches it by
address as it does a `var`, and `isConst` too, which makes an item
for it, or for a part of it, `ro`, as another module's variable is.
`onlyRead` tells the two apart, so that `notReadOnly` says "is only
read here", and a slice of its array may still be made, to read, as a
constant's may. `passArg` gives a variable's own address, where a value
parameter's record is copied first:

    value parameter, a record:   copyToTemp(a); address(a)
    const parameter:             address(a)     (* a variable, in place *)

and anything else, a constant number, an expression, a call's result,
a packed record's field, it puts in a temporary of the statement first
(`constTemp`). A `match` on something only read gives names that are
`isConst` too (`matchStatement`), where another module's variable is
copied first and its names are the copy's.

The compiler takes its own `Item`, about 130 bytes, as `const` where
it only reads it on the paths every program goes through (`adrOf`,
`discard`, `onlyRead`, `zeroRange`, `forCmp`, Parse's `assignable`
and `clearMissing`, ...): measured with callgrind, each such copy gone
saves instructions, 0.4% in all. The routines reached only to word an
error (`what`, `mismatch`, `doesntApply`, ...) take it as a value,
where a copy costs nothing that is measured.

An address given where a `var` or `const` parameter of its type wants
the variable, `f(ADR(b))` or `f(p)`, is the commonest slip in a program
written before the library took `var`; `givenAddress` says what to
write instead, `b` or `p^`, from the argument's own text. `return f(x);` passing on
f's several results, with `returnAll`, pushes them from the call's
temporary if they are two words, or else copies them to the place its
own hidden pointer names.

## Parse.raz: the parser

A recursive descent parser, one routine for each rule of the grammar in
the report, calling `Item.raz`, and for jumps `Gen.raz`, as it goes.
Like the other modules it is written in raz: the Free Pascal seed built
it the first time, and it builds itself now. Its routines begin in
lower case, and each one that can find an error ends in an `ERROR`
result, passed up with `try` (see Recovery below).

Start with expressions, bottom up: `factor`, `term`, `simpleExpr`,
`relation`, `conjunct` (the `and`s), `expression` (the `or`s). Then `designator`, which reads a name and what follows
it: `.field`, `^`, `[i]`, `[lo..hi]`, a call, a conversion, a view
`.(T)`. Each step
calls the matching routine in `Item.raz` on the item it has. The
`want` parameter carries the type an expression must have, where it is
known, so that `[1, 2, 3]`, `{x: 1}` and `{red}` know what to build
(`arrayLiteral`, `recordLiteral`, `setLiteral`). A call of a
procedure that only returns is made in place by `inlined` (see
"Inlining a procedure that only returns").

Then statements: `statement` makes each one a recovery point (below)
and `oneStatement` dispatches; `ifStatement`,
`whileStatement`, `forStatement` and `matchStatement` emit their jumps
with gen's labels. A branch of an `if` that ends, in `return` or
`break` (`ends`), gets no jump past the others; and `if c then break;
end` is one jump out of the loop where `c` holds (`thenPart`,
`loneJump`, and `Item.condJumpTrue`), not a jump past a jump; so is
`if c then continue; end`, to the end of the round. A loop keeps two
chains of jumps in its `Loop`: `brk`, fixed after the loop, and
`cont`, for `continue` (report 2026-10.31), fixed where the round ends:
a `while`'s test, a `repeat`'s `until`, a `for`'s step (`forNext`). A `for` loop
steps its variable at the top and tests at the bottom, so that a round
by 1 is one compare and one jump; its rare case, a body that moves the
variable past the limit, has code of its own after (`Item.forNext`, whose
comment walks through the report's rule). The blank is a symbol of its own, `sBlank`, so
no declaration or expression takes it: `_ := e` loads a single value
and drops it, and `multiAssign` skips the results it stands for. A
`match` on an integer reads each arm's
labels in `intArm`, which refuses a value in two of them. The arms
come first and the test after them: the match starts with a jump to
`dispatch`, placed after the last arm, since a jump table can only be
made once every arm's place is known (an enumeration's arms are
picked the same way; a variant's, by its tag, arm by arm).
`dispatch` makes a jump table (gen's `jumpTable`, whose comment shows
the code) for four labels or more that lie close together, else
compares and branches one label after another with `Item.matchRange`, each
jumping back to its arm. A `match` on a string is tested arm by arm,
as a variant's is: `Item.matchBegin` puts the string's slice in a slot
(`seqSlice`, as `=` does), and `strArm` compares each label with it by
`Item.matchStr`, gen's `compareSeq` and a jump, to the arm if they are
equal or, for the arm's last label, past it if they aren't. It keeps
each label's bytes, as their chunk and length, to refuse a second one
the same. `deferStatement` is worth reading: a deferred statement
is compiled where it stands, as a little subroutine of the procedure
that the code jumps over (gen's `deferBegin` and `deferEnd`), and
`runDefers` emits a call to it at every way out of its statement list:
the end, `return`, `break` and `continue`. A `return`'s result waits in the frame
meanwhile, so that gen's stack is empty when they run.

`try` (report 7.8) is `tryCall`, for the statement, an operand
(`factor`) and the right of a multiple assignment (`multiAssign`). It
reads the call as `designator` does, takes the error, the last of its
results, out of the way into a slot of the frame, and leaves in `x`
the results that are left: none, one value, or a tuple of the others,
`withoutLast`. Then, in the code before and after, this:

```
        load [slot]; jz ok            ; Gen.jumpIf(ok, false); with no deferred
                                      ; statement, the register, tryTest
        and rsp, -16                  ; Gen.tryAlign, if a deferred statement is in force
        call deferred...              ; runDefers(0), as for a return
        mov rax/rdx or the results    ; Gen.tryReturn(slot), tryReturnFrom: zeros, and the error last
        jmp exit
ok:     ...
```

Unlike `return`, which is a statement and finds gen's stack empty,
`try` can stand in the middle of an expression, with values waiting
on gen's stack and quadwords pushed for another call's arguments. The
out-of-line code therefore makes no entry on the stack: `tryReturn`
loads registers and jumps, and `tryAlign` makes the machine's stack
even for the deferred statements, which expect it so. The code that
follows is the code for an error that is nil, with the stack as it
was, so no model needs resetting.

Then declarations: `declarations` reads `const`, `type`, `var`, `proc`
and `extern`, each one through `declaration`, a recovery point, which
calls `constDecl`, `typeDecl`, `varDecl`, `procDecl` or `externDecl`
(by `declarationOf`). `procDecl` handles forward declarations, code procedures
(`codeBody`, which checks the signature, a slice parameter counting as
two of the six integer registers and a slice result going in rax and
rdx, and has gen's `codeProc` run
the target's assembler) and bodies (`body`).
`parseType` and its helpers (`recordType`, `variantType`, `signature`,
`enumType`) build `Sym.Type`s. In a `type` section (`inTypes`) a
pointer's base and a procedure type's parameter or result may name a
type declared later (report, 4), so that two records can point at each
other and a record's callback can take the record: `laterType` reads
the name, and if nothing is declared by it yet gives a placeholder, a
type of form `fNone` of its own, noting it in `laters` with its owner,
the pointer or the procedure type. When the section ends,
`resolveLaters` puts the type declared in each placeholder's place, in
the owner's base, parameters or results, and lays several results out
again (`layOut`), as their sizes are known only now. Nothing waits on
the size: a pointer is a word and a procedure value an address, and no
call is made inside a `type` section. A field by value is read by
`parseType` alone, so a record holding itself is still "isn't
declared". `qualIdent` reads a name, `M.x` too, and
`Elem.bold`, a name of an enumeration with its type (`enumName`); it
refuses a name two enumerations share (`twinError`). An arm of a `match`
on an enumeration or a variant names its case (`armCase`): a name
alone is looked for among the type's own cases (`caseNamed`), whatever
the scope holds, so `| done:` serves a type of another module; a name
followed by a dot, `Kind.done`, `Xml.done` or `Xml.Kind.done`, is read
by `qualIdent`, as it is in an expression, and must then be a case of
the matched type, or the message names both types. `compareIface` passes over an enumeration's names,
which its type's fingerprint has.

Last, modules, at the end of the file. `compileFile` reads one module.
What report 2026-10.37 fences behind `import SYSTEM` is refused by
`needSystem` in a module whose `Sym.Module.system` isn't set: a pointer's arithmetic, indexing and
slicing, pointer and procedure conversions, views and `BYTES` that make
or change an address (`Sym.isPlain`, the item's `viewOver`, checked in
`notReadOnly`), a string as a `^U8`, `extern`, `link`, `check off` and
code procedures (the last four reported and the declaration read on,
so that one missing import is one error). `builtin` refuses `ADR`,
`PTR`, `SYSCALL` and `ARGV` not reached through `SYSTEM` (their
objects' `home` tells them apart). A string, a slice of a constant,
`MSG` and a slice of a `const` parameter's array are `[]const`. raz
0.23 took all of it, under an option `-strict` to refuse it while the
library and the programs were mended; 0.24 has no other way.

`import SYSTEM` (report 2026-10.37) finds no file: the import binds the
name to `Sym.system`, a module made once in `Sym`'s body whose scope
holds four of the built-ins, `ADR`, `PTR`, `SYSCALL` and `ARGV` (made by
`enterIn`), so that `qualIdent` finds `SYSTEM.ADR` as it finds any
export and `builtin` compiles it as `ADR`. It is marked used at the
import, since a module may import it only for `extern` or `link`. An
alias, `import S := SYSTEM`, is refused, so a grep finds every such
module.

`importModule` finds a module's file, trying the target's names first,
and compiles it if it isn't yet. `compileMain` keeps `/` as the
directory of a main file at the root, and `modulePath` joins a directory
and a name without a second slash when the directory ends in one (`lib/`),
so that listing a directory and opening its files name the same places,
`/` too. A module found in an `-I` or
`RAZ_PATH` directory that holds a file `RAZ-VERSION` gets a line
(`libraryNote`, `majorMinor`) saying the raz its library was written
for and this one's, "0.21" for `0.21.0-5-g38d29a8`; the compiler only
reads the file. `checkOneModule` first makes sure no
later directory has the module too, unless the file is a link to one
of its files there (a file's identity is its device and inode from `Sys.info`,
which follows a symbolic link, as on every target); `checkSiblings` then reads the files for other
targets beside it, declarations only, and `compareIface` holds them
to the same exports by their fingerprints. A generic module is
compiled once per distinct list of arguments, where it is first used.
The import only notes where its arguments are (`skipArgs`, `deferred`);
`firstUse`, from `qualIdent`, has `makeInstance` go back there, where
`parseArgs` reads them, then compile the instance. `moduleParams` binds them
to the module's parameters, and `isModule` decides whether an instance
already exists. An instance can't be compiled in the middle of another
procedure's code, since the code buffer is one run of bytes, so
`instancesFor` reads ahead through a procedure, or the module's body,
before its code begins, and makes the instances it names.

**Recovery.** After an error the parser carries on, so that one run
reports them all. The Pascal seed did it with `setjmp` and `longjmp`;
raz has neither, so here an error is a value. `Scan.mark` and the
routines like it show the message and return the `ERROR` `Scan.Failed`;
each routine that calls one passes it up with `try`, until it reaches a
recovery point, `statement` or `declaration`, which looks at what came
back. At the start of its construct it called `guard`, which notes in a
`Recover` the scanner's state and the parser's (the scopes, gen's stack,
the loop, the deferred statements, how deep it is nested, `quiet`). On an error `restore` puts
the state back, the construct's first symbol current again, and
`skipConstruct` reads past it, counting the words that open and close
blocks. A symbol at the start of a line ends the skip: by the usual
layout it starts the next declaration, so the statement gives up its
procedure (`giveUp`), which passes the error on up to the next
recovery point, the declaration of the procedure, and `skipProc`
reads to the procedure's `end Name;`. A declaration that is not a
procedure is skipped by `skipDeclaration`. `guards` counts the recovery
points open: `giveUp` with none left ends the compile. A routine that
can't fail has no `ERROR` result (`declarations`, `declaration`). A name not declared is reported by
`notDeclared`, with what it may have meant: a module to import
(`moduleFile`), a hexadecimal number without its first digit
(`hexLike`), or a name spelled alike (`didYouMean`). It is then
declared where it is used, with the type `tPoison` (`poison`), as are
the names of a declaration that had an error; a construct that uses
poison sets `Diag.quiet` (by `Diag.setQuiet`, since a variable
exported by another module is read-only), and its errors aren't
reported, since they follow from one that was. Nothing breaks for the
half-made code: once there is an error, no executable is written.

**Hints.** Some messages guess at the mistake from the layout. A
block statement passes `closeEnd` its start and how far its line is
indented; an `end` further left was most likely meant for a block
around it, so the first such statement is kept, and `endMissing`
notes it when a procedure's own `end` turns out to be missing. A type
error in an argument goes through `Item.mismatch`, which notes the
parameter it goes to (`Item.passing`, set by `Item.passArg`).

**Warnings.** `declare` keeps each module's declarations in order in
two lists, through `chain`: its own (`first`) and its procedures'
(`locals`), parameters
and a match's names for fields among them. `named` marks an object
`used` and `read` wherever a name finds it, except a procedure naming
itself; `leftSide` puts `read` back as it was for a variable named
whole before `:=`, which is written, not read. At the end of a module
with no errors, `warnings` merges the two lists by position and `warn`
reports what isn't exported, doesn't start with `_`, and was never
used, or, for a variable, only assigned, and a procedure with results
that may reach its end (`openEnd`, from `ends`, which each statement
sets). The calls that drop results, and the other doubts, are a third list, `doubts`, in
order: `compileFile` notes where the module's own begin (`numDoubts`),
since the instances it makes along the way add theirs and take them
back. A
generic module's instances
share its text, so only the first is warned of.

The built-in procedures are in `builtin` (and `new_`, `atomic`): each
parses its own arguments, since `SIZE` takes a type and `INC` a
variable.

`CAS`, `XCHG` and `XADD` (report 2026-10.37) take a variable, as `INC`
does: `atomic` pushes its address, as `ADR` would, and `Gen.atomic`
works through it as before, so the code is the same as for
`XADD(ADR(n), 1)`. A first argument that is a pointer but no variable,
`ADR(n)`, the form before 10.37, is refused with help. Since the
address is taken, `chooseRegs` keeps a local named in one in memory,
as it does one named in `ADR`.

`SIZE(T.f)` and `OFFSET(T, f)` (report 2026-10.36) read the type with
`parseType` and then the field with `typeField`. The name before a `.`
in a type can only be a module's, so `parseType` reads `M.T` whole,
and a `.` after the type is always a field's: `SIZE(M.T.f)` is field
`f` of `M.T`, with nothing read ahead. `typeField` refuses a type that
isn't a record, with help for a variant, whose cases share one place,
and a path, `a.b`, with help that asks `a`'s type instead. Each is an
untyped constant, the field's size or its `val`, the offset
`recordType` gave it, so both may stand in a constant.

`PTR(s)` (report 2026-10.34) is `ptrOf`, which refuses what isn't a
slice, an array or a string with a message that says what PTR is for
(and, for a pointer, what to write), and Item's `startOf`, which makes
it. Of a slice it is the first of its two words, read as `LEN` reads
the second, with no check, so that an empty slice gives what it holds;
a call's slice, in two words on the stack (`mWords`), drops its length.
Of an array or a string it is the address, refused wherever `slice`
would refuse the slice of all of it:

    ADR(s[0])    check 0 < LEN(s), then s's first word   (stops on "")
    PTR(s)       s's first word                         (no check)

`BYTES(x)` (report 2026-10.36) is Item's `bytesOf`. It is made as a
slice of `x` is, and refused where one is: a string constant, another
constant or a call's result, what is only read, a volatile variable, a
packed record's field and a view, each with its message; and
`bytesType` refuses a type a view may not take, by `notPlain`, its help
naming the record's field that holds it. The call becomes a slice in a
temporary of the statement:

    BYTES(s)     {PTR(s), LEN(s) * SIZE(T)}             s: []T
    BYTES(v)     {ADR(v), SIZE(T)}                      v: T, anything else

A slice's two words are read as `PTR` and `LEN` read them, so one
reached through an address on the stack, or a call's two words, goes
to a temporary first. `ADR(v)` is `address`, which puts a variable kept
in a register in memory. The slice keeps `x`'s `frame`, so `notOfFrame`
refuses `return BYTES(h)` of a local `h`, a field or an element of one
too, as it refuses a slice of one.

`ROL(x, n)` and `ROR(x, n)` (report 2026-10.35) are Item's `rotand`,
which refuses an `x` not of an unsigned type, an untyped constant with
help that says to give it one, and loads `x` before `n` is read, as
`op1` loads an operator's left; and `rotate`, which folds two constants,
right by k as left by the width less k, or has `Gen.rotate` make `rol`
or `ror`.

`MIN(T)` and `MAX(T)` (report 2026-10.36) are Item's `limit`, which
refuses a `T` not an integer type and makes the constant: as many ones
as `T` has bits, shifted right once more if `T` is signed, is `MAX`,
and minus that less 1 is a signed `MIN`. They are untyped constants
but for `MAX(U64)` and `MAX(UINT)`, which are above `high(I64)`, where
an untyped constant ends, and keep their type, as a hexadecimal number
above it is a `U64`.

`CLZ(x)`, `CTZ(x)` and `POPCOUNT(x)` (report 2026-10.36) are Item's
`countBits`, which refuses an `x` not of an unsigned type, or a set for
`POPCOUNT`, and an untyped constant with help that says to give it a
type, as `rotand` does; folds a constant by counting its bits one by one
(`countOf`); or has `Gen.countZeros` or `Gen.popCount` count them. The
result is an `INT`.

`ABS(x)` (report 2026-10.36) is Item's `absolute`, which refuses an `x`
not an integer or a real; folds a constant, as `neg` does, a real's by
clearing the top bit of the `F64` it is held as and the smallest
untyped constant an error, as its negation is beyond the `I64`s; or,
for a signed integer or a real, has `Gen.abs` make it. The result is
of `x`'s type, a built-in's, not an operator's, and widens.

Two mismatches in `coerce` that people meet on the way to it, a slice
where its element's pointer is wanted and a pointer where a slice is,
come with help that says what to write (`mismatchHelp`).

**Register variables.** One pass can't know whether a variable's
address will be taken before its code is made, so `chooseRegs` reads
the body ahead, as `instancesFor` does, and counts each variable's
uses: 1 for each, 4 in a loop, 16 in two, at most 64 (loops nested three
deep or more); one `ADR` takes is out. The
busiest used at least three times get the five registers (`o^.reg`),
a slice two (`o^.reg2` too), its count halved for each, and the
busiest reals the four of `Gen.XVarRegs`, each with a slot as well
(`placeLocals`, `Gen.xHome`). An
address wanted after all, by a `var` parameter, say, comes to
`Item.address`, which puts the variable back in memory and
sets `Item.demoted`: `body` then throws the procedure's code away
(`Gen.markCode`, `Gen.redo`), places the locals again, and compiles its
statements again. So it does when Gen wanted a parameter's `rdi` or
`rsi` (`Gen.lost`), the parameter moved to a free register or memory
(`unkeep`). Its notes for
the trap report are made after, by `varKind`, which marks a variable
in a register with the register's number.

## Link.raz: tree shaking and layout

`markLive` starts from the entry chunk and follows fixups, marking each
chunk it reaches, through the data fixups of constants too; nothing
else goes into the executable. `linkAll`
places the live chunks section by section (`place`), each at its
alignment, then copies their bytes into the images of text and rodata,
patching every fixup with the distance from the end of its field to its
target, and every data fixup with its target's address.

The file is loaded at `base`, 400000H unless `raz -base` says another
(`setBase`), as a kernel wants: Limine one in the top 2 GB. Code reaches
its data by `rip`, wherever it lies, but `X64.memAbs` holds an address
in 32 bits that the machine extends by their sign, and the places keep
each procedure's start and stop in 32 bits: so `linkAll` refuses an
image not wholly in the low or the top 2 GB, where both hold, checked by
its size so that no sum overflows. `Rt.procAt` compares the low 32 bits
of an address with them, the same order in either.

Between placing text and placing rodata, `makePlaces` writes the
places, a rodata chunk: for the trap report, each live procedure's
address range and name, and its variables, which `Parse.body`
notes with `Chunk.noteVar`: each one's name, its place in the frame and how
`Rt` shows it (`varKind`); then the line table (`makeLines`), DWARF
4's line program, which gdb reads as `.debug_line`: one sequence of
rows for each procedure, a row for each line note in live code, its
address, file, line and column. A row that moves the address and the
line a little is a byte, one of DWARF's special opcodes. `Rt` reads
the places, through `Rt.places`, which the entry point sets, and runs
the line table (`row`) to say where a failed check or a signal was:
the row with the highest address up to the one it has. Its signal
handlers, set in its body, run on a stack of their own, so that they
can tell a stack overflow, and leave by returning to the faulting
instruction with the handler reset, so that the signal ends the
program.

Then `Rt` follows the chain of frames, each `rbp` pointing at its
caller's, and says each call under way and its variables (`calls`);
`Rt.trace` does the same on demand. A thread's first frame has `rbp`
zero, which ends the chain. With `RAZ_PROFILE` set, `Rt`'s body has the
kernel send SIGPROF every millisecond of the program's time
(`setitimer`); `onProf` notes the address it interrupted and the
calls under way, up the chain of frames while it stays in the program's
own code, and `exit` has `profile` say which procedures and places
those fell in, by the same tables: each procedure's samples in its own
code, and its total, counting once each sample it was on the chain of.
The entry point gives Rt what the program has (`Gen.Link`): the places,
`calls`, which tells the calls under way, `place`, which says where an
address is, and the profiler's start. What it isn't given, nothing
reaches, so the linker leaves it out: `raz -noprofile` gives no
profiler, and `raz -s` none of them, whose failures say only their
address (and `Elf.raz` writes no symbols or line numbers). Hello is 28
KB, 21 KB without the profiler, and 7 KB stripped.

The layout is chosen so the file can be mapped as it lies, with no
padding: text just after the headers, then rodata, then the dynamic
loader's table (in a program that uses C), each loaded a page further
from its place in the file than the one before, so that no two
segments, with their different permissions, share a page. bss follows
the loader's table, or begins a page of its own.

## Elf.raz: the executable

`writeElf` writes the ELF header, the program headers, the text and
rodata images, and then what isn't loaded: section headers, a symbol
table with every live procedure and variable by `Module.name`, and
the compile unit that names the line table. The line table is in the
places, in rodata; `.debug_line`'s header points there.

A program that uses C is linked dynamically, in the least way the
loader accepts: an interpreter header naming the loader; a dynamic
section naming the libraries; and, for each C symbol the program uses,
a symbol and a `GLOB_DAT` relocation that has the loader write the
symbol's address into the quadword `Chunk.externChunk` made. Code calls C
through that quadword. There is no PLT and no lazy binding. The
loader and the first library are glibc's,
`/lib64/ld-linux-x86-64.so.2` and `libc.so.6`, or musl's,
`/lib/ld-musl-x86_64.so.1` and `libc.so`, which musl's loader, being
the library itself, takes to mean itself (`Elf.setMusl`). `-libc`
chooses; left out, `Host.cLibrary` does: musl where the machine has
its loader and not glibc's, as Alpine does. A symbol that isn't live
gets no relocation, so a program runs over a C library that lacks a
procedure it declares but never reaches. `sizeTables` and `putTables` lay these out in the room `Link.raz` left
at the end of rodata.

Line numbers are DWARF 4: the line table `makeLines` made from the
notes `Chunk.noteLine` made, and the single compile unit gdb needs to find
it, which `putDebug` writes. There are no types or variables in it;
gdb can stop at a line and show where it is, not print a variable.

## Host.raz: the system running the compiler

The host is the system running raz; the target is the system its
program will run on. Everything the compiler asks of its host that the
library doesn't give is in `Host.raz`, five procedures, each a real
difference between hosts. Nothing else in `src/` makes a system call,
reads `argv`, opens `/proc` or sets a file's mode; it reads, writes and
lists files, the environment and the working directory through the
library (`Sys`, `Files`), and `Files.argCount` and `Files.arg` give it
its command line.

- `libraryDir`: the directory of the standard library when `-lib`
  doesn't name one. Linux's is the `lib` beside raz, found by
  `/proc/self/exe` so that a link to raz works, or, with no `/proc`,
  beside argument 0.
- `cLibrary`: `CLib = (none, glibc, musl)`, the C library a program that
  uses C is linked against when `-libc` doesn't say. `none` says the
  host can't make such a program, and `Raz` refuses one when it finds
  the program uses C. Linux's is glibc, or musl where only its loader
  is there.
- `writeExecutable`: the bytes `Elf` made, written as an executable.
  Linux's writes the file and sets mode 755. It returns false on any
  failure, which `Elf` reports.
- `prepareRun`: the path `raz run` writes to, or an error, which is the
  refusal of a host that can't run a program. Linux's is a memfd,
  `/proc/self/fd/N`, kept open until `execute`.
- `execute`: replaces the compiler with the program at that path, whose
  arguments are the compiler's from number `first` on (so its argument 0
  is `Main.raz`), and the environment. It returns only on failure.

**Building for another host.** Stage the sources: copy `src/` to a
directory, put that host's `Host.raz` there in place of raz's, and
build `Raz.raz` from the copy with that host's library. This is the one
way; raz knows no host but Linux. A module in the main file's
directory is found first, so `-I` alone can't replace `Host.raz`, which
is right: a module is never replaced silently. The new file keeps every
export, `CLib` too, and opens with what it is, as raz's does.
`test/host/Host.raz` is such a file (its library from the environment,
no run, no C), and `test/compiler-host.sh` builds the compiler with it
and checks the four differences. The host changes nothing of the target:
a program for another system still needs that system's `Sys` and `Rt`,
and for a kernel the options `-bare`, `-s` and `-base`.

## Raz.raz: the command line

`Raz.raz` parses the arguments, calls `Parse.compileMain`, and works out what
the program uses: `use` marks the modules imported from the main module
and `Rt`; `usesC` decides whether the program is dynamic, refusing one
that both uses C and has a module saying `link static`. In a program
that uses C, it gives the entry point the C symbols the library needs,
each with the variable it goes in, found by name (`addCLink`): `exit`
for `Rt.cExit`, and, if the program has `Thread`, `pthread_create` and
`pthread_join` for `Thread.cCreate` and `Thread.cJoin`. Then it has
gen's `entryPoint` write the entry point, and `Link.markLive` mark what it
reaches. The program is `proc main*: INT`; `Host` says where the library is and
which C library to use by default (below), and the version it prints is
the module `Version`, which the build makes from `git describe`. On a target
without reals (`HasReals`, a constant of `Parse`; x86-64 has
them), a live chunk that computes with one is an error at the first
place it does: `Item.usesReals` notes it, from `Item.value` and a
real literal, on the chunk of the procedure being compiled. A real
moved whole, as a record's bytes are, isn't noted. A static program starts at `_start` itself. A dynamic
one starts at a `_start` that calls `__libc_start_main` the way C's own
start-up does, which sets C up and calls back a `main` that runs the
module bodies and the program's `main`.

`raz -bare` makes a program for the bare machine, a kernel, with no
Linux under it: its `_start` reads no `argc` and `argv`, which only
Linux leaves on the stack, and calls no body of `Rt`, whose
`rt_sigaction` and `sigaltstack` would fault there (`EFER.SCE` is
clear) and, with no IDT yet, reset the machine. Nor is `Rt` given the
profiler, which its body would start. It is still given the places, by
stores alone, if its `Rt` declares them (below), so a failed check says where it was; but `Rt.fail` and
`Rt.exit` end in system calls, which the kernel catches or replaces. A
program that uses C is refused.

`raz -S` lists the code (`X64.list`) instead of writing
it. `raz run` writes the executable to the path `Host.prepareRun` gives
and has `Host.execute` run it in raz's own place, handing it the rest
of raz's arguments. On Linux the path is a memfd, a file only in
memory, so nothing is left on disk, and the program's status is the
command's. `prepareRun` is called as soon as the command line is read,
before any source, so a host that can't run refuses there. The
arguments are read through `Files.argCount` and `Files.arg`.

Before compiling, `userLibraries` reads `RAZ_PATH` with `Sys.envAt`,
which distinguishes an unset variable from an explicitly empty one.
Unset means `$HOME/.raz/lib` if `HOME` is nonempty; set means a
colon-separated list, with empty entries ignored. `Parse.setUserDirs`
keeps its slices in `userDirs`, separate from the 16 `-I` directories. `searchDir`
puts them between those and the standard library, for both finding
modules and checking duplicate names. No subdirectories are searched.

`-lib dir` makes `dir` the library: `Raz.raz` reads it with the other
options, stops with "-lib dir: no such directory" if `Sys.access` can't
reach it, and gives it to `Parse.setLibDir` in place of
`Host.libraryDir()`. It changes nothing else: `searchDir` still puts
the library last, after `-I` and `RAZ_PATH`, and the duplicate check
(a symbolic link to one of the two files chooses it) is as before.

## A program with its own Rt

A hosted program uses `lib/Rt.raz`. A freestanding one, a kernel's
(`raz -bare`), has to bring its own, and this says what the compiler
asks of it and what a program's start may count on. Where this and the
code disagree, the code (`Gen.entryPoint`, `Raz.raz`) is right.

**Giving a program its own `Rt`.** A program has one module of each
name, and the library is `lib/` beside the compiler, so an `Rt.raz`
beside the main file meets `lib/Rt.raz` and is refused. `raz -lib DIR`
makes `DIR` the library instead: the program's own `Rt` and `Sys`, and
symbolic links to whichever of raz's modules it takes (a link chooses a
module, as always). The library is all of what is in `DIR`, and nothing
of raz's unless it is linked there. `test/own` does it: `check.sh`
builds `test/own/Own.raz` and `OwnFail.raz` with `-lib test/own/lib`,
whose `Rt.raz` is the whole library, under `-bare` (and `test/err/RtPair`
gives an `Rt` with half a pair).

**What `Rt` must declare.** `Raz.raz` finds each name in `Rt`'s scope
(`objIn`) and stops with "Rt has no X" where one of the first two, or `cExit`, is missing; the rest are optional:

| Name | What | Needed |
|---|---|---|
| `proc exit*(status: INT)` | Ends the program; never returns, so the compiler puts `ud2` after its call. | always |
| `proc fail*(what, a, b, len: INT; at: UINT; name: ^U8; rdi, rsi: UINT)` | A failed check; never returns. | always |
| variable `places` | The compiler stores the address of the places table in it, for `Rt` to say where a check failed. | if declared |
| `proc calls` and variable `teller` | `teller` is given the address of `calls`, which says the calls under way. | if both are declared, not under `-s` |
| `proc place*` and variable `placer` | `placer` is given the address of `place`, which says where an address in the code comes from. | if both are declared, not under `-s` |
| `proc startProfile*` and variable `profiler` | `profiler` is given `startProfile`, which `Rt`'s body calls when `RAZ_PROFILE` is set. | if both are declared, not under `-s`, `-noprofile` or `-bare` |
| variable `cExit: proc(status: I32)` | Given C's `exit`. | only in a program that uses C, which `-bare` refuses |

Each variable is 8 bytes, for an address stored with `lea` and a store
at the entry. The places are optional, each linked only when `Rt`
declares it (`giveRtPlaces`): `places` alone; `calls` with `teller`; `place`
with `placer`; `startProfile` with `profiler`. A pair is both or neither:
one of them alone stops the compiler with "Rt has calls but no teller",
naming the other. `-s` leaves all of them out, and the ELF's symbols and
line numbers with them. Without `-s`, an `Rt` that declares none still
has its symbols in the ELF (what a debugger reads), but no line table, which
lives in the places table. A failed check in such a program is told by
its address: `fail` is given `at`, an address inside the code, and it is
for `Rt` to print it, or look it up in the symbols. A hosted program's
`Rt` is raz's, which declares them all, so its output is as before.

**`fail`'s kinds.** The compiler's code calls `Rt.fail` through a stub,
one for each kind it uses, that makes the call from where the check
was (the parser gives a `fail` declared in a module called `Rt` the
chunk `Gen.rtFail`; the stubs are `Rt.check0` to `Rt.check7`). `what`
says why. These are the numbers `lib/Rt.raz` gives; an `Rt` that wants
names for them writes constants:

    const
        Index = 0;          (* index a, of something of len elements *)
        Slice = 1;          (* slice a..b, of something of len elements *)
        Enum = 2;           (* a is no position of the enumeration called name *)
        BackwardSlice = 3;  (* slice a..b of a pointer, which runs backwards *)
        NilPointer = 4;     (* a nil pointer, reached more than NilPage bytes in *)
        DivisionFault = 5;  (* not raised by the code: Rt's signal handler tells it *)
        StackOverflow = 6;  (* nor this *)
        View = 7;           (* a view at index a runs past len *)

x86-64 code raises 0 to 4 and 7. Kinds 5 and 6 are what the machine
catches itself, which `lib/Rt.raz`'s signal handlers tell with the same
procedure; a kernel's fault handlers may too. The arguments `what, a,
b, len, at, name` come in `rdi, rsi, rdx, rcx, r8, r9`, as System V
gives the first six integers; `rdi` and `rsi` as the failing code had
them (a parameter may live there; `Rt` shows them in the trap report)
go on the stack, the seventh and eighth. `at` is an address inside the
call, one byte before the return address, so that `Rt` finds the
failing line. `name` is a zero-ended string, the enumeration's, for
`Enum`, else unset. `rsp` is a multiple of 16 at the call. The stub puts
`ud2` after it, so `fail` must end the program or halt the machine.
That is the whole panic hook: a kernel's `fail` prints and halts.

**What a program's start may count on.** The entry point, `_start`,
does this and no more:

- Hosted (not `-bare`, no C): reads `argc` from `[rsp]` and `argv` from
  `rsp + 8` into the program's `argc` and `argv`, which `ARGC()` and
  `SYSTEM.ARGV()` read. It aligns nothing: Linux enters a program
  with `rsp` a multiple of 16, the compiler's calls count on it, and
  `rbp` is left as it is (Linux gives 0).
- Under `-bare`: reads nothing from the stack and aligns nothing, so
  `ARGC()` is 0. The loader or boot stub enters it with `rsp` a
  multiple of 16, the bss zeroed (the compiler's variables count on
  it), the direction flag clear, and `rbp` 0, where a trace of frames
  ends.
- Both then store into `Rt`'s variables the addresses they are to hold
  (the table above); call the body of every used module in the order
  the modules were finished (a module after those it imports, `Rt`
  early), except `Rt`'s own under `-bare`, whose body sets the signal
  handlers by system calls the bare machine hasn't; then `main`, if the
  program has one.
- `main` may return. `Rt.exit` is then called with its result, or 0 for
  `proc main*` or when there is no `main`.

Under `-bare`, what `Rt`'s body does (handlers, tables, a first stack)
a kernel does in a module body of its own, which runs before `main`.

**What the compiler's code does to the machine.** A kernel that
interrupts raz code, and runs raz code from the handler, needs these
facts; each was read in the source, where it says.

- *Registers.* The code follows System V. It uses `rax`, `rcx`, `rdx`,
  `rsi`, `rdi` and `r8` to `r11` freely (`r8` to `r11` also hold the
  value stack, `Gen.Regs`; `r10` and `r11` are scratch in a prologue
  and a call through a procedure value); `rbp` is the frame pointer;
  `rbx` and `r12` to `r15` hold a procedure's busiest variables
  (`Gen.VarRegs`) and are saved in its frame and restored on return,
  so they live through calls. All of `xmm0` to `xmm15` may change: the
  value stack's reals are in `xmm8` to `xmm11`, the variables' in
  `xmm12` to `xmm15` (and `xmm4` to `xmm7` in a procedure that calls
  nothing), `xmm8` is a scratch of the prologue, `xmm0` to `xmm7` carry
  arguments and results; none is kept through a call, so a variable in
  one is loaded again from its slot after it (`Gen.call`). The flags
  change at will. The code uses no x87 register, no AVX, and never
  writes `MXCSR`, so it counts on the default (round to nearest, all
  exceptions masked). A 16 byte move of memory is `movdqu`, never an
  aligned form, so nothing in it needs an aligned address; `movaps`
  appears only between registers. `syscall` (`SYSTEM.SYSCALL`)
  changes `rcx` and `r11` as the machine does.
- *The stack.* `rsp` is a multiple of 16 at every call, as System V
  asks: a procedure's frame is a multiple of 16 (`Gen.endProc`, at
  least 16) and a call pushes a quadword of padding where an odd
  number are pushed (`Gen.call`). A procedure begins `push rbp; mov
  rbp, rsp; sub rsp, frame` and ends `leave; ret`: every local and
  temporary is at a negative offset from `rbp` inside that frame, so
  above `rsp`. **The code never writes below `rsp`**, no red zone:
  where it looked, `rsp`-relative operands are in only two places,
  `[rsp]` and `[rsp + 8]` read by the entry point and by the fail
  stubs (`Gen.entryPoint`, all `X.mem(RSP, ...)` in `Gen.raz`), and
  `X64.raz` and the assembler address only through the operands
  `Gen.raz` gives them. Every other use of the stack is a `push` or
  a `sub rsp`, which move `rsp` first, and a procedure with no calls
  still makes its frame. An interrupt, then, needs no stack of its own
  (IST) for that reason; it still needs room above the frame for its
  own pushes, as any code does.
- *The direction flag.* The code never sets it: neither `std` nor `cld`
  is emitted anywhere. `rep movsb` and `rep stos` (`X64.repMovsb`,
  `repStos`: `COPY`, `FILL`, a record's copy, zeroing) go upwards, and
  a copy that must go downward is a loop of moves
  (`Gen.copyDown`), since `rep movsb` with the flag set is slow. So it
  must be clear whenever raz code runs, at entry and at every call,
  as System V asks; an interrupt stub that uses `std` must clear it
  before it calls a procedure.

The recipe for an interrupt's entry, and its test, follow.

## What the compiler asks of Sys, Rt and Files

What `src/` takes from `lib/`, for a host that has to supply it
(`Host`, and a program that brings its own library): every qualified
name, in code, of a library module. Nothing else of `lib/` is used by
`src/` itself; the library modules listed import others in turn
(`Heap`, `Mem`, `Out`, `Files` and the rest call `Sys` and `Rt`), and a
replacement for one has to give what the others ask of it. `Rt` is
also found by name for `fail`, `exit` and the places, as the previous
section says, and `NEW(p, a)` needs `a` to be a `^Mem.Allocator` and
calls its `alloc` field, the one library type the compiler knows by
name. Besides the library, only `Host` reaches the system: Linux's makes
`memfd_create` and `execve` itself for `raz run`, and reads
`SYSTEM.ARGV` for the program's arguments and environment; another
host's `Host` replaces all of it.

`test/asks.sh` keeps this list true: it fails when `src/` uses a
library name that is not a row here, or a row names one that `src/`
no longer uses. Each row is one name; a type is listed with its
fields as the code reads them.

`Sys`, the system:

| Name | What for |
|---|---|
| `Sys.access` | `Host.cLibrary`: whether the dynamic loaders of glibc and musl are installed |
| `Sys.chmod` | `Host.writeExecutable`: makes the program's file executable (mode 755) |
| `Sys.close` | `Scan` and `Parse`: closes a source or `RAZ-VERSION` file after reading |
| `Sys.closeDir`, `Sys.openDir`, `Sys.nextEntry`, `Sys.Dir` | `Parse`: the files of a directory, to find a module's other files for the one-module-of-each-name check |
| `Sys.env`, `Sys.envAt` | `Diag` (`NO_COLOR`) and `Raz.userLibraries` (`RAZ_PATH`, `HOME`; `envAt` tells unset from empty) |
| `Sys.errDenied`, `Sys.errNoEntry` | `Scan`: "permission denied" and "there is no such file" in a message |
| `Sys.info`, `Sys.Info` | `Scan` and `Parse`: whether a path is a file (`file`) and its length (`size`) |
| `Sys.isTerminal` | `Diag`: colour only when standard error is a terminal |
| `Sys.openRead`, `Sys.read` | `Scan`: reads a source file whole; `Parse`: the library's `RAZ-VERSION` |
| `Sys.readLink` | `Host.libraryDir`: `/proc/self/exe`, to find the library beside the compiler |
| `Sys.stderr`, `Sys.write` | `Diag`: its messages |
| `Sys.workDir` | `Diag`: shows a path relative to the working directory; `Elf`: the compilation directory of the line table |

`Rt`, the run time, besides `fail`, `exit` and the places (above):

| Name | What for |
|---|---|
| `Rt.exit` | `Diag`: ends the compiler, with status 1, after an error that stops it |

`Files`, whole files and the command line:

| Name | What for |
|---|---|
| `Files.arg` | `Raz` and `Host.libraryDir`: the command line's words |
| `Files.argCount` | `Raz` and `Host.execute`: how many words the command line has |
| `Files.write` | `Host.writeExecutable`: writes the executable |

The rest of the library, which `Diag`, `Sym`, `X64` and `Parse` use for
text and `Scan` for tables:

| Name | What for |
|---|---|
| `Buf.Buf`, `Buf.init`, `Buf.add`, `Buf.str`, `Buf.bytes`, `Buf.reset`, `Buf.done` | A growing buffer: `Diag`'s message and working directory, a type's name in `Sym`, an instruction's text in `X64`, a name made in `Parse` |
| `Fmt.write`, `Fmt.Arg`, `Fmt.str`, `Fmt.int`, `Fmt.char`, `Fmt.hex` | Formatting: `Diag.say`'s `{}` messages and a type's name |
| `Out.str`, `Out.ln`, `Out.flush` | Standard output: the `-S` listing, `-h` and `--version` |
| `Str.copy`, `Str.find`, `Str.hasPrefix`, `Str.hexVal` | A kept copy of a path (`Diag`), the one-character operators (`Scan`), a prefix of a path, a file name or a mnemonic (`Diag`, `Parse`, `X64`), and a hex digit (`Parse`) |
| `Heap.heap`, `Mem.alloc`, `Mem.free` | The allocator that `NEW`, `Buf.init` and `Str.copy` are given, and the blocks of `Scan`'s tables and `Diag`'s lists |

## This compiler's choices

What the report's appendix A leaves to an implementation, and what
this one does.

- **The target.** x86-64 Linux, `linux-x86_64`: `INT` is 64 bits, and
  there are reals. Every module of a program is compiled together, in
  one run, into a static ELF executable, or a dynamic one if the
  program uses C; no object files. The C library is glibc or musl,
  as `-libc` says, or by default glibc, and musl where only its
  loader is there.
- **Finding modules.** `raz Main.raz` looks for `X`, imported, in
  `Main.raz`'s directory, then in each `-I dir` in the order given
  (16 at most), then in `RAZ_PATH`'s directories (or `$HOME/.raz/lib`
  when unset), then in `lib` beside the `raz` executable, following
  a link to it (`make install` puts `raz` and `lib/` together in
  `PREFIX/lib/raz`). In each directory it tries `X.linux-x86_64.raz`,
  `X.linux.raz`, `X.x86_64.raz` and `X.raz`, in that order, and takes
  the first found (`moduleFile`, `Parse.raz`).
- **Errors.** Every error in a run is reported, up to 20 (`MaxErrors`,
  `Diag.raz`); then the compiler stops. Each comes with its file, line
  and column, the line of source with the offending part underlined
  and, where they help, notes pointing at other places, such as where
  a name is declared, and a suggestion, such as a name in reach spelled
  almost alike. After an error the compiler skips the statement or
  declaration it is in and goes on with the next; a name that isn't
  declared is reported once, and nothing that follows from it. An error
  in the text itself, such as a string left open, stops the compile,
  and so does a module with errors, after it. Two errors at the same
  place are told as one. Any error is status 1, and no executable is
  written.
- **Limits.** The least of the report's section 10, and what this
  compiler takes. Past its own, each stops with an error that names the
  limit (`tooMany`, `Parse.raz`); `test/err` has a program for each,
  and `conform/run/Limit*.raz` holds the report's least.

  | | report's least | this compiler |
  |---|---|---|
  | statements, expressions and types nested | 63 levels of statements, 63 of parentheses and calls | 256 together (`MaxNest`) |
  | values waiting in one expression | none given | 1,024 (`MaxStack`, `Gen.raz`) |
  | chain of imports | 15 modules | 63 (`MaxPending`) |
  | names declared together | 31 | 64 (`MaxNames`) |
  | variables assigned together | 15 | 16 |
  | elements in an array literal | 1,023 | 1,024 (`MaxElements`); a constant's has no limit of its own |
  | labels in one `match` | 255 | 1,024 (`MaxLabels`) |
  | deferred statements in force | 31 | 64 (`MaxDefers`) |
  | type arguments to a generic module | 8 | 8 |

  `nest` is the parser's own depth, so that a deeply nested program
  can't overflow the compiler's stack. It counts a statement, a factor
  (an operand, a parenthesis, a call, `not`) and a type; `guard` notes
  it and `restore` sets it back, as for the rest of the parser's
  state. A level costs at most about 3 KiB of stack (an operand, which
  goes through `factor`, `term`, `simpleExpr`, `relation`, `conjunct`
  and `expression`; a statement about 1.5 KiB, a type less), so 256
  levels use under 1 MiB of the main thread's 8. The stack of values
  is full before `MaxNest` when each level leaves several waiting, as a
  call of many arguments does (63 nested calls of 15 arguments fit);
  the compile then ends at once with the error, as the pops after it
  would have no place to go.
- **Warnings.** Of a declaration never used, or a variable only
  assigned (`warn`, `Parse.raz`): not of what is exported, a name that
  starts with `_`, an enumeration's names or a generic module's
  parameters. A procedure naming itself doesn't use it; a type named by
  a pointer in its own declaration does. Assigning a variable whole
  (`x :=`, `a, b :=`) doesn't read it; anything else does. Warnings
  come only for a module with no errors, and a generic module's only
  for its first instance. A procedure with results is warned of if
  it may reach its end without `return` (`ends`, `Parse.raz`): each
  way through its statements must end in a `return`, an `if` with an
  `else`, a `match`, a `while true` or a `repeat ... until false`
  with no `break`. So is a call standing on its own that drops a
  result (`doubts`, kept by `noteDrop` and told by `dropped`);
  `_ := f(x)` drops one on purpose. Two more are noted the same way,
  by `noteDoubt`, which keeps the words to say. A relation binds
  tighter than `and` and `or`, so `a # b and c` is `(a # b) and c`, as
  a Pascal reader doesn't expect: `relation` sets `bareBoolRel` when it
  read an `=` or `#` of two `BOOL`s (a parenthesised one is a factor,
  and the relation around it sets it false), and `conjunct` and
  `expression` ask `noteBoolRel` of each operand of an `and` or an
  `or`. And a string with `\0` before a digit, `"\01"`, is a zero byte
  and a `1`, not C's octal escape: `Scan.zeroDigit` looks for it in the
  text of the string, and `factor` notes it (`noteZeroDigit`); `\x00`
  keeps the two apart. A text the compiler reads twice, a `while`'s
  condition, is noted once. Warnings don't stop the compile;
  `raz -Werror`, an option of this compiler's, makes each an error.
- **Registers for variables.** Up to five of a procedure's single
  values, not reals, whose address is never taken, live in `rbx` and
  `r12` to `r15`, a slice taking two of them, and up to four reals in
  `xmm12` to `xmm15`, each written to its slot in the frame too; in a
  procedure that calls nothing, a parameter that arrives in `rdi` or
  `rsi` stays there. The trap report shows them as it shows the
  others, but for slices, which it never shows.
- **Several results** that are two words, and a slice, come back in
  rax and rdx, as from a code procedure; others through a hidden
  pointer to the caller's slots.
- **Reals.** A real constant is held as an F64. An `F32` in a register
  is its low 32 bits; the upper ones are left as they fall.
- **How a failure is caught.** A division by zero, a stack overflow
  (the guard page under the stack), a call to `nil` and a load or
  store within 4 KB of address 0 are caught by the machine, as
  signals; a field of a `nil` pointer further on is tested for in the
  code. The smallest value of a signed type divided by -1 faults as the
  machine does for 64 bits; for a narrower type the code makes it
  fault.
- **Run-time failures.** A failed check says on standard error what
  failed and with what values, at the place of the offending
  expression, then the calls under way and their variables, and ends
  the program by `Rt.exit` with status 2; `Rt.stop` says its message
  and ends it the same way. A signal
  is told at the place of the statement it stopped in, or of the
  procedure for a stack overflow in its prologue, and then `Rt.exit`
  ends the program with status 2, after the procedures registered with
  `Rt.atExit`, as for a failed check. A fault inside a section that holds the lock of `Out` or `Heap` (a stack overflow in `Out`, say) would leave `atExit`'s flush waiting for it: the program hangs instead of ending. This is rare, and a failed check has the same exposure. The handlers run on a stack
  of their own: `Rt`'s for the main thread, one in each `Thread`
  thread's mapping, whether clone or C made the thread. Threads a
  program makes with C's `pthread_create` itself have none, so a stack
  overflow in one ends the program by the signal with no message.
- **Locks.** `Heap` and `Out` lock with `Lock`, a spinlock that yields,
  since they serve C's threads and `Thread`'s alike; `Thread.Mutex` is
  a futex.
- **C.** A program uses C if a module it uses has an `extern` or a
  `link` of a library. C's symbols are reached through quadwords the
  loader fills in (GLOB_DAT), with no PLT; the executable exports
  nothing. Its entry point stores C's `exit` in `Rt.cExit`, and, if
  the program has `Thread`, `pthread_create` and `pthread_join` in
  `Thread.cCreate` and `Thread.cJoin`, before any module body runs:
  `Thread` then makes C's threads, which C's library knows of, and
  uses no C itself.
- **Frames.** A deferred statement's slots stay reserved for the rest
  of its procedure. A generic instance first used in a procedure, or in
  a module's body, is made before that code begins (`instancesFor`).
- **Heap.** Blocks of nine sizes, from 16 to 4096 bytes with their
  header, each with a list of the free ones; a bigger block gets pages
  of its own.
- **The assembly language.** Intel's syntax as NASM writes it: the
  destination first; registers by name (`rax`, `eax`, `al`, `xmm0`);
  memory as `[base + index * scale + disp]`, with `byte`, `word`,
  `dword` or `qword` before it where no register says the size; `lock`
  before an instruction.
- **The executable** holds only what can be reached from `main` and the
  module bodies: unused procedures, variables and strings are left
  out. It carries DWARF line numbers and the names of
  procedures for gdb, and the places (`Rt.places`), which hold the
  line table, DWARF's, that gdb reads and `Rt` runs.

## Where to start changing it

- **A built-in procedure:** an entry in `Sym.raz`'s universe (`enter`),
  a case in `builtin` in `Parse.raz`, and the code, in `Gen.raz` if it is an
  instruction, or of calls to gen right there.
- **An instruction:** a routine in `X64.raz` built on `opM` or `opR`,
  its encoding checked against `objdump -d` once, and a program in
  `conform/` or `test/` that uses it.
- **A machine:** a new `Gen.raz`, answering the same calls, and an
  encoder and assembler for it in place of `X64.raz`.
- **A statement:** a reserved word in `Scan.raz` (in `Sym` and `words`,
  in the same order), a case in `oneStatement`, and a routine beside the
  others.
- **A check that fails:** `check` in `Gen.raz`, and the message in
  `lib/Rt.raz`'s `fail`; a reason a signal gives, `onSignal` there.

The compiler is in raz. `make raz` builds it with the release `BOOT`
names, by its tag and its tarball's SHA-256: `src/boot.sh` fetches the
tarball into `build/boot/`, checks the sum, and puts its `raz` there
with this `lib/` beside it, so that `src/` is built against today's
library. So `src/`, and the modules of `lib/` it imports, use only what
that release knows: v0.23.0 has `const` parameters, views, the
widening, `PTR`, report 2026-10.36's built-ins (`MIN`, `MAX`, `ABS`,
`CLZ`, `CTZ`, `POPCOUNT`, `INT(b)`, `OFFSET`, `BYTES`, `FILL`, ...), and
10.37's `[]const T`, `import SYSTEM` and atomics on a variable. `make fixpoint` has BOOT's compiler build
`src/`, that build it again, and that again, and checks that the last
two are the same file. `make prev-bench` compares this compiler's speed
with BOOT's on the same program, and fails if it is more than a tenth
slower. Each unit of `src/` was once tested against the seed's, while it
was ported; that test was dropped after v0.17.0, as the two had grown
apart, and the seed itself after v0.19.0. After any change: `make
check`, `make bench`, `make loc`.
