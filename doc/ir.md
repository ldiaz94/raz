# The intermediate form of raz

A draft, for review before any code (PLAN.md, v0.6.0, step 3).

This is the code an object file holds (report, section 10): what the
parser makes of a module's procedures, before any machine is chosen.
A back end turns it into one target's machine code; an interpreter
could run it as it is. It is this compiler's choice, not the
language's (report, appendix A): another implementation may keep
object files of its own.

It is a stack code, as Wirth's P-code was. The parser already
compiles to a stack machine through `rax` (`doc/compiler.md`); the
intermediate form is that stack machine written down, with the
machine taken out. Each call the parser makes into `gen.pas` today
becomes one or a few instructions here.

## What it is for

- **One parser, many machines.** The parser emits this, and knows
  nothing of x86-64. A port writes a back end: instruction selection
  and encoding, a few thousand lines at most, and leaves the rest of
  the compiler alone.
- **Object files.** A module is compiled once into its interface and
  this code, and linked into any program later (report, section 10).
- **Registers without an allocator.** A back end keeps the stack in a
  stack of registers, as Wirth's compilers do: the value at depth `d`
  lives in register `R[d]`. Nothing has to be allocated, and no
  instruction moves a value the program didn't ask to move.
- **An interpreter as a fallback.** Every instruction is simple
  enough that an interpreter of the whole form is a few hundred lines,
  in raz or in anything else: a way to run raz on a machine before it
  has a back end.

## What it leaves out

No SSA, no basic blocks, no optimisation; no types beyond what a
machine needs (the parser has checked everything else); no syntax
tree. Sizes and layouts are already worked out: an object file is
made for one target, its `INT` and its C layout. The same form serves
every target, but one object file serves one.

## Values

The stack holds values of four kinds:

| Kind | What |
|---|---|
| `w` | a word: an integer as big as an address, `INT`, `UINT`, a pointer, a procedure, an `ERROR`, a `BOOL` or an enumeration |
| `l` | a 64-bit integer, `I64` and `U64`; the same as `w` where an address is 8 bytes |
| `f` | an `F32` |
| `d` | an `F64` |

A narrower integer (`I8` to `I32`, `U8` to `U32`) is a `w` on the
stack, extended by its sign or by zeros as its type says, and cut back
when it is stored. Records, arrays, slices and variants are never on
the stack: their addresses are.

An instruction names the kinds it works on after a dot: `add.w`,
`add.l`, `add.d`. Signed and unsigned are told apart only where they
differ: `div.s` and `div.u`, `lt.s` and `lt.u`, `shr.s` and `shr.u`.

## A procedure

```
proc Name.f  params: w w  results: w  frame: 32 align 16
    ...
end
```

`params` and `results` are the kinds of the procedure's scalar
parameters and results, in order; a record, array, slice or variant
parameter is a `w`, its address. `frame` is the size of the frame,
whose slots the parser has laid out: its parameters, its variables,
and the temporaries of each statement. `frame k` pushes the address
of the slot at offset `k`.

On entry the parameters are already in their slots, put there by the
back end's prologue; the frame is zero everywhere else (report,
section 4). A procedure returns with `ret`, taking its results from
the stack, as many as `results` says. A procedure with several
results, or a result that isn't a scalar, has a hidden first
parameter, the address to put them at, and the parser writes them
there itself; such a procedure's `results` is empty. This is the rule
of today's compiler (CLAUDE.md, "several results come back through a
hidden pointer"), and C's rule for a struct.

## The instructions

Each one takes its operands off the stack and pushes its result, the
operand pushed last being the right one: `const.w 7; const.w 2; sub.w`
leaves 5. `pos` is a place in the source, as a line and a column.

**Constants and addresses**

| Instruction | Does |
|---|---|
| `const.w n`, `const.l n`, `const.f x`, `const.d x` | pushes the constant |
| `frame k` | the address of the frame slot at offset `k` |
| `addr sym+k` | the address of a chunk of the program (a module variable, a string, a procedure, an `ERROR`), plus `k` |
| `extern name` | the address of a C symbol (report, section 9) |
| `drop` | throws the top value away |
| `dup` | pushes the top value again |

**Memory**

