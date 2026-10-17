# MEM_PROPOSAL: a memory-safe raz

**Status.** A proposal, drafted 2026-10-17 for the owner's review.
Nothing in it is built. It assumes that anything may change: the
language, the library, the compiler, and the programs written for
them. It builds on two entries of `PROPOSALS.md`, "Less that is
undefined" and part 3 of "What a call does with its arguments" (`ret`
and `keep`), and goes further than either: it puts them together into
one promise, closes the holes they leave open, and counts the cost.

**In one paragraph.** Raz checks where memory is (an index against a
length, `nil`, zeroed variables) but not when it is still there, and
anything that can break memory may stand in any module. This proposal
splits modules in two. An `unsafe;` module may do what raz allows today.
Every other module is safe: the compiler holds it to rules under which
it can't read or write memory that isn't a live variable of the right
type. The rules are four:

1. Pointer arithmetic, casts, `ADR`, C and code procedures go behind
   `unsafe;`.
2. A slice or pointer *lent* by a variable can't outlive that
   variable. Most of this is checked when compiling, and it takes
   PROPOSALS' `ret` and `keep`.
3. A container that hands out slices of its memory *counts* them,
   and won't free a block while one is held.
4. Safe code doesn't free heap memory by hand. It keeps that memory
   for the life of the program, or holds it in a container or a
   `Pool` that frees it.

The library's own unsafe modules are trusted to keep the promise, as
a safe program is trusted to keep its logic. The cost, measured below:

- **Programs:** nothing for code that keeps to slices and records. 1.5
  to 2 times for chasing a linked structure through checked handles
  instead of raw pointers, where a program chooses handles.
- **Compiler:** about 5% more instructions, if its scanner checks its
  buffer instead of reading it through a pointer.
- **Ergonomics:** a record can't keep a slice into a buffer that
  belongs to someone else.

---

## Contents

1. Motivation
2. What the code we have does: a survey
3. The guarantee
4. The design, in brief
5. Part A: the fence, `unsafe;`
6. Part B: lending, `ret` and `keep`
7. Part C: owners that count what they lend
8. Part D: the heap without `free`
9. Part E: threads
10. Part F: the small mends
11. Part G: a debugging heap
12. Raz beside other languages
13. Performance
14. Ergonomics
15. What breaks
16. Changes to the report
17. Changes to the library
18. Changes to the compiler
19. Alternatives considered
20. Order of work
21. Open questions
- Appendix 1: the survey's numbers
- Appendix 2: the benchmarks
- Appendix 3: the five programs of section 1

---

## 1. Motivation

### 1.1 What raz promises today

| Check | Today |
|---|---|
| Index and slice bounds | checked, unless `check off;` |
| `nil` dereference, `nil` procedure | stops the program |
| Division by zero, `low / -1` | stops the program |
| Stack overflow | stops the program |
| Variables start at zero | always |
| Integer overflow | wraps, defined |
| A variant's fields read only through `match` | always |
| A view's bytes stay inside its variable | checked |
| Integer to enumeration conversion | checked |
| A slice returned from its own frame | an error, but only for a direct `return` (7.3) |
| Use after free, after `Arena.reset`, after a `Vec` grows | nothing |
| A slice kept past its frame by any other route | nothing |
| A slice of a call's array kept past its statement | nothing |
| Pointer arithmetic, `p[i]` | unchecked, anywhere |
| Integer to pointer, pointer to pointer | allowed, anywhere |
| `ADR` of a local, kept | allowed, anywhere |
| C, code procedures, `SYSCALL` | allowed, anywhere |
| A race tearing a slice or a variant | the report says nothing becomes undefined (7.6); it does |

This is close to Oberon's or Pascal's promise, without a garbage
collector behind it. Spatial safety (indexes, lengths, `nil`) is
mostly there. Temporal safety (whether memory is still there) isn't
there at all. Nothing marks the code that can break memory, so any
module may.

### 1.2 Five programs that compile with no warning

Each is complete, compiled by today's compiler with no warning, and run.
The full texts are in appendix 3.

**Appending a buffer to itself.**

```
Buf.init(b, Heap.heap);
for i := 1 to 64 do Buf.add(b, 'a'); end;   (* full: 64 of 64 *)
Buf.str(b, Buf.bytes(b));                   (* doubles it, or should *)
```

`Buf.str` grows `b` first: it allocates a new block, copies the bytes
and frees the old block. It then copies from `s`, which still points at
the old block. It prints 24 `a`s, as it should, because the heap didn't
reuse the freed block in time. With another allocator, or another
thread using the heap, it prints garbage. Nothing tells the programmer
that this line is wrong. A test passes.

**A slice kept across a `Vec`'s growth.**

```
first := Vec.all(v);        (* good until v next grows *)
p := Vec.add(v);            (* grows: first now points at freed memory *)
...
p^ := -1;                   (* after another growth: writes into a block the heap took back *)
Out.int(first[0]);          (* prints 1, as if nothing were wrong *)
```

The library's comments say "good until the array next grows". The
compiler doesn't know that comment.

**A slice of the frame, through a call.**

```
proc head(var h: Hex): []U8; begin return h[0..8]; end;     (* allowed *)
proc short: []U8; var h: Hex;
begin ... return head(h); end;                               (* not caught *)
```

The caller prints `########`, the bytes the next call left in the dead
frame. 7.3 catches `return h[0..8]` in `short` but not the same slice
handed back through `head`.

**A map keeping a slice of a frame.**

```
proc remember(n: INT);
var buf: [8]U8;
begin
    buf := "name-000"; buf[7] := U8('0' + n);
    _ := Names.put(table, buf[0..8], n);    (* the map keeps a slice of this frame *)
end;
```

After `remember(1); remember(2);` both `name-001` and `name-002` are
"missing": the map's keys point at a frame that is gone. Every caller
of `Map([]U8, ...).put` must know, from the documentation alone, that
the key is kept.

**A slice of a call's array, kept.**

```
a := named('a')[0..8];
b := named('b')[0..8];
Out.str(a); Out.str(" "); Out.str(b);
```

It prints `name-..b ^A^@^@^@^@^@^@^@`. Both arrays used the same
temporary, so `a` shows `b`'s bytes and `b` shows whatever came after.
Section 8 says this is undefined, and nothing catches it.

None of these is exotic. Three are what the library's own
documentation warns of; two are what 7.3 and 8 warn of. Each runs to
the end with status 0.

### 1.3 Why it matters for raz in particular

- **Raz's audience.** CLAUDE.md asks that the compiler be "a model of
  plain code that a beginner can follow". A beginner can't follow a
  rule that lives only in a comment ("good until it next grows"). A
  language that checks every index and then lets a slice outlive its
  buffer teaches a false sense of safety: the checks cover the easy
  half.
- **Undefined behaviour passes tests.** In four of the five programs
  above the output is plausible, or right. The heap's free lists keep
  freed bytes for a while; a dead frame keeps its bytes until the
  next call. A program can carry such a bug for years.
- **No fence means no audit.** Today, to know whether a program can
  corrupt memory, you read all of it. With a fence, you read the
  modules that say `unsafe;`, and `grep` finds them. The survey
  (section 2) shows how few modules would need to say it.
- **The library is growing.** Each container added (`Vec`, `Map`, `Buf`,
  `List`, and `Svec` in sauce) adds rules of the "good until" kind. Those
  rules should be the compiler's to check.
- **Threads.** `Thread` and `Lock` are in the library, and rnet and
  rsqlite use them. A race on a slice reaches any memory today, though
  7.6 promises it can't.

---

## 2. What the code we have does: a survey

### 2.1 How it was measured

For an exact count, not an estimate from `grep`, the compiler itself
was changed in a scratch copy. It printed one line for each operation
this proposal would fence, where it compiled one: a pointer indexed or
sliced, pointer arithmetic, a conversion to or from a pointer, `ADR`,
`PTR`, `SYSCALL`, a view, `NEW` and every dereference. Each program
and each library module's test was compiled with it. The places are
counted once each, whatever number of programs compiled them. The
hooks stand where most of the fence's checks would go (section 18).

Code surveyed:

| Code | Version | Lines | How |
|---|---|---|---|
| raz `src/` (the compiler) | main | 14,323 | compiler-counted |
| raz `lib/` | main | 10,291 | compiler-counted |
| raz `tools/`, `examples/`, `test/libc` | main | 2,207+ | compiler-counted |
| rnet (HTTP, DNS, TLS seams) | raz 0.15.0 | 5,111 | compiler-counted, with 0.15.0's `lib/` |
| rjson | raz 0.15.0 | 1,882 | compiler-counted, with 0.15.0's `lib/` |
| rflate (inflate) | raz 0.15.0 | 1,319 | compiler-counted, with 0.15.0's `lib/` |
| rsqlite (SQLite over C) | raz 0.18.0 | 705 | compiler-counted, with 0.18.0's `lib/` |
| rterm | raz 0.15.0 | 101 | compiler-counted |
| rmacs (an editor, archived) | raz v0.5.0+7 | 4,932 | `grep`: written before `INT`, today's compiler refuses it |
| ravite (an editor) | raz v0.5.0+7 | 2,460 | `grep`, as rmacs |
| rlX11 (X11 over a socket) | raz v0.3.0+52 | 7,026 | `grep`, as rmacs |

About 50,000 lines in all. Code written for an older raz was compiled
by today's compiler against the library of the version it was written
for. The full tables are in appendix 1.

### 2.2 What it found

**Nobody uses `check off;`.** Not one module in 50,000 lines. Bounds
checks are cheap enough that no one has wanted them off.

**Almost every `ADR` is an argument to the library.** Of rnet's 572
`ADR`s, 571 are arguments, and so are 556 of rmacs's 560 and all 77 of
rjson's. They are the library's old pointer parameters, which report
2026-10.33 made `var` and `const`; code written for v0.19.0 and later
has lost them already. `src/`, which has been ported, keeps 27, and
none of them needs to be an `ADR`:

| What `src/` does with `ADR` and pointer casts | Sites | The safe form |
|---|---|---|
| a grown array: `^Chunk(Scan.regrab(^U8(chunks), ...))` | 35 | `Vec(Chunk)`, or a slice and `Mem`'s growth, in one trusted module |
| a real's bits: `p := ^F64(ADR(x.val))` | 6 | a view, `x.val.(F64)`, safe today |
| a slice passed as two words: `Scan.intern(ADR(s[0]), LEN(s))` | 7 | `Scan.intern(s)`: a slice parameter |
| out-parameters: `isReg(w, ADR(r), ADR(size))` | 5 | `var r, size` |
| a pointer to a local record: `curLoop := ADR(lp)` | 1 | a field index, or `var` |
| `SYSCALL(4, ...)`: `stat` | 1 | `Sys.info` |

