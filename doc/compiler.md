# Reading the raz compiler

The compiler is eleven files of Free Pascal, under 10,000 lines of code.
This guide walks through them in the order they are best read: from the
characters of a source file to the bytes of an executable. It assumes
you know the language from `doc/raz.md`, and enough x86-64 to read a
disassembly. The manual pages say the rest: `raz(1)` the command,
`raz-tutorial(7)` and `raz(7)` the language, and `raz-lib(3)` the
library, made from `lib/` by `tools/Doc.raz`.

| File | Lines | Code | What |
|---|---|---|---|
| `src/diag.pas` | 316 | 233 | Messages: positions, source excerpts, colour, counts |
| `src/scan.pas` | 886 | 747 | Symbols, literals, comments, positions |
| `src/sym.pas` | 646 | 528 | Types, objects, scopes, layout |
| `src/chunk.pas` | 318 | 246 | The compiled program: chunks, fixups, line notes |
| `src/x64.pas` | 1,146 | 951 | The instruction encoder, jumps within a procedure, the assembler |
| `src/gen.pas` | 2,010 | 1,462 | The stack machine, for x86-64: values, operations, checks, calls, frames |
| `src/item.pas` | 1,574 | 1,299 | Items: types, constants, variables, operators, conversions, calls |
| `src/parse.pas` | 3,078 | 2,689 | Declarations, statements, expressions, built-ins, recovery, warnings |
| `src/link.pas` | 334 | 258 | Tree shaking, layout, patching, the places |
| `src/elf.pas` | 373 | 294 | Static and dynamic ELF, symbol table, line numbers |
| `src/raz.pas` | 245 | 188 | The command line |

Every file opens with a comment that says what it is, what it depends
on and what it leaves out. Read those first; they are the map.

## The shape of it

There is one pass and no tree. The parser reads a construct and, in
the same breath, has the code generator emit its machine code. Nothing
is kept to be looked at again, except the declarations, which live in
the symbol table for as long as the compiler runs.

Three layers do it. `parse.pas` knows the language's syntax. `item.pas`
knows what the program means: each operand is an *item*, as in Wirth's
compilers, and the routines there check the items' types, fold
constants and work out where variables are. Neither knows the machine:
they drive a stack machine, `gen.pas`, by its calls (push a value,
add the two on top, store the top in a variable, jump if it is false),
each with the kind of the value (a word, a 64-bit integer, an `F32`,
an `F64`). `gen.pas` is the only one that knows x86-64; a port to
another machine is a new `gen.pas`, with an encoder of its own in place
of `x64.pas`.