| Instruction | Does |
|---|---|
| `load.t` | takes an address, pushes the value there, of type `t`: `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `w`, `f`, `d` |
| `store.t` | takes an address and a value, stores the value there |
| `vload.t`, `vstore.t` | the same, volatile: exactly one access of exactly that size, in this order among the volatile ones (report, section 7.6) |
| `uload.t`, `ustore.t` | the same, at an address that may be misaligned: a field of a packed record (report, section 5.5) |
| `copy n a` | takes a destination and a source, copies `n` bytes, both aligned to `a` |
| `zero n a` | takes an address, zeroes `n` bytes aligned to `a` |

**Arithmetic.** On `w` and `l`: `add`, `sub`, `mul`, `div.s`, `div.u`,
`mod.s`, `mod.u`, `and`, `or`, `xor`, `shl`, `shr.s`, `shr.u`, `neg`,
`not`. On `f` and `d`: `add`, `sub`, `mul`, `div`, `neg`. All of them
wrap, and a shift takes its count modulo the width (report, section
6.1). `div` and `mod` on integers carry a `pos`: dividing by zero, or
the smallest integer by -1, stops the program there (report, section
10), by the machine's trap or by a test the back end puts in on a
machine that doesn't trap, as RISC-V doesn't.

**Comparisons** push a `w`, 0 or 1: `eq`, `ne`, and `lt`, `le`, `gt`,
`ge` with `.s` or `.u` on integers, plain on reals, where they are
IEEE's (report, section 6.3).

**Conversions**

| Instruction | Does |
|---|---|
| `cut.t` | a `w` or `l` cut to the integer type `t` and extended back by its sign or zeros: what `I8(x)` does, and what keeps `U8` arithmetic wrapping at 8 bits |
| `wide.s`, `wide.u` | a `w` to an `l`, by sign or by zeros; nothing where they are the same |
| `narrow` | an `l` to a `w`, cut |
| `itof.s.k`, `itof.u.k` | an integer of kind `w` or `l` to the real kind `k` |
| `ftoi.k` | a real to an `l`, toward zero; a NaN or a value out of range gives the smallest `I64` (report, section 6.7) |
| `ftod`, `dtof` | `F32` to `F64` and back |

**Checks** carry a `pos`; a failed one calls `Rt.fail` with what
failed (report, section 6.5).

| Instruction | Does |
|---|---|
| `check.index pos` | takes an index and a length; stops the program unless `0 <= index < length` by value; leaves the index, as a `w` |
| `check.slice pos` | takes `lo`, `hi` and a length; stops the program unless `0 <= lo <= hi <= length`; leaves `lo` and `hi` |
| `check.order pos` | takes `lo` and `hi`; stops the program unless `lo <= hi` (a slice of a pointer) |
| `check.enum n name pos` | takes a `w`; stops the program unless it is below `n`, the number of names of the enumeration `name` |
| `check.nil pos` | looks at the top value, a pointer or a procedure, without taking it; stops the program if it is `nil` |

A module that says `check off;` has no `check.index`, `check.slice`
or `check.order` in its code. `check.nil` comes before every
dereference and every call through a procedure value; a back end for
a machine that traps on a low address may make it nothing.

**Control.** Labels are numbers, one set to each procedure.

| Instruction | Does |
|---|---|
| `label n` | marks a place |
| `jump n` | goes there |
| `jz n`, `jnz n` | takes a `w`, and goes there if it is zero, or not |
| `line pos` | the statement that starts here begins at `pos`; it goes into the table of lines, for the debugger and the trap report |
| `gosub n` | runs the code at label `n`, in this same frame, until its `back`, then goes on after the `gosub` |
| `back` | returns from a `gosub` |

At a `label`, every way in brings the same values on the stack, of the
same kinds. Most labels are reached with the stack empty; the one at
the end of `a and b` used as a value is reached with one `w`. A back
end keeping the stack in registers therefore finds each value in the
same register whichever way it came.

**Calls**

| Instruction | Does |
|---|---|
| `call sym` | calls a procedure of the program; its arguments are on the stack, the first pushed first, and its results replace them |
| `calli sig` | the same, through a procedure value pushed after the arguments; `sig` gives the kinds of its parameters and results |
| `callc name sig` | calls a C procedure (report, section 9), by C's convention, `...` and all |
| `ret` | returns, with the procedure's results on the stack |

A record, array, slice or variant passed by value goes as the address
of a copy the caller makes (`copy`, then the temporary's address), as
today. Arguments are worked out left to right, onto the stack, so
working out one can't disturb another: the back end, not the parser,
moves them into the target's registers.

**The rest**

| Instruction | Does |
|---|---|
| `cas.t`, `xchg.t`, `xadd.t` | the atomic built-ins (report, section 6.8), on an address and one or two values |
| `fence` | a full barrier |
| `syscall n` | a Linux system call with `n` arguments; only for Linux targets |
| `argc`, `argv` | the command line (report, section 6.8) |

## Code procedures and assembly

A procedure written in machine code, or in assembly (PLAN.md, step
9b), isn't in this form: its bytes are the target's. The object file
keeps them as they are, with the name of the target they are for, and
a back end for another target rejects them. This is why a module that
holds machine code comes in one file per target (report, section 3).

## Statements, as they come out

What the parser emits for a few statements, the frame offsets made
up:

```
x := a[i] + 1;       (* a: [10]I64, i: I64, x: I64; all locals *)

    line 12:5
    frame 0             (* x's slot: the destination first, section 7.5 *)
    frame 16            (* a *)
    frame 8             (* i *)
    load.i64
    const.w 10
    check.index 12:14
    const.w 8
    mul.w
    add.w               (* the element's address *)
    load.i64
    const.l 1
    add.l
    store.i64
```

```
if p # nil then p^.n := 0; end;     (* p: ^Node, n at offset 8 *)

    line 13:5
    frame 24
    load.w
    const.w 0
    ne.w
    jz 1
    line 13:21
    frame 24
    load.w
    check.nil 13:21
    const.w 8
    add.w
    const.l 0
    store.i64
    label 1
```

A back end keeping the stack in four registers turns the second into,
on x86-64:

```
mov rax, [rbp-24]
test rax, rax
je L1
mov rax, [rbp-24]      ; check.nil: nothing, the machine traps on nil
mov qword [rax+8], 0
L1:
```

where today's compiler pushes and pops. A back end may match small
patterns such as `frame k; load.w` (one instruction on most machines)
or a comparison followed by `jz` (a compare and a branch), and that is
all the optimising it does.

## Object files

An object file is a module's, for one target. It holds, in this order:

1. **A header**: the module's name, the target, the version of this
   form, and the fingerprint of the module's interface.
2. **Its imports**: each module it read the interface of, with that
   interface's fingerprint when it was compiled. The object file is
   current while each of those is still the one there, and its source
   hasn't changed (report, section 10).
3. **Its interface**: what it exports, as an importer needs it: its
   constants with their values, its types with their layouts, its
   variables, and its procedures' signatures. An importer reads this,
   never the source.
4. **Its chunks**: each procedure in this form; each module variable
   as a size and an alignment; each string and `ERROR` as its bytes.
   A chunk is named, so that the linker finds it from other object
   files.
5. **Its instances**: each instance of a generic module it made, its
   chunks named by the generic module, its arguments and the
   fingerprints they were built from (report, section 10). The linker
   keeps one of each name.
6. **Its places**: the lines of its statements and the places of its
   checks, for messages, the trap report and the debugger.

Numbers are written as LEB128, the variable-length encoding of
WebAssembly and DWARF; names as a length and their bytes. A program
is linked from object files alone: the linker reads them, marks what
the entry point reaches (tree shaking, as today), hands each live
procedure to the back end, and writes the executable.

## The interpreter

An interpreter keeps a stack of values, a frame per call, and memory
laid out as the object file's target says. Each instruction is a few
lines of it; `callc` and `syscall` are the only ones that need the
machine under it. It is not part of v0.6.0. It is here so that the
form stays small enough to have one: every instruction added must be
easy to interpret, or it doesn't belong.

## Open questions

1. **Locals in registers.** The form reaches every variable through
   `frame k`, so a back end can keep the stack in registers, but not a
   variable. Keeping variables in registers too (the next step in
   speed) needs to know which variables never have their address
   taken. The parser could mark them in the procedure's header at its
   end, since it has seen every `ADR` by then. Proposed: leave it out
   of v0.6.0, and keep room in the header for it.
2. **Text or binary.** The object file is binary, for speed. A text
   form, as written above, is what `raz -S` would print, and what the
   tests of the back end compare. Proposed: both, the text one only
   for reading.
3. **Statements deferred.** The parser compiles a deferred statement
   once, as a piece of its procedure that ends in `back`, and calls it
   with `gosub` at each way out of its list, newest first, as today's
   compiler does with a call inside the procedure. The other way,
   compiling it again at each way out, needs no `gosub` but makes the
   code bigger and the parser read the statement more than once.
   Proposed: keep `gosub`, which costs an interpreter a stack of places
   to go back to.