**Pointer indexing is buffers.** `src/` indexes a pointer 277 times
and slices one 30 times, nearly all in six modules: `Scan` (76), `Link`
(63), `Chunk` (53), `X64` (23), `Elf` (17) and `Diag` (15). Each keeps
a byte or record buffer that it grows by hand: `text[pc + i] := ...`,
`lp[lpLen] := ...`, `buf[at + i] := ...`. That is `Vec` and `Buf`
written out again, for speed, without checks. The scanner reads its
source through `buf: ^U8`, past the end to a sentinel zero.

**Dereferences are everywhere and harmless.** 1,015 in `src/` (`Parse`
517, `Item` 256, `Sym` 106): `o^.typ`, `t^.base`. Every one is a pointer
from `NEW` on the heap, which the compiler never frees. Under part D
they stay as they are, unchecked and free of cost.

**The library is where the unsafe code is.** `Sys` (287 operations,
129 of them `SYSCALL`), `Rt` (111), `Thread` (33), `Heap` (16) and `Map`
(19). It is the code that should be trusted and read twice. `Math`,
`Out`, `Sort` and `Width` have none; `Str`, `Fmt`, `Opt`, `Files` and
`Lock` have two to five each, all of them avoidable.

**Slices held from containers.** 35 places assign `Buf.bytes`,
`Vec.all` or `Windows.all` to a variable and use it over several
statements; the rest pass it straight on. Some places store one in a
record:

```
m^.body := Buf.bytes(ADR(m^.data));                            (* rnet Http.readWhole *)
m^.headers[m^.n] := {name: l[0..colon], value: trim(...)};      (* l is a slice of m^.head's bytes *)
res^.body := Buf.bytes(ADR(text));                             (* rnet's test server: a module Buf, reset per request *)
```

`Http.Message` holds slices into two buffers of its own. It is right,
as long as nobody grows `m^.head` after the headers are read and
nobody uses the headers after `Http.done`. The compiler knows neither
condition. Section 14 shows what this pattern costs under the
proposal.

**Records that hold slices** (each one is a place where something must
decide how long the slice lives): `src/` 10, `lib/` 22, rnet 12, rjson 8,
ravite 5, rmacs 4, `tools/` 4, rlX11 3, rflate 2, rsqlite 1.

**Threads are rare.** Two of the eight other repositories spawn
threads (rnet's server, rsqlite's test). `src/`, the tools and the
editors have none.

**Freeing is rare too.** `Mem.free`, `Heap`'s `free` or `Str.free` by
hand: `src/` 7 (all in grown arrays), rmacs 9, rjson 6, ravite 2,
rlX11 1, rnet, rflate and rsqlite 0. Programs free memory through
`done` on a container (rnet 30, rmacs 16) far more than by hand: 54
`done`s to 26 frees, outside the library.

### 2.3 What the survey says about the design

1. A fence costs little. Outside the library and the compiler's
   buffers, the operations it fences are almost all `ADR`s that the
   v0.19.0 library already removed. In `src/`, the fenced
   operations are buffers and small habits, each with a safe form.
2. Leaving pointers unchecked costs nothing as long as nothing frees
   them. The compiler's 1,015 dereferences are of heap memory that
   lives as long as the program. Making `free` unsafe, and giving
   containers the job of freeing (part D), keeps those dereferences
   free of cost.
3. The hard case is a slice of a container's memory held while the
   container changes. It is found in rmacs, ravite, rnet and the
   library itself (`Fmt`, `Opt`), and nothing today checks it. Part C
   is aimed at it.
4. Threads can wait for a weaker rule than Rust's (part E), since few
   programs use them.

---

## 3. The guarantee

The proposal puts one paragraph into section 10 of the report, in
place of today's list of what isn't defined:

> **The guarantee.** A program is *safe* if none of its modules says
> `unsafe;`, the library's aside, and its threads race (7.6) only on
> variables of a basic, pointer, procedure or slice type. A safe
> program reads and writes only variables that exist, each as a value
> of its own type, and calls only procedures. It does what this report
> says, or stops with status 2 and says where and why. The library's
> unsafe modules are trusted to keep this promise for every use a safe
> program can make of what they export.

What the guarantee covers:

- **Spatial:** no read or write outside a variable: indexes and views
  checked, as now; pointers in safe code made only by `NEW` and by the
  library, never by arithmetic or conversion.
- **Temporal:** no read or write of memory that has been freed or
  reused: slices and pointers lent by a frame or a container can't
  outlive it (B, C); the heap is never freed under a pointer safe code
  holds (D).
- **Type:** no value read as another type: views of pointers and
  conversions to pointers fenced; variants only through `match`; enums
  and `BOOL` only from their values.
- **Initialization:** as now, every variable starts at zero.
- **Races:** within the bounds above (part E).

What it doesn't cover, on purpose:

- **Leaks.** A safe program may keep memory it no longer needs, as a
  garbage-collected one may.
- **Running out of memory or stack.** These stop the program, as now.
- **Logic.** A stale handle into a `Pool` stops the program; it doesn't
  fix the bug. A slice of a buffer that was cleared shows the buffer's
  new contents, safely.
- **Deadlock**, and a race on a whole record, variant or container.
  The second is undefined, as in Go, and part E says why.
- **The unsafe modules themselves.** They are trusted, as `unsafe`
  code is in Rust and `UNSAFE MODULE`s are in Modula-3.

The guarantee is stated once and is the same on every target.
Appendix A keeps only how it is carried out: whether the machine or
the code catches a fault, and how a slice is read in one access.

---

## 4. The design, in brief

| Part | What it does | Checked | Cost at run time |
|---|---|---|---|
| A. The fence | `unsafe;` modules alone may use `ADR`, pointer arithmetic and indexing, casts, views of pointers, `check off`, `extern`, `link`, code procedures, `SYSCALL`, `PTR`, or call an `unsafe proc` | compiling | none |
| B. Lending | every slice or pointer is *lasting* or *lent* by a variable of the procedure; a lent one can't be stored where it outlives its lender, nor returned unless the heading says `ret`; `keep` parameters take only lasting ones | compiling, one pass | none |
| C. Owners | a record with a `LENDS` field is an *owner*; what it lends is counted while a local holds it; an owner doesn't free a block while its count is above zero, and `done` with the count above zero stops; owners aren't copied | compiling, and a count at run time | an add and a subtract per lend held |
| D. The heap | `free` is unsafe; `NEW` gives memory that lasts; a `Pool(T)` holds what must be freed, by checked handles; containers own and free their memory | compiling, and checks in `Pool` | none, or a compare per `Pool` access |
| E. Threads | slices read and written in one access; containers and variants shared only under a lock, or the guarantee doesn't hold; `Task(T)` spawns safely; atomics take variables | partly | none on x86-64 with AVX |
| F. Small mends | an array a call returns lives to the end of its procedure; writing a string's bytes stops or changes them | compiling | a larger frame |
| G. Debugging | `Heap` in a mode that poisons and holds back freed blocks | at run time, when chosen | when chosen |

A program that is safe today, which is to say every program that
keeps to slices, records and the library, mostly stays as it is. Section 15 counts
what breaks.

---

## 5. Part A: the fence, `unsafe;`

### 5.1 The rule

A module that says `unsafe;`, after its imports, links and `check`
line, may do everything raz allows today. A module that doesn't is
*safe*, and it is an error for it to do any of the following:

| Operation | Why it's fenced |
|---|---|
| `ADR(x)` | a pointer to anything, a local included, that outlives nothing |
| `p + i`, `p - i`, `p[i]`, `p[lo..hi]` on a pointer | no length to check against |
| a conversion to a pointer or procedure type, from an integer or another pointer or procedure type | makes a pointer to anything, of any type |
| a conversion from a pointer or procedure to an integer | not unsafe in itself, but needed only by unsafe code; fenced so `grep unsafe` finds address games |
| `PTR(s)` | the first word of a slice, unchecked |
| a view `v.(T)` whose `T` holds a pointer, procedure or slice | makes one from bytes |
| writing through a view of a variable that holds a pointer, procedure, slice, variant, enumeration or `BOOL` | changes those bytes behind their type |
| `check off;` | indexes unchecked |
| `extern`, `link` | C can do anything |
| a code procedure, `SYSCALL` | the machine can do anything |
| `ARGV()` | a `^^U8` from C; `Files.arg` gives a slice |
| a call of an `unsafe proc`, or of a value of an `unsafe proc` type | the procedure says it can break the promise |

What stays safe, though it involves pointers: `p^`, `p^.f`, `p^[i]` (an
array through a pointer is indexed and checked), `nil`, comparing
pointers, `p - q` (an integer), `NEW`, and passing and storing a
pointer as any value. A pointer in safe code is only ever `nil`, from
`NEW`, or handed out by the library. Part B says how long each one
lives.

The message names the mending:

```
Window.raz:41:13: error: ADR is for unsafe modules
    41 |     XNextEvent(dpy, ADR(ev));
       |                     ^^^^^^^
    help: say "unsafe;" after the module's imports, or pass ev as a var
```

### 5.2 Unsafe procedures

Some of the library's procedures can break the promise whatever safe
code does: `Mem.free`, `Heap`'s `free`, `Str.free`, `Sys.mmap`,
`Sys.munmap`, `Thread.spawn` with its `^U8`. They are declared

```
unsafe proc free*(a: ^Allocator; p: ^U8);
```

and only an unsafe module may call one. A procedure type may say
`unsafe proc(...)`; a value of that type may be called only from an
unsafe module, and a safe procedure may stand where an unsafe type is
wanted, not the other way. `Mem.Allocator`'s two fields are of unsafe
types: safe code may pass an allocator to the library but can't call
it.

`unsafe`, like `static` in `link static;`, is a word only where it
stands: before `proc`, and as the module's line. Elsewhere it is a
name.

### 5.3 The trust

A safe module may import an unsafe one. What the unsafe module
exports, other than its `unsafe proc`s, it promises safe to use: for
any arguments a safe module can make, its procedures keep the
guarantee. This is Modula-3's rule for an `UNSAFE MODULE` that
implements a safe `INTERFACE`, and Rust's for a safe function built
on `unsafe` blocks. What the promise demands of an unsafe module, in
the report (section 16):

1. What it returns as lasting (part B) lasts: its memory is never
   freed or reused while the program runs.
2. What it returns through `ret` lives no longer than the argument it
   says. If the argument is an owner, the module doesn't free memory
   it lent while the owner's `LENDS` count is above zero (part C).
3. What it keeps (`keep` parameters) it may hold for as long as it
   likes; what it doesn't mark `keep`, it doesn't hold past the call.
4. Its exported types hide whatever a safe module could misuse: a
   container's pointer fields aren't exported.
