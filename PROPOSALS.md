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

## A minus sign after an operator

`x & -8` and `n * -1` are errors: a unary minus belongs to the start
of a `SimpleExpr` (6), not to a factor, so after an operator it needs
parentheses, `x & (-8)`, or another spelling, `x & ~7`. This is the
report's grammar, Oberon's, and the compiler is right to refuse it;
but nearly every other language takes it, and the error ("expected an
expression, found -") surprises.

The proposal: a factor that follows an operator may be `"-" Factor`.
The minus at the start of a `SimpleExpr` stays as it is, applying to
the first term, so no program changes meaning: `-a & b` is still
`-(a & b)`, which isn't `(-a) & b`, nor is `-a shr n` the same as
`(-a) shr n`. Only text that is an error today, `x & -8`, gets one.
The cost is that a minus means two things by where it stands, which
the report would say in a line.

Met in tery's `aligned`, `(a + 7) & -8`.

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

## Inlining a procedure that only returns

Not the language's but the compiler's: a call of a procedure whose
body is `return` and an expression, as `Grep.zeros` and
`Scan.tokPos` are, made in place of the call. One pass keeps no
tree to copy, but it can read source again, as `while` reads its
condition again (`saveScan`, `restoreScan`): the arguments go to
temporaries, each evaluated once and in order, a scope names the
parameters as them, and the expression is read again from where the
procedure's begins, in its own module's scope.

Measured by hand on the kernels: Grep with `zeros` and `lowest`
written in place is 20% faster, 0.88 times FPC `-O2`'s time where it
is 1.14 now. The compiler has 78 such procedures and the library 28;
the compiler's profile names the calls of small routines as what is
left (doc/compiler.md).

Kept narrow: scalars passed by value, no recursion, no code
procedure (a square root has its own way), a procedure taken as a
value still called. What it costs: an inlined procedure is not in
the trap report's list of procedures, nor in gdb's backtrace, though
a failed check in it is still told at its line; 60 to 100 lines of
the budget; and, across modules, the imported module's
text kept to be read again, which is to be checked.

More cases, from sauce (`~/r/sauce`, RAZ-NOTES.md). Its SHA-256, with
the rotation a procedure, `return (x shr n) | (x shl (32 - n))`, and
each word read by `Str.be`, ran at 52 MB/s; with both written out in
the loop, 115 MB/s, where FPC `-O2` does about 200 and `check off`
adds only 9%. Most of the gap is calls. `ror` is the narrow case
above; `Str.be` is not, a loop over its bytes, and would want a
`Str.be32` of four bytes that only returns, or the loop unrolled where
it is. A rotate of the language's own, an operator or a built-in
procedure, would serve SHA, the other hashes and checksums without
any inlining, but it is a language change, for a thaw. On 100 MB of
new files `sauce commit` takes 1.2 s against the Pascal sauce's 0.7,
and `verify` 0.95 s against 0.48: the hashing.

## A slice that outlives what it points at

```
proc short(h: Hex): []U8;    (* Hex = [64]U8 *)
begin
    return h[0..8];
end;

proc word: []U8;
var a: [4]U8;
begin
    ...
    return a;                (* the array, silently a slice *)
end;
```

Both compile without a word, under `-Werror`, and return a slice of
the procedure's own frame, which the next call overwrites. Section 10
says a program that reaches memory only through checked variables is
defined; a slice is checked, so this is a hole in that promise, a
defect rather than a wish, and it can be mended without a thaw.

The narrow mend, which needs no analysis of where values go: it is an
error to return, as a slice, a slice of a local array or of a value
parameter that is an array or holds one, the silent conversion of
such an array included. It doesn't catch a slice stored in a module
variable or through a pointer, which is the rarer mistake, nor one of
an `ADR`, which section 10 already gives no promise for. The report
says it in section 7.3, Return; the compiler checks it where it
checks the type of `return`'s expression.

Met in sauce's `Ssha.short`, which takes `var h: Hex` now.

## `Vec(T)`, a growable array

The library has `List`, linked, and `Map`, a hash; nothing that grows
in place and can be indexed. A program that keeps what it learns the
length of as it reads (lines, entries, changes) writes one: sauce's
`Svec`, 90 lines, imported four times. Every program of size will.

A generic module of the standard library, not the core: like `List`
and `Map` it takes its memory from the allocator `init` gives it, and
a target with no heap to speak of may leave it out. It is `Buf` for
any `T`, and works as `Buf` does:

```
module Vec(T);
type Vec* = record len*: INT; ... end;
proc init*(v: ^Vec; a: ^Mem.Allocator);
proc room*(v: ^Vec; n: INT): BOOL;    (* room for n more; false if the allocator has none *)
proc push*(v: ^Vec; x: T);            (* x added at the end *)
proc add*(v: ^Vec): ^T;               (* a new element at the end, zero, to fill in place *)
proc resize*(v: ^Vec; n: INT);        (* n elements, the new ones zero *)
proc all*(v: ^Vec): []T;              (* the elements, until it next grows *)
proc reset*(v: ^Vec);                 (* emptied, its memory kept *)
proc done*(v: ^Vec);                  (* its memory given back *)
```

`all` gives a slice, so that indexing is checked; `v.len` is its
length. `push`, `add` and `resize` stop the program when the
allocator has no room, as `Buf.add` does, rather than returning a
`BOOL` as `List.push` does: a `push` whose result is dropped loses an
element silently, and an array is pushed to far more often than a
list. `room` asks first. No `pop`, `insert` or `remove` until a
program needs one: `v.len := v.len - 1` and `Sort` cover most.

A new module breaks no program, so it can come with any release.
