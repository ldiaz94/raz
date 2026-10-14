# raz: proposals

What the language or the library might have, met while writing raz.
None is built while the freeze holds; each waits for a later thaw, by
the owner's word, and goes into the report before any code.

## A `const` parameter

`proc what(const x: Item): []U8;`: the callee may not change `x` (nor
take its address), so the caller may pass the address of a record or
array without a copy, and the program means the same.

Met in porting the compiler to raz, where the seed's `const x: TItem`
(about 130 bytes) became a value parameter, copied at every call.
Measured once the port built: not what stands out, the compiler's
profile is flat (`Scan.tokPos` is 9%).

## Text that runs over lines, or comes from a file

A string ends on the line it starts on, so a long text, a program's
help or a script it carries, is written as one constant of many
strings joined by `+`, a `\n` at the end of each. Two ways out, either
enough:

- a string that may run over lines, its line breaks part of it;
- a constant whose value is a file's bytes, read when the module is
  compiled, found as a module is: `const Prelude = file "prelude.fs";`.
  The second keeps the text a file of its own, which an editor and
  other tools see as what it is.

Met in tery, a Forth in raz, whose prelude of 270 lines of Forth is
made into a module of 270 strings by `sed` in its Makefile, every `\`
and `"` escaped.

## Dereferencing a conversion

`^I64(ADR(mem[a]))^` is an error today ("a conversion can't be
dereferenced"), and a statement can't start with one, so a program
that reads and writes typed values in an array of bytes declares a
pointer variable for each access:

```
p := ^I64(ADR(mem[a]));
p^ := v;
```

The proposal: a conversion to a pointer type may be followed by `^`,
and the designator it makes may stand where any other does, on the
left of `:=` too, so that the two lines are `^I64(ADR(mem[a]))^ := v;`.
The grammar's `Designator` would start with a `QualIdent` or such a
conversion.

Met in tery, whose memory is an array of bytes holding cells: every
fetch and store of a cell, and in any program that reads a file
format or a device's registers through a byte buffer.

## A minus sign after an operator

`x & -8` and `n * -1` are errors: a unary minus belongs to the start
of a `SimpleExpr` (6), not to a factor, so after an operator it needs
parentheses, `x & (-8)`, or another spelling, `x & ~7`. This is the
report's grammar, Oberon's, and the compiler is right to refuse it;
but nearly every other language takes it, and the error ("expected an
expression, found -") surprises.

The proposal: `"-" Factor` is a factor too. Where the two readings
both apply, as `-a * b`, they give the same value: an integer's
negation and product wrap alike, `-(a * b)` and `(-a) * b` are the
same bits, and so are they for reals. The smallest value of a signed
type is no exception: it is its own negation.

Met in tery's `aligned`, `(a + 7) & -8`.

## INT and I64 in one expression

An `INT` goes silently into an `I64` where it is assigned, passed or
returned (5.10), but not in an expression: with `n: INT` and `a: I64`,
`a + n` is an error, and must be `a + I64(n)`. A program whose numbers
are `I64`s, a file's size and position, a time, a Forth's cells, and
whose lengths and indexes are `INT`s, writes `I64(...)` and `INT(...)`
on line after line.

The proposal: where one operand of an arithmetic operator or a
relation is an `INT` and the other an `I64` (or `UINT` and `U64`),
the `INT` is widened, as it would be by an assignment, and the result
is an `I64`; which, as the assignment's widening, loses nothing on
any target. The other way, an `I64` into an `INT`, stays written.

Met in tery throughout: its cells are `I64`, and every slice of its
memory, every stack depth and every length is an `INT`.

## Dividing 128 bits by 64

`Math.mul` gives the 128-bit product of two `U64`s; there is nothing
to divide such a number back down. Forth's `UM/MOD` and `M*/`, and
any arithmetic on numbers wider than a word (a bignum, a fixed-point
product scaled back), need "this 128-bit number, given as its high
and low words, divided by a 64-bit one: the quotient and the
remainder". x86-64 does it in one instruction, `div`; a raz program
does it by a loop of 64 shifts and subtractions, or a code procedure
per target.

The proposal, in the library:

```
proc div*(hi, lo, d: U64): (U64, U64);   (* hi, lo divided by d: the quotient and the remainder; hi < d *)
```

in `Math`, beside `mul`; `hi >= d`, whose quotient doesn't fit a word,
and `d = 0` stop the program as a division by zero does. It breaks no
program, so it could come with any release, not only a thaw.

Met in tery's `udivmod`, a loop of 64 rounds.

## Sys: the position in a file, and its size

`Sys.seek` moves to a position from a file's start or end, and says
the new one; nothing says where a file is without moving, nor makes a
file shorter. tery's `FILE-POSITION`, `FILE-SIZE` and `RESIZE-FILE`
make the system calls themselves, by their Linux numbers (`lseek`'s
`SEEK_CUR`, `ftruncate`), which is what `Sys` is there to keep out of
programs.

The proposal, in `Sys`:

```
proc position*(fd: INT): I64;           (* where the next read or write is, or minus an errno *)
proc truncate*(fd: INT; size: I64): INT;   (* the file made size bytes long *)
proc sync*(fd: INT): INT;               (* what was written to it on the disk *)
```

Each is a system call on Linux and a C call elsewhere, as the rest of
`Sys` is; they break no program.

## Opt: where the operands are

`Opt.operand` gives the operands one at a time, as slices; nothing
says where they are among the program's arguments. An interpreter
whose first operand is a script and the rest the script's own
arguments, as `tery file arg ...` or `sh script arg ...`, copies
each into an array of its own to hand them on.

The proposal: `proc at*(p: ^Parser): INT;`, the number of the
argument `operand` would give next, after what options are left; so
that the arguments from there on are `Files.arg(i)` for `i` from
`at(p)` to `ARGC() - 1`, as they are. It breaks no program.