5. Its procedures given to other threads, or shared by them, are safe
   to call from several threads at once, or say otherwise.

So `grep -l '^unsafe;'` lists every module whose bugs could corrupt
memory, and the library's are among them, as they are today.

### 5.4 Which modules would say it

From the survey, as the code stands:

- **The library:** `Rt`, `Mem`, `Heap`, `Arena`, `Bytes`, `Sys`,
  `Thread`, `Lock`, `C`, `CAbi`, and the containers `Buf`, `Vec`, `Map`,
  `List`, which hold raw blocks and grow them. `Str`, `Fmt`, `Opt` and
  `Files` can drop their two to five fenced operations and be safe.
  `Math`, `Out`, `Sort` and `Width` are safe already.
- **`src/`:** all eleven modules today. Mended as section 2.2's
  table says, with the six buffer modules' grown arrays made `Vec`s or
  slices, `src/` keeps one unsafe module: `Scan`, for its allocator
  (`grab`) and, if it keeps it, the pointer through its source buffer.
  `Elf` writes the executable through `Sys.write` and needs none.
- **`examples/`:** `Args` (it reads `ARGV()`, which `Files.arg` does
  for it), `Cpu` (a code procedure), `Pthreads`, `Printf`, `Window`
  (C), `Volatile` (a device's address), `Sh` and `Workers` (`ADR` at
  calls: mended by `var`). Five stay unsafe (`Cpu`, `Pthreads`,
  `Printf`, `Window`, `Volatile`), as an example of each kind of
  unsafety should be.
- **Elsewhere:** rsqlite's `Sqlite` (C); rlX11's three casts look like
  work for views; rnet needs it only to keep `Http.Message` as it is
  (section 14).

---

## 6. Part B: lending, `ret` and `keep`

Part B is PROPOSALS' part 3 (`ret`, `keep`) with two changes. Pointers
are followed, not only slices, and a third kind of lender, the owner,
comes from part C. What is said there of "frame-bound", "outliving the
call" and the checks stands. This section gives the rules in the
terms the guarantee needs.

### 6.1 Lasting and lent

Every value that holds a slice or a pointer (a *reference*) is, for
the compiler, either:

- **lasting:** it points at memory that lives to the end of the
  program: `nil`, `[]`, a string constant, a module variable or a part
  of one, memory from `NEW` on the heap (part D), and what the library
  returns as lasting (a result with no `ret` parameter);
- **lent** by one or more *lenders* of the procedure it is in:
  - **the frame**: a slice of a local array, of a value parameter's
    array, or of an array literal; an array a call returned (part F);
  - **a parameter `p`**: a slice parameter's value, what a `var` or
    `const` parameter's arrays hold or its references point at; and
    the parameter's own variable, for `var` and `const`;
  - **an owner `o`** (part C): what `o` lent through a `ret`.

A value made from others is lent by every lender of its parts: a slice,
a field, an element of `x`; a record, variant or array literal of
parts; a call's result, from its arguments for `ret` parameters. A
local variable holding references is lent by everything assigned to
it anywhere in its procedure. That is PROPOSALS' rule, and the reason
some checks wait for the procedure's `end`.

### 6.2 What may be done with a lent reference

A lent reference may be:

- read, indexed, sliced, compared, and passed to any parameter not
  marked `keep`;
- held in a local variable, or in a field or element of one (owner-lent
  values only in a local of slice or pointer type: see 7.3);
- returned, if each of its lenders is a parameter marked `ret`.

It may not be:

- stored in a module variable, through a pointer (`p^.f := s`), or into
  a `var` parameter or part of one;
- given to a `keep` parameter;
- returned while lent by the frame, an owner, or a parameter not
  marked `ret`;
- given to `Task.spawn` (part E).

The rules are PROPOSALS' checks 1 to 3, with "frame-bound" read as
"lent". Every check needs only the procedure in hand and the headings
of what it calls, so a one-pass compiler can make it: the checks on a
local wait for the procedure's `end`, as PROPOSALS describes.

### 6.3 Marks

```
proc trim*(ret s: []U8): []U8;                     (* the result may point where s does *)
proc bytes*(ret const b: Buf): []U8;               (* the result is lent by b, an owner *)
proc put*(var m: Map; keep k: K; keep v: V): BOOL; (* k and v must last *)
```

`ret` and `keep` stand before `var` or `const`, and are words only
there. A mark that lends nothing (`keep n: INT`) is allowed, so a
generic module can mark `keep v: T` for every `T`. PROPOSALS covers
procedure values, generics, `extern` (no marks; unsafe anyway) and
code procedures (trusted; unsafe anyway).