On x86-64 the stack lives in registers, as in Wirth's compilers
(Niklaus Wirth's Pascal and Oberon compilers): the value at depth `d`,
depth 0 being the bottom, is in register `d mod 4`, of `r8` to `r11`.
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
Nothing but their own assignments can change them.

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

1. `raz.pas` reads the command line and calls `CompileMain`
   (`parse.pas`).
2. `CompileMain` imports `Rt` first, since every program needs it, and
   then compiles `Hello.raz` with `CompileFile`.
3. `CompileFile` opens the file in the scanner and parses the module.
   At `import Out;` it calls `ImportModule`, which finds `Out.raz` and
   compiles it there and then, saving and restoring the scanner and the
   scopes around it. So modules are finished in an order where each
   comes after those it imports; that is the order their bodies run.
4. Each procedure becomes a chunk of code; `Out.str("hello, world\n")`
   becomes a string chunk, a call, and a fixup to `Out.str`'s chunk.
5. Back in `raz.pas`, `Use` marks the modules the program uses; the
   entry point, `_start`, is written by `gen.pas`'s `EntryPoint` as one
   more chunk: save `argc` and `argv` and the address of the places
   (below), call every used module's body, call `main`, call `Rt.exit`.
6. `MarkLive` (`link.pas`) marks what `_start` reaches; then
   `WriteElf` (`elf.pas`) has `link.pas` place it and patch it, and
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
push   rbp                            ; EnterBody: the frame
mov    rbp,rsp
sub    rsp,0x10                       ; its size, patched in by EndProc
mov    r9,rsi                         ; b, at depth 1; a, at depth 0, and
shl    r9,0x1                         ;   the 2 are only noted; times 2
mov    r8,rdi                         ;   is a shift; a is loaded for +
add    r8,r9
mov    rax,r8                         ; return: the result
leave                                 ; no jump to here, as it is next
ret
```

`scale` calls nothing, so its parameters stay in `rdi` and `rsi`,
where they arrive (`KeepArrived`): they are register variables that
cost nothing to keep. Every line of it can be traced to a routine in
`gen.pas`: the moves are `Loaded`'s, the shift and the add `Op`'s, the
result `ReturnJump`'s, and the frame is `EnterBody`'s and `EndProc`'s.
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
   memory are zeroed (`PlaceLocals`, `UseRegs`, `EnterBody`).
2. **The hidden pointer**: the two results went through `rcx` to the
   caller's memory. Two words come back in `rax` and `rdx` now
   (`InTwoRegs`), so `return 0, 0` is two instructions; and the caller
   pops them straight into its variables (`mWords`, `MultiAssign`).
3. **`cmp r8, 0`** is `test r8, r8`, the same flags in fewer bytes
   (`CmpI`).
4. **Copies through `rax`**: `s[0]`'s address is worked out in the
   register it is used from (`IndexSlice`), and a result is put in `rax`
   from where it is (`PopTo`).
5. **The `jmp 421` after `return`**, which nothing could reach: a branch
   of an `if` that ends gets no jump past the others (`IfStatement`).

What is left is worth knowing too. The slice's two words still go to
the frame, since only single values live in registers; `movzx` then
`movsxd` reads a byte and makes an `I32` of it in two steps where one
would do; and the four registers are saved and restored on every call,
though this path uses one of them. Each could go, at the cost of lines
a reader would have to follow.

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

   Its item is at `bReg`, and its `TAdr` names both registers (`hi`
   for the length's): `PushVar` reads either word (`RegAt`),
   `IndexSlice` and `Slice` compare with the length's and add the
   pointer's, a failed check takes the length from its register
   (`InRegister`), and `CopyTo` loads both. What wants a slice's
   memory, a comparison or `COPY`, has its words stored in a
   temporary first (`CopyToTemp`). rat 5% faster, the heap sort 5%,
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
   `SYSCALL` or `COPY`, as `ChooseRegs` sees reading ahead, the
   parameters that arrive in `rdi` and `rsi` stay there, which only a
   call or a copy needs: nothing is saved or moved, and `s[i]` is read
   through `rdi` itself (`KeepArrived`). Where gen needs them after
   all, to copy a record or compare two slices, it sets `lost`, and
   `Body` compiles the procedure again with the parameters in memory,
   as for a variable demoted. The trap report shows a parameter kept
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
   operand `[rdi + r12 * 8]` (`lIdx`, made by `IndexSlice`), and a
   variable in memory, or at an address noted, as the operand that
   reads it (`lMem`, made by `PushVar`): each is read where it is
   used, and `Op`, `Compare` and `JumpCmp` take an 8-byte one as their
   right operand as it is (`TopInMem`):

   ```
   mov r8, rbx
   add r8, [rdi + r12 * 8]
   ```

   A value noted in memory must be read before anything can change
   it: before a call (`SpillBelow`) and an atomic built-in (`Atomic`),
   both through `ReadMems`. The heap sort 14% faster, the search 5%;
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
   `xor`, naming it nowhere else (`ChangesItself`, read ahead in the
   statement), has gen work the value out in the variable's own
   register (`inPlace`, `lInto`), and `ForStep` steps one so too:

   ```
   add r12, 1
   add rbx, [rdi + r12 * 8]
   ```

   That left the sum's loop four instructions, as FPC's are, and as
   slow as before, for it crossed a 64-byte line that the processor
   fetches decoded instructions in. The top of a `for` loop, which
   the code jumps to rather than runs into, now starts at a multiple
   of 32 bytes (`AlignLoop`, `Align` in x64), the no-ops before it
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

   One pass reads the condition before the body, so `WhileStatement`
   compiles it where it is written, for its messages, takes its code
   back (`Rewind`), and reads it again after the body (`SaveScan`,
   `RestoreScan`). A constant condition, as in `while true`, is no
   test. The heap sort 3% faster, rat 2%; the search lost 7%, all of
   it to where its loops fell: without the top aligned it lost
   nothing, and rat gained nothing either.

5. **One table of lines, not two.** Rt had a table of its own in the
   places, 16 bytes a line note, beside the DWARF line table that gdb
   read, which wasn't loaded. Now the DWARF table, its columns added,
   is in the places, loaded, and Rt runs it (`row`, in `Rt.raz`) where
   it looked through its own; `.debug_line`'s section header points
   at it in rodata. Hello is 7 KB smaller, 28 KB; rat 17%, 505 KB.

## diag.pas: messages

Every message the compiler prints is made here. A position, `TPos`, is
a file and a stretch of bytes in it; `Error`, `Warning` and `Note` show
it as `file:line:column`, then the line of source with the stretch
underlined, and `Help` adds a line of advice. Notes and help are shown
only with an error that was: not one at the place of the last, and
not one under `quiet`, which the parser sets when an error follows
from another (see parse.pas). The line and column are
worked out only when a message is printed (`Locate`, `Chars`), so
positions cost nothing while compiling. `AddFile` keeps every source
file the scanner opens, so a note can show a line of any of them.
`Finish` prints the count of errors and warnings and stops if there
were errors; `Fatal` is for errors with no place in the source.

## scan.pas: the scanner

The scanner turns bytes into symbols (`TSym`). The current symbol is in
`tok`, with its value in `ival` (integers and characters), `rval`
(reals), `id` (identifiers) or `sbuf` and `slen` (strings, already
decoded).

Read `Next` first: it skips white space and comments (`Comment`, which
counts nesting), then dispatches on the first character. `Number`
handles decimal, `0FFH`-style hexadecimal and reals; `LitChar` handles
one character of a literal, escapes included. `ReadReal` turns a real's
digits into the nearest `F64` exactly, as a fraction of two big
integers (`TBig`), since Free Pascal's `Val` can be one bit off.

Identifiers are *interned*: `Intern` puts each distinct name once in a
pool and hands back a small integer, so every later comparison of names
is a comparison of integers. The reserved words are interned first, in
the order of `TSym`, so a name's number tells at once whether it is a
reserved word.

Source is UTF-8, checked by `Utf8` wherever a byte above 127 appears:
in strings, characters and comments. Anywhere else it is an error.

`TokPos` is the position of the current symbol, `SpanFrom` the stretch
from a saved position to the end of the symbol before the current one,
and `MissingPos` the place to say a symbol is missing: just after the
symbol before, when the current one starts a new line. Errors go
through `Mark`, at the current symbol, `MarkAt`, at a position, or
`MarkHelp`, which adds a line of help; each reports the error
(`diag.Error`) and jumps to `recovery`, the parser's place to go on
from (see parse.pas), through `Fail`. An error with notes is reported
with `Error` and `Note`, then `Fail`. A message names what it found: `Found` describes
the current symbol and `SymText` spells an operator or reserved word,
so that the parser's `Expect` and `Expected` say `expected ";", found
"end"`. Errors in the text itself stop the
compiler (`MarkBytes`, `LexError`): past a string left open, the
symbols can't be trusted. A slip from another language, such as `!=`
for `#`, is reported by `Slip`, which reads on as if the right symbol
were written; not while the parser is `skipping` what it read once
before an error. `SaveScan` and `RestoreScan` keep
the scanner's state while an imported module is compiled.

## sym.pas: types, objects and scopes

Two records hold everything the compiler knows about a program.

`TType` is a type. Its `form` says what kind (`fInt`, `fPtr`, `fArray`,
`fRecord`, `fVariant`, `fProc`, and so on), and the other fields mean
what that form needs: `base` is what a pointer points at, an array or
slice holds, or a procedure returns; `fields` lists a record's fields,
a variant's cases, a procedure's parameters; `len` counts an array's
elements. `size` and `align` are worked out when the type is built, by
the C rules. `obj` is the declaration that named the type, if any.

`TObj` is anything a name can stand for: a constant, type, variable,
procedure, module, field, variant case or built-in (`cls`), and `pos`
is where its name is declared, for notes. Where it
lives is decided here too: a module variable's chunk, a local's frame
offset in `val`, a procedure's chunk.

Scopes are numbers. The universe is 0; each module, procedure, record
and match arm gets a new one from `NewScope`. All objects of all scopes
sit in one open-addressed hash table, keyed by scope and name: `Find`
looks in one scope, `Lookup` in each open scope from the innermost out.
A lookup costs the same however big a program grows, which matters at
a million lines a second. After an error, `Closest` looks through the
whole table for the name in reach spelled most like one not found
(`Distance`), for "did you mean".

`Same` and `Alike` decide whether two types are the same: one
declaration for named types, built alike otherwise. `Fingerprint`
hashes what a declaration exports, for the check that a module's files
for different targets agree. The universe, the basic types and built-in
procedures, is set up in the unit's `initialization`.

## chunk.pas: the compiled program

Code is written into one growing buffer, `code`, with `pc` its length;
strings and other constants go to `rodata`. A chunk (`TChunk`) records
its section, where its bytes start, how many, and the fixups it makes.
`BeginChunk` and `EndChunk` bracket a procedure; `SetData` and `SetBss`
make data chunks.

A *fixup* (`TFixup`) is a 32-bit field in the code that will hold the
distance to another chunk: a call's target, or a rip-relative address.
`AddFixup` records one; `link.pas` fills them in. A constant's
addresses are *data fixups*, `AddDataFixup`'s: 64-bit fields in
rodata that will hold a chunk's address itself, since the executable is
loaded where the linker placed it. `NoteLine` records
which line and column of the source the code from `pc` on belongs to,
for gdb and for the places. `ExternChunk` makes, once per C symbol,
the quadword the dynamic loader will fill with that symbol's address.
None of this depends on the machine.

## x64.pas: machine code

The encoder is `OpM` and `OpR`: a prefix, the REX byte, the opcode, the
ModRM and SIB bytes and the displacement, for a register and a memory
operand (`TMem`) or two registers. Everything else (`MovRR`, `Load`,
`Store`, `Alu`, `Sse`, ...) is a line or two that calls them with the
right opcode. Only the instructions the code generator uses are here.
`test/enctest.pas` emits one of each for `objdump` to check. `Here` is
the address of the code being written, as an operand.

The assembler, `Assemble`, reads a code procedure's instructions with
the scanner, Intel's syntax as NASM writes it, and encodes them with
`OpM` and `OpR`: `Operand` reads a register, a memory operand or a
constant (by the parser's `ConstExpr`, handed in), and a few tables
give the operations of a kind their opcodes (`Alus`, `Unaries`,
`Shifts`, `SseOps`, `Plain`). Labels are chains of jumps, as below.
`db` gives bytes it doesn't know. `RegNames` and `CondNames` are the
names of the registers and conditions.

The listing, `raz -S`: with `listing` set, each routine of the encoder
says, with `Say`, the instruction it is about to write, as the
assembler would read it; `List` prints the main module's live
procedures with each line of source (`LineText` in `diag.pas`) and the
instructions under it. Nothing is disassembled: the listing is what
the encoder meant.

Jumps within a procedure don't wait for the linker. A label not yet
placed is a chain of the jumps to it, each jump's 32-bit field holding
the position of the one before (`Jmp`, `Jcc`); `FixLink` walks the
chain and patches each once the label's position is known. This is the
trick from Wirth's compilers, and it means a label is one integer.
`DropJumpTo` takes back a `jmp` just made to a label about to be
placed after it, so a `return` that ends a procedure doesn't jump to
the next instruction; the line notes made after it move back with it
(`TakeBack`, in `chunk.pas`).

## gen.pas: the stack machine

This is the only unit that knows the machine. The calls it answers:

- values: `PushConst`, `PushAdr` (the address of a variable),
  `PushVar` (its value), `PushProc`, and `PopVar`, which stores the
  value on top; `Drop` and `Swap`;
- operations on the values on top: `Op`, `Compare`, `Neg`,
  `Complement`, `NotBool`, `Narrow` (to a narrow integer's width),
  the conversions between integers and reals, `CompareSeq` (of two
  slices), and copying: `CopyBlock`, `CopyTo`, `ZeroVar`, and
  `CopySlice` for `COPY`, a `rep movsb` that goes down when the
  destination is above the source;
- jumps: `Jump`, `JumpIf` (on a `BOOL`), `JumpCmp` (on two integers),
  `JumpOut` (`JumpCmp` from within an expression) and `CondValue` for
  `and` and `or`, `Fix` where the label is, and `JoinJumps`;
- checks: `CheckIndex`, `CheckEnum`, and `IndexSlice`, `Slice` and
  `SlicePtr`, which check as they make their address or slice;
- calls (`Call`), frames (`BeginProc`, `EnterBody`, `ReturnJump`,
  `EndProc`, the temporaries of `AllocTemp`), deferred statements
  (`DeferBegin`, `DeferEnd`, `RunDefer`), the built-ins that are
  instructions (`Atomic`, `SysCall`, `Fence`), and the program's entry
  point (`EntryPoint`).

A variable's place is a `TAdr`: relative to the frame (`bFrame`), to a
chunk (`bGlobal`), to an address on the stack (`bStack`), or to one
held in a frame slot (`bSlot`, as a `var` parameter's is); plus `off`.
`Place` turns it into an x64 memory operand, popping or loading the
address first, so that a variable is read or written with one
instruction.

The stack: `stack` notes where each value is, a constant (`lConst`), an
address not yet computed (`lAdr`, `AdrMem`'s operand), an element's
address not yet computed (`lIdx`, an operand `[base + index * size]`),
a variable's value not yet read (`lMem`, at an operand), a register
variable's own register, read in place (`lHeld`), the value's own
register (`lReg`) or a frame slot (`lFrame`); `owner` says which
value each register holds, `lIdx` and `lMem` holding theirs when it
is their index. The value at depth `d` belongs in
`Regs[d mod 4]`, `r8` to `r11`: `rax`, `rdx` and `rcx`, which division
and shifts need, and `rsi` and `rdi`, which copying needs, aren't among
them. `Claim` gives a value its register, and `Spill`s the lower one
that holds it, when an expression is deeper than the registers;
`Loaded` brings a value into its register, from its constant, address
or slot; `Place` uses a noted address as the operand itself, so that
`PopVar`, storing a constant, and `IncDec` are one instruction on
memory: `DEC(n)` is `sub qword [rbp - 8], 1`. `Top` is `Loaded` for the
value on top, and `Target` the register a new one is computed in.
`Drop` emits no code, and the dropped value's register still holds it
until the next push, which several routines rely on. Before a call every
value in a register is spilled (`SpillBelow`), since the call may change
them, and so are the values under a comparison that jumps out of an
expression (`JumpOut`), which both ways to its label must find in the
same place. `pushed` counts the quadwords on the machine's stack. A
call needs `rsp` a multiple of 16, so `Call` pads by one quadword when
`pushed` plus its stack arguments is odd; in a deferred statement
`pushed` starts at 1, for the return address. `Op` takes a
constant on the right as it is, after moving one on the left of `+`,
`*`, `&`, `|` or `xor` there, and a power of two on the right of `*`,
`div` or `mod` becomes shifts (`DivPow2`), since `idiv` is slow; an
element's size multiplies an index by a shift too (`MulI`), as a shift
takes one cycle and `imul` three.
Narrow integers are brought back to their width after each operation,
which is how `U8` arithmetic wraps; since they are computed in 64 bits,
a shift's count is cut to their width first, and `DivTrap` makes the
smallest value of one divided by -1 fault as an `I64`'s does.

Checks: `Check` jumps, when the check fails, to code at the end of the
procedure (`EndFails`), so that a check that holds is a jump not taken.
That code puts the values involved where `Rt.fail` wants them and
calls a stub for its kind of failure (`failStubs`, made by
`EntryPoint`), which says the kind and passes the address it was
called from, by which `Rt` finds the place: the failing code has the
place of the offending expression (`LineCol` in `scan.pas`). It leaves
`rdi` and `rsi` as they were, so that the stub can pass them on, for
the trap report to show a parameter kept in them. A check
costs a compare and a jump where it stands, and a dozen bytes out of
the way. Code is aligned to 32 bytes, the windows x86 fetches it in,
so that where a procedure's loops fall doesn't depend on what comes
before it.

What the machine catches, the code doesn't test for (report section
10, appendix A): on x86-64 Linux a division by zero raises SIGFPE, a
stack overflow meets the guard page under the stack, a call to `nil`
jumps to an address never mapped, and so does a load or store within
`NilPage` bytes of address 0. `Rt`'s handlers say where and why. What
is left is a field of a `nil` pointer past that page: an item reached
through `^` is `deref` until `NilTest` (`item.pas`) has it used, and
gen's `CheckNil` tests the pointer only if the use reaches past
`NilPage`. A port whose machine catches less tests for more, in its
own `gen.pas`: `Rt.fail` stops for a nil pointer, a division by zero
and a stack overflow as the signals would.

Calls: the arguments are computed left to right onto the stack, where
they wait for `Call`, as any values do: a constant, an address or a
variable in a register only noted, the rest in registers, or spilled
by a call in a later argument, so that it can't disturb them. `Call`
spills what is under them, moves each into the register System V
wants (`ValueTo`), `r8` and `r9` last since they may hold others, and
aligns the stack. A slice goes as its two words, in two registers or
both on the stack, as System V passes a struct of two integers, and
the procedure keeps them in its frame. A record
passed by value goes as the address of a copy. A result of two words,
a slice or two single values that aren't reals (`InTwoRegs`, in
`sym.pas`), comes back in rax and rdx, as System V returns a struct of
two integers: `return` leaves both on the stack for `ReturnJump`.
`Call` leaves two results on the stack, and stores a slice in a
temporary of the caller's. Any other record, or
several results, come back in memory the caller provides, through a
hidden pointer in `rdi` (`BehindPointer`, `ResultTo`, `CopyResult`). C
returns a struct of up to 16 bytes in `rax` and `rdx`; raz sends every
record through memory, and only a slice or two single values in
registers.

Frames: `BeginProc` gives the parameters their slots; `EnterBody`
writes the prologue, which zeroes the locals in memory (with a few
stores, or a loop for more; there are none to zero in `scale`) but not
the temporaries, since each is written before it is read; `EndProc` writes
the epilogue and patches the frame's size in. Within a statement,
scratch space comes from `AllocTemp` and is given back by
`ReleaseTemps`; `AllocPerm` reserves space for the whole procedure.

Register variables: the parser chooses them (`ChooseRegs`, below),
then gives the locals left in memory their slots (`PlaceLocals`), and
tells gen (`UseRegs`) the registers, as bits of `VarRegs`. A variable
in a register has no slot of its own. Gen saves the registers in slots
a quadword each, after the locals and not zeroed, as each is written
first. The
prologue saves them, zeroes them, and moves a parameter into its
register from the register or stack slot it arrived in; the epilogue
restores them. A slice may have two, its pointer's and its length's
(see "Better code again" above). A variable in one is an
item at `bReg`: `PushVar` notes it (`lHeld`) rather than copying it,
`Peek` reads it in place where the value is only read, so `i < n` is
`cmp rbx, r12`, and `PopVar` and `IncDecReg` write it. Rt finds the
values for the trap report from the saves: each procedure's record in
the places says which it saved, and where (`saveMask`, `saveAt`).

## item.pas: items

An operand is an *item* (`TItem`), as in Wirth's compilers. Its `mode`
says what it is now:

- `mConst`: a value known to the compiler, in `val`;
- `mVar`: a variable, at `base`, `chunk` and `off`, which `AdrOf`
  makes a `TAdr` for gen;
- `mStack`: a value on gen's stack;
- `mWords`: the two results of a call, as rax and rdx brought them, on
  gen's stack, the first under the second. `a, b := f(x)` brings the
  first to the top (`Swap`) and pops each into its variable, so that
  nothing goes through memory; `return f(x)` leaves them for
  `ReturnJump`; anything else makes them a temporary (`CopyToTemp`);
- `mCond`: a condition, as Wirth's compilers keep one: two integers on
  gen's stack, compared by `rel` once something wants the result, and
  the jumps of `and` and `or` that land where it is false (`fj`) or
  true (`tj`); `CondJump` makes it a jump, `Value` a `BOOL`;
- `mProc`, `mType`, `mStr`, and a few more the parser needs.

An item also carries `pos`, the stretch of source it came from, which
the parser sets as it reads an expression; an error about an item is
reported there (`MarkAt(x.pos, ...)`), and one about two operands
across both (`Join(x.pos, y.pos)`). `What` names an item for a
message: a constant without a type of its own as it is written
(`found 1.5`), anything else by its type.

Two routines move items towards the machine: `Value` pushes an item's
value, and `Address` a variable's address. Both leave the item saying
it is on the stack. An item nothing more is done with is given back to
`Discard`.

Expressions: `Op1` is called when the parser has seen an operator and
its left operand, `Op2` when it has the right one. `Op1` pushes the
left operand, unless it is a constant; for `and` and `or` it makes the
left one a condition (`MakeCond`) and jumps past the right one, which
`Op2` joins to it: `(a < b) and (c < d)` in an `if` is two compares
and two jumps, as `not` of a condition is the other comparison. `Op2` checks the types, folds constants
(`FoldInt`, `FoldReal`), and otherwise pushes the right operand and has
gen do the operation; a constant on the left goes on after the right,
and the two `Swap`. A set's operations are operations on its bits
(`SetOp`). `=` and `#` on arrays, slices and strings make a slice of
each side (`SeqSlice`) and have gen compare them right where the
comparison stands: no call. `+` on two string constants is `JoinStr`,
which makes one string of them, in a chunk of its own.

Variables: `Deref`, `Field`, `Index` and `Slice` turn an item for a
variable into an item for part of it, mostly by adding to `off`. An
item for another module's exported variable, or part of it, is `ro`:
it isn't a variable (`isVar`), and `NotReadOnly` says why where one is
wanted; what it points at is. An array or record constant is a
variable too, in read-only data: `AggregateConst` (`parse.pas`) reads
its literal, part by part in `ConstPart`, into the bytes of a chunk,
as a string constant's are; an address in it, of a string, an array
constant, a procedure or an `ERROR`, becomes a data fixup. `MakeItem` makes it
an `mVar` there that isn't `isVar`, so it is read, indexed, sliced and
passed, never changed. `Index` and `Slice` have gen make the bounds
checks, unless the module says `check off;` (`checks`, which
`CompileFile` sets for each module), and `Convert` the check of an
enumeration's position.

Assignment and conversion: `Coerce` makes a value fit the type it's
going to, or reports that it can't; it's where a string literal becomes
a slice, an array a slice, an untyped constant a typed one, and an
`INT` an `I64` (`Widens`). `CoerceExact` is for where the types must
be the same, as in a `for` loop, `INC` and several results. `Assign`
stores, or copies records and arrays. `Convert` is the written
conversion, `T(x)`.

Calls: `BeginCall`, then `PassArg` for each argument, then `EndCall`,
which has gen's `Call` make the call. Each argument is left on gen's
stack, a slice as its two words (`PushWords`). `return f(x);` passing
on f's several results, with `ReturnAll`, pushes them from the call's
temporary if they are two words, or else copies them to the place its
own hidden pointer names.

## parse.pas: the parser

A recursive descent parser, one routine for each rule of the grammar in
the report, calling `item.pas`, and for jumps `gen.pas`, as it goes.

Start with expressions, bottom up: `Factor`, `Term`, `SimpleExpr`,
`Relation`, `Conjunct` (the `and`s), `Expression` (the `or`s). Then `Designator`, which reads a name and what follows
it: `.field`, `^`, `[i]`, `[lo..hi]`, a call, a conversion. Each step
calls the matching routine in `item.pas` on the item it has. The
`want` parameter carries the type an expression must have, where it is
known, so that `[1, 2, 3]`, `{x: 1}` and `{red}` know what to build.

Then statements: `Statement` makes each one a recovery point (below)
and `OneStatement` dispatches; `IfStatement`,
`WhileStatement`, `ForStatement` and `MatchStatement` emit their jumps
with gen's labels. A branch of an `if` that ends, in `return` or
`break` (`ends`), gets no jump past the others; and `if c then break;
end` is one jump out of the loop where `c` holds (`ThenPart`,
`LoneBreak`, `CondJumpTrue`), not a jump past a jump. A `for` loop
steps its variable at the top and tests at the bottom, so that a round
by 1 is one compare and one jump; its rare case, a body that moves the
variable past the limit, has code of its own after (`ForNext`, whose
comment walks through the report's rule). The blank is a symbol of its own, `sBlank`, so
no declaration or expression takes it: `_ := e` loads a single value
and drops it, and `MultiAssign` skips the results it stands for. A
`match` on an integer reads each arm's
labels in `IntArm`, which refuses a value in two of them, and tests them
one after another with `MatchRange`: compares and branches, no jump
table. `Defer` is worth reading: a deferred statement
is compiled where it stands, as a little subroutine of the procedure
that the code jumps over (gen's `DeferBegin` and `DeferEnd`), and
`RunDefers` emits a call to it at every way out of its statement list:
the end, `return` and `break`. A `return`'s result waits in the frame
meanwhile, so that gen's stack is empty when they run.

Then declarations: `Declarations` reads `const`, `type`, `var`, `proc`
and `extern`, each one through `Declaration`, a recovery point, which
calls `ConstDecl`, `TypeDecl`, `VarDecl`, `ProcDecl` or `ExternDecl`. `ProcDecl` handles forward declarations, code procedures
(`CodeBody`, which checks the signature and has gen's `CodeProc` run
the target's assembler) and bodies (`Body`).
`ParseType` and its helpers (`RecordType`, `VariantType`, `Signature`,
`EnumType`) build `TType`s.

Last, modules, at the end of the file. `CompileFile` reads one module.
`ImportModule` finds a module's file, trying the target's names first,
and compiles it if it isn't yet. `CheckOneModule` first makes sure no
later directory has the module too, unless the file is a link to one
of its files there; `CheckSiblings` then reads the files for other
targets beside it, declarations only, and `CompareIface` holds them
to the same exports by their fingerprints. A generic module is
compiled once per distinct list of arguments, where it is first used.
The import only notes where its arguments are (`SkipArgs`, `deferred`);
`FirstUse`, from `QualIdent`, has `MakeInstance` go back there, where
`ParseArgs` reads them, then compile the instance. `Params` binds them
to the module's parameters, and `IsModule` decides whether an instance
already exists. An instance can't be compiled in the middle of another
procedure's code, since the code buffer is one run of bytes, so
`InstancesFor` reads ahead through a procedure, or the module's body,
before its code begins, and makes the instances it names.

**Recovery.** After an error the parser carries on, so that one run
reports them all. `Guard` notes, at the start of a statement or
declaration, the scanner's state and the parser's; `setjmp` marks the
place, and `MarkAt` jumps back to it after reporting. `Restore` puts
the state back, the construct's first symbol current again, and
`SkipConstruct` reads past it, counting the words that open and close
blocks. A symbol at the start of a line ends the skip: by the usual
layout it starts the next declaration, so the statement gives up its
procedure (`GiveUp`), and `SkipProc` reads to the procedure's
`end Name;`. A name not declared is reported by `NotDeclared`, with
what it may have meant: a module to import (`ModuleFile`) or a name
spelled alike. It is then declared where it is used, with the type
`tPoison` (`Poison`), as are the names of a declaration that had an
error; a construct that uses poison sets `quiet`, and its errors
aren't reported, since they follow from one that was. Nothing breaks
for the half-made code: once there is an error, no executable is
written.

**Hints.** Some messages guess at the mistake from the layout. A
block statement passes `CloseEnd` its start and how far its line is
indented; an `end` further left was most likely meant for a block
around it, so the first such statement is kept, and `EndMissing`
notes it when a procedure's own `end` turns out to be missing. A type
error in an argument goes through `Mismatch`, which notes the
parameter it goes to (`passing`, set by `PassArg`).

**Warnings.** `Declare` keeps each module's declarations in order in
two lists, through `link`: its own and its procedures', parameters
and a match's names for fields among them. `Named` marks an object
`used` and `read` wherever a name finds it, except a procedure naming
itself; `LeftSide` puts `read` back as it was for a variable named
whole before `:=`, which is written, not read. At the end of a module
with no errors, `Warnings` merges the two lists by position and `Warn`
reports what isn't exported, doesn't start with `_`, and was never
used, or, for a variable, only assigned, and a procedure with results
that may reach its end (`openEnd`, from `ends`, which each statement
sets). The calls that drop results are a third list, `drops`, in
order: `CompileFile` notes where the module's own begin, since the
instances it makes along the way add theirs and take them back. A
generic module's instances
share its text, so only the first is warned of.

The built-in procedures are in `Builtin` (and `New_`, `Atomic`): each
parses its own arguments, since `SIZE` takes a type and `INC` a
variable.

**Register variables.** One pass can't know whether a variable's
address will be taken before its code is made, so `ChooseRegs` reads
the body ahead, as `InstancesFor` does, and counts each variable's
uses: 1 for each, 4 in a loop, 16 in two, at most 64 (loops nested three
deep or more); one `ADR` takes is out. The
busiest used at least three times get the five registers (`o^.reg`),
a slice two (`o^.reg2` too), its count halved for each. An
address wanted after all, by a `var` parameter, say, comes to
`Address` (`item.pas`), which puts the variable back in memory and
sets `demoted`: `Body` then throws the procedure's code away
(`MarkCode`, `Redo`), places the locals again, and compiles its
statements again. Its notes for
the trap report are made after, by `VarKind`, which marks a variable
in a register with the register's number.

## link.pas: tree shaking and layout

`MarkLive` starts from the entry chunk and follows fixups, marking each
chunk it reaches, through the data fixups of constants too; nothing
else goes into the executable. `LinkAll`
places the live chunks section by section (`Place`), each at its
alignment, then copies their bytes into the images of text and rodata,
patching every fixup with the distance from the end of its field to its
target, and every data fixup with its target's address.

Between placing text and placing rodata, `MakePlaces` writes the
places, a rodata chunk: for the trap report, each live procedure's
address range and name, and its variables, which `Body` (`parse.pas`)
notes with `NoteVar`: each one's name, its place in the frame and how
`Rt` shows it (`VarKind`); then the line table (`MakeLines`), DWARF
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
The entry point gives Rt what the program has (`TLink`): the places,
`calls`, which tells the calls under way, `place`, which says where an
address is, and the profiler's start. What it isn't given, nothing
reaches, so the linker leaves it out: `raz -noprofile` gives no
profiler, and `raz -s` none of them, whose failures say only their
address (and `elf.pas` writes no symbols or line numbers). Hello is 28
KB, 21 KB without the profiler, and 7 KB stripped.

The layout is chosen so the file can be mapped as it lies, with no
padding: text just after the headers, then rodata, then the dynamic
loader's table (in a program that uses C), each loaded a page further
from its place in the file than the one before, so that no two
segments, with their different permissions, share a page. bss follows
the loader's table, or begins a page of its own.

## elf.pas: the executable

`WriteElf` writes the ELF header, the program headers, the text and
rodata images, and then what isn't loaded: section headers, a symbol
table with every live procedure and variable by `Module.name`, and
the compile unit that names the line table. The line table is in the
places, in rodata; `.debug_line`'s header points there.

A program that uses C is linked dynamically, in the least way the
loader accepts: an interpreter header naming the loader; a dynamic
section naming the libraries; and, for each C symbol the program uses,
a symbol and a `GLOB_DAT` relocation that has the loader write the
symbol's address into the quadword `ExternChunk` made. Code calls C
through that quadword. There is no PLT and no lazy binding.
`SizeTables` and `PutTables` lay these out in the room `link.pas` left
at the end of rodata.

Line numbers are DWARF 4: the line table `MakeLines` made from the
notes `NoteLine` made, and the single compile unit gdb needs to find
it, which `PutDebug` writes. There are no types or variables in it;
gdb can stop at a line and show where it is, not print a variable.

## raz.pas: the command line

`raz.pas` parses the arguments, calls `CompileMain`, and works out what
the program uses: `Use` marks the modules imported from the main module
and `Rt`; `UsesC` decides whether the program is dynamic, refusing one
that both uses C and has a module saying `link static`. Then it has
gen's `EntryPoint` write the entry point, and `MarkLive` mark what it
reaches. On a target
without reals (`HasReals`, beside `Target` in `parse.pas`; x86-64 has
them), a live chunk that computes with one is an error at the first
place it does: `UsesReals` in `item.pas` notes it, from `Value` and a
real literal, on the chunk of the procedure being compiled. A real
moved whole, as a record's bytes are, isn't noted. A static program starts at `_start` itself. A dynamic
one starts at a `_start` that calls `__libc_start_main` the way C's own
start-up does, which sets C up and calls back a `main` that runs the
module bodies and the program's `main`.

`raz -S` lists the code (`List`, in `x64.pas`) instead of writing
it. `raz run` writes the executable to a memfd, a file only in memory, and
executes it through `/proc/self/fd` in raz's own place, handing it the
rest of raz's `argv`. Nothing is left on disk, and the program's
status is the command's.

## This compiler's choices

What the report's appendix A leaves to an implementation, and what
this one does.

- **The target.** x86-64 Linux, `linux-x86_64`: `INT` is 64 bits, and
  there are reals. Every module of a program is compiled together, in
  one run, into a static ELF executable, or a dynamic one if the
  program uses C; no object files.
- **Finding modules.** `raz Main.raz` looks for `X`, imported, in
  `Main.raz`'s directory, then in each `-I dir` in the order given
  (16 at most), then in `lib` beside the `raz` executable, following
  a link to it (`make install` puts `raz` and `lib/` together in
  `PREFIX/lib/raz`). In each directory it tries `X.linux-x86_64.raz`,
  `X.linux.raz`, `X.x86_64.raz` and `X.raz`, in that order, and takes
  the first found (`ModuleFile`, `parse.pas`).
- **Errors.** Every error in a run is reported, up to 20 (`MaxErrors`,
  `diag.pas`); then the compiler stops. Two errors at the same place
  are told as one. Any error is status 1.
- **Warnings.** Of a declaration never used, or a variable only
  assigned (`Warn`, `parse.pas`): not of what is exported, a name that
  starts with `_`, an enumeration's names or a generic module's
  parameters. A procedure naming itself doesn't use it; a type named by
  a pointer in its own declaration does. Assigning a variable whole
  (`x :=`, `a, b :=`) doesn't read it; anything else does. Warnings
  come only for a module with no errors, and a generic module's only
  for its first instance. A procedure with results is warned of if
  it may reach its end without `return` (`ends`, `parse.pas`): each
  way through its statements must end in a `return`, an `if` with an
  `else`, a `match`, a `while true` or a `repeat ... until false`
  with no `break`. So is a call standing on its own that drops a
  result (`drops`, kept by `OneStatement` and told by `Dropped`);
  `_ := f(x)` drops one on purpose. `-Werror` makes each an error.
- **Registers for variables.** Up to five of a procedure's single
  values, not reals, whose address is never taken, live in `rbx` and
  `r12` to `r15`, a slice taking two of them; in a procedure that
  calls nothing, a parameter that arrives in `rdi` or `rsi` stays
  there. The trap report shows them as it shows the others, but for
  slices, which it never shows.
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
  procedure for a stack overflow in its prologue, and then ends the
  program, so its status is the signal's. The handlers run on a stack
  of their own: `Rt`'s for the main thread, one in each `Thread`
  thread's mapping. C's threads have none, so a stack overflow in one
  ends the program by the signal with no message.
- **Locks.** `Heap` and `Out` lock with `Lock`, a spinlock that yields,
  since they serve C's threads and `Thread`'s alike; `Thread.Mutex` is
  a futex.
- **C.** A program uses C if a module it uses has an `extern` or a
  `link` of a library. C's symbols are reached through quadwords the
  loader fills in (GLOB_DAT), with no PLT; the executable exports
  nothing. Its entry point stores C's `exit` in `Rt.cExit` before any
  module body runs.
- **Frames.** A deferred statement's slots stay reserved for the rest
  of its procedure. A generic instance first used in a procedure, or in
  a module's body, is made before that code begins (`InstancesFor`).
- **The executable** carries DWARF line numbers and the names of
  procedures for gdb, and the places (`Rt.places`), which hold the
  line table, DWARF's, that gdb reads and `Rt` runs.

## Where to start changing it

- **A built-in procedure:** an entry in `sym.pas`'s universe, a case in
  `Builtin` in `parse.pas`, and the code, in `gen.pas` if it is an
  instruction, or of calls to gen right there.
- **An instruction:** a routine in `x64.pas` built on `OpM` or `OpR`,
  and a line in `test/enctest.pas` to check its encoding.
- **A machine:** a new `gen.pas`, answering the same calls, and an
  encoder and assembler for it in place of `x64.pas`.
- **A statement:** a reserved word in `scan.pas` (in `TSym` and `Words`,
  in the same order), a case in `OneStatement`, and a routine beside the
  others.
- **A check that fails:** `Check` in `gen.pas`, and the message in
  `lib/Rt.raz`'s `fail`; a reason a signal gives, `onSignal` there.

After any change: `make check`, `make bench`, `make loc`.