Marks at the call (PROPOSALS' part 1) are not part of this proposal:
the checks hold whether or not the call repeats them.

### 6.4 Examples

```
proc greet: []U8;
var line: [80]U8; n: INT;
begin
    n := Sys.read(Sys.stdin, line);
    Out.str(Str.trim(line[0..n]));    (* fine: lent by the frame, used here *)
    return Str.trim(line[0..n]);      (* error: lent by the frame *)
end;

proc first(ret s: []U8): []U8;
begin
    return s[0..1];                   (* fine: s is ret *)
end;

proc remember(n: INT);
var buf: [8]U8; k: []U8; ok: BOOL;
begin
    buf := "name-000"; buf[7] := U8('0' + n);
    _ := Names.put(table, buf[0..8], n);        (* error: put keeps k, and this is lent by the frame *)
    k, ok := Str.copy(Heap.heap, buf[0..8]);    (* lasting: a copy on the heap *)
    if ok then _ := Names.put(table, k, n); end;   (* fine *)
end;
```

The messages:

```
Kept.raz:10:30: error: Names.put keeps its key, and buf[0..8] is lent by this call's frame
    10 |     _ := Names.put(table, buf[0..8], n);
       |                           ^^^^^^^^^
    help: give put a copy that lasts: Str.copy(Heap.heap, buf[0..8])
```

```
Escape.raz:14:12: error: head(h) is lent by h, a local of short, and can't be returned
    14 |     return head(h);
       |            ^^^^^^^
    help: head's result points into what it is given (ret h); return a copy, or take h as a var parameter of short
```

### 6.5 Pointers

PROPOSALS' marks follow slices only and leave pointers to the promise
of section 10. Here pointers are references too. In a safe module the only
pointers are lasting (from `NEW` on the heap, or from the library) or
lent by an owner (`Vec.add`, `Pool.at`). `ADR` is fenced, so a safe
module can't make a pointer to the frame. A pointer lent by an
owner follows the same rules as a slice.

### 6.6 What it closes

- A slice of the frame returned or stored by any route (today's 7.3
  catches one route).
- A slice of a parameter's array stored past the call, or returned
  unmarked.
- A map, list or vector keeping a slice that doesn't last.
- `Opt.init` keeping a table built on the frame (it becomes `keep
  table`, and `examples/Sh.raz` passes a constant, as PROPOSALS shows).

---

## 7. Part C: owners that count what they lend

### 7.1 The problem part B can't solve

`Buf.bytes(b)` returns a slice of heap memory, so by PROPOSALS' rule it
points "nowhere that ends", and part B would call it lasting. It
isn't: the next `Buf.add` may free that memory. The slice is lent by
`b`, and how long it stays good depends on what happens to `b`, at run
time, often through a pointer: `Buf.bytes(x^.path)`.

There are two ways to check that when compiling. One is Rust's: no
change to `b` while any slice of it is live, found by liveness and
the exclusivity of `&mut`. The other is flow analysis in one pass:
mark a slice stale when its lender is passed as `var`, and refuse to
read it after that. Both fail raz's limits. Rust's needs lifetimes in
types and borrow regions. The one-pass flow analysis can't see a
loop's second iteration before it compiles the first:

```
s := Buf.bytes(b);
while more do
    Out.str(s);          (* compiled before the add below; but the second time round s is stale *)
    Buf.add(b, c);
end;
```

and through a pointer every call may change the lender, so every call
would make the slice stale, which is false alarms everywhere.

So part C checks at run time, as raz checks an index. The cost is an
add when a lent slice is taken into a variable and a subtract when the
variable lets go of it.

### 7.2 Owners

A record type with a field of the new built-in type `LENDS` is an
*owner*:

```
type
    Buf* = record
        lends: LENDS;            (* how many slices of data are held *)
        a: ^Mem.Allocator;
        data: ^U8;
        len*, cap: INT;
    end;
```

`LENDS` is an `INT` that only the compiler changes: the owner's own
module may read it, and nothing may assign it. An owner is lent from
only through a `ret` parameter of its type, `var` or `const`:

```
proc bytes*(ret const b: Buf): []U8;
proc all*(ret const v: Vec): []T;
proc add*(ret var v: Vec): ^T;
proc spare*(ret var b: Buf; n: INT): []U8;
```

A record that holds an owner, `Http.Message` with its two `Buf`s, is
not an owner itself. What its `Buf`s lend is counted on each `Buf`.

### 7.3 Counting

Where a call returns a reference lent by an owner `o`:

- **Used in its statement** (`Out.str(Buf.bytes(b))`, `Buf.str(c,
  Buf.bytes(b))`): `o.lends` is raised by one as the call returns and
  lowered at the end of the statement.
- **Assigned to a local** of slice or pointer type, `s := Buf.bytes(b)`:
  the local gets a hidden word, its *hold*, which records the address of
  `o.lends`. Assigning the local again lowers the old count and raises
  the new; when the procedure returns, by any path, each hold still set
  lowers its count, as a `defer` would. `s := []` lets go.
- **Anywhere else**: stored in a record, an array, a module variable,
  through a pointer, or returned. This is an error by part B, since
  the reference is lent by an owner. A local record holding one is
  also an error, so that each hold covers one reference:

```
Fmt.raz:140:5: error: Buf.bytes(b) is lent by b, which counts what it lends: hold it in a slice variable
```

A reference passed to another procedure needs no count of its own:
the caller holds it, by a statement's count or a local's hold, for the
whole call. A `ret` result lent by a lent value (`t := Str.trim(s)`,
with `s` lent by `b`) is lent by `b` too, and its local gets its own
hold.

The owner's address is fixed while it is lent. An owner is either a
local, a parameter, or a variable reached through a lasting pointer,
and part B keeps the lent value from outliving a local or parameter
owner. So the hold's address stays good until it is let go.

### 7.4 What an owner does with its count

The owner's module, which is unsafe and trusted, reads `lends`
before it frees memory it has lent:

- **Growing:** if `lends` is 0, free the old block, as now. If not,
  keep it on a list of *retired* blocks, and free those at the next
  growth, `reset` or `done` that finds `lends` 0. A slice held across
  the growth keeps pointing at the old block, which stays allocated:
  it reads what the buffer held when the slice was taken. This is Go's
  `append`: the old slice still sees the old array.
- **`done`**, which gives everything back: if `lends` is above 0, the
  program stops:

  ```
  Buf.done while 1 slice it lent is still held
  ```

  and the calls under way are shown, as a failed check shows them.
  `done` can't wait, and can't leave the memory to the slice without
  leaking it for good.
- **`reset`** keeps the block, so it is always safe: a slice held
  reads the new bytes as they are written over the old.

With this, the self-append of 1.2 is right: `Buf.str(b, Buf.bytes(b))`
holds a count across the call, the growth retires the old block, and
`COPY` reads the old block, still allocated. The `Vec` example reads
`1 2` because the memory is still there. The stale `p^ := -1` writes
into a retired block: lost, but harmless. Section 11's debugging heap
can say so.

### 7.5 What it costs

- **Run time:** two adds per lend held: on x86-64, `inc qword [r]` and
  `dec qword [r]`, about two cycles each. In a program that uses
  `Thread` they are `lock xadd`, about 20 cycles each (part E). Lends
  are rare next to element accesses: `Fmt.format` lends once per call,
  and a loop over `Buf.bytes(b)` lends once.
- **Memory:** a word per owner, a word per local that holds a lend,
  and at most the retired blocks, which add up to less than the
  current block (each was half the next).
- **Compiler:** the hold slots, the raise and lower code, and the
  epilogue's let-go. The epilogue reuses the machinery `defer` already
  has.

### 7.6 Owners aren't copied

Copying a `Buf` today makes two records that both own one block.
Freeing it twice, or growing one while the other reads, breaks
memory. rnet's `Http.reset` does exactly this, safely by luck:
`head := m^.head; ...; m^ := {..., head: head}`. In a safe module, a
value of an owner type, or of a type that holds one, may not be:

- assigned from another variable, returned, passed as a value
  parameter, or put in a literal. A literal may still leave it out, so
  that it is zero (`{}`), the empty owner;
- compared, or viewed.

It is passed as `var` or `const`, and moved by the library: `Buf.swap(var
a, b)`, `Buf.take(var from, to)`. The message:

```
Http.raz:153:5: error: a Buf.Buf owns memory, and can't be copied
    help: Buf.take(m^.data, data) moves it, leaving m^.data empty
```

### 7.7 Who is an owner

`Buf`, `Vec`, `Map` (it lends nothing, but owns its table; `LENDS`
stops a copy), `List`, `Pool`, `Arena` and the owned-string map of
part D. A program's own record may be an owner too, if an unsafe
module of the program frees what it lends.

---

## 8. Part D: the heap without `free`

### 8.1 The rule

In a safe module:

- `NEW(p, a)` with `a` lasting (`Heap.heap`) gives a lasting `p`.
  `Heap.heap` never frees it under safe code, because only unsafe code
  can call `free`.
- `NEW(p, a)` with `a` lent by an owner (an arena, part C) gives a
  `p` lent by that owner, counted like a slice.
- `Mem.free`, `Heap`'s `free`, `Str.free` and `Mem.unmap` are `unsafe
  proc`s.

So a safe program frees memory in one of three ways:

1. **Through a container** that owns it: `Buf.done`, `Vec.done`,
   `Map.done`, `List.clear`, `Pool.free`. Most programs do this already:
   outside the library, the survey's `done` calls outnumber its hand
   frees 54 to 26.
2. **Through a `Pool(T)`**, for records that come and go one by one
   (8.2).
3. **By ending the program.** A compiler, a tool or a short-lived
   server process frees nothing by hand, and `src/` frees only its
   grown arrays, which become `Vec`s.

The 1,015 dereferences in `src/` stay as they are, with no check and
no cost: every pointer behind them is lasting.

### 8.2 `Pool(T)`: handles with a generation

```
module Pool(T);

type
    Handle* = record i, gen: INT; end;     (* zero: no record *)
    Pool* = record lends: LENDS; ... end;

proc init*(var p: Pool; a: ^Mem.Allocator);
proc add*(var p: Pool; keep x: T): Handle;     (* a new record, x copied in *)
proc get*(const p: Pool; h: Handle): T;        (* a copy; stops if h is stale *)
proc set*(var p: Pool; h: Handle; keep x: T);  (* stops if h is stale *)
proc at*(ret var p: Pool; h: Handle): ^T;      (* in place, lent by p, counted *)
proc valid*(const p: Pool; h: Handle): BOOL;
proc free*(var p: Pool; h: Handle);            (* the record gone; h, and every copy, stale *)
proc done*(var p: Pool);
```

Each slot holds a `T` and a generation. `free` raises the slot's
generation and puts the slot on a free list. `get`, `set` and `at` check
the handle's generation against the slot's, and the index against the
pool's length, and stop the program if they differ:

```
Pool.get: a stale handle (slot 4, generation 3; the slot is at 5)
```

A slot is used only for a `T`, so even a pointer from `at` kept past
`free` points at a `T`: a wrong record, perhaps, but never memory
of another type. `at`'s count also keeps the pool from moving its slots
while the pointer is held (7.4).

This is the generational arena of Rust's `slotmap` and
`generational-arena`, and the handle pattern Zig and game engines use;
Vale builds the same check into every reference. Measured cost
(section 13): a list chased through handles takes 1.5 times as long as
one chased through raw pointers when it is too big for the caches, and
2 times when it fits in L1. Part of the first is that each slot is 32
bytes, not 16.

### 8.3 Owned strings

`Str.copy` gives a lasting copy, which a safe program can't free. For a
long-running program that makes and drops strings (an editor's buffer
names, a server's paths), the library adds:

- `Buf` as the string a program owns: `Buf.str(name, s)`, freed by
  `Buf.done`;
- `Names(V)`, a map from strings to `V` that copies each key in on
  `put` and frees it on `remove` and `done`: `Map([]U8, V, ...)` with
  its keys owned, for those who would otherwise `Str.copy` and leak.

### 8.4 Arenas

An arena hands out memory and frees it all at once, so what it gives
is lent by the arena:

```
var ar: Arena.Arena; t: ^Tree;
...
NEW(t, Arena.allocator(ar));    (* lent by ar *)
...
Arena.reset(ar);                (* stops the program if t is still held *)
```

`Arena.allocator(ret var ar): ^Mem.Allocator` gives the allocator,
lent by `ar`; `NEW` from it gives a `t` lent by `ar`, counted. Lent
values can't be stored in records (part B), so an arena in safe code
holds no linked structure: the pointer to a tree's root may live in
a local, but the tree's own links can't. A program that builds
linked structures in an arena does it in an unsafe module, or with
indexes into a `Vec`. Section 14 weighs this.

---

## 9. Part E: threads

### 9.1 What races can break

7.6 says a variable that two threads touch without ordering "holds a
value it had or was given, or a mixture of their bytes" and that
"nothing else of the program becomes undefined". The second half is
wrong today:

- a **slice** torn between two writes, one's address with the other's
  length, is checked against the wrong length and reaches any memory;
- a **variant** torn between two cases reads one case's bytes as the
  other's fields: an integer as a pointer;
- a **container** written by two threads at once (`Buf.add` in each)
  races on its length and its block: one thread writes past the end of
  the block the other just freed.

Go has the same hole: its memory model says that a race on a
multi-word value (an interface, a slice, a string) "can lead to
arbitrary memory corruption". Rust closes it with `Send` and `Sync`,
traits that the type system checks. Java closes it by tearing only
`long` and `double`, never a reference.

### 9.2 The proposal

1. **A slice is one access.** On every target, a slice is read and
   written in one access that can't tear, as a word is. On x86-64 a
   slice is aligned to 16 bytes and moved with `movdqa`, which Intel
   and AMD guarantee single-copy atomic on processors with AVX. On
   x86-64 without AVX, the implementation uses `lock cmpxchg16b`, or
   refuses the target, as appendix A says. ARMv8.4 has 16-byte
   atomic `LDP`/`STP` (FEAT_LSE2). A program that hands slices from
   thread to thread, publishing a buffer for others to read, is then
   safe with no lock.
2. **The guarantee holds for races on basic, pointer, procedure and
   slice variables, and no others.** A race on a variant, or on a
   whole record or array copied at once, or calls of one container's
   procedures from two threads at once without a lock, is outside
   it: undefined, as in Go. Section 3 says so, and 7.6 is rewritten
   to say so.
3. **A safe way to start a thread.** `Thread.spawn(p, arg: ^U8)` becomes
   an `unsafe proc`. A generic `Task(T)` takes its place for safe
   modules:

   ```
   module Task(T);
   proc spawn*(p: proc(var x: T); keep x: T): (^Thread.Thread, ERROR);
   ```

   `x` is copied into the new thread's stack before `spawn` returns.
   Its references must be lasting (`keep`), so a thread never holds
   a slice of its spawner's frame.
4. **Atomics take a variable.** `CAS(x, old, new)`, `XCHG(x, v)` and
   `XADD(x, k)` take a variable, as `INC` does; through a pointer, `XADD(p^,
   1)`. A safe module can then use them, with no `ADR`.
5. **Counts are atomic where there are threads.** Part C's raise and
   lower are `lock xadd` in a program that imports `Thread`, so that two
   threads lending from one locked `Buf` keep its count right. A
   program without `Thread` gets the plain `inc` and `dec`.
6. **`Lock.Guarded(T)`**, a value with its lock, for sharing a
   container:

   ```
   g: Guarded(Names.Map);
   Guarded.with(g, addName);     (* addName(var m: Names.Map) runs under the lock *)
   ```

   It makes the safe pattern the easy one, as Rust's `Mutex<T>` does,
   though nothing stops a program from sharing a container without it.

### 9.3 Why not Rust's way

A static rule that a container can be reached from two threads only
under a lock needs, at the least, marks on types for what may cross
threads (`Send`) and be shared (`Sync`), and a way to see that module
variables are shared. Module variables are reachable from every thread,
and raz has no thread-local storage to put them in instead. It would
add a second type system to the language for a feature two
repositories out of eight use. Section 19 keeps it as a later step.

---

## 10. Part F: the small mends

### 10.1 An array a call returns lives to the end of its procedure

"Less that is undefined", piece 1. The temporary's slot in the frame is
reserved for the rest of the procedure, as a deferred statement's slots
already are, so `s := f('a')[0..4]` is lent by the frame, not by the
statement: defined until the procedure returns, and part B keeps it
from going further. In a loop the slot holds the latest call's array.
1.2's last program then prints `name-..a name-..b`, since each call has
a slot of its own.

The same for a `const` parameter's temporary (section 8): its slot is
reserved to the end of the procedure.

Cost: a frame bigger by each such call's array. That is not measured
here; in `src/`, arrays returned by calls are small (`Str.fromInt`'s
20 bytes, `Str.encode`'s 4), so the estimate is tens of bytes per
frame.

### 10.2 A string's bytes

"Less that is undefined", piece 2. Writing a string constant's bytes,
through a slice of it, either stops the program (a bad address, as now
on Linux, since constants are in read-only data) or changes the
constant for the rest of the run. Which one is the target's choice
(appendix A). Either is defined, and neither touches another
variable. A later `[]const U8` (PROPOSALS) would make it a compile-time
error.

### 10.3 Views

A view reading any variable's bytes as an integer type is safe: it
reveals an address, but it can't make one. Writing through a view of a
variable that holds a pointer, slice, procedure, variant, enumeration
or `BOOL` is fenced (5.1), since it would make one of those from
arbitrary bytes. Views of plain data, the survey's every use outside
`Rt`, stay safe.

### 10.4 `match` on a lent variant

A `match` on a variant whose case holds references gives names that
are lent as the variant is: a field of a local variant lent by the frame
is lent by the frame. Part B's rules follow.

---

## 11. Part G: a debugging heap

Unsafe modules are trusted, and trust must be tested. `Heap` gets a
second mode, chosen when the program starts (`RAZ_HEAP=debug` in the
environment, or `Heap.debug(true)` before the first allocation):

- every freed block is filled with `0DEH` and kept off the free lists
  for the next 1,024 frees (a quarantine), so a stale read sees junk
  and a stale write is found when the block leaves the quarantine and
  its bytes are checked;
- each block gets eight guard bytes after it, checked when it is freed;
- `Buf`, `Vec` and `Pool` fill a retired block with `0DEH` too, so a
  slice held across a growth reads junk in the debugging heap and the
  old bytes otherwise.

A break is reported as a failed check is: where, and the calls under
way. `make check` runs the library's tests and `test/run` in both modes.
This is Zig's debug allocator, glibc's `MALLOC_PERTURB_`, and Chrome's
MiraclePtr quarantine, without their reach. It costs nothing unless
chosen. It is the one part that changes no rule and could come first.

---

## 12. Raz beside other languages

| Language | Spatial | Temporal | Forged pointers | Races | Fence | What it costs |
|---|---|---|---|---|---|---|
| C | none | none | anything | UB | none | nothing |
| C++, hardened | hardened `std` containers; `-fbounds-safety` for C (clang) | none | anything | UB | none | a little |
| Zig | checked in Debug and ReleaseSafe | the debug allocator finds use after free and double frees at run time; nothing in release | `@ptrCast`, `@intToPtr` anywhere | UB | none, but builtins are visible | a check per index |
| Odin, Hare, C3 | checked | none | anywhere | UB | none | a check per index |
| Go | checked | a garbage collector | only through `unsafe` | a race on a multi-word value corrupts memory | `import "unsafe"` | a GC, write barriers, a runtime |
| Java, C# | checked | a garbage collector | none | references never tear; `long` may in Java | C#: `unsafe` blocks | a GC, a runtime |
| Swift | checked | reference counting; exclusivity checked at compile and run time | only through `Unsafe*` types | Swift 6: `Sendable`, checked | `Unsafe` in names | refcounting traffic |
| Rust | checked | the borrow checker, at compile time | only in `unsafe` | `Send`/`Sync`, at compile time | `unsafe` blocks and functions | lifetimes, learning, compile time |
| Ada, SPARK | checked | accessibility levels: an access can't outlive its object's level; `Unchecked_Deallocation` named as unsafe; SPARK adds ownership | `Unchecked_Conversion` | protected objects | the word "unchecked" | a check per index; some dynamic accessibility checks |
| Modula-3 | checked | a garbage collector for traced references; `DISPOSE` only in unsafe modules | only in `UNSAFE MODULE` | not promised | `UNSAFE MODULE`, `UNSAFE INTERFACE` | a GC |
| Oberon | checked | a garbage collector | only through `SYSTEM` | n/a | `IMPORT SYSTEM` | a GC |
| Vale | checked | generational references: each object carries a generation, each reference the one it expects, checked at each dereference; regions skip the check | none | regions | `unsafe` | wider references, a check per dereference |
| Cyclone | fat pointers | regions, checked statically | none | n/a | none | annotations, wider pointers |
| Fil-C, CHERI | every pointer carries its bounds (compiler or hardware) | Fil-C: a GC; CHERI: revocation | none | Fil-C: atomic capabilities | none | Fil-C: a few times slower; CHERI: hardware |
| **raz, proposed** | checked | lending checked at compile time; owners count lends at run time; no `free` in safe code; `Pool` handles checked | only in `unsafe;` modules | slices and words atomic; containers and variants under a lock or UB | `unsafe;` modules, `unsafe proc` | an add and a subtract per lend held; a compare per `Pool` access |

What raz takes from each:

- **From Modula-3:** the fence by module, and the trust in an unsafe
  module's safe interface. The unit of review is a file, as Wirth's
  languages always had it.
- **From Ada:** a static rule that a reference can't outlive its
  object's level, with no lifetime variables in types. Ada's
  accessibility levels are part B's frame, parameters and lasting
  memory, nearly exactly. Ada also names deallocation as unchecked.
- **From Rust:** `ret` is lifetime elision written out; `keep` is
  `'static`. What raz doesn't take is lifetimes in records, which is
  what lets Rust check `Http.Message` and what costs Rust its
  learning curve.
- **From Swift:** checking exclusivity at run time where the compiler
  can't, as part C counts lends.
- **From Go:** a slice held across a growth sees the old array; and an
  honest statement about races.
- **From Vale, `slotmap` and Zig's handle idiom:** generations,
  but in a container (`Pool`), not in every pointer, so that the 99% of
  pointers that are never freed pay nothing.
- **From Zig:** the debugging allocator as the first line of defence
  for unsafe code.

Where raz ends up: about as safe as Go or Modula-3 for a program that
uses no threads, with no garbage collector and no run time beyond a
count per lend; less expressive than Rust (no record may borrow); and
far simpler to learn and to compile.

---

## 13. Performance

All measurements are on the session's machine, 4 cores of an x86-64
virtual machine, using today's compiler. Wall-clock times are the
best of several runs; on this machine they vary by 10 to 20% between
runs, so where it matters instruction counts from `valgrind
--tool=callgrind` are given, which don't vary.

### 13.1 The compiler's speed

The largest cost of the proposal to `src/` itself would be checking the
scanner's buffer, if `Scan` stops being unsafe. To measure it, `Scan`'s
`buf: ^U8` was made a checked `[]U8` (with the sentinel inside its
length) and everything else left as it was. Five lines changed:

| Compile | Pointer (today) | Checked slice | More |
|---|---|---|---|
| `src/Raz.raz`, the compiler itself | 240,851,288 instructions | 251,595,933 | **+4.5%** |
| the generated benchmark, 58,025 lines | 40,305,841 | 42,519,299 | +5.5% |

`make bench`'s 348,025 lines compile in 625 to 660 ms here, about
530,000 to 557,000 lines a second; 5.5% more is about 500,000 to 528,000, inside the 400,000-line
floor and inside `make prev-bench`'s tenth. Most of the cost is the
scanner's inner loops, `while (c = ' ') ... c := buf[p]`, checking
each byte. Section 21 asks whether `Scan` stays unsafe instead,
leaving the compiler as fast as it is.

The other changes to `src/` (grown arrays to `Vec`, `intern(s)`, views)
cost nothing measurable: `Vec`'s access through `all` is a slice index,
which is the same check the hand-grown arrays don't have, on paths
much cooler than the scanner's.

The compiler's own checks (part B, C, the fence) are flags on items
and modules and run while each expression is compiled: no measurable
compile time.

### 13.2 Kernels

`MemBench.raz` and `GenBench.raz` (appendix 2):

| Kernel | Run 1 | Run 2 | What it shows |
|---|---|---|---|
| chase a 1,000,000-node list (16-byte nodes), raw pointers | 8,312 ms | 7,515 ms | the baseline |
| the same through `Pool`-style handles (32-byte slots, index and generation checked) | 12,336 ms | 11,992 ms | **1.5–1.6×**: half of it the larger slot |
| chase a 1,000-node list (in L1), raw pointers | 857 ms | 810 ms | |
| the same through handles | 1,631 ms | 1,643 ms | **1.9–2.0×**: the checks themselves |
| chase 1,000,000 32-byte nodes, raw pointers | 14,001 ms | 13,725 ms | the larger node alone, against row 1: **+70–85%** |
| the same through fat (address, generation) pointers, generation in the node | 8,672 ms | 10,145 ms | the check is free here: in the node's own cache line |
| 1,000 32-byte nodes, raw | 870 ms | 917 ms | |
| 1,000 32-byte nodes, fat pointers | 830 ms | 1,047 ms | within noise to +15% |
| sum 16,000,000 bytes through `^U8`, 50 times | 305 ms | 342 ms | |
| the same through a checked `[]U8` | 271 ms | 434 ms | within noise: the check hides behind the loads |
| sum 4,000 bytes (in L1), 200,000 times, `^U8` | 261 ms | 265 ms | |
| the same, checked `[]U8` | 256 ms | 306 ms | 0–15% |

What they say:

- **Bounds checks are cheap.** On sequential access the check is
  hidden by the loads it guards. This is why nobody uses `check off;`.
- **A generation check is cheap when it is in the object's cache line**
  (the fat-pointer rows). **Wider references are not cheap:** doubling a
  node from 16 to 32 bytes costs 70 to 85% when the structure doesn't fit
  in the caches. This is the main argument against making every `^T`
  a fat generational pointer (section 19). It is also why `Pool`'s
  handles cost half again: the 32-byte slots, not the check.
- **Handles cost 1.5–2× where pointer chasing dominates**, which is
  linked lists and trees. A safe program pays it only for the records
  it frees one by one; everything else stays a lasting `^T` with no
  check.

### 13.3 What each part costs a program

| Part | Cost | Where |
|---|---|---|
| A, the fence | none | compile time |
| B, lending | none | compile time |
| C, counts | `inc`/`dec` per lend held, or `lock xadd` with threads; a word per holding local | once per `Buf.bytes`, `Vec.all`, `Vec.add`: not per element |
| C, retired blocks | memory: at most the current block again, only while a lend is held across a growth | rare |
| D, no `free` | none for lasting pointers; handles where chosen, 1.5–2× on chasing | `Pool` users only |
| E, atomic slices | none: two 8-byte moves become one 16-byte one; records holding slices may grow by padding to 16 | `src/` has 10 such fields |
| E, atomic counts | about 20 cycles per lend, with threads only | |
| F, temporaries | frame size | |
| G, the debugging heap | none unless chosen | |

---

## 14. Ergonomics

### 14.1 What doesn't change

Most raz is already safe under this proposal: the survey's `Parse`,
`Item`, `Sym` and `Gen`, `tools/`, rjson's parser, rflate's inflater,
rterm. They use records, slices, `var`, `const` and pointers from
`NEW`, and they don't free. For them the change is a few `ret`s in the
library's headings, which the caller never writes.

### 14.2 What a programmer meets

**A slice of a buffer kept in a record.** rnet's `Http.Message` keeps
`headers[i].name` as slices of `m^.head`'s bytes and `body` as a slice
of `m^.data`. Under part B and C these are lent by owners and can't be
stored in a record. The choices:

1. Offsets instead of slices:

   ```
   Header* = record name, value: Span; end;     (* Span = record at, len: INT; end *)
   proc name*(ret const m: Message; i: INT): []U8;   (* m^.head's bytes, lent by m *)
   ```

   which is safe, a little longer, and survives `m^.head` growing. It
   is how Rust programs without lifetimes in structs do it.
2. `Http` says `unsafe;`, and keeps its invariant by hand, as it does
   today. It becomes one of the modules a reviewer reads twice.

The proposal recommends the first for libraries, since it is what
the guarantee is for.

**A slice held across a call that might change its owner.** This is
allowed. Part C counts it, and the owner retires instead of freeing.
rmacs's `save`, with its `path := Buf.bytes(x^.path)` held across
`Buf.reset(tmp)` and `Buf.str(tmp, path)`, compiles and runs as
before.

**`done` with a slice still held.** This stops the program at run time:

```
proc report(x: ^Buffer);
var name: []U8;
begin
    name := Buf.bytes(x^.name);
    Buf.done(x^.name);          (* stops: name still holds a lend *)
    ...
end;
```

The cure is `name := []` before `done`, or not holding it. It is a
false alarm only when `name` is never read again. Since a stop is
loud and the cure is one line, the proposal accepts it.

**Owners can't be copied.** `head := m^.head` in rnet becomes
`Buf.take(m^.head, head)`. The survey didn't count such copies; rnet's
`Http.reset` is the one found by reading.

**Records that come and go.** An editor's windows, freed when closed,
become a `Pool(Window)` with `Handle`s where rmacs had `^Window` and
`Mem.free`. Each access is `Windows.at(pool, h)^.field` or `get`. This is
longer than `w^.field`, and 1.5–2× slower in a pointer-chasing loop,
which an editor doesn't have.

**An arena with links.** A tree built in an arena with `^Node` links
can't be safe (8.4): links are stored in records, and lent pointers
can't be. It becomes indexes into a `Vec(Node)`, which is often faster
(smaller, contiguous), or stays in an unsafe module.

**Strings that must be freed.** `Str.copy` and `Str.free` become
`Names(V)` or a `Buf` per string (8.3).

**Threads.** `Thread.spawn(work, ^U8(ADR(job)))` becomes
`Jobs.spawn(work, job)`, with `import Jobs := Task(Job)`. That is
shorter.

### 14.3 What the compiler says

Each new error names the rule and the mending, in the house style:

```
error: ADR is for unsafe modules
    help: pass x as a var parameter, or say "unsafe;" after the module's imports
error: Names.put keeps its key, and buf[0..8] is lent by this call's frame
    help: give put a copy that lasts: Str.copy(Heap.heap, buf[0..8])
error: Buf.bytes(b) is lent by b, which counts what it lends: hold it in a slice variable
error: a Buf.Buf owns memory, and can't be copied
    help: Buf.take(from, to) moves it
error: Str.trim(s) is lent by s, which isn't marked ret
    help: mark the parameter "ret s: []U8" to return what points into it
error: Mem.free is an unsafe procedure
    help: free through the container that owns the memory, or say "unsafe;"
```

and two new run-time stops:

```
Buf.done while 1 slice it lent is still held
Pool.get: a stale handle (slot 4, generation 3; the slot is at 5)
```

---

## 15. What breaks

Everything breaks that uses a fenced operation in a module that
doesn't say `unsafe;`, or stores a lent reference, or copies an
owner. By codebase:

| Code | What breaks | The mending |
|---|---|---|
| `lib/` | every module with a fenced operation: `Rt`, `Mem`, `Heap`, `Arena`, `Bytes`, `Sys`, `Thread`, `Lock`, `C`, `CAbi`, `Buf`, `Vec`, `Map`, `List` | `unsafe;` |
| | `Str`, `Fmt`, `Opt`, `Files` | drop two to five operations each; they become safe |
| | headings: `ret` on `Str.trim`, `trimLeft`, `trimRight`, `cut`, `field`, `Buf.bytes`, `spare`, `Vec.all`, `add`, `Sys.nextEntry`; `keep` on `Map.put`, `List.push`, `Vec.push`, `tryPush`, `Opt.init`, `scope` | marks |
| | `Buf`, `Vec`, `Map`, `List`, `Arena`: a `LENDS` field, retiring, `done`'s stop, `take`, `swap` | about 15 lines each |
| | new: `Pool`, `Task`, `Names`, `Lock.Guarded`, `Arena.allocator`; `Heap`'s debugging mode | about 400 lines in all |
| | `unsafe proc`: `Mem.free`, `Mem.unmap`, `Heap`'s `free`, `Str.free`, `Sys.mmap`, `Sys.munmap`, `Thread.spawn`, the `Sys` calls that take a raw pointer; `Mem.Allocator`'s fields | a word each |
| `src/` | all eleven modules (section 2.2) | grown arrays to `Vec` (35 sites), `intern(s)` (7), views (6), `var` (6), `Sys.info` (1); `Scan` stays `unsafe;` |
| `tools/` | nothing fenced; any `Map.put` of a frame slice | none found |
| `examples/` | `Args`, `Cpu`, `Pthreads`, `Printf`, `Window`, `Volatile`, `Sh`, `Workers` | `Args`, `Sh`, `Workers` mended; the other five say `unsafe;`, as examples of it |
| `test/run`, `test/libc`, `conform/` | the tests of `ADR`, pointers, C | `unsafe;` in each; new tests in `conform/` for the guarantee: what is an error, and what stops |
| rnet | `Http.Message` keeps lent slices; `reset` copies `Buf`s; `Thread.spawn` | spans and accessors; `take`; `Task` |
| rjson | `Str.free` and `Mem.free` (6); a few casts | `Names` or `Buf`; views |
| rflate | none beyond `ADR` at calls (gone with v0.19.0's library) | none |
| rsqlite | C | `unsafe;` on `Sqlite` |
| rmacs, ravite | `ADR` at calls (gone with v0.19.0); `Mem.free` (9 and 2) of windows and buffers | `Pool` |
| rlX11 | casts on X11 replies | views; one unsafe module for the socket's bytes |
| rmacs's and ravite's `Scan` use | `tools/Scan.raz` | nothing fenced |

Every break is found when compiling, with a message that names its
mending, except a `done` while a lend is held, which shows up at run
time with a message. No program changes meaning without an error.

A `raz -fix` (or `tools/Mutate.raz` taught the rewrites) can make
the mechanical ones: `ADR(x)` at a `var` parameter, `^F64(ADR(x))` to
a view, `intern(ADR(s[0]), LEN(s))` to `intern(s)`, `unsafe;` where a
module keeps a fenced operation after those.

---

## 16. Changes to the report

The report grows by about three pages, from 32 to 35, inside its
40. By section:

**1. A first look.** One paragraph: what is safe, what `unsafe;`
means, where to read more.

**3. Modules.** The grammar takes the line:

```
Module = "module" ident [ "(" ModParams ")" ] ";"
         { Import } { Link } [ Check ] [ Unsafe ] { Declaration }
         [ "begin" Statements ] "end" ident "." .
Unsafe = "unsafe" ";" .
```

A new paragraph, **`unsafe;`**, says what it allows (the table of
5.1), and that `link` and `check off;` need it. **Generic modules**:
an instance is safe or unsafe as its generic module is, as with
`check`.

**5.3 Slices.** "A slice is aligned to twice an address's
alignment, and read and written in one access (7.6)."

**5.4 Pointers.** A paragraph: in a safe module a pointer is `nil`,
from `NEW`, or from the library; section 8.x says how long it lives.

**5.5 Records.** **Owners**: a record with a `LENDS` field; it can't
be copied in a safe module (7.6 of this proposal). `LENDS` joins the
basic types in 5.1, as a type only a record's field may have.

**5.9 Procedure types.** `unsafe proc`, and the marks `ret` and `keep`,
which a procedure type carries; what may stand where (PROPOSALS).

**6.4 Pointers.** `p + i`, `p - i`, `p[i]` and `p[lo..hi]`: "only in an
unsafe module".

**6.7 Conversions.** The pointer rows: "only in an unsafe module".

**6.8 Built-in procedures.** `ADR`, `PTR`, `SYSCALL` and `ARGV`: "only in
an unsafe module". `NEW` (part D): what it gives lasts, or is lent by
its allocator's owner. `CAS`, `XCHG` and `XADD` take a variable.

**6.9 Views.** Writing a view of a variable that holds a pointer,
slice, procedure, variant, enumeration or `BOOL`, and a view as a
pointer type, are for unsafe modules.

**7.3 Return.** The paragraph on slices of the frame is replaced by a
reference to the new section 8.x, which covers every route.

**7.6 Volatile.** "Nothing else of the program becomes undefined by
it" becomes: a race on a variable of a basic, pointer, procedure or
slice type gives a value it had or was given, never a mixture; a race
on anything else, or on a container's procedures called at once, is
outside the guarantee (10).

**8. Procedures.** The marks `ret` and `keep` in the grammar,
`Params = [ "ret" ] [ "keep" ] [ "var" | "const" ] ...`, and
`ProcDeclaration` takes `[ "unsafe" ]` before `proc`. A new section,
**8.x Lending**, about two pages, with part B's rules (lasting,
lent, by whom; what may be done with each) and part C's counting,
and the examples of 6.4 of this proposal. An array a call returns, and a
`const` parameter's temporary, live to the end of the procedure
(part F). The paragraph "kept past its statement ... the exception of
section 10" goes.

**9. Calling C.** "`extern` and `link` only in an unsafe module."

**10. Programs.** **Defined behaviour** becomes **The guarantee**
(section 3), and the list of exceptions shrinks to one sentence: an
unsafe module, a code procedure and C may break memory, and what
follows isn't defined; a safe program can't. The stops stay as they
are, and the two new run-time stops are added: an owner's `done` with
lends held, and a library container's own checks (a stale handle). **Errors**: a
fenced operation outside an unsafe module, a lent value where it can't
go, a copied owner, a call of an `unsafe proc` from a safe module.

**Appendix A.** How slices are made one access (16-byte moves, or a
lock, or a refused target); whether writing a string constant stops or
changes it; how the debugging heap is chosen.

**Appendix B.** The grammar's new lines.

**The library volume.** `unsafe proc` and `ret`/`keep` in every
heading; `Pool`, `Task`, `Names`, `Lock.Guarded`; owners' `take`,
`swap` and their stop; `Heap`'s debugging mode. `Mem.Allocator`
described as an unsafe interface. Which modules are unsafe, and their
promise.

**`doc/report-history.md`**, **`doc/compiler.md`** (each rule, where in
the compiler, with code before and after), **raz(7)**, the tutorial and
`STANDARDS.md` ("a parameter is a value, `var`, `const`, or `keep`; a
pointer only in an unsafe module or where `NEW` gave it").

---

## 17. Changes to the library

| Module | Change |
|---|---|
| `Mem` | `Allocator`'s fields `unsafe proc`; `free`, `unmap`, `pages` `unsafe proc`s |
| `Heap` | `free` unsafe; the debugging mode (part G); big blocks' address ranges kept reserved after `free` in debugging mode |
| `Arena` | an owner; `allocator(ret var ar)`; `reset` and `done` stop if lends are held |
| `Buf` | an owner; `bytes`, `spare` `ret`; retiring; `done` stops; `take`, `swap` |
| `Vec` | an owner; `all`, `add`, `tryAdd` `ret`; `push`, `tryPush` `keep x`; retiring; `done` stops; `take`, `swap` |
| `Map` | an owner (it counts no lends, but isn't copied); `put` `keep k`, `keep v` |
| `List` | an owner; `push` `keep v` |
| `Str` | `trim`, `trimLeft`, `trimRight`, `cut`, `field` `ret`; `free` unsafe; `copy` documented as lasting; safe module |
| `Fmt`, `Opt`, `Files` | made safe; `Opt.init`, `scope` `keep` |
| `Sys` | the raw-pointer calls `unsafe proc`; `nextEntry` `ret`; the rest safe to call |
| `Thread` | `spawn` unsafe; `Mutex` taken by `var`, as now |
| `Lock` | `Guarded(T)` |
| new `Pool(T)` | 8.2 |
| new `Task(T)` | 9.2 |
| new `Names(V)` | 8.3 |

---

## 18. Changes to the compiler

Where each part goes in `src/`, and about how big each is. The
budget is 14,000 lines of code and the compiler is about 11,500 today.

| Part | Where | Lines |
|---|---|---|
| A. The fence | a flag on the module, set by `unsafe;` in `Parse`; a check at each place the survey's counting build hooked (`Item.index`, `slice`, `op2`, `convert`, `view`, `indexView`; `Parse`'s `ADR`, `PTR`, `SYSCALL`) and at `ARGV`, `extern`, `link`, `check` and code procedures; `unsafe proc` on `Obj` and on procedure types | 120 |
| B. Lending | PROPOSALS' estimate: a set of lenders on each `Item` in place of today's `frame: BOOL` (`Item.raz:58`), the same on each local, the checks, the list that waits for `end`; plus pointers followed as slices are | 300–450 |
| C. Owners | `LENDS` as a type; `Sym`'s owner flag; the hold slots, the raise and lower in `Gen`, the let-go in the epilogue (reusing `defer`'s); the copy checks | 200 |
| D. `NEW`'s provenance | lasting or lent by its allocator | 20 |
| E. Atomic slices | 16-byte alignment in `Sym`, `movdqa` in `X64`'s slice moves; atomics taking variables; `lock xadd` counts when `Thread` is imported | 80 |
| F. Temporaries | the slot reserved to the end, as `defer`'s are | 20 |
| Messages, with help | | 100 |
| **In all** | | **840–990** |

So the compiler grows to about 12,400–12,500 lines, inside the budget,
with room for the documentation the house style demands. The
rewrite of `src/` to be safe (section 15) takes lines away: 35 grown
arrays made `Vec`s.

Each rule is explained in `doc/compiler.md` where it is done, with the
code before and after, as CLAUDE.md asks.

---

## 19. Alternatives considered

**A garbage collector.** It would make `free` and part C unneeded, as in
Go, Java and Oberon. It is rejected: raz promises "a static executable
with no run time besides the code it uses" (10). A collector needs
stack maps, barriers or pauses, and a heap the language owns, and it
would end raz as a systems language with a C-like footprint.

**Rust's borrow checker.** It closes everything, races included, at
compile time. It is rejected for raz: lifetimes in types, regions
inferred over whole procedures (non-lexical lifetimes are a fixpoint
over the control flow, not one pass), and a learning curve that is
the opposite of "a beginner can follow". The proposal takes from it
`ret` (elision, written) and `keep` (`'static`), and leaves out
lifetimes in records, knowing what that costs (14.2).

**Fat generational pointers for every `^T`** (Vale). Every `^T` would
become (address, generation), and `free` would be safe and checked at
every dereference. Measured (13.2): the check costs little, since the
generation sits in the object's cache line, but doubling a pointer
cost 70–85% on a structure past the caches. Records with pointers grow,
C interop needs a second, raw pointer type, and the 1,015 dereferences
in `src/`, of memory never freed, would pay for a check they can't fail.
It is kept as a fallback if part D proves too narrow: `Pool` is the
same mechanism, where it is paid for only by what is freed.

**Statically killing a lent slice when its owner changes.** One-pass
flow analysis can't see a loop's back edge, and through a pointer
every call may change the owner (7.1). It would need a second pass, or
a rule so strict ("a lent slice dies at the end of its statement")
that `s := Buf.bytes(b)` over several lines, 35 places in the survey,
would all break.

**Stop on growth while lent, instead of retiring.** It is simpler to
explain, and it finds the stale-pointer bug in 1.2 at once. But it also
stops `Buf.str(b, Buf.bytes(b))`, which is right and common in other
languages (Go's `append(s, s...)`). Retiring keeps right programs
running, and the debugging heap (part G) shows the stale ones.

**Thread-local module variables, or `Send`/`Sync`.** They are needed
for a static race guarantee. They are left for later (9.3): they
cost a second type system for a feature little used. If they come,
part E's statement grows to cover every program, and nothing else in
this proposal changes.

**Hardware: memory tagging (ARM MTE) and CHERI.** They catch use
after free and out-of-bounds by tagging memory and pointers. They
help unsafe modules and C, they aren't on x86-64, and they are
probabilistic (MTE's four bits). They would make part G stronger,
not replace B to D.

**Only the fence (PROPOSALS' piece 4).** It is cheap and gives a list
of modules to audit, but what it leaves undefined in safe code is
exactly 1.2's first four programs. A fence around code that is still
unsafe would mislead the reader. That is why this proposal exists.

---

## 20. Order of work

Each step is a release, and each leaves `make check` passing and every
program building, with warnings where a later step will make errors.

1. **The debugging heap (G).** It changes no rule, and finds bugs in
   today's code, the library's above all, before the rules arrive.
   Run `make check` under it.
2. **Temporaries to the end of the procedure (F.1), strings (F.2).**
   No program breaks.
3. **Atomic slices, and 7.6 rewritten (E.1, E.2).** No program breaks.
4. **`ret` and `keep` (B), as warnings,** then errors a release later.
   Mark the library. This is PROPOSALS' part 3, extended to
   pointers.
5. **Owners (C).** `LENDS` in the containers, retiring, counting,
   `take` and `swap`; the copy check as a warning, then an error.
6. **The heap (D).** `Pool`, `Names`, `Task`; `free` an `unsafe
   proc`, warned of first.
7. **The fence (A),** last, as a warning for one release, then an
   error, once everything it would flag has a safe form. `src/` comes
   to it, keeping `Scan` unsafe, or not, by the owner's word (21).
8. **The report's guarantee (section 10),** stated when step 7 makes
   it true.

`src/` must build with the release `BOOT` names, so it takes up each
step one release after the step ships.

---

## 21. Open questions

1. **Does `Scan` stay unsafe?** Checking its buffer costs the
   compiler 4.5% (13.1). Leaving it unsafe keeps the speed, and the
   compiler then has one unsafe module, which is easy to read.
2. **`LENDS` as a type, or a mark on the record** (`owner record`)?
   The field makes the count visible to the module that reads it, and
   needs no new word; a mark would be more explicit.
3. **Should `done` with a lend held leak instead of stopping?** It
   would mean no false alarms, but a silent leak that can grow.
4. **Is a local record holding an owner-lent slice worth allowing?**
   (7.3 forbids it.) It needs one hold per reference in the record, and
   a let-go when the record is reassigned. `Fmt.Arg` arrays are the
   case: `[Fmt.str(Buf.bytes(b))]` is fine inside a statement, but not
   held in a local array.
5. **Is the race guarantee enough?** A cheap dynamic check would close
   the container case in programs with threads: each owner records
   the thread that last changed it, and changes from another thread
   without the lock stop the program, as Swift's exclusivity checks do.
6. **`Pool`'s handle**: two words, or one, with 40 bits of index and 24
   of generation? One word fits in a register and halves `Pool`'s
   memory for handles, and generations would wrap after 16 million
   frees of one slot.
7. **`unsafe` per procedure, not per module?** Rust's `unsafe` blocks
   are finer. A module is raz's unit of review, and a module can be
   split, but `Sys` would need a split into a safe and an unsafe half
   for readers to see the difference.

---

## Appendix 1: the survey's numbers

Places of each operation, counted once each, by the instrumented
compiler. `deref` and `new` are shown for scale; they stay safe, as
does `p - q`, which the module table below counts with the rest.

| Code | `ADR` | deref | `p[i]` | `p[a..b]` | `p ± i` | `p - q` | ptr cast | int→ptr | ptr→int | view | `NEW` | `SYSCALL` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| raz `src/` | 27 | 1,015 | 277 | 30 | 3 | 0 | 42 | 0 | 0 | 0 | 5 | 3 |
| raz `lib/` | 144 | 93 | 88 | 14 | 49 | 2 | 52 | 13 | 4 | 2 | 1 | 140 |
| raz `examples/` | 15 | 46 | 2 | 1 | 0 | 0 | 5 | 0 | 0 | 3 | 1 | 0 |
| raz `test/libc` | 110 | 15 | 35 | 11 | 18 | 0 | 64 | 1 | 6 | 0 | 1 | 0 |
| rnet | 471 | 359 | 0 | 0 | 0 | 0 | 9 | 1 | 1 | 0 | 0 | 0 |
| rjson | 91 | 105 | 0 | 7 | 1 | 0 | 13 | 0 | 0 | 0 | 0 | 0 |
| rflate | 61 | 102 | 0 | 0 | 0 | 0 | 7 | 0 | 0 | 0 | 2 | 0 |
| rsqlite | 38 | 12 | 1 | 3 | 0 | 0 | 2 | 0 | 1 | 0 | 0 | 0 |

The fenced operations of each module of `src/` and `lib/`:

| Module | Fenced | Of which |
|---|---|---|
| `src/Scan` | 99 | `p[i]` 76, casts 12, `p[a..b]` 6, `ADR` 3, `p ± i` 2 |
| `src/Link` | 71 | `p[i]` 63, `p[a..b]` 4, casts 4 |
| `src/Chunk` | 65 | `p[i]` 53, casts 10, `p[a..b]` 1, `ADR` 1 |
| `src/X64` | 31 | `p[i]` 23, `ADR` 5, casts 3 |
| `src/Diag` | 23 | `p[i]` 15, `p[a..b]` 3, casts 3, `ADR` 2 |
| `src/Elf` | 23 | `p[i]` 17, `p[a..b]` 3, `ADR` 3 |
| `src/Parse` | 21 | `p[a..b]` 8, `ADR` 5, `p[i]` 5, casts 2, `SYSCALL` 1 |
| `src/Sym` | 17 | `p[i]` 12, casts 3, `ADR` 2 |
| `src/Item` | 16 | `p[i]` 5, `p[a..b]` 4, casts 4, `ADR` 3 |
| `src/Gen` | 8 | `p[i]` 5, `ADR` 2, casts 1 |
| `src/Raz` | 8 | `p[i]` 3, `SYSCALL` 2, `ADR` 1, `p[a..b]` 1, `p ± i` 1 |
| `lib/Sys` | 287 | `SYSCALL` 129, `ADR` 98, `p[i]` 31, casts 12, `p ± i` 8, `p[a..b]` 6 |
| `lib/Rt` | 111 | `p ± i` 32, `p[i]` 31, casts 20, `ADR` 10, int→ptr 10, `SYSCALL` 6 |
| `lib/Thread` | 33 | `ADR` 16, casts 6, `SYSCALL` 5, `p[i]` 3, `p ± i` 3 |
| `lib/Map` | 19 | `p[i]` 16, casts 3 |
| `lib/Heap` | 16 | `p ± i` 4, casts 4, ptr→int 4, `p[i]` 2 |
| `lib/Bytes` | 10 | `ADR` 5, casts 5 |
| `lib/Buf` | 6 | `p[a..b]` 4, `p[i]` 1, `ADR` 1 |
| `lib/Opt` | 5 | `ADR` 5 |
| `lib/Arena` | 4 | `p ± i` 2, `ADR` 1, cast 1 |
| `lib/Fmt` | 4 | `ADR` 4 |
| `lib/Files`, `lib/Str` | 3 each | |
| `lib/Lock`, `lib/Mem` | 2 each | |
| `lib/List` | 1 | |
| `lib/Math`, `Out`, `Sort`, `Width` | 0 | |

`Vec` (generic, and instantiated by no program surveyed) has 11 by
`grep`. `C` and `CAbi` are `extern` declarations (96 and 2).

By `grep`, for the code today's compiler refuses (written before
`INT`):

| Code | Lines of code | `ADR` | at a call | casts | frees | `done` | `reset` |
|---|---|---|---|---|---|---|---|
| rmacs | 4,323 | 560 | 556 | 9 | 9 | 16 | 66 |
| ravite | 2,185 | 202 | 200 | 3 | 2 | 1 | 15 |
| rlX11 | 5,226 | 89 | 87 | 3 | 1 | 0 | 0 |

## Appendix 2: the benchmarks

Built with `raz -o MemBench MemBench.raz` and run as they are. Both
are in the session's scratch space and can be added to `test/bench`
if the proposal goes ahead.

```
module MemBench;
import Out, Sys;

const
    Big = 1000000;      (* past the caches *)
    Small = 1000;       (* in L1 *)
    Bytes = 16000000;

type
    Node = record next: ^Node; val: INT; end;
    H = record i: INT; gen: INT; end;
    Slot = record next: H; val: INT; gen: INT; end;

var
    nodes: [Big]Node;
    slots: [Big]Slot;
    perm: [Big]INT;
    bytes: [Bytes]U8;
    sink: INT;

(* A random cycle through the first n nodes, the same in both arrays *)
proc build(n: INT);
var i, j, t: INT; seed: U64;
begin
    seed := 7;
    for i := 0 to n - 1 do perm[i] := i; end;
    for i := n - 1 to 1 by -1 do
        seed := seed * 6364136223846793005 + 1442695040888963407;
        j := INT(seed shr 33) mod (i + 1);
        t := perm[i]; perm[i] := perm[j]; perm[j] := t;
    end;
    for i := 0 to n - 1 do
        j := perm[(i + 1) mod n];
        nodes[perm[i]] := {next: ADR(nodes[j]), val: i};
        slots[perm[i]] := {next: {i: j, gen: 3}, val: i, gen: 3};
    end;
end;

proc chasePtr(steps: INT): INT;
var p: ^Node; s, k: INT;
begin
    p := ADR(nodes[perm[0]]);
    for k := 1 to steps do s := s + p^.val; p := p^.next; end;
    return s;
end;

(* As a checked Pool.get would: the generation, and the index *)
proc chaseHandle(steps: INT): INT;
var h: H; s, k: INT;
begin
    h := {i: perm[0], gen: 3};
    for k := 1 to steps do
        if slots[h.i].gen # h.gen then Sys.exit(3); end;
        s := s + slots[h.i].val;
        h := slots[h.i].next;
    end;
    return s;
end;

proc sumPtr(p: ^U8; n, reps: INT): INT;
var s, i, r: INT;
begin
    for r := 1 to reps do
        for i := 0 to n - 1 do s := s + INT(p[i]); end;
    end;
    return s;
end;

proc sumSlice(b: []U8; reps: INT): INT;
var s, i, r: INT;
begin
    for r := 1 to reps do
        for i := 0 to LEN(b) - 1 do s := s + INT(b[i]); end;
    end;
    return s;
end;
```

`main` builds `Big`, times each chase for 100,000,000 steps, builds
`Small`, times each for 500,000,000, then the sums: 16,000,000 bytes 50
times and 4,000 bytes 200,000 times. `GenBench.raz` is the same chase
with 32-byte records on both sides:

```
type
    Node = record next: ^Node; val, pad1, pad2: INT; end;
    GP = record p: ^GNode; gen: INT; end;
    GNode = record gen: INT; next: GP; val: INT; end;

proc chaseGen(steps: INT): INT;
var g: GP; s, k: INT;
begin
    g := {p: ADR(gnodes[perm[0]]), gen: 5};
    for k := 1 to steps do
        if g.p^.gen # g.gen then Sys.exit(3); end;
        s := s + g.p^.val;
        g := g.p^.next;
    end;
    return s;
end;
```

The compiler's instruction counts: `valgrind --tool=callgrind raz -I src
-I build/src -o /dev/null src/Raz.raz`, the same compiler built twice
from `src/`, once with `Scan.State.buf: ^U8` and once with `[]U8`. The
five lines changed were the field's type, `grab(n + 1)[0..n + 1]`,
`Diag.addFile(path, PTR(cur.buf), n)`, the local `buf` in `next`, and
`intern(PTR(buf) + start, p - start)`. The second compiler builds
itself.

## Appendix 3: the five programs of section 1

```
module SelfAppend;
import Buf, Heap, Out;

proc main*;
var b: Buf.Buf; i: INT;
begin
    Buf.init(b, Heap.heap);
    for i := 1 to 64 do Buf.add(b, 'a'); end;    (* full: 64 of 64 *)
    Buf.str(b, Buf.bytes(b));                    (* doubles it: or should *)
    Out.str(Buf.bytes(b)[56..80]); Out.ln;
end;

end SelfAppend.
```

Prints `aaaaaaaaaaaaaaaaaaaaaaaa`, status 0: right, by luck.

```
module Stale;
import Vec := Vec(INT), Heap, Out;

proc main*;
var v: Vec.Vec; first: []INT; i: INT; p: ^INT;
begin
    Vec.init(v, Heap.heap);
    for i := 1 to 16 do Vec.push(v, i); end;
    first := Vec.all(v);        (* good until v next grows *)
    p := Vec.add(v);            (* grows: first now points at freed memory *)
    p^ := 99;
    for i := 0 to 15 do Vec.push(v, 1000 + i); end;    (* grows again: p is stale *)
    p^ := -1;                   (* writes into a block the heap has taken back *)
    Out.int(first[0]); Out.str(" "); Out.int(first[1]); Out.ln;
end;

end Stale.
```

Prints `1 2`, status 0: it read and wrote freed memory, and looks right.

```
module Escape;
import Out;

type Hex = [16]U8;

proc head(var h: Hex): []U8;
begin
    return h[0..8];             (* allowed: h is the caller's *)
end;

proc short: []U8;
var h: Hex; i: INT;
begin
    for i := 0 to 15 do h[i] := 'x'; end;
    return head(h);             (* a slice of short's frame: not caught *)
end;

proc noise;
var junk: [64]U8; i: INT;
begin
    for i := 0 to 63 do junk[i] := '#'; end;
end;

proc main*;
var s: []U8;
begin
    s := short();
    noise;
    Out.str(s); Out.ln;
end;

end Escape.
```

Prints `########`, status 0: `noise`'s bytes, read through a slice of
a dead frame.

```
module Kept;
import Names := Map([]U8, INT, Str.hash, Str.eq), Str, Heap, Out;

var table: Names.Map;

proc remember(n: INT);
var buf: [8]U8;
begin
    buf := "name-000";
    buf[7] := U8('0' + n);
    _ := Names.put(table, buf[0..8], n);    (* the map keeps a slice of this frame *)
end;

proc main*;
var v: INT; ok: BOOL;
begin
    Names.init(table, Heap.heap);
    remember(1);
    remember(2);
    v, ok := Names.get(table, "name-001");
    Out.str("name-001: "); if ok then Out.int(v); else Out.str("missing"); end; Out.ln;
    v, ok := Names.get(table, "name-002");
    Out.str("name-002: "); if ok then Out.int(v); else Out.str("missing"); end; Out.ln;
end;

end Kept.
```

Prints `name-001: missing` and `name-002: missing`, status 0.

```
module Temp;
import Out;

type Name = [8]U8;

proc named(c: U8): Name;
var n: Name;
begin
    n := "name-..."; n[7] := c;
    return n;
end;

proc main*;
var a, b: []U8;
begin
    a := named('a')[0..8];      (* the array lives to the end of the statement *)
    b := named('b')[0..8];
    Out.str(a); Out.str(" "); Out.str(b); Out.ln;
end;

end Temp.
```

Prints `name-..b`, a space and eight bytes of junk, status 0.
