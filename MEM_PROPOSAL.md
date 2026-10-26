# MEM_PROPOSAL: a memory-safe raz

**Status.** A proposal, drafted 2026-10-17. Reviewed whole by the owner on 2026-10-26: `PLAN.md` §2 says what goes in (F.1, `[]const T`, G, E.4, `Task`, `Guarded`, the fence as `import SYSTEM`) and what is left out (B, C, D, the rest of E).
Nothing in it is built. Four adversarial reviews, made the same day,
are appendices 4 to 7. They find real holes in the guarantee
(appendix 4), wrong and imprecise claims about other languages and
hardware (5), wrong counts and unsupported benchmark conclusions (6),
and pain in real code that sections 14 and 15 understate (7). The body
below is as first drafted; where an appendix contradicts it, the
appendix stands until the body is revised. It assumes that anything may change: the
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
- Appendix 4: adversarial review, soundness
- Appendix 5: adversarial review, claims about other languages and hardware
- Appendix 6: adversarial review, the proposal's numbers and samples
- Appendix 7: adversarial review, porting real code

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

---

## Appendix 4: adversarial review, soundness

This appendix tests section 3's promise against parts A to F, read as
written. It finds 12 ways a program of safe modules and the library, as
section 17 would change it, still breaks the guarantee; 7 ambiguities
or contradictions; and 3 problems with checking or building the rules
in one pass. Two of the breaks are in today's language too, and the
proposal leaves them as they are: a variant changed while `match` names
its fields, and an `ERROR` written through a view. Both were run with
today's compiler. The rest follow from the text of the proposal.

### Breaks the guarantee

**1. A variant changed under its `match`.**

```
type V = variant ptr(p: ^INT); num(n: INT); end;
var v: V;                                   (* a module variable *)
proc flip(a: INT); begin v := num(a); end;
...
v := ptr(q);
match v of
| ptr(p): flip(h.(INT) + 8); p^ := 1000000;  (* p reads num's bytes as a pointer *)
| num(_n):
end;
```

Run today, this sets the length of a heap slice, `h^.s`, to 1,000,000.
Every operation in it stays safe under 5.1: the view only reads a
pointer's bytes as an integer (10.3), and that is allowed. 7.4 says the
names stand for the fields of `s` itself, and nothing stops the arm, a
call it makes, or an alias (`var` parameter, pointer) from giving `s`
another case. 10.4 covers only lending. Fix: in a safe module, an arm's
names are a copy of the fields whenever the arm could change the
variable (any call, any store through a pointer or `var` parameter, or
the variable named), or each use of a name checks the tag first. Cost:
a compare per use, or a copy per `match`, and one line less of 7.4.

**2. An `ERROR` written through a view.** `e.(INT) := h.(INT);
Out.str(MSG(e))` printed 64 KB of memory today. `ERROR` is an address
(5.8), but the list in 5.1 and 10.3 of what may not be written through
a view (pointer, procedure, slice, variant, enumeration, `BOOL`) leaves
it out. Fix: add `ERROR`, and better, state the rule the other way round:
a view may write only a variable made wholly of the types 6.9 allows as
a view's `T`. Cost: none.

**3. A safe module makes its own allocator.** `Mem.Allocator`'s fields
are exported. 5.2 lets a safe procedure stand where an `unsafe proc`
type is wanted. So a safe module can build `{alloc: mine, free: none}`
and pass it to `NEW`. Its `mine` can return the same lasting `^U8` for
every call, or a 1-byte block for a large `T`. Then `NEW` zeroes and
hands out memory that two pointers of different types share, or that
runs past its block. The same goes for copying `Arena.allocator(ar)^`,
or `ar.base`, into a heap record and passing that: Arena's `alloc`
casts its argument to `^Arena`, and reads past the copy. The trust of
5.3 is broken by code the trusted module calls back. Fix: a field of an
`unsafe proc` type may be set only in an unsafe module, and
`Mem.Allocator` becomes a type safe code can't build or copy (its
fields unexported, copying refused as for an owner). Cost: a rule in
5.2 and in 7.6.

**4. Procedures that take an allocator report arena memory as lasting.**
`Mem.alloc`, `Str.copy` and the result of `NEW` through such a call
carry no `ret` on their allocator, so by 6.1 what they return is
lasting. Given `Arena.allocator(ar)`, they return arena memory. After
`Arena.reset`, that memory goes to the next `NEW` of another type. The
same holds for `Buf.init`, `Vec.init`, `Map.init`, `List.init` and
`Pool.init`, which keep the allocator in the owner without a `keep`
mark, against obligation 3. Fix: `ret a` on every procedure whose
result comes from `a`, and `keep a` on every `init`. Then an arena's
allocator can't be kept by a container, and what `Str.copy` gives from
it is lent by the arena. Cost: marks on about ten headings.

**5. Storing a lent slice in an element of a slice.** 6.2 allows a
lent value to be "held in a local variable, or in a field or element of
one". An element of a local slice is someone else's memory:

```
proc stash(s: [][]U8);              (* s: the caller's array, or a Vec's block *)
var buf: [8]U8;
begin s[0] := buf[0..8]; end;       (* allowed by 6.2's words; dangles after return *)
```

PROPOSALS' "outliving the call" lists `p^.f` and `p^[i]` but not
`s[i]`. Fix: what is reached through a slice is a place that outlives
the call, as through a pointer, unless the slice is lent only by the
frame. Cost: a few false alarms on local slices of local arrays.

**6. Only a call's result is counted.** 7.3 counts "where a call
returns a reference lent by an owner". `t := s`, `t := s[1..3]` and
`u := t^[0..10]`, with `s` held, are not calls. Read as written, `t`
gets no hold. Then `s := []` lets the count fall to zero while `t`
still points into the block, and the next growth frees it. Fix: every
assignment to a local of a value lent by an owner sets that local's
holds, whatever the expression. Cost: none beyond what was meant.

**7. One hold, two owners.** A value may be lent by two owners at once:
`Buf.bytes(all[0])` with `all := Bufs.all(v)`; `NEW(t, al)` with `T` an
owner, then `Buf.bytes(t^)`; `pick(Buf.bytes(a), Buf.bytes(b))` with
two `ret` parameters. 7.3 gives a local one hidden word. Whichever owner
it leaves uncounted can free or move the memory: the outer `Vec` frees
the block that holds the inner `Buf`, and the hold then lowers a word of
freed memory. Fix: a hold per owner a value can be lent by, which the
compiler knows from the heading. Or forbid an owner reached through an
owner-lent value. Cost: a word per extra owner. The second choice
forbids `Vec(Buf.Buf)` and `Pool` of owners in practice.

**8. Library containers copy owners.** 7.6 forbids copies only in safe
modules. `Vec`, `Pool`, `Map` and `List` are unsafe and generic, so
they can't know that `T` is an owner. `Pool.get` returns a copy of a
slot. `Vec`'s growth copies every element into the new block, and, with
a lend held, keeps the old copy alive too. `Vec.pop`, `List.pop` and
`Map.get` copy out. Two `Buf`s then own one block: one grows and frees
it, and the other reads it. 7.6's rule also misses the result of a call
(`b := Pools.get(p, h)` isn't "assigned from another variable"). Fix: a
generic module's type parameter may be an owner only if the module says
it takes owners. Those modules move owners, never copy them, and
`get` is refused for them. Cost: a mark on generic parameters, and
`Pool` and `Vec` written for both cases.

**9. Other routes that copy or overwrite an owner.** None of these is in
7.6's list:

- `COPY(y, x)` on arrays of owners;
- `match` on another module's variable, which today names fields of a
  copy (confirmed by running it), and so counts on the copy;
- a variant case built from an owner, `has(b)`, which isn't plainly
  "a literal";
- `b := {}`, `x^ := {}`, and `Pool.add(p, {})`, which 7.6 allows, and
  `Buf.init(b, a)` on a `Buf` with a lend held. Each sets `lends` to
  zero under a hold. The hold's later let-go makes it -1. The next lend
  brings it back to 0 while that slice is held, and the next growth
  frees the block under it.

Fix: state the rule as "a value of a type that holds an owner is never
copied or overwritten in a safe module, nor by the library while its
`lends` is above zero". Add `COPY`, case construction, `match` on a
copy, and `{}` over a variable that isn't already empty (or make
`init` and `{}` stop when `lends` isn't zero). Cost: a few rules and a
test in each `init`.

**10. `take`, `swap` and the count.** 7.6 names `Buf.take(var from, to)`
and `Buf.swap` and says nothing of `lends`. Holds point at `from.lends`.
After the move, `to` owns the block with a count of 0, and frees it at
its next growth while the slices are held. Fix: `take` and `swap` stop
when either owner's `lends` is above zero. Cost: a compare each. Add it
to obligation 2.

**11. Letting go of a hold while a `match` names its fields.**

```
p := Vs.add(v);  p^ := a("abc");
match p^ of
| a(s): p := nil; grow(v); Out.str(s);   (* s names a field of a freed block *)
| b:
end;
```

The names stand for the variable in place, and assigning `p` lets its
hold go. Fix: a `match` on a lent variable takes its own count for the
whole statement. Cost: an add and a subtract per such `match`.

**12. The library breaks its own obligations.** Section 17 leaves these
as they are, and each lets a safe program reach freed memory:

- `List.head*` and `Node.next*` are exported, against obligation 4.
  `n := l.head; List.pop(l); n^.val` reads a freed node.
- `Thread.join` unmaps the mapping that holds the `Thread` record. The
  `^Thread` that `Task.spawn` returns stays "lasting", and a second
  `join` or a `signal` reads, and unmaps by, whatever the address
  holds next.
- Over C, `Sys.nextEntry`'s name points into C's `readdir` buffer,
  which `closeDir` frees. `Dir` is no owner, so nothing counts it. A
  `nextEntry` or `closeDir` after `closeDir` hands C a freed `DIR`.
- Over musl, `Sys.env`'s "lasting" result can be freed by a later
  `setEnv` of the same name, since musl frees the strings it made.
- `Names(V)`'s procedures that return a key must be `ret`, or `remove`
  frees what they gave. The proposal doesn't give its headings.

Fix: unexport `List`'s pointers and give an iterator that lends;
`Task` returns an owner handle that `join` takes by `var` and empties;
`Dir` an owner; `env` copied into lasting memory over C. Cost: small,
but it shows that obligations 1 to 5 need an audit of each module, not
only the marks of section 17.

### Ambiguities and contradictions

**13. Section 3 calls a racing container program safe.** Section 3's
definition counts a program as safe if its threads race "only on
variables of a basic, pointer, procedure or slice type". Two threads
calling `Buf.add` on one `Buf` race only on such fields (`len`,
`data`), so the guarantee claims their behaviour is defined. 9.2 says
it isn't. Fix: put 9.2's "a container's procedures called at once"
into section 3's sentence.

**14. A slice in a packed record, or in a block aligned to 8.** E.1
promises one access for every slice. A slice field of a packed record
is read in parts (5.5). `Vec` asks its allocator for 8-byte alignment.
Either tears, or `movdqa` faults on it. Fix: no slice in a packed
record; every allocator call for a type holding a slice asks for 16.

**15. Returning what an owner inside a parameter lent.** 6.2 forbids
returning a value "lent by an owner", even when the owner is a `ret`
parameter. So `proc bytes2(ret const b: Buf): []U8 begin return
Buf.bytes(b) end` is an error, and 14.2's recommended
`Http.name(ret const m: Message; i): []U8` can't be written. If it is
allowed, a caller of `name` sees only `m`, which is no owner (7.2), and
has no count to raise. Fix: allow it when the `ret` parameter is itself
the owner. For a record that holds owners, the caller raises each of
their counts, or the accessor is refused.

**16. When the epilogue lets go.** 7.3 says the let-go happens "as a
`defer` would". If it is placed as a `defer` at the assignment, a user
`defer f(b, s)` written before it runs after the let-go, and `f` can
grow `b` and read `s`. Fix: holds are let go after every deferred
statement has run.

**17. "The end of the statement" for compound statements.** A count
taken in a `while` condition, a `for` bound, an `if` condition or a
`match` head: is it lowered once per evaluation or at the statement's
`end`? Lowered once at `end`, a `while` raises it each round and leaks
counts. Then `done` stops though nothing is held. A `try` that leaves
mid-statement must lower it too. Fix: say per evaluation, and on every
exit.

**18. Two arms of one rule for `{}`.** 7.6 forbids passing an owner as
a value parameter but allows a literal that leaves it out. So is
`Pool.add(p, {})` allowed? Item 9 shows why the answer matters.

**19. Writable constants beyond strings.** F.2 covers a string's bytes.
An array constant of variants, enumerations or `BOOL`s may be sliced
(4), and on a target where constants are writable, a compiler that
folds `match Rows[0]` from the constant's case reads fields of another
case. Fix: on such targets, writing any constant through a slice stops
the program, or slices of non-string constants can't be written.

### One-pass and implementability problems

**20. A hold must be kept for every reference local.** A local may hold
a lasting value at one assignment and an owner's lend at a later one
(a loop's next round), and one pass doesn't know the later one when it
compiles the earlier. So every assignment to every slice or pointer
local must test and lower a hold, and every copy from one local to
another must pass the hold on. That cost is per assignment, not "per
lend held", and it falls on `src/`'s pointer loops (`o := o^.next`).
Section 13 doesn't count it. Fix: measure it, or let a hold word exist
only for locals declared with a mark (say `lent s: []U8`), checked at
`end`.

**21. Atomic counts depend on the whole program.** E.5 makes the counts
`lock xadd` "in a program that imports `Thread`". A module compiled
before another module's `import Thread` is read can't know which to
emit, and separate compilation (10) forbids depending on it. Fix:
always `lock`, or read every module's imports first. Cost: about 20
cycles per lend, or a pass over the import graph.

**22. Re-entry through the procedures a container is given.** `Map`
calls `hash` and `eq`, `Sort` calls `less`, `Guarded.with` calls its
procedure, and `Rt.atExit` procedures run after a failed check inside
any of these. A safe callback can call `put`, `remove` or `done` on the
same container while its own code is mid-loop: `done` inside `eq` while
`get` probes leaves `slots` nil with an index still in hand. No
obligation in 5.3 speaks of it, and checking the trusted code for every
re-entry is not one pass of anything. Fix: obligation 6, "a module that
calls a procedure given by safe code holds its own `lends` across the
call", so that `done` stops; the library's containers do it.

### Checked and found covered

- `Pool.at` across `Pool.free`: the slot keeps its type, so a stale
  pointer reads the wrong record of the right type, as 8.2 says. That
  holds except for variants (item 1) and owners in slots (items 7 to 9).
- Retired blocks and `reset`: the bytes keep their type; a held slice
  sees new contents, safely.
- `var` parameters aliasing: `f(x, x)` with a `done` inside stops on
  the count; a callee assigning the caller's held local through `var`
  leaves the hold set, which errs on the safe side.
- Holds and threads: a thread raises a count only while it already
  holds one, so the count can't pass through zero under another
  thread's test.
- `Task.spawn`: `keep x` refuses lent values, and owners can't be
  passed by value.
- `a, b := f(x)` and `return f(x)`: each target is checked as a single
  assignment.
- A `const` parameter of another module's variable is passed in place
  today (run to confirm), so its count lands on the real owner.
- A safe generic module instantiated with an owner: each instance is
  checked, so a copy inside it is refused there.

---

## Appendix 5: adversarial review, claims about other languages and hardware

This appendix checks every claim MEM_PROPOSAL.md makes about other
languages, hardware, research and precedent. Of 44 claims checked, 5
are wrong, 22 imprecise, 15 correct and 2 unverifiable. None of the
errors breaks the design. Three of them touch it, though: 21.5 leans on
Swift for a cross-thread check that Swift doesn't make; 9.2 says a
slice published with no lock is safe, which fails on ARM; and 11 files
Chrome's BackupRefPtr under debugging heaps, when it is the closest
precedent for part C. Most of the imprecise ones are table cells that
leave out a condition or a newer fact.

How it was checked: through the session's proxy, which let through only
GitHub-hosted sources (raw.githubusercontent.com) and web search. So
primary sources were read where they live on GitHub (the Go memory
model and spec, the C# standard, swift-evolution, Zig's langref and
library, Fil-C, Chromium, glibc, slotmap, generational-arena,
portable-atomic, GCC's libatomic, the Linux kernel's MTE document, D's
DIPs, CPython). Vendor manuals (Intel SDM, AMD APM, Arm ARM) and the
Modula-3, Ada and Java texts were checked through quotations that web
search returned. Where a manual's section number could not be seen
directly, the entry says so.

### Wrong

**W1. Section 21.5: "changes from another thread without the lock stop
the program, as Swift's exclusivity checks do."**
Wrong. Swift's run-time exclusivity checks are not required to see
accesses from other threads, and by design they don't look. SE-0176
says: "Dynamic enforcement is not required to detect concurrent
conflicting accesses, and we propose that by default it should not
make any effort to do so ... it can track accesses in a thread-local
data structure." Swift leaves races to Thread Sanitizer and, since
Swift 6, to `Sendable` checking at compile time.
Source: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0176-enforce-exclusive-access-to-memory.md (section "Concurrency").
Correct wording: "... stop the program. Swift's run-time exclusivity
checks don't do this: they track accesses per thread. The nearest
precedents are Go's run-time check for concurrent map writes and
ThreadSanitizer."

**W2. Section 12, Zig row: "`@ptrCast`, `@intToPtr` anywhere".**
Wrong name. `@intToPtr` was renamed `@ptrFromInt` in Zig 0.11 (2023),
and `@ptrToInt` became `@intFromPtr`. Today's langref has
`@ptrFromInt` (7 uses) and `@intFromPtr` (6), and no `@intToPtr`.
Source: https://raw.githubusercontent.com/ziglang/zig/master/doc/langref.html.in (Zig has since moved to Codeberg; the GitHub copy is the last one mirrored).
Correct wording: "`@ptrCast`, `@ptrFromInt` anywhere".

**W3. Section 12, "Java, C#" row: forged pointers "none".**
Wrong for C#. C# has real pointers, pointer arithmetic and casts from
integers in `unsafe` code. The same row names C#'s `unsafe` blocks as
its fence, so the row contradicts itself. Also,
`System.Runtime.CompilerServices.Unsafe` and `MemoryMarshal` reinterpret
references with no `unsafe` keyword at all, so the fence has holes. Java
can forge addresses through `sun.misc.Unsafe` (its memory methods were
deprecated for removal in JDK 23, JEP 471) and through the FFM API's
restricted methods, which warn unless `--enable-native-access` is given
(JEP 454 and 472).
Sources: https://github.com/dotnet/csharpstandard (unsafe code chapter); https://mail.openjdk.org/pipermail/jdk-dev/2024-May/008910.html (JEP 471); https://www.infoq.com/news/2024/07/jep-472-restrict-jni-jdk-24.
Correct wording: split the row. Java: "none in the language;
`sun.misc.Unsafe` and FFM restricted methods, behind a flag". C#: "in
`unsafe` code; also the `Unsafe` and `MemoryMarshal` classes, which
need no `unsafe`".

**W4. Section 9.2, point 1: "A program that hands slices from thread to
thread, publishing a buffer for others to read, is then safe with no
lock."**
Wrong on ARM, and true on x86-64 only if the compiler keeps the stores
in order. Single-copy atomicity means the 16 bytes don't tear. It says
nothing about the order in which other stores are seen. AArch64 is
weakly ordered. A reader can see the new slice and still see old bytes
in the buffer it points at, unless the store is a release (`STLR`, or
`DMB` then `STP`) and the load an acquire. If the buffer was a recycled
heap block, those old bytes may be another type's pointers. That breaks
the type guarantee of section 3, which publication with no lock is
meant to keep. x86-64's TSO keeps store order, so there it holds,
provided the compiler doesn't reorder.
Sources: https://raw.githubusercontent.com/taiki-e/portable-atomic/main/src/imp/atomic128/aarch64.rs (needs FEAT_LRCPC3's `LDIAPP`/`STILP`, or barriers, for acquire and release); the Arm ARM's memory model, B2.3.
Correct wording: "... is then safe with no lock on x86-64. On AArch64 a
slice store that publishes is a release and its load an acquire;
appendix A says how."

**W5. Section 12, "Java, C#" row: "references never tear; `long` may in
Java".**
Wrong by omission for C#, the row's other language. The C# standard
(9.6) promises atomic reads and writes only for `bool`, `char`, the
integer types up to 32 bits, `float` and references. It says "Reads and
writes of other types, including `long`, `ulong`, `double`, and
`decimal`, as well as user-defined types, need not be atomic." So C#
structs tear, and that includes multi-word ones such as `ArraySegment<T>`
and `Memory<T>`. C# stays memory-safe anyway because every array access
is checked again against the array itself. That is worth saying, since
it is the other way out of the torn-slice problem.
Source: https://github.com/dotnet/csharpstandard/blob/draft-v8/standard/variables.md#96-atomicity-of-variable-references.
Correct wording: "references never tear; `long` and `double` may (in
C#, structs too), but each array access is checked again".

### Imprecise

**I1. Section 9.2: "`movdqa`, which Intel and AMD guarantee single-copy
atomic on processors with AVX"; section 4: "none on x86-64 with AVX".**
Right in substance, but conditions are missing. Intel's SDM Vol. 3A,
"Guaranteed Atomic Operations" (section 9.1.1 in the editions that GCC
and Microsoft's STL quote; numbering shifts between editions), says:
"Processors that enumerate support for Intel AVX (by setting the
feature flag CPUID.01H:ECX.AVX[bit 28]) guarantee that the 16-byte
memory operations performed by the following instructions will always
be carried out atomically: MOVAPD, MOVAPS, and MOVDQA; VMOVAPD,
VMOVAPS, and VMOVDQA when encoded with VEX.128; VMOVAPD, VMOVAPS,
VMOVDQA32, and VMOVDQA64 when encoded with EVEX.128 and k0 (masking
disabled)", with the operands 16-byte aligned. AMD's APM Vol. 2
(Access Atomicity; I couldn't see the section number) is broader in one
way and narrower in another: "Processors that report CPUID
Fn0000_0001_ECX[AVX](bit 28) = 1 extend the atomicity for cacheable,
naturally-aligned single loads or stores from a quadword to a double
quadword." So AMD's covers any aligned 16-byte load or store, but only
to cacheable memory. Neither promise belongs to "x86-64 with AVX" in
general. GCC's libatomic trusts it only on Intel, AMD, Zhaoxin and
newer Centaur parts, and clears AVX for other vendors: "We don't have
a guarantee from vendors of other CPUs with AVX, like VIA."
"Single-copy atomic" is Arm's term; Intel says "carried out
atomically".
Sources: https://gcc.gnu.org/pipermail/gcc-patches/2022-February/590960.html (PR104688, quoting the SDM); https://raw.githubusercontent.com/gcc-mirror/gcc/master/libatomic/config/x86/init.c; https://raw.githubusercontent.com/taiki-e/portable-atomic/main/src/imp/atomic128/x86_64.rs ("Intel, AMD, and Zhaoxin officially guarantee this behavior (VIA has not responded)"); https://github.com/microsoft/STL/issues/4480.
Correct wording: "moved with `movdqa` from a 16-byte-aligned address.
Intel (SDM Vol. 3A, Guaranteed Atomic Operations) and AMD (APM Vol. 2,
Access Atomicity, for cacheable memory) guarantee this atomic on
processors that report AVX, and so does Zhaoxin. Other vendors' AVX
parts take the fallback."

**I2. Section 9.2: "ARMv8.4 has 16-byte atomic `LDP`/`STP`
(FEAT_LSE2)".**
True, but the conditions and the reach are missing. FEAT_LSE2 is
optional from Armv8.2 and mandatory from Armv8.4. The Arm ARM (DDI
0487, B2.2.1.1, as quoted on LKML) makes LDP/LDNP/STP of two 64-bit
registers single-copy atomic only when the access is 16-byte aligned
and goes to Inner Write-Back, Outer Write-Back Normal cacheable memory.
Many 64-bit Arm machines in use don't have it: Cortex-A72 (Raspberry
Pi 4), Cortex-A76 (Pi 5), Neoverse N1 (AWS Graviton2, Ampere Altra).
They need `LDXP`/`STXP` loops (Armv8.0) or `CASP` (FEAT_LSE, Armv8.1).
Sources: https://lkml.iu.edu/2511.1/09040.html; https://raw.githubusercontent.com/taiki-e/portable-atomic/main/src/imp/atomic128/aarch64.rs ("LDP/STP: load/store (if Armv8.4 FEAT_LSE2 (optional from Armv8.2, mandatory from Armv8.4) is available)").
Correct wording: "With FEAT_LSE2 (mandatory from Armv8.4) an aligned
16-byte `LDP`/`STP` to normal cacheable memory is single-copy atomic.
Earlier cores use `LDXP`/`STXP` or `CASP`."

**I3. Section 9.2: "On x86-64 without AVX, the implementation uses
`lock cmpxchg16b`".**
Works, with three costs left unsaid. First, CMPXCHG16B (CPUID CX16) is
not in the x86-64 baseline (x86-64-v1): the first AMD64 processors
lack it. Second, a load done as `lock cmpxchg16b` writes the line. So
it faults on read-only pages, needs the memory to be writable (as
portable-atomic's safety comments say), and makes readers contend with
one another. libatomic: "Since load and store are implemented with
CAS, they are not fast." Third, a store needs a CAS loop. Raz keeps
slice constants, `[]` among them, in read-only data. The compiler would
have to know those are never raced and read them plainly.
Sources: https://raw.githubusercontent.com/gcc-mirror/gcc/master/libatomic/config/x86/host-config.h; portable-atomic's x86_64.rs, as above.

**I4. Section 13.3, row E: "none: two 8-byte moves become one 16-byte
one".**
Not free when the slice goes to or from general registers. That is
the usual case, since raz returns a slice in rax and rdx. A 16-byte
load into an XMM register then needs `movq` plus `pextrq` (or a shuffle
and `movq`) to split it, and a store needs `movq` plus `pinsrq` or
`punpcklqdq` to join it: two to three more uops, and a few cycles of
latency. `pextrq` and `pinsrq` are SSE4.1, which is not baseline
x86-64. This is the machine's cost, and it should be measured like the
others.
Correct wording: "a load or store of a slice through an XMM register:
one or two more instructions where its words go to or from general
registers; records holding slices may grow by padding to 16."

**I5. Section 7.5: "`inc qword [r]` ... about two cycles each ... `lock
xadd`, about 20 cycles".**
Rough. On Intel, an uncontended `lock` read-modify-write measures about
18 cycles (uops.info, Skylake). On recent AMD cores it is lower. It is
a full barrier, and under contention, with the line bouncing between
cores, it costs hundreds of cycles. That is the case that matters for
two threads lending from one locked `Buf`. A memory-destination `inc`
has a throughput near one a cycle, but about five to six cycles of
latency when chained through store forwarding.
Sources: https://uops.info/html-instr/INC_LOCK_M32.html; https://www.agner.org/optimize/instruction_tables.pdf.
Correct wording: "... `lock xadd`, about 20 cycles uncontended on
Intel, and far more when threads contend for one owner".

**I6. Section 12, Zig row: "the debug allocator finds use after free and
double frees at run time; nothing in release".**
Partly. `std.heap.DebugAllocator` (renamed from `GeneralPurposeAllocator`
in 0.14.0) lists "Double free detection" and "Leak detection, with
stack traces". It doesn't detect use after free. It "Never reuses
memory addresses" and gives freed pages back "so that it causes page
faults when used", and in safe modes freed memory reads as `0xaa`. So
a use after free may fault or read junk, and nothing reports it as
such. The allocator is chosen by the program, not by the build mode:
it works in ReleaseSafe too.
Source: https://raw.githubusercontent.com/ziglang/zig/master/lib/std/heap/debug_allocator.zig (header comment).
Correct wording: "the debug allocator finds double frees and leaks, and
never reuses addresses, so a use after free tends to fault; a program
chooses it, usually in Debug".

**I7. Section 12, "C++, hardened" row: "hardened `std` containers;
`-fbounds-safety` for C (clang)".**
This mixes two things. `-fbounds-safety` is a C extension, not C++
hardening. Apple designed it and ships it in Apple's clang. Upstream,
it is "being incrementally upstreamed", behind
`-fexperimental-bounds-safety`. On the C++ side, the newer fact is
missing: C++26 standardizes library hardening (P3471, adopted at
Hagenberg, February 2025), on top of libc++'s hardening modes and
libstdc++'s `_GLIBCXX_ASSERTIONS`.
Sources: https://lists.llvm.org/pipermail/cfe-commits/Week-of-Mon-20240513/579251.html; https://clang.llvm.org/docs/BoundsSafetyImplPlans.html; https://open-std.org/JTC1/SC22/WG21/docs/papers/2025/p3471r4.html.
Correct wording: C row: "Spatial: none; Apple's `-fbounds-safety`
extension (clang, partly upstream) adds checked bounds". C++ row:
"hardened standard library (libc++, libstdc++; standard in C++26 by
P3471)".

**I8. Section 12, "Odin, Hare, C3" row: spatial "checked".**
True by default for all three, but each can turn it off. C3 checks
only in its safe (debug) mode, and in fast builds an out-of-bounds index
is undefined. Hare checks every slice and array access, but its `[*]T`
arrays are unchecked. Odin has `#no_bounds_check` and
`-no-bounds-check`.
Sources: https://c3-lang.org/language-rules/undefined-behaviour/; https://harelang.org/blog/2022-06-21-safety-features/.
Correct wording: "checked by default (C3: in safe builds only); each can
turn it off".

**I9. Section 12, Swift row: fence "`Unsafe` in names".**
Out of date. SE-0458, "Opt-in Strict Memory Safety Checking", is
implemented in Swift 6.2. It adds `-strict-memory-safety`, an `@unsafe`
attribute, a `@safe` attribute for a declaration that is "actually
safe to use" though its signature holds unsafe types, and an `unsafe`
expression "much like `try` and `await`". That is a real fence, and
`@safe` is section 5.3's trust in a safe interface.
Source: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md.
Correct wording: "`Unsafe` in names; since Swift 6.2, an opt-in
checked fence (`@unsafe`, `@safe`, `unsafe` expressions)".

**I10. Section 12, Ada row: races "protected objects".**
Protected objects are the tool, not the guarantee. In Ada, two
unsynchronized conflicting uses of a shared variable are erroneous (RM
9.10): "The execution of two concurrent actions is erroneous if the
actions make conflicting uses of a shared variable." SPARK, under the
Ravenscar and Jorvik profiles, proves there are no data races.
Source: https://ada-lang.io/docs/arm/AA-9/AA-9.10/.
Correct wording: "erroneous unless synchronized (protected objects,
atomics); SPARK proves their absence".

**I11. Section 12: "Ada's accessibility levels are part B's frame,
parameters and lasting memory, nearly exactly."**
Overstated. Ada's levels (RM 3.10.2) attach mainly to where an access
type is declared. A library-level access type can't designate a
deeper object. Most checks are static, but those for anonymous access
parameters and some others run at run time and raise `Program_Error`.
There is no notion of "lent by this parameter" for a result. The
closest match to part B is C#'s ref-safety rules: their "safe-context"
values are "declaration-block", "function-member" and
"caller-context". Those are part B's frame, parameters and lasting
nearly one for one. C# 11 adds `scoped` and `[UnscopedRef]`, which play
the roles of `ret` and `keep`.
Source: https://github.com/dotnet/csharplang/blob/main/proposals/csharp-11.0/low-level-struct-improvements.md.
Correct wording: "Ada's accessibility levels are the idea; C#'s
safe-contexts (declaration block, function member, caller) are part
B's three lenders nearly exactly."

**I12. Section 5.3: "This is Modula-3's rule for an `UNSAFE MODULE`
that implements a safe `INTERFACE`".**
Right as far as it goes, but Modula-3 also fences imports, and raz
doesn't. The Modula-3 report's Safety section says: "It is a static
error for a safe interface to import an unsafe one or for a safe module
to import or export an unsafe interface." Raz lets any safe module
import an unsafe one and fences per procedure (`unsafe proc`). That is
closer to D's `@safe`/`@trusted`/`@system` per function, and to Rust's
`unsafe fn`, than to Modula-3.
Source: https://www.cs.purdue.edu/homes/hosking/m3/reference/safety.html.
Correct wording: add "Unlike Modula-3, which forbids a safe module to
import an unsafe interface, raz fences per procedure, as D's
`@trusted` and Rust's `unsafe fn` do."

**I13. Section 12: "The unit of review is a file, as Wirth's languages
always had it."**
Modula-3 isn't Wirth's. It came from DEC SRC and Olivetti, building on
Modula-2+. Pascal had no modules, so "always" is wrong. Modula-2 and
Oberon do mark low-level code by importing `SYSTEM` per module.
Correct wording: "The unit of review is a module, as in Modula-2's and
Oberon's `IMPORT SYSTEM` and Modula-3's `UNSAFE`."

**I14. Section 12, Vale row: "regions skip the check"; races "regions";
fence "`unsafe`".**
These are mostly Vale's plans. Vale's last release is 0.2 (2022). Its
own project page lists the region borrow checker and hybrid-generational
memory as medium-term goals, and its `unsafe` blocks and "Fearless
FFI" were proofs of concept. Generational references themselves,
section 8.2's claim, are right: each object carries a current
generation, each non-owning reference a remembered one, checked on
dereference. Owning references aren't checked.
Sources: https://vale.dev/memory-safe; https://vale.dev/project; https://vale.dev/blog/version-0.2-released.
Correct wording: "generational references, checked at each
dereference; regions, which would skip the check, are designed and not
finished".

**I15. Section 12, Cyclone row: temporal "regions, checked
statically".**
Leaves out that Cyclone's heap region is garbage collected
(conservatively, with the Boehm collector). Grossman's PLDI 2002 paper
integrates regions "with stack allocation and a garbage collector".
Unique and reference-counted pointers came later (Hicks et al.).
Cyclone's temporal safety for the heap is a GC, which is what raz
refuses.
Sources: https://www.cs.umd.edu/~mwh/papers/GrossmanMJHWC02.html; https://www.cs.washington.edu/homes/djg/slides/cyclone_pldi02.pdf.
Correct wording: "regions checked statically; the heap region garbage
collected".

**I16. Section 12, "Fil-C, CHERI" row: "Fil-C: a few times slower";
"Fil-C: atomic capabilities"; "CHERI: revocation".**
Fil-C's own figures are "about 1.5x-4x slower" (README and Manifesto,
version 0.686). On races, Fil-C says "Pointer races on pointers not
marked `_Atomic` or `volatile` lead to Fil-C panics, at worst". Only
atomic pointers get an "atomic box". CHERI's capabilities give spatial
safety in hardware. Its temporal safety needs software revocation
sweeps (Cornucopia, in CheriBSD), and it costs 128-bit pointers.
Sources: https://raw.githubusercontent.com/pizlonator/fil-c/deluge/README.md; https://raw.githubusercontent.com/pizlonator/fil-c/deluge/Manifesto.md.
Correct wording: "Fil-C: 1.5 to 4 times slower, and a concurrent GC;
CHERI: 128-bit capabilities, and revocation by software sweeps".

**I17. Section 19: "[MTE and CHERI] aren't on x86-64, and they are
probabilistic (MTE's four bits)."**
Two fixes. First, only MTE is probabilistic: a 4-bit tag per 16-byte
granule (Linux's document: "a 4-bit allocation tag for each 16-byte
granule"), so a stale pointer passes 1 time in 16 by chance. CHERI's
bounds are exact. Second, x86 is on its way: Intel and AMD announced
ChkTag, a common x86 memory-tagging specification, on 13 October 2025,
with no shipping date. MTE is also not only for debugging any more.
Apple's Memory Integrity Enforcement runs Enhanced MTE always on and
synchronously on the iPhone 17 (September 2025).
Sources: https://raw.githubusercontent.com/torvalds/linux/master/Documentation/arch/arm64/memory-tagging-extension.rst; https://www.amd.com/en/blogs/2025/amd-and-intel-celebrate-first-anniversary-of-x86-ecosys.html; https://www.phoronix.com/news/AMD-Intel-One-Year-x86-Eco; https://security.apple.com/blog/memory-integrity-enforcement.
Correct wording: "They aren't on x86-64 yet (Intel and AMD announced
ChkTag in 2025). MTE is probabilistic, with four bits a tag; CHERI is
exact, but needs software revocation for use after free."

**I18. Section 11: "This is ... Chrome's MiraclePtr quarantine".**
MiraclePtr is not a debugging heap, and its quarantine isn't a fixed
count. `raw_ptr<T>`, implemented by BackupRefPtr, keeps a reference
count in each PartitionAlloc slot. It is "quarantining the freed memory
as long as any dangling `raw_ptr<T>` pointing to it exists, and
poisoning it (with 0xEF..EF pattern)". Its constructor, destructor and
assignment "need to maintain BackupRefPtr's ref-count (atomic
increment/decrement)". It ships in production Chrome. That makes it a
precedent for part C, not part G: count the references a block has
lent, and retire the block instead of freeing it while the count is
above zero. Its documentation also records the cost part C should
expect: "on a couple occasions it led to significant memory leaks". A
fixed FIFO quarantine with guard bytes, like part G's, is
AddressSanitizer's quarantine and redzones, and GWP-ASan's.
Source: https://raw.githubusercontent.com/chromium/chromium/main/base/memory/raw_ptr.md.
Correct wording in 11: "This is AddressSanitizer's quarantine and
redzones, Zig's debug allocator and glibc's `MALLOC_PERTURB_`, without
their reach." Add to section 7: "Chrome's BackupRefPtr (MiraclePtr)
does the same in C++: it counts a block's references and quarantines
it on free while the count is above zero."

**I19. Section 3 and 9.2, point 2: a race on a whole record or variant
"is undefined, as in Go".**
Go doesn't call it undefined. The memory model says a racy read of a
multi-word value may see "inconsistent values not corresponding to a
single write". Only "when the values depend on the consistency of
internal (pointer, length) or (pointer, type) pairs, as can be the case
for interface values, maps, slices, and strings in most Go
implementations, such races can in turn lead to arbitrary memory
corruption." Go sets itself apart from C and C++, "where the meaning of
any program with a race is entirely undefined". A race on a plain
struct of integers just gives mixed values.
Source: https://raw.githubusercontent.com/golang/go/master/doc/go_mem.html (go.dev/ref/mem).
Correct wording: "undefined. Go is narrower: a race tears such a value,
and corrupts memory only through its pointer and length or type pairs."

**I20. Section 9.1: Go's memory model on races over multi-word values.**
The quotation is right, but the list it gives is short. Go names
"interface values, maps, slices, and strings", hedged "in most Go
implementations", and says such races "can in turn lead to arbitrary
memory corruption". The proposal's list drops maps, and its "an
interface, a slice, a string" reads as Go's words when they are a
paraphrase.
Source: as I19.
Correct wording: "Go's memory model says that races on values made of
(pointer, length) or (pointer, type) pairs, 'interface values, maps,
slices, and strings in most Go implementations', 'can in turn lead to
arbitrary memory corruption'."

**I21. Section 12: "From Swift: checking exclusivity at run time where
the compiler can't, as part C counts lends."**
Loose. Swift's dynamic exclusivity tracks the start and end of each
access to a class property, global or escaped variable, per thread
(W1). It doesn't count. Part C counts outstanding loans and refuses or
defers a release while any is held. That is Rust's `RefCell` (a borrow
count that panics), CPython's `bytearray` (it keeps `ob_exports` and
refuses to resize: "Existing exports of data: object cannot be
re-sized"), Java's and .NET's fail-fast iterators (a modification
count), and Chrome's BackupRefPtr (I18).
Sources: https://raw.githubusercontent.com/python/cpython/main/Objects/bytearrayobject.c; https://raw.githubusercontent.com/rust-lang/rust/master/library/core/src/cell.rs.
Correct wording: "From Rust's `RefCell`, CPython's buffer exports and
Chrome's BackupRefPtr: a count of what is lent, checked at run time,
where the compiler can't see it."

**I22. Section 8.2: "Part of the first is that each slot is 32 bytes,
not 16"; and open question 6, one word or two for a handle.**
The precedent the proposal cites answers the question, and the
proposal doesn't use it. slotmap's key is one 64-bit word: a 32-bit
index and a 32-bit version (`idx: u32, version: NonZeroU32`). A slot
costs `4 + max(sizeof(T), 4)` bytes. Versions wrap after 2^31 reuses of
a slot, "and in all circumstances is the behavior safe". So the 32-byte
slot of the benchmark comes from the two-word `Handle` chosen here, not
from generational handles as such. The 1.5x past the caches is partly
an artifact of that choice.
Source: https://raw.githubusercontent.com/orlp/slotmap/master/src/lib.rs.
Correct wording: add to 21.6: "slotmap takes one word, 32 bits each,
and lets the version wrap; with it, a slot of a 16-byte `T` is 20 or
24 bytes, not 32."

### Correct

**C1. Section 9.1: "Java closes it by tearing only `long` and `double`,
never a reference."** Correct. JLS 17.7: a non-volatile `long` or
`double` write may be treated "as two separate writes, one to each
32-bit half"; "Writes to and reads of references are always atomic,
regardless of whether they are implemented as 32-bit or 64-bit
values." Source: https://docs.oracle.com/javase/specs/jls/se21/html/jls-17.html#jls-17.7 (read through a mirror: https://www.oreilly.com/library/view/the-java-language/9780133260335/ch17lev1sec7.html).

**C2. Section 7.4: "This is Go's `append`: the old slice still sees the
old array."** Correct for a growing append. The spec says: "If the
capacity of s is not large enough to fit the additional values, append
allocates a new, sufficiently large underlying array ... Otherwise,
append re-uses the underlying array." In Go the GC keeps the old array
while it is referenced. Raz retires the block and frees it at a later
growth once the count is 0, which matches for every slice still held.
Source: https://raw.githubusercontent.com/golang/go/master/doc/go_spec.html.

**C3. Section 19: `append(s, s...)` is right in Go.** Correct: append
copies with memmove semantics, so overlap is safe. Source: as C2.

**C4. Section 12, Go row: checked, GC, forged pointers "only through
`unsafe`", fence `import "unsafe"`.** Correct. cgo is the other way
out, and it is also visible in imports (`import "C"`).

**C5. Section 8.2: "the generational arena of Rust's `slotmap` and
`generational-arena`".** Correct. slotmap: "persistent unique keys ...
The keys returned by `slotmap` are versioned." generational-arena: "A
safe arena allocator that allows deletion without suffering from the
ABA problem by using generational indices." Sources: https://github.com/orlp/slotmap; https://github.com/fitzgen/generational-arena.

**C6. Section 8.2: "the handle pattern Zig and game engines use".**
Correct as practice. The pattern's best-known write-up is Andre
Weissflog's "Handles are the better pointers" (2018), worth citing:
https://floooh.github.io/2018/06/17/handles-vs-pointers.html.

**C7. Section 12, Rust row, and 9.1: `Send`/`Sync` checked by the type
system; `unsafe` blocks and functions.** Correct.

**C8. Section 19: "non-lexical lifetimes are a fixpoint over the control
flow, not one pass".** Correct. NLL (RFC 2094) computes liveness and
region constraints by dataflow over MIR's control-flow graph.

**C9. Section 12, Swift row: "exclusivity checked at compile and run
time"; "Swift 6: `Sendable`, checked".** Correct. Swift 5 enabled
run-time exclusivity checks in release builds; the Swift 6 language
mode makes data-race checks errors. Source: https://github.com/swiftlang/swift-org-website/blob/main/_posts/2019-02-05-swift-5-exclusivity.md.

**C10. Section 12, Modula-3 row: a GC for traced references, `DISPOSE`
only in unsafe modules, `UNSAFE MODULE` and `UNSAFE INTERFACE`.**
Correct. The report: "An interface or module not explicitly labeled
UNSAFE is called safe." SRC's compiler: `IF Module.IsSafe () THEN
Error.Msg ("DISPOSE: unsafe operation")`. Untraced references (`UNTRACED
REF`) aren't collected. Sources: https://www.cs.purdue.edu/homes/hosking/m3/reference/unsafe.html; https://softwarepreservation.computerhistory.org/modula3/archive/DEC_SRC/release-2.11-unpacked/compiler/src/builtinOps/Dispose.m3.

**C11. Section 12, Oberon row: unsafe only through `SYSTEM`, marked by
`IMPORT SYSTEM`.** Correct. The GC belongs to the Oberon system rather
than the language report, which is a fine point.

**C12. Section 12, Ada row: `Unchecked_Deallocation`,
`Unchecked_Conversion`, "SPARK adds ownership".** Correct. SPARK's
pointers follow "the Rust model": move for pool-specific access types,
borrow and observe for anonymous ones (SPARK Community 2020 onward).
Source: https://docs.adacore.com/spark2014-docs/html/ug/en/source/access.html.

**C13. Section 12, Zig row: bounds "checked in Debug and
ReleaseSafe".** Correct. The langref: "In Debug and ReleaseSafe mode
... triggers a safety panic"; ReleaseFast and ReleaseSmall assume
the checks away.

**C14. Section 11: "Zig's debug allocator".** Correct name since Zig
0.14.0 (`std.heap.DebugAllocator`; `GeneralPurposeAllocator` survives
as a deprecated alias). Source: https://ziglang.org/download/0.14.0/release-notes.html.

**C15. Section 11: glibc's `MALLOC_PERTURB_`.** Correct: it fills
blocks "when they are allocated ... and freed". It has no quarantine
and no guard bytes; the proposal's "without their reach" allows for
that. Source: https://raw.githubusercontent.com/bminor/glibc/master/manual/memory.texi.

### Unverifiable

**U1. Section 12, Zig row: races "UB".** Zig has no written memory
model. Its atomics follow LLVM's, under which a data race on a
non-atomic location is undefined, so the claim is very likely right.
No Zig document says so.

**U2. Section 12, Modula-3 row: races "not promised".** The report
doesn't speak to it in what I could read. Since Modula-3's open arrays
and `TEXT`s are behind references, a race in a safe module may not
break memory at all. Leave it, or write "not addressed by the report".

### Precedent the proposal misses

- **D: `@safe`, `@trusted`, `@system`, and DIP1000's `scope` and `return
  scope`.** This is the closest match to parts A and B together.
  `@trusted` is section 5.3's trust, per function. `return scope` is
  `ret`, and plain `scope` is the opposite of `keep`. PROPOSALS.md
  cites DIP1000; MEM_PROPOSAL.md doesn't. It should, together with D's
  lesson that the corners (fields, generics, delegates) took years.
  DIP1000 is still behind `-preview=dip1000`, and its document is marked
  "Superseded". Source: https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1000.md.
- **C#: `ref struct`, `Span<T>`, `scoped`, ref-safety contexts.** C#
  checks with local, one-pass rules that a `Span<T>` never outlives what
  it points at, with three contexts that are part B's three lenders
  (I11). It is the strongest evidence that part B works in a
  mainstream compiler without lifetimes in types. Source: https://github.com/dotnet/csharplang/blob/main/proposals/csharp-11.0/low-level-struct-improvements.md.
- **Swift: `~Escapable` types, lifetime dependencies, `Span`, and
  SE-0458.** Swift 6.2's non-escapable types (SE-0446) and `Span`
  (SE-0447) give a slice that can't outlive its source, with a
  dependence written on the function. That is `ret` again. SE-0458's
  `@safe` and `@unsafe` are the fence and the trust. Sources: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0446-non-escapable.md; .../0447-span-access-shared-contiguous-storage.md; .../0458-strict-memory-safety.md.
- **Chrome's BackupRefPtr.** Counted references with quarantine on
  free, in production C++ (I18). It is the precedent for part C's
  retirement, with measured costs and recorded leaks.
- **Rust's `RefCell`, CPython's buffer exports, Java's `modCount`.**
  Run-time counts of loans that refuse a change while one is held
  (I21). CPython's `bytearray` refusing to resize while exported is
  part C's "stop" alternative from section 19, shipped for years.
- **Checked C.** Microsoft's extension of C with checked pointer types
  (`_Ptr`, `_Array_ptr` with bounds) and `_Checked`/`_Unchecked`
  scopes. It is a fence in a C-like language, at a finer grain than a
  module, and it shows the cost of a per-block fence.
  https://github.com/checkedc/checkedc.
- **SafeStack (clang).** It moves address-taken locals to a separate
  stack. That is relevant to what an unsafe module's `ADR` of a local
  can reach, and to part F's frame slots. https://clang.llvm.org/docs/SafeStack.html.
- **Hylo (formerly Val).** Mutable value semantics: no stored
  references at all, only projections that last the call. That is the
  extreme of section 14's "a record can't keep a slice into a buffer
  that belongs to someone else", and it argues that the limit is
  livable. https://www.hylo-lang.org.
- **Austral.** Linear types with lexical borrows, kept small on purpose
  so that one person can hold the whole checker in their head. That
  matters to raz's "a beginner can follow". https://austral-lang.org.
- **Mojo and Carbon.** Mojo has ownership with inferred "origins", a
  Rust-like model with lighter syntax. Carbon plans a safe subset
  reached by incremental migration from C++, as part of section 20's
  order of work. Both are worth a line in section 19's view of Rust's
  way. https://docs.modular.com/mojo/manual/values/lifetimes; https://github.com/carbon-language/carbon-lang/blob/trunk/docs/design/safety/README.md.
- **Modula-2+ and Cedar.** They had safe and unsafe (Cedar: checked,
  trusted, unchecked) modules before Modula-3, and are where the
  module fence of section 12 comes from.
- **AddressSanitizer and GWP-ASan.** The real models for part G's
  quarantine and guard bytes (I18).

---

## Appendix 6: adversarial review, the proposal's numbers and samples

**Summary.** The five demo programs compile with `-Werror`, print what
the proposal says, and do the undefined thing claimed. The callgrind
figures repeat to within a thousand instructions. Several other things
don't hold:

- The survey counts lines, not operations, and the proposal calls them
  operations.
- Its "test/libc" row is really `lib/Sys.raz`.
- rnet's TLS backends and two of its tests were never compiled.
- Most `ADR`s in rnet, rjson, rlX11 and ravite are arguments to the
  programs' own procedures, not to the library. So the claim that
  v0.19.0 "removed them already" is wrong.
- Every one of raz's own benchmark kernels says `check off;`.
- The kernels don't run "past the caches": the machine reports a
  260 MB L3.
- The 16-to-32-byte and fat-pointer conclusions are confounded by node
  layout and by noise.
- Part C's run-time rule would stop the library's own `Opt.say`, the
  compiler's `Parse.moduleParams` and ravite's `load`.
- 7.3 forbids the accessor that 14.2 recommends.
- No container's `init` is marked `keep`, so a `Buf` over an `Arena`
  (used by `Fmt.eprint` and `examples/Sh`) can't be written safely.
- Three of the sample error messages are wrong, and one gives help that
  doesn't compile.
- The compiler cost is likely low by 40 to 70%, judged against
  PROPOSALS' own revised figure.

Commands below were run on 2026-10-17. The scratch data used is in
`/tmp/claude-0/-home-user-raz/bab05b52-9d9d-4262-9f3e-de1807ce50a5/scratchpad/`
(S below). Files made for this review are in
`/tmp/claude-0/-home-user/f9bd1744-45c5-5c51-82fd-fddfc77d01cc/scratchpad/`
(W below).

### 1. Survey counts

**1.1 "Places", counted once each, are lines (2.1, 2.2, appendix 1).**
`Diag.tally` prints `path:line` with no column, and `agg.py` keys on
(kind, file, line). So two operations of one kind on one line count
once. I rebuilt the tally compiler to print the offset as well
(`W/tc/raz`) and compiled `src/Raz.raz` with it:

| kind | lines (proposal) | distinct places |
|---|---|---|
| `ADR` | 27 | 32 |
| deref | 1,015 | 1,410 |
| `p[i]` | 277 | 372 |
| `p[a..b]` | 30 | 44 |
| ptr cast | 42 | 48 |
| `p ± i` | 3 | 4 |

The distinct places are themselves a floor: nested operations at one
position still merge. **Correction:** call them "lines with", or give
the operation counts. The ratios between modules hold.

**1.2 The `test/libc` row is library code.** `test/libc/mods/Sys.raz`
is a link to `lib/Sys.raz`, the C `Sys`. It holds 108 of the row's 110
`ADR`s, 63 of its 64 casts and all 35 of its `p[i]`. The tests' own
files hold 2 `ADR`s, 1 cast and 1 `NEW`. **Correction:** move 242
fenced operations to `lib/` (`lib/Sys`, the C one), and say so when
naming the library's unsafe modules (2.2, "Sys (287 operations)" is
the Linux file only).

**1.3 rnet was compiled in part.** `S/out/rnet.log` shows
`test/Net.raz` and `test/Https.raz` failing, because `module Tls is in
.../gnutls/Tls.raz and .../openssl/Tls.raz`. So neither TLS backend
was counted. Both are `extern` modules: 26 and 35 `extern`s, 27 and 24
`ADR`s. **Correction:** 5.4 says "rnet needs it only to keep
`Http.Message`". In fact both `tls/*/Tls.raz` must say `unsafe;`, as
`Sqlite` must. Section 15's rnet row should list them.

**1.4 rnet's and rjson's `ADR` totals disagree with appendix 1.** 2.2
gives rnet 572 and rjson 77. Appendix 1 gives 471 and 91 (lines, from
the tally). A grep outside comments finds 792 occurrences in rnet (621
lines) and 110 in rjson. rlX11's 89 doesn't come out either: grep
finds 108, 78 of them in `src/`. ravite's 202 and rmacs's 560 match a
grep.

**1.5 "Almost every ADR is ... the library's old pointer parameters"
is wrong for most repositories.** I sorted each `ADR` by the call it
is an argument to (`W/py/adr.py`, a textual parser):

| repo | `ADR`s | to the library | to its own procedures and modules | casts and other |
|---|---|---|---|---|
| rnet | 792 | 226 | 525 | 41 (34 to `Tls`) |
| rjson | 110 | 35 | 70 | 5 |
| rflate | 67 | 48 | 16 | 3 |
| rsqlite | 42 | 12 | 27 (some to C) | 3 |
| rmacs | 560 | 424 | 132 | 4 |
| ravite | 202 | 107 | 93 | 2 |
| rlX11 | 108 | 5 | 100 | 3 |

The top callees in rnet are its own `fetches`, `resolves`,
`Conn.close` and `parseAnswer`. In rlX11 it is its own `expect`. Those
are the programs' pointer-taking headings. They mend by `var`, but the
programs have to be rewritten for it; v0.19.0's library didn't remove
them. **Correction:** "Most `ADR`s are arguments; in rmacs and rflate
mostly to the library, in rnet, rjson and rlX11 mostly to the
programs' own pointer parameters."

**1.6 "Nobody uses `check off;`" (2.2, 13.2) is wrong.** All seven
kernels in `test/bench` say `check off;` (`grep -l '^check off'
test/bench/*.raz` gives 7 of 7). The Makefile says so too: "the
kernels of test/bench, which say check off". So does
`test/run/mods/Unchecked.raz`. The survey left `test/` out, but the
inference "no one has wanted them off" doesn't follow: raz's own speed
comparison with FPC turns the checks off. **Correction:** "No library
module or program surveyed turns them off. raz's benchmark kernels do,
to match FPC -O2."

**1.7 Frees and `done`s (2.2, 8.1).**

- The hand frees match: `src/` 7, rmacs 9 (4 `Mem.free` plus 5
  `Heap.heap^.free`), rjson 6, ravite 2, rlX11 1, others 0.
- rnet has 41 `done`s, not 30: `src/` has 30, its tests 11. With 41,
  "54 to 26" becomes 65 to 25 or 26. That still makes the point.
- The mendings in section 15 misdescribe some of the frees:
  - rjson's 6 are all `Mem.free` of grown arrays (`nodes`, `kids`,
    `stack`), with no `Str.free`. They mend by `Vec`, not by `Names`
    or `Buf`.
  - ravite's 2 are `Text`'s grown `data` and `changes`, not windows.
    They mend by `Vec` or `Buf`, not `Pool`.
  - Only rmacs's 5 `Heap` frees, of windows and parts, are `Pool`
    material.

**1.8 "35 places assign Buf.bytes, Vec.all or Windows.all"** holds.
A grep finds 36 assignments to locals and 3 to fields (`m^.body`, and
`res^.body` twice). The only `.all` is rmacs's `Windows.all`.

**1.9 "Records that hold slices: src/ 10" isn't reproduced.** I find
three slice fields in `src/`'s records: `Diag.File.path`,
`Sym`'s `path*` (line 116) and `X64.Said.text`. 13.3 repeats "10".
**Correction:** 3, or say how 10 was counted.

**1.10 Dereferences: "Every one is a pointer from NEW on the heap,
which the compiler never frees" (2.2) is false today.** Some are not:

- `X64`'s `r^`, `size^` and `o^` point at locals through `ADR(r)` and
  `ADR(ao[an])`.
- `Elf`'s `dynSize^` and `roExtra^` point at locals.
- `Scan`'s `bits^` points at a local.
- `Diag`'s `f^` and `Chunk`'s `c^` point into grown arrays that
  `regrab` frees (`Scan.raz:137`, `Diag.raz:103`).

They are few (tens), and part A's mendings would remove them. But the
sentence should say "nearly every".

**1.11 The `src/` `ADR`-and-cast table (2.2) misses some sites and
miscounts others.** The table sums to 55. There are 62 distinct lines
with an `ADR` or a cast.

- Grown arrays: 31 lines are `grab`/`regrab`/`free` of arrays. 3 more
  are single records, `^Buf.Buf(Scan.grab(SIZE(Buf.Buf)))`, which
  should be `NEW`, not `Vec`.
- "A real's bits" are 4 lines (Item 152, 165, 364; Scan 879). 3 more
  are a value's bytes for data (`Gen.raz:293`, `Parse.raz:3186`,
  `Parse.raz:3334`). They need `setData` and the copy to take a slice,
  besides the view.
- `intern`: 7, correct. Two `Elf.putBytes(ADR(s[0]), LEN(s))` are
  missing.
- Out-parameters: 4 lines, 8 `ADR`s, not 5.
- Not listed at all:
  - `ADR(chunks[n])`, `ADR(files[i])` ×2 and `ADR(ao[an])`;
  - `Scan.raz:119` (`return ADR(sbuf[0])`, the allocator);
  - `Item.raz:2155` (`^I64(p)`);
  - `Raz.raz`'s two `SYSCALL`s (`memfd_create`, and `execve` with
    `ARGV() + first`).

  The `SYSCALL`s mend by `Sys.memFile`, and `Sys.execve` with
  `Sys.envAt`, but they are not "1 SYSCALL".

### 2. The five programs

Each was extracted from appendix 3 and compiled with
`/home/user/raz/raz -Werror`. Each is identical to `S/demo/`.

| program | printed | status |
|---|---|---|
| SelfAppend | 24 `a` | 0 |
| Stale | `1 2` | 0 |
| Escape | `########` | 0 |
| Kept | `name-001: missing`, `name-002: missing` | 0 |
| Temp | `name-..b`, a space, then `01 00 00 00 00 00 00 00` | 0 |

All as claimed.

**2.1 SelfAppend's explanation (1.2) is vague where it could be
exact.**

- `Buf.room` copies, then frees the old block (`Buf.raz:36-37`).
  `Buf.str` then copies from `s`.
- The old block is size class 3 and the new one class 4. `Heap.free`
  writes only the 16-byte header (`b := ^Block(h)`, `Heap.raz:96`).
  Nothing allocates between the free and the copy.
- So with `Heap` in one thread the program is always right. That is
  not luck "in time".
- A block past 4,080 bytes gets pages of its own, and `free` unmaps
  them. Filled to 8,192 bytes, the same line stops the program:
  `Buf.raz:67:5: stopped by a bad address` (`W/demo/SelfBig.raz`).
  That makes a stronger demonstration than the one shown.

**2.2 Stale.** Holds as explained:

- The class-4 block of 16 elements is freed when the `Vec` grows to 32.
- `p` points into the class-5 block, which is freed at the next growth.
- `free` touches only headers, so `first[0]` and `first[1]` read 1
  and 2.

**2.3 Escape** holds.

**2.4 Temp.** The listing (`raz -S`) confirms one slot,
`[rbp - 40]`, for both calls.

- `a` was printed before anything overwrote the slot, so it shows
  `b`'s bytes.
- `b` points at the same slot. That slot was overwritten by the next
  call's argument, `Out.str(" ")`, whose length 1 lands at
  `[rbp - 40]`. Hence `01 00 ...`.
- "Whatever came after" is right. The precise cause is the next
  statement's temporaries.

**2.5 "Three are what the library's own documentation warns of" (1.2)
is two.** `Buf` ("until it next grows") and `Vec` warn. `Map`'s
documentation says nothing about keeping its keys: neither the module
comment nor `put`'s "k now maps to v". The proposal itself says the
caller "must know, from the documentation alone". **Correction:** "two
are what the library's documentation warns of, one what it doesn't
say, and two what 7.3 and 8 warn of." Or mend `Map`'s comment.

### 3. Benchmarks

The machine is a 4-core Xeon VM at 2.1 GHz, with AVX-512. `lscpu`
reports L2 2 MiB a core and **L3 260 MiB**. THP is `madvise`.

**3.1 Two runs each of MemBench and GenBench (ms):**

| kernel | proposal | mine, run 1 | mine, run 2 |
|---|---|---|---|
| big, raw, 16-byte nodes | 8,312 / 7,515 | 5,300 | 4,859 |
| big, handles, 32-byte slots | 12,336 / 11,992 | 10,665 | 10,429 |
| small, raw | 857 / 810 | 864 | 876 |
| small, handles | 1,631 / 1,643 | 1,829 | 1,734 |
| big, raw, 32-byte nodes | 14,001 / 13,725 | 13,734 | 13,499 |
| big, fat pointers | 8,672 / 10,145 | 9,232 | 10,624 |
| small, raw, 32-byte | 870 / 917 | 852 | 870 |
| small, fat | 830 / 1,047 | 815 | 888 |
| sum, big, `^U8` / `[]U8` | 305 / 342; 271 / 434 | 296 / 279 | 318 / 370 |
| sum, small, `^U8` / `[]U8` | 261 / 265; 256 / 306 | 336 / 428 | 387 / 392 |

Findings:

- **Big handles cost 2.0 to 2.2 times here, not 1.5 to 1.6.** The raw
  baseline varies by 40% between sessions.
- **The working sets are not "past the caches".** The big arrays are
  16 MB and 32 MB, inside a reported 260 MB L3. So "doesn't fit in
  the caches" and `Big = 1000000; (* past the caches *)` are wrong
  here. What grows with the node is the page-walk footprint and the
  share of L3, not a miss to DRAM.
- **"Half of it the larger slot" is not supported.** Across the two
  programs, the 32-byte raw chase (13.5 s) is *slower* than the
  32-byte handle chase (10.5 s). The two programs aren't comparable.

**3.2 Why big-gen beats big-ptr.** I tested three explanations:

- Run order (`W/mb/GenOrder.raz`): not it. Gen first or second, gen
  11.4 to 11.6 s, ptr 13.4 s.
- Array placement in bss (`W/mb/GenSwap.raz`): not it. Ptr stays
  slower.
- Layout and code (`W/mb/GenWhy.raz`, 50M steps):
  - ptr 6.8 s;
  - gen 3.8 to 4.5 s;
  - gen with no check 2.7 to 3.9 s;
  - a raw pointer chase over the *gnodes* array 4.2 to 5.8 s.

  In `W/mb/Offs.raz`, the same 32-byte node chased raw takes 6.3 to
  6.5 s with the link at offset 0, and 5.3 to 5.9 s with it at offset
  8.

So part of the gap is the node's layout (where the link and the value
sit), and the rest is noise of ±20 to 30% on this VM. The generation
check itself isn't what the rows measure. Its cost is within noise;
calling it "free" or "the check is free here" goes further than the
data. The same layout effect sits inside the "+70–85%" for doubling a
node: the comparison is across two programs with different layouts.
**Correction:** "On this machine, wider records and handles cost 1.5 to
2.2 times in a pointer chase; the measurements can't separate the
check from layout and noise." Keep the conclusion against fat
pointers on other grounds: C interop, record size.

**3.3 MemBench understates a real `Pool`.** `chaseHandle` indexes a
fixed module array inline: no call, no copy of `T`, no heap
indirection, no `LENDS` count. `Pool.get` (8.2) is a call that copies
`T`, through a `const p: Pool`, into a heap block. `Pool.at` adds a
counted lend. Expect more than the table's figure.

**3.4 The bounds-check sums** do test the check: the listing shows
`cmp r12, rsi; jae` in the loop. My figures run from -6% to +27%.
"0–15%" is about right, given the noise.

**3.5 The scanner experiment** repeats: `valgrind --tool=callgrind`
of `S/base/raz` and `S/safe/raz` over `src/Raz.raz` gives 240,850,230
and 251,594,863 instructions, +4.46%.

Caveats:

- The "safe" `Scan` still uses `PTR(cur.buf)` and
  `intern(PTR(buf) + start, ...)`, so it isn't safe. The cost of
  `intern(s)` taking a slice isn't measured.
- `PTR` is not in v0.19.0, so this `Scan` can't be built by `BOOT`
  yet.
- Wall-clock times of the 348,025-line bench were 688 to 891 ms for
  the base compiler and 723 to 858 ms for the "safe" one, interleaved
  six times. The "safe" one was sometimes faster. Wall clock can't
  show 5% here.
- The proposal's "625 to 660 ms" was a quiet moment. At this
  session's best (688 ms, 506,000 lines a second) 5% more is about
  480,000, still above the floor. On a slow run (891 ms, 390,000) the
  floor already fails today.

**3.6 "Two 8-byte moves become one 16-byte one" (13.3)** is true only
from memory to memory. Into the rax/rdx pair the ABI returns a slice
in, or from it, a `movdqa` needs `movq` and `pextrq`/`pinsrq`. That is
three instructions and a domain crossing, not none.

### 4. Library signatures, report sections, quotations

- **Exact:**
  - `Thread.spawn*(p: proc(arg: ^U8); arg: ^U8): (^Thread, ERROR)`;
  - `Str.copy*(a: ^Mem.Allocator; s: []U8): ([]U8, BOOL)`;
  - `Buf.spare*(var b: Buf; n: INT): []U8`;
  - `Buf.bytes*(const b: Buf): []U8`;
  - `Map.put*(var m: Map; k: K; v: V): BOOL`;
  - `Sys.mmap`, `Sys.munmap`, `Sys.nextEntry(var d: Dir)`,
    `Sys.read(fd: INT; buf: []U8): INT`;
  - `Item.raz:58` is `frame*: BOOL` with the comment the proposal
    describes;
  - `C` has 96 `extern`s and `CAbi` 2; `Vec` has 11 fenced lines;
  - `src/` is about 11,550 lines of code by a comment-stripping count
    (rloc isn't installed), so "about 11,500" holds.
- **`Vec.all`'s comment** is "The elements, until the array next
  grows." "Good until the array next grows" is in `Vec`'s module
  comment and in `add`'s (capitalized). The quote is fair, but not
  `all`'s own words.
- **7.6 is misquoted (9.1).** The report says a variable raced on
  "holds no particular value then: a read of it gives a value it had
  or was given, or a mixture of their bytes. Nothing else of the
  program becomes undefined by it." The proposal puts "holds" in
  front of "a value it had or was given", which the report doesn't
  say. **Correction:** quote "a read of it gives a value it had or was
  given, or a mixture of their bytes".
- **Section 10's "no run time besides the code it uses" (19)** is said
  of "a program that doesn't [use C]". The quote is exact. It is a
  property of programs without C, not a promise of the language. That
  weakens the argument a little; line 7 of the report ("no hidden run
  time") supports it better.
- **5.3 (16):** a slice's alignment is set in 5.1 ("a slice is aligned
  as an address is"), not 5.3. The sentence to change is there.
- **Elf "writes the executable through `Sys.write`" (5.4):** it uses
  `Files.write(path, buf[0..len])` (`Elf.raz:442`). The conclusion
  holds.
- **Zig in 12:** `@intToPtr` has been `@ptrFromInt` since Zig 0.11.
- **The Go memory-model wording** in 9.1, "arbitrary memory
  corruption", is accurate.
- **Section 15's `ret` list** leaves out `Vec.tryAdd`, which 17 marks.
  **Neither list marks `init`'s allocator `keep`** on `Buf`, `Vec`,
  `Map`, `List` or `Pool`. Every one stores `a` in its record, and
  5.3(3) says "what it doesn't mark keep, it doesn't hold past the
  call". See 5.5 below.

### 5. Code samples and the proposal's own rules

**5.1 Today's-raz samples compile.**

- Appendix 2 and 3 compile.
- 6.4's `greet`, `first` (without `ret`) and `remember` compile.
- 7.1's loop compiles (`W/demo/Samples.raz`).

**5.2 The help in 6.4 and 14.3 doesn't compile.** "give put a copy
that lasts: `Str.copy(Heap.heap, buf[0..8])`". `Str.copy` has two
results:

```
Samples.raz:31:27: error: copy returns several results
    help: they go to variables: a, b := copy(...)
```

**Correction:** "copy it first: `k, ok := Str.copy(Heap.heap,
buf[0..8])`".

**5.3 The message positions are off.** The positions shown don't match
the programs:

- `Kept.raz:10:30`: the call is at line 11, column 27.
- `Escape.raz:14:12`: it is at 15:12.
- `Window.raz:41:13 ... XNextEvent(dpy, ADR(ev))`: the line in
  `examples/Window.raz` is 59, `_ := XNextEvent(d, ^U8(ADR(ev)))`.

Window's help, "or pass ev as a var", is impossible. An `extern`'s
parameters are integers, `BOOL`, reals, pointers or procedures (report
9), and the module is unsafe for its `extern`s anyway. Pick a safe
module's `ADR` for that example.

**5.4 The Escape message assumes a `head` that 6.2 forbids.** It says
"head's result points into what it is given (ret h)". Appendix 3's
`head(var h: Hex)` has no `ret`, so under 6.2 the first error is in
`head` itself: "returning what is lent by h, not marked ret".

**5.5 7.3 forbids what 14.2 recommends.** 7.3 says an owner-lent
reference "returned ... is an error". 14.2's option 1 is `proc
name*(ret const m: Message; i: INT): []U8; (* m^.head's bytes, lent by
m *)`, which returns bytes of `m.head`, a `Buf`. That is exactly an
owner-lent return. 7.2 also says a `Message` is not an owner, so it
can't lend through `ret` at all.

The same rule refuses `tools/Widths.raz`'s `load(path; var b:
Buf.Buf): []U8 ... return Buf.bytes(b)`, yet section 15 says `tools/`
has "none found". It also refuses any safe wrapper over `Vec.all` or
`Pool.at`.

Either 7.3 allows returning through a `ret` parameter that is itself
an owner, or the library's own exports, which do this, need a
different rule from safe code. If returning is allowed, the hold must
pass to the caller, and 7.3 doesn't say how.

**5.6 Part C stops correct programs, the library's and the compiler's
included.** 7.3 lets a local's hold go only when the procedure
returns, and 7.4 makes `done` stop while a count is above zero. A scan
for a slice held from `Buf.bytes(b)` and a later `Buf.done(b)` in one
procedure (`W/py/heldone.py`) finds:

- `lib/Opt.raz` `say`: `s := Buf.bytes(b)`, loop, `Buf.done(b)`;
- `src/Parse.raz` `moduleParams`, lines 3696 to 3699 (every generic
  instance);
- ravite's `load` (`Ravite.raz:1402`, done at 1411).

Five more do `defer Buf.done(x)` and then hold `Buf.bytes(x)`:
`examples/Elf.raz` `main`, rnet `Dns.init` and `fromHosts`, and rmacs
`writeFile` and `loadInit`. Whether those stop depends on whether a
hold's let-go runs before or after the deferred statements. The
proposal says only "as a defer would".

So the compiler itself would stop on every program with a generic
import. 14.2 calls this "a false alarm only when name is never read
again", and these are exactly such cases. Section 15's claim that
every break is found when compiling, but `done`, should count them.
**Correction:** let a hold go at the variable's last use, or at a
`done` of the owner from the same procedure (both known in one pass
only for straight-line code). Or count these breaks and mend them with
`s := []`.

**5.7 A `Buf` or `Vec` over an `Arena` has no safe form.** By 8.4,
`Arena.allocator(ar)` is lent by `ar`, and a lent value can't be
stored in a record (6.2) or given to `keep` (5.5 above). `Buf.init`
keeps its allocator, so `Buf.init(b, Arena.allocator(ar))` is an
error. This pattern appears in:

- `Fmt.eprint`;
- `Fmt`'s test;
- `Buf`'s test;
- `examples/Sh.raz`, lines 88 and 188.

So "Fmt ... can be safe" (5.4, 15, 17) and "Sh ... mended by var" (5.4,
15) fail. `Fmt.format` also takes `^Buf.Buf` with `nil` for standard
output, which needs an interface change.

**5.8 Other "can be safe" claims (5.4).**

- `Files.arg` *is* `ARGV()[i]` and pointer indexing
  (`Files.raz:10-13`). 5.1 fences `ARGV` and names `Files.arg` as the
  safe form, so `Files` must stay unsafe, or `ARGV` must move into a
  trusted module.
- `Str.copy` and `Str.free` index and free a `Mem.alloc` pointer. `Str`
  can be safe only if `Mem` gains a safe slice allocation. Section 17
  doesn't add one, and `free` is an `unsafe proc` in a module 17 calls
  safe.
- `Lock` needs E.4 (`CAS` on a variable) first.
- `examples/Workers.raz` uses `Thread.spawn(work, nil)` and
  `XADD(ADR(next), 1)`. It needs `Task` and E.4, not `var`.

**5.9 Owners can't sit in generic containers.** 7.6 forbids passing an
owner as a value parameter or copying it. `Vec.push(x: T)`,
`Pool.add(keep x: T)`, `Map.put(..., v: V)` and `List.push` all copy.
So `Vec(Buf.Buf)`, `Pool(Window)` where a `Window` holds a `Buf`, and
`Names(Buf.Buf)` can't be used. Yet 14.2 turns rmacs's windows, which
hold `Buf`s, into a `Pool(Window)`. The proposal needs an `add` that
gives a zero slot in place (`Pool.at` after a zero `add`) and says
that copies are refused there.

### 6. The compiler's cost (section 18)

- **A, 120:** about right, perhaps to 150. It needs `unsafe proc`'s
  rules in `Sym.same` and assignability, the two contextual places the
  word stands, the interface check, and a generic instance taking its
  module's mark.
- **B, 300–450: low.** PROPOSALS' own second review (its open
  question 4, PROPOSALS.md line 476) revised part 3 to "400 to 600
  lines, not 250 to 400", for slices alone. This proposal adds
  pointers, owners as lenders, `match` names (10.4), literal parts and
  generic instances checked one by one. Likely 550 to 800.
- **C, 200: low.**
  - Hidden hold slots per local.
  - A raise at each call that returns an owner-lent value.
  - A lower at the end of each statement. Only `const`'s temporaries
    have such a point today.
  - A let-go on every exit, `try` and early `return` included, with
    an order against `defer` (5.6).
  - The copy check at assignment, value parameters, results, literals,
    comparison, views and generic instances (5.9).
  - Likely 300 to 450.
- **D, 20:** plausible.
- **E, 80: low.**
  - 16-byte alignment of slices changes record layout in `Sym`, and
    frame-slot and temporary alignment in `Gen`.
  - Every slice load and store goes through xmm, with
    `movq`/`pinsrq`/`pextrq` for the rax/rdx pair. `X64` today
    encodes `movdqu` but not those.
  - Records holding slices are copied by `rep movsb` past `MaxMoves`.
  - `CAS`, `XCHG` and `XADD` change from pointer to variable in
    `Parse` and `Item`.
  - `lock xadd` when `Thread` is imported.
  - Likely 150 to 250.
- **F, 20:** plausible, since `defer`'s reserved slots exist.
- **Messages, 100:** plausible for about 10 new kinds with help.

**In all, likely 1,250 to 1,700, not 840 to 990.** That still fits
under 14,000, from about 11,550, but with much less room than 18
suggests for the documentation the house style requires.

The `src/` rewrite is also larger than "35 grown arrays". `Chunk.chunks`,
`Chunk.text` and `Chunk.rodata` are exported and indexed from `Item`,
`Parse`, `Gen`, `Raz`, `Elf`, `Link` and `X64`: about 250 lines of
`p[i]` and `p[a..b]` outside `Scan`. Each would become a `Vec.all(...)`
with a counted lend, often in `X64`'s emitter and `Link`'s patching,
which are hot. 13.1's "cost nothing measurable" for these is
unmeasured.

### 7. `src/` becoming safe (2.2, 5.4, 15)

The plan is plausible module by module, with three gaps:

- **Elf:** its buffers are a `grab`/`regrab` byte array (a `Buf`), plus
  `putBytes(ADR(s[0]), LEN(s))` (a slice parameter) and
  `sizeTables(ADR, ADR)` (`var`). It can be safe.
- **Diag:** `files` is a grown array (`Vec`), and two `^Buf.Buf(grab)`
  become `NEW`. `File.buf: ^U8` keeps a pointer to the scanner's
  source. As a slice it is lasting only if `Scan`, unsafe, promises
  so. It can be safe.
- **Link:** four arrays sized once from `Scan.grab`, then `p[i]` 63
  times. They need `Vec(INT)` with `resize`, or a typed `grab` that
  gives a slice. Safe, at the cost of checks on the linker's paths.
- **Chunk:** grown record arrays exported to every module, and
  `ADR(chunks[n])`. Safe as `Vec`s, but see 6 on cost and lines.
- **X64:** `said` is grown, `^Buf.Buf(grab)` becomes `NEW`, and the
  `isReg` out-parameters and `operand(ADR(ao[an]))` become `var`. It
  writes `Chunk.text` per byte. Safe, with that cost.
- **Gaps:**
  - `Raz.raz` needs its `SYSCALL`s and `ARGV() + first` replaced:
    `Sys.memFile`, and `Sys.execve` with an environment built from
    `Sys.envAt`.
  - `Scan.grab`'s callers outside `Scan` (`Item.raz:2154`,
    `Parse.raz:452`, `Parse.raz:3812`, `Raz.raz:165`) index its
    `^U8`. `grab` must give a slice.
  - `Parse.moduleParams` stops at run time under part C (5.6).

"`src/` keeps one unsafe module: Scan" can be reached, but it is
several hundred changed lines, not the table's 55 sites.

### Confirmed

- The demos' outputs and status 0, and that each does the undefined
  thing claimed.
- The callgrind counts, +4.5%.
- Appendix 1's per-module tallies, as the aggregator gives them, read
  as lines.
- The hand-free counts.
- rmacs's 560 and 556, and ravite's 202, `ADR`s.
- About 36 held `Buf.bytes`/`Windows.all` slices.
- `tools/` has no fenced operation.
- Threads in rnet (`Http`'s server, tests) and rsqlite (`Sqlite`'s
  test) only.
- Lines per repository, about 50,000.
- `src/`'s 7 frees all in grown arrays.
- The cited signatures, and `Item.raz:58`.
- 7.3's and 8's text on what isn't caught.
- `C` 96 and `CAbi` 2 `extern`s.
- The sums' bounds check really emitted.
- `src/` about 11,500 lines of code.

---

## Appendix 7: adversarial review, porting real code

Section 14 says most raz stays as it is and the pain is narrow. To
test that, six pieces of real code were ported on paper under parts A
to F, read as strictly as a compiler would read them: rnet's `Http`
with its test servers, rmacs's buffers and windows, the compiler's
name table, grown arrays, files and scopes, the library's `Fmt`, `Opt`,
`Map` and the containers, `examples/Sh.raz`, and rjson's `Json`. About
25,000 lines were read; about 900 of them change for parts B to F, 4%,
on top of the `ADR`s the fence turns into `var`, which `STANDARDS.md`
asks for anyway. By lines, then, the claim holds. By kind it doesn't.
The changes gather in the one type each piece is built round
(`Http.Message`, rmacs's `Text` and its accessors, `Chunk`'s arrays,
`Sh`'s arena, `Json.Doc`), and each of those needs a redesign, not a
mark. Three rules cause most of it: an owner's lend can't be returned
by any procedure but the owner's own, can't sit in a record, and the
fence has no safe form for a pointer to "the caller's state". The
port also found six holes in the rules as written (A7.7): four let
unsafe code through, and two leave a trap or an undecided stop. It
found eight places in correct code that would stop at run time with
`done` while held, and no real bug in today's code.
Most of the pain goes away with seven additions that weaken nothing
(A7.10).

### A7.1 How it was done

Each piece was first brought to today's library, so that an `ADR` at a
call where the library now takes `var` doesn't count. Then each rule
was applied to every line. Where the proposal is unclear, the stricter
reading was taken, and noted:

- **A pointer parameter is lent by its parameter** (6.1, 6.5). Storing
  one in a module variable or a record needs `keep`.
- **Reading through a pointer gives a lasting value.** Only lasting
  values may be stored through a pointer (6.2), so what is read back
  is lasting too. The more lenient reading is taken here.
- **An owner's lend may be returned only through a `ret` parameter
  that is the owner itself**, as `Buf.bytes` does. 7.3 says that
  returning one is an error. 6.2 allows it through `ret`. The middle
  reading is the only one under which the caller still knows whose
  count to raise.
- **A local array or record may not hold an owner's lend** (7.3), not
  even one of slices.

"Changed" counts lines touched, written or removed, against the
source as it stands. The counts come from reading and `grep`, not from
a compiler, and are good to about a fifth.

### A7.2 rnet's `Http` (`src/Http.raz`, `src/Conn.raz`, `test/Webserver.raz`, `test/Server.raz`, `examples/Hello.raz`)

**What the rules reject.**

| Line or construct | Rule | The compiler's error |
|---|---|---|
| `m^.headers[m^.n] := {name: l[0..colon], value: trim(...)}` (`parseHeaders`), `l` a slice of `Buf.bytes(m^.head)` | 6.2, 7.3 | `Buf.bytes(m^.head) is lent by m^.head, which counts what it lends: hold it in a slice variable` |
| `m^.raw := text`, `m^.method := l[0..i]`, `m^.target := ...`, `m^.reason := ...` | 7.3 | the same |
| `m^.body := Buf.bytes(ADR(m^.data))` (`readWhole`) | 7.3 | the same |
| `res^.body := Buf.bytes(ADR(text))` (Webserver, twice) | 7.3 | the same, in the program that uses `Http` |
| `Http.add(res, "Location", Buf.bytes(ADR(text)))` (Webserver, twice), `add(ADR(res), "Date", Buf.bytes(ADR(when)))` (`serveConn`) | 6.2: `add` stores `name` and `value`, so it is `keep` | `Http.add keeps its value, and Buf.bytes(text) is lent by text` |
| `head := m^.head; ... m^ := {..., head: head, data: data}` (`reset`) | 7.6 | `a Buf.Buf owns memory, and can't be copied` |
| `out := req^` (`open`): a `Message` with two `Buf`s, copied | 7.6 | the same |
| `try parseUrl(Buf.bytes(ADR(here)), ADR(u))`: `parseUrl` keeps slices of `s` in `u^` | 6.2 | `parseUrl keeps s, and Buf.bytes(here) is lent by here` |
| `cl^.scheme := u^.scheme` (`connect`), always `"http"` or `"https"` | 6.2: `u`'s parts are lent as `u` is | `u.scheme is lent by u, a parameter not marked keep` |
| `r^ := {conn: c, ...}` (`startBody`), `c` an `ADR` of a local `Conn` or of `cl^.conn` | 5.1, then 6.2 | `ADR is for unsafe modules`; with `var c`, `c is a var parameter and can't be kept` |
| `return ADR(cl^.body), nil` (`open`) | 5.1 | `ADR is for unsafe modules` |
| `Thread.spawn(work, ^U8(s))`, `s := ^Server(arg)` | 5.1, 5.2 | `a conversion to a pointer is for unsafe modules`; `Thread.spawn is an unsafe procedure` |
| `Handler = proc(req, res: ^Message; arg: ^U8)`: a safe handler can't turn `arg` back into its own type | 5.1 | the same, in every program with state |
| `t := ^Text(c^.state)` (`Http`'s and `Conn`'s tests); `Conn.state: ^U8` | 5.1 | the same |
| `proc trim(s: []U8): []U8` returns `s` | 6.2 | `trim's result is lent by s, which isn't marked ret` |
| every `^Message`, `^Conn.Conn`, `^Reader`, `^Url`, `^Client`, `^Server` parameter given `ADR(local)`: 228 `ADR`s in `Http.raz`, 37 in `Conn.raz` | 5.1 | `ADR is for unsafe modules` |

The last row is what `STANDARDS.md` asks for, `var` or `const`. It
changes `Http`'s whole interface, and every program that calls it.
It is counted apart below.

Section 14.2 offers a way out: `Http` says `unsafe;` and keeps
`Message` as it is. That breaks the proposal's own rule 4 of 5.3. A
safe program can read `req^.body` after `Http.done(req)`, so the
exported slice fields are just what a safe module could misuse. And
the programs that *write* messages (Webserver, `Hello`) are safe
modules: they still can't store a `Buf`'s bytes in `res^.body`. So the
spans are the only design that compiles.

**Rewritten.** The text a message holds goes in its own buffers, as
spans. Everything a program gives it is copied in.

```
(* Before *)
Header* = record
    name*, value*: []U8;
end;
Message* = record
    method*, target*: []U8;
    status*: INT;
    reason*: []U8;
    minor*: INT;
    headers*: [MaxHeaders]Header;
    n*: INT;
    body*: []U8;
    maxBody*: INT;
    close*: BOOL;
    raw*: []U8;
    head, data: Buf.Buf;
end;

(* After *)
Span = record at, len: INT; end;            (* bytes at up to at + len of one of the buffers *)
Header = record name, value: Span; end;     (* in head *)
Message* = record
    status*, minor*, n*, maxBody*: INT;
    close*: BOOL;
    method, target, reason, raw: Span;      (* in head *)
    headers: [MaxHeaders]Header;
    body: Span;                             (* in data *)
    head, data: Buf.Buf;                    (* all of its text, read or to be written *)
end;

(* s added to b, and where it stands there *)
proc put(var b: Buf.Buf; s: []U8): Span;
begin
    Buf.str(b, s);
    return {at: b.len - LEN(s), len: LEN(s)};
end;

proc add*(var m: Message; name, value: []U8): ERROR;
begin
    if m.n = MaxHeaders then return TooManyHeaders; end;
    m.headers[m.n] := {name: put(m.head, name), value: put(m.head, value)};
    INC(m.n);
    return nil;
end;

proc setBody*(var m: Message; s: []U8);     (* new: s copied into the message *)
begin
    Buf.reset(m.data);
    m.body := put(m.data, s);
end;

(* The bytes of sp in b *)
proc bytesOf(ret const b: Buf.Buf; sp: Span): []U8;
begin
    return Buf.bytes(b)[sp.at..sp.at + sp.len];    (* fine: b is the owner, and ret *)
end;

proc target*(ret const m: Message): []U8;
begin
    return bytesOf(m.head, m.target);   (* refused as written: lent by m.head, a part of m; see A7.7, H2 *)
end;
```

`target`, `method`, `reason`, `raw`, `body`, `header`, `name(i)` and
`value(i)` are new accessors, and the setters `setMethod`,
`setTarget`, `setReason` and `setBody` are new too. They need the
relaxation R1 of A7.10 to compile at all. In the programs:

```
(* Before (Webserver) *)
path := req^.target;
Fmt.write(ADR(text), "{}", [Fmt.int(conns)]);
res^.body := Buf.bytes(ADR(text));

(* After *)
path := Http.target(req);               (* held, and counted on req's head *)
Fmt.write(text, "{}", [Fmt.int(conns)]);
Http.setBody(res, Buf.bytes(text));     (* copied *)
```

`reset` keeps its buffers by moving them out and back:

```
proc reset*(var m: Message);
var head, data: Buf.Buf; max: INT;
begin
    Buf.take(m.head, head);
    Buf.take(m.data, data);
    max := m.maxBody;
    m := {minor: 1, maxBody: max};      (* the owners left out: empty *)
    Buf.take(head, m.head);
    Buf.take(data, m.data);
    Buf.reset(m.head);
    Buf.reset(m.data);
end;
```

`m := {minor: 1, maxBody: max}` alone also compiles. It drops both
buffers' memory and their allocator, so the next `Buf.add` calls a
`nil` allocator and stops (A7.7, H4).

A `Reader` can't hold the `Conn` it reads from, since no safe pointer
to a local `Conn`, or to `cl^.conn`, exists. Either the `Conn` comes
from `NEW`, and a `Client`'s 16 KB buffer can never be freed (D), or
the reader takes the connection on each call:

```
proc read*(var r: Reader; var c: Conn.Conn; b: []U8): (INT, ERROR);
proc readBody*(var cl: Client; b: []U8): (INT, ERROR);   (* open no longer returns ^Reader *)
```

`parseUrl` fills a local `Url` with slices of a `Buf`, and the `Url`
dies before the `Buf` does. That is PROPOSALS' false alarm of "a record
that lives in the frame". Returning the `Url` as a result doesn't help,
since a local record may not hold a lend (7.3). The cure that compiles
copies the URL into a frame array, whose slices a local record *may*
hold:

```
var here: [MaxUrl]U8; hereLen: INT; u: Url;
...
try parseUrl(here[0..hereLen], u);     (* frame-lent: allowed in the local u; parseUrl's s is keep *)
```

So a URL gets a fixed limit only to get past the rule. `cl^.scheme :=
u.scheme` becomes `cl.tls := u.scheme = "https"`. The server's threads
become `Task(^Server)`, `Hello` makes its `Server` with `NEW`, and
`arg: ^U8` goes from `Handler`. A server with state keeps it in module
variables, shared by its workers with no lock unless it uses
`Lock.Guarded`. The tests that cast `Conn.state` go into an unsafe
module of their own.

**Count.** About 2,700 lines, tests included. The fence alone
(`ADR` to `Http`'s own pointer parameters, casts): about 330 lines.
Parts B to F: `Message` and its accessors and setters about 120, the
readers and writers that use them about 40, `reset` and `open`'s copy
15, `Url` 15, `Reader` and `Client` 20, threads and the handler 10,
Webserver 8, `Server` 16, `Hello` 3. About 230 lines in all, 9%.

**Judgement: worse.** Every field is now a call. Each header and each
body a handler makes is copied once more, and a 100,000-byte body made
in a `Buf` is copied whole. Fixed limits come in only to dodge a rule
(`MaxUrl`), and handlers lose their context. In return, "good until the
message is read again or reset", which `Http`'s header comment asks a
reader to remember, is now checked.

**Contortions and false alarms:** `parseUrl` into a frame array; the
scheme as a BOOL; `Reader` without its `Conn`; the accessors, which
don't compile without R1. **Run-time stops in correct code:** none
found. **Real bugs caught:** none. `reset`'s copy of the `Buf`s, which
section 7.6 calls "safe by luck", is right: the copies are put back at
once. `res^.body := req^.body` in `test/Server.raz` is right by the
order `serveConn` keeps.

### A7.3 rmacs (`src/Core.raz`, `Commands.raz`, `Text.raz`, `Mini.raz`, `Dired.raz`, `Windows.raz`)

**What the rules reject.**

| Line or construct | Rule | The compiler's error |
|---|---|---|
| `Text`: `data: ^U8`, `Mem.alloc`, `Mem.free`, `t^.data[i]`, `^U8(t^.changes)` | 5.1, 5.2 | `Mem.free is an unsafe procedure`, `indexing a pointer is for unsafe modules` |
| `proc slice*(lo, hi: I64): []U8; ... return Text.slice(ADR(b^.t), lo, hi)` (`Core`), 12 callers | 7.3: returned, lent by the owner `b^.t`, which no parameter names | `Text.slice(b^.t, lo, hi) is lent by b^.t, which counts what it lends, and can't be returned` |
| `proc text: []U8` (`Mini`), the same through `Core.mini^.t` | 7.3 | the same |
| `proc nameAt(i: I64): []U8` (`Dired`), a slice of the module `Buf` `names` | 7.3 | the same |
| `bufferNames(i)` returns `Buf.bytes(ADR(choices[i]^.name))`, as a `Mini.Names` procedure value | 7.3 | the same; and no mark on `Mini.Names` could allow it |
| `Heap.heap^.free(Heap.heap, ^U8(x))` (`Core.kill`), four in `Windows` | 5.1, 5.2, D | `Heap's free is an unsafe procedure` |
| `t := ADR(w^.buf^.t)` (`Rmacs.colours`) | 5.1 | `ADR is for unsafe modules` |
| `DEC(out^.len)`, `DEC(line.len)`, `s.len := ...`, `t^.log.len := ...`: 7 writes of a `Buf`'s `len` | 5.3 rule 4 (see A7.7, H3) | nothing, as the proposal stands: a safe hole |
| `selected := w`, `shown := x`, `Core.b := x`: a pointer parameter stored in a module variable (8 procedures) | 6.2, read strictly | `w is lent by the parameter w; mark it keep` |
| 139 `ADR`s given to rmacs's own pointer parameters (`Text.len(ADR(b^.t))`, `Mini.read(..., ADR(answer))`) | 5.1 | `ADR is for unsafe modules` |

**Rewritten.** No procedure but the owner's own can hand out what an
owner lends, so `Core.slice` can't be written, and each of its twelve
callers names the text itself:

```
(* Before *)
Buf.str(ADR(Core.tmp), Core.slice(p, b));
(* After *)
Buf.str(Core.tmp, Text.slice(Core.b^.t, p, b));
```

A procedure value can't return a lend either, so `Mini.Names` changes
to write the name into a buffer it is given:

```
(* Before *)
Names* = proc(i: I64): ([]U8, BOOL);
proc bufferNames(i: I64): ([]U8, BOOL);
begin
    if i >= numChoices then return "", false; end;
    return Buf.bytes(ADR(choices[i]^.name)), true;
end;

(* After *)
Names* = proc(i: I64; var name: Buf.Buf): BOOL;     (* the i-th name, into name *)
proc bufferNames(i: I64; var name: Buf.Buf): BOOL;
begin
    if i >= numChoices then return false; end;
    Buf.reset(name);
    Buf.str(name, Buf.bytes(choices[i]^.name));
    return true;
end;
```

`gather`'s loop and `commandNames` change to match: about 10 lines. A
killed buffer and a closed window are not freed. Their contents are
(`Text.done`, `Buf.done`), and the empty record, about 200 bytes, is
kept to the end of the run:

```
Text.done(x^.t);
Buf.done(x^.name);
Buf.done(x^.path);
(* x itself is kept, empty: part D lets no safe module free it *)
```

That is five lines taken out. The `Pool(Buffer)` that section 14.2
offers would touch about 370 dereferences of `^Buffer` and `^Window`.
`Pool` can't take a `Buffer` at all anyway: `add(var p; keep x: T)`
passes `x` by value, and a `Buffer` holds owners (7.6). `Pool` would
need an `alloc(var p): Handle` that hands out a zeroed slot.

`Text` either says `unsafe;` and carries the owner's protocol by hand
(a `LENDS` field, retiring in `room`, `ret` on `slice`: about 25
lines), or is rebuilt on `Vec(U8)` and `Vec(Change)` (about 60 lines).
Its gap moves under a slice that is held (`moveGap`), which the rules
let pass, since it is memory-safe. That is right: today's comment,
"good until the next change", stays a comment.

**Count.** 4,931 lines. The fence alone: about 160 (the 139 `ADR`s,
the casts, `Text`'s heading). Parts B to F: `Text` 25, the four
accessors and their 20 callers 35, `Mini.Names` 10, `colours` 7, frees
5, `len` writes 7: about 90, 2%.

**Judgement: the same.** Twelve calls grow a little longer.
`Mini.Names` copies each name once per keystroke of ido, about 256
small copies, which doesn't show.

**Run-time stops in correct code.** `writeFile` holds `p :=
Buf.bytes(abs)` under `defer Buf.done(abs)`, and `loadInit` holds
`s := Buf.bytes(b)` under `defer Buf.done(b)`. Section 7.3 lets a
hold go "when the procedure returns", but doesn't say whether that is
before or after its deferred statements. If after, `C-x C-w` stops
the editor every time, and so does starting it with a `~/.rmacs`
(A7.7, H5). **Real bugs caught:** none. No self-
append or kill-while-held was found. `killBuffer` and `deleteWindow`
take care with `Core.b` and `Core.selected` already.

### A7.4 The compiler (`src/Scan.raz`, `Chunk.raz`, `Diag.raz`, `Sym.raz`, and their users)

**Scan's name table: can be safe, and is clearer.** Today names are
three hand-grown arrays and a table, all freed and copied by hand, and
the bytes sit in 64 KB chunks that are never freed. Safe, the chunks
come from `NEW` (lasting, so their slices last), and the arrays are
`Vec`s:

```
var
    chunk: ^[PoolChunk]U8;     (* from NEW, never freed: its slices last *)
    chunkUsed: INT;
    names: Strs.Vec;           (* import Strs := Vec([]U8) *)
    hashes, table: Ints.Vec;   (* import Ints := Vec(INT) *)

proc intern*(s: []U8): INT;    (* was intern(p: ^U8; n: INT), called with ADR(s[0]), LEN(s) *)
var h, i, k: INT; t, hs: []INT; p: []U8;
begin
    h := hash(s);
    t := Ints.all(table);
    hs := Ints.all(hashes);
    i := h & tableMask;
    while t[i] # 0 do
        k := t[i] - 1;
        if (hs[k] = h) and (Strs.get(names, k) = s) then return k; end;
        i := (i + 1) & tableMask;
    end;
    if (chunk = nil) or (LEN(s) > PoolChunk - chunkUsed) then NEW(chunk, Heap.heap); chunkUsed := 0; end;
    p := chunk^[chunkUsed..chunkUsed + LEN(s)];
    COPY(p, s);
    INC(chunkUsed, LEN(s));
    k := names.len;
    Strs.push(names, p);        (* keep: p lasts *)
    Ints.push(hashes, h);       (* may grow hashes: hs is retired, and not read again *)
    t[i] := k + 1;
    t := [];                    (* or grow's Ints.done(table) stops the program *)
    hs := [];
    if (k + 1) * 2 > tableMask then grow; end;
    return k;
end;
```

Two things here aren't in the proposal. `Strs.get` is new: `return
Strs.all(names)[n]` is refused, since an element of an owner's lend is
lent (6.1), though what it holds was stored by `keep` and lasts (A7.10,
R4). And `t := []` before `grow` is needed only to get past `done`'s
stop. Today's `intern` checks `n > chunkLeft` and then copies `n`
bytes into a 64 KB chunk: a name longer than 65,536 bytes would
overrun it. That can't happen, since `MaxStr` is 65,536 and `MaxIdent`
is 63, so the bound holds only by the coincidence of two constants.
The safe form checks it. About 40 lines change; the scanner's buffer
stays unsafe, as section 21 suggests.

**Chunk's grown arrays: can be safe, and grow longer.** `text`,
`rodata`, `chunks`, `fixups`, `dataFixups`, `lines` and `varNotes`
become `Buf`s and `Vec`s. `put1` becomes `Buf.add(text, U8(b & 0FFH))`,
which is clearer. But there are about 200 places in `Link`, `X64`,
`Elf`, `Gen`, `Parse` and `Item` that read `Chunk.chunks[c].adr` or
`Chunk.lines[i].at`, and each one becomes either

```
Chunks.all(Chunk.chunks)[c].adr := a;          (* a count raised and lowered, each time *)
```

or a local held over the procedure, `cs := Chunks.all(Chunk.chunks)`.
The obvious mending, `proc at*(c: INT): ^Chunk` in `Chunk`, can't be
written, since it returns a lend of an owner that no parameter names
(7.3). And a held `cs` across a `newChunk` that grows the array is a
new trap. The writes through `cs` go into the retired block and are
lost, with no message, even in the debugging heap, which poisons
retired blocks for reads only (11). Today that is a use after free.
Under the proposal it is a wrong executable, and the proposal calls it
"lost, but harmless" (7.4). For a compiler it is not harmless.

**Diag's files and messages.** `files: ^File` becomes `Vec(File)`, and
`pathOf` needs `Vec.get` (R4). `say` keeps every message for good, in
a `Buf` from `grab` that is never freed:

```
(* Before *)
b := ^Buf.Buf(grab(SIZE(Buf.Buf)));
Buf.init(b^, Heap.heap);
Fmt.write(b^, f, args);
return Buf.bytes(b^);

(* After, with Buf.leak (R5) *)
var b: Buf.Buf;
Buf.init(b, Heap.heap);
Fmt.write(b, f, args);
return Buf.leak(b);      (* b gives its block up for good: it lasts *)
```

Without `Buf.leak` the only safe form is a second copy, `Str.copy` of
the bytes and then `Buf.done`, for every message. `Sym.typeName` is the
same, and so are four `grab`-and-slice strings in `Parse`, `Item` and
`Raz`.

**Sym's scopes.** The hash table `hashTab: ^^Obj` becomes `Vec(^Obj)`,
and `rehash` builds a new one and drops the old. `Obj`s and `Type`s
come from `NEW` and are never freed, so the 1,015 dereferences stay as
they are, as 8.1 says. Under the strict reading of 6.1, though, each
procedure that stores a pointer it is given needs `keep`: `newObj`'s
`typ`, `insert`'s `obj`, and the 17 procedures of `Item` and `Parse`
that put a `^Sym.Type` or `^Sym.Obj` parameter into a `var x: Item`.
That is about 40 headings across `src/`, and every argument is a
pointer from `NEW` already (R3 removes them). `Parse`'s `curLoop :=
ADR(lp)` becomes a stack of loops in a module array, about 10 lines.

**Count.** 14,285 lines. The fence's own list (section 2.2): about 60
sites. Parts B to F and what the mending entails: Scan 40, Chunk 60,
the 200 accesses, Diag and the kept strings 30, Sym 20, `keep` marks
40, loops 10. About 420 lines, 3%.

**Judgement.** Scan's table and `Diag.say` come out clearer. `Chunk`
and `Link` come out longer, and no clearer, unless R1 allows accessors.
Speed: a call, a count and a bounds check where a pointer index stood,
on the symbol lookup and code emission paths. That is not measured; an
estimate is 1 to 3% of instructions, on top of the 4.5% of 13.1 if
`Scan` goes safe as well. **Run-time stops in correct code:**
`Parse.raz:3696`, `text := Buf.bytes(s)` and then `Buf.done(s)`, would
stop at the first generic instance the compiler made, and so `make
check` would stop in its first minute. **Real bugs caught:** none,
beyond the bound in `intern` that holds by luck.

### A7.5 The library (`Fmt`, `Opt`, `Map`, `Buf`, `Vec`, `List`, `Files`) and `examples/Sh.raz`

**`Fmt` can't be made safe as section 5.4 says.** `format` takes
`b: ^Buf.Buf`, with `nil` for standard output, and `write` and
`eprint` pass `ADR(b)`. Without `ADR`, the `nil` must become a flag,
and `print` has no `Buf` to pass:

```
(* After *)
var none: Buf.Buf;      (* never written: what print passes for b *)

proc put(var b: Buf.Buf; out: BOOL; s: []U8);
begin
    if out then Out.str(s); else Buf.str(b, s); end;
end;

proc print*(f: []U8; args: []Arg);
begin
    format(none, true, f, args);
end;
```

This is a contortion: an owner kept only to stand in for "none".
`eprint` builds its text in a `Buf` over an arena, so that a program
that doesn't call it carries no heap. Under the proposal
`Buf.init(b, Arena.allocator(ar))` is refused. `init` keeps its
allocator, so its parameter is `keep`, and the arena's allocator is
lent by the arena (8.4). So `eprint` moves to the heap and loses the
reason its comment gives. No container can take memory from an arena
in safe code. About 15 lines change.

**`Opt` is safe, with one stop in correct code.** `left` and
`leftWidth` take `const r: Row` for `ADR(p.table[i])`, six lines.
`init` is `keep name, table`, and `scope` is `keep name`. `say` would
stop:

```
proc say(fd: INT; var b: Buf.Buf);
var s: []U8; n: INT;
begin
    s := Buf.bytes(b);
    while LEN(s) > 0 do
        n := Sys.write(fd, s);
        if n <= 0 then break; end;
        s := s[n..LEN(s)];
    end;
    s := [];          (* new: else the next line stops, though s is empty and never read again *)
    Buf.done(b);
end;
```

Every usage message and every `--help` of every program goes through
`say`.

**`Map` marks are easy, and its uses narrow.** `put(var m; keep k: K;
keep v: V)` is one heading. `Map([]U8, V)` keys must now last, so a
key made in a `Buf` is `Str.copy`'d and never freed, or goes in
`Names(V)`. `Map(K, Buf.Buf)` can't be made at all: `put` takes `V` by
value, and an owner can't be copied. A map of strings to buffers, an
editor's "buffer by name", has no safe form but `Pool` handles.

**The containers export what breaks them.** `Buf.len*`, `Vec.len*`,
`List.head*` and `List.Node.next*` are fields a safe module can write.
`b.len := 1 shl 40; Buf.bytes(b)` reads any memory, because `bytes`
slices `b.data`, a pointer, unchecked. `l.head := other.head;
List.clear(l)` frees another list's nodes. This is 5.3's rule 4, but
section 17 doesn't list it. Hiding the fields changes every read of
`b.len` in every program, dozens in rmacs alone, unless fields can be
exported read-only (R6). `Files.load` writes `INC(b.len, n)` after
`Buf.spare`, as `spare`'s own comment says to, so `Files` isn't safe
either until `Buf` gets a checked `took(var b; n)`. `examples/Words`
walks `order.head` and `n^.next`, three lines that become
`Names.first` and `Names.next`.

**`examples/Sh.raz`: its arena has no safe form.** `Sh` builds each
word in a `Buf` over a module arena, keeps `Buf.bytes(b)` in the module
variable `text` and in `Command.args`, and resets the arena for each
script. Every one of those is refused: the `Buf` over the arena (keep,
8.4), `text := Buf.bytes(b)` (7.3), `c^.args[c^.n] := text` through a
pointer (6.2), `return Buf.bytes(b), true` in `find` (7.3), and `s :=
script` from `run(Buf.bytes(line))` (keep). Building `argv` from spans
at `spawn` is refused too, since a local array of slices may not hold
a lend (7.3). What compiles is a bump allocator written by hand over a
module array, whose slices last:

```
var
    pool: [1 shl 24]U8;     (* the words of what is being run; a module's array lasts *)
    used: INT;

proc add(c: U8);
begin
    if used = LEN(pool) then say("out of room for words", []); Rt.exit(2); end;
    pool[used] := c;
    INC(used);
end;

(* in readWord, for Buf.init(b, ADR(arena.base)) ... text := Buf.bytes(b) *)
start := used;
...
text := pool[start..used];
```

The rules let this pass, and that's right: `used := 0` makes old words
show new bytes, which is a matter of logic, not memory. But it shows
that the arena was refused for what it is, not for anything it does.
`ADR(p^.cmds[i])` becomes an index, and `builtin` and `start` take
`const`. The scanner's module state (`s`, `at`, `text`) goes into a
`Scanner` record passed by `var`, so that `run` needn't keep its
script. That is 45 of 387 lines, 12%. The scanner comes out clearer,
and the allocator worse: an `Arena` was one line, and this is ten.

### A7.6 rjson's `Json` (`src/Json.raz`, `test/Suite.raz`)

`Doc` grows its nodes by hand with `Mem.alloc` and `Mem.free`, and
copies strings into a list of chunks that `reset` frees. So `Json`
says `unsafe;` and carries the owner protocol itself: a `LENDS` field,
retiring chunks in `reset`, `ret` on `text`, `key` and `copy`. That is
about 25 lines of trusted code outside the library, and the same holds
for every program with a container of its own (`Text` in rmacs). The
audit surface grows with each one. The zero-copy design ("the text
must live as long as the document") means `parse` keeps its text. The
suite's

```
v := Json.parse(ADR(d), Buf.bytes(ADR(text)));     (* twice *)
```

is refused, since a `Buf`'s bytes don't last. Such a program either
leaks each file's bytes with `Buf.leak`, which is fine for a test but
not for a server parsing request bodies, or `Json` gets a `parseCopy`
that copies the text into the document first: one copy per parse,
small next to parsing. About 40 lines change, 4%.

### A7.7 Holes the port found in the rules

Each of these lets unsafe code through as the proposal is written, or
leaves undecided whether correct code stops.

- **H1. A store through a slice isn't a store that outlives.** 6.2
  lists module variables, `p^.f` and `var` parameters. It doesn't list
  `s[i] := e` for a slice `s`. So `proc fill(names: [][]U8); var buf:
  [8]U8; begin names[0] := buf[0..8]; end;` puts a slice of the frame
  in the caller's array. `Vec.all(v)[i] := e` puts a lend in a
  container the same way. The rule must say that a store through a
  slice not lent by the frame alone is a store that outlives.
- **H2. A `ret` through a record that holds owners loses the owner.**
  `name*(ret const m: Message; i: INT): []U8`, the accessor section
  14.2 recommends, returns a lend of `m.head`. The caller knows only
  that the result is lent by `m`, which isn't an owner (7.2), so it
  doesn't know whose count to raise, and it raises none. Then
  `readRequest` grows `m.head`, frees the old block, and the held
  slice dangles. Either the accessor is refused, and 14.2's way out
  doesn't compile, or it is allowed, and the count is lost. R1
  mends it.
- **H3. The containers' exported fields** (A7.5): `Buf.len*`,
  `Vec.len*`, `List.head*`, `Node.next*`, and `Files.load`'s `INC(b.len,
  n)` by design.
- **H4. A literal over a live owner.** `m := {minor: 1}` is allowed
  (7.6: a literal may leave an owner out). It drops the owner's block,
  which is a safe leak, and zeroes its allocator, so the owner's next
  growth stops. It is a trap that compiles, and the obvious rewrite of
  `Http.reset` falls into it.
- **H5. The order of a hold's let-go and `defer`.** If holds are let go
  after the deferred statements, every `defer Buf.done(b)` over a
  local that holds `Buf.bytes(b)` stops the program. If before, a
  deferred statement that reads the local reads memory still allocated,
  which is fine. Section 7.3 must say "before".
- **H6. Option 2 of 14.2 breaks rule 4 of 5.3** (A7.2). An unsafe
  `Http` with exported slice fields hands a safe module a slice it can
  read after `Http.done`.

### A7.8 The verdict, in numbers

| Code | Lines | The fence alone (`ADR` to own pointers, casts) | Parts B to F | Share | Result |
|---|---|---|---|---|---|
| rnet `Http`, `Conn`, tests, `Hello` | 2,700 | 330 | 230 | 9% | worse |
| rmacs | 4,931 | 160 | 90 | 2% | the same |
| raz `src/` | 14,285 | 60 sites | 420 | 3% | Scan, Diag clearer; Chunk, Link longer |
| `lib/`: `Fmt`, `Opt`, `Map`, `Buf`, `Vec`, `List`, `Files` | 1,500 | 15 | 70 | 5% | Fmt worse; the rest the same |
| `examples/Sh.raz` | 387 | 10 | 45 | 12% | scanner clearer, allocator worse |
| rjson `Json`, `Suite` | 1,050 | 15 | 40 | 4% | the same, with a copy per parse |
| **All** | **24,850** | **about 590** | **about 895** | **4%** | |

Where parts B to F's 895 lines come from, by rule:

| Rule | Lines | Share | What it hits |
|---|---|---|---|
| 7.3: an owner's lend returned, or held in a record or array | 450 | 50% | `Message`, `Url`, `Core.slice`, `Mini.Names`, `Chunk`'s accessors, `Sh`'s words, `Json`, `Diag.say` |
| 5.1 and 8.4: no safe form for a context pointer, or for a container over an arena | 200 | 22% | `Conn.state`, `Server.arg`, `Thread.spawn`, `Fmt.eprint`, `Sh`'s arena |
| 6.1 and 6.2 read strictly: `keep` on a pointer parameter that is stored | 60 | 7% | `Sym`, `Item`, rmacs's `Core` |
| 7.6: owners aren't copied | 30 | 3% | `Http.reset`, `open`'s `out := req^` |
| 5.3 rule 4: the containers' fields hidden | 20, or every read of `.len` | 2% | rmacs, `Files` |
| D: no `free` | 5, leaking | 1% | rmacs's buffers and windows |
| the rest: `ret` marks, `t := []`, views | 130 | 15% | everywhere, a line at a time |

**Stops at run time in correct code: 8**, found by a search for a
local holding `Buf.bytes(b)` when `b` is done: `Opt.say`,
`Parse.raz:3696`, `examples/Elf.raz`, rmacs's `Commands` (two),
ravite's `Ravite.raz`, rnet's `Dns` (two). Five of them depend on H5.
Each is found the first time its code runs, and each is mended with one
line. But there is one in the compiler and one in the library, so
`make check` would stop the day part C came in.

**Real bugs caught: none** in about 25,000 lines. One bound holds by
the coincidence of two constants (Scan). Every slice held across a
change of its buffer was right, by an order the code keeps. So the
rules make "right by discipline" checked. They guard tomorrow's code;
they don't mend today's. The five programs of section 1.2 were written
to show the holes. None of them was found in this code.

**Is the pain narrow?** By lines, yes: 96% of the code is left alone,
or changes only where `STANDARDS.md` already asks it to. By kind, no.
Five of the six pieces need a redesign of the one type they are built
round. Each such type keeps a slice of a buffer in a record, or hands
one out from a procedure that isn't the buffer's own, and those are
the pieces that do I/O or hold data. Code that only computes, `Parse`'s
statements, `Item`, `Gen`, rflate's inflater, `Fmt`'s formatting, is
left alone, as section 14.1 says.

### A7.9 Beside Rust and beside today's raz

**Beside today's raz.** Today the six pieces compile as they are, and
their rules of lifetime are comments ("good until the buffer next
grows", "the text must live as long as the document"). Under the
proposal four of those comments become checks, and the code that
leans on them grows by about 4%. It loses three things that were
easy: a record of slices of someone else's buffer, an accessor that
returns a slice of a buffer, and a container over an arena.

**Beside Rust.** Where a record holds slices of its *own* buffer
(`Message`, `Doc`), Rust can't do it either: a struct can't borrow
from itself, so Rust programs use spans, as here, or a crate built for
it. Where a record holds slices of *another's* buffer (`Url` of a
`Buf`, `Sh`'s `argv`, a `Doc` over a file's bytes), Rust writes
`Url<'a>` and is done; raz must copy, or use a frame array. Where a
procedure returns a slice of an owner it reaches through a global or a
pointer (`Core.slice`, `bufferNames`, `Chunk.at`), Rust writes
`&'static` or a lifetime on the result; raz can't write it at all.
Where a callback needs its context (`Server.arg`, `Conn.state`), Rust
has closures and trait objects; raz has `^U8`, which is fenced. On
the other hand, 96% of the code needs no mark at all, where a Rust
port of `Sym`, `Item` and `Parse`'s trees, with their `^Obj` and
`^Type` links everywhere, would need `Rc`, arenas with lifetimes or
indexes throughout. And Rust would reject at compile time the eight
`done`-while-held places, where this proposal stops at run time. In
short, the proposal costs much less than Rust in the code that
computes, more than Rust in the code that holds buffers, and it has
nothing for type-erased context, where Rust has a great deal.

### A7.10 Relaxations and additions

Each of these removes pain found above. Each says what it would cost,
and what, if anything, it weakens.

- **R1. A lend carries its count.** An owner's lend returned from any
  procedure carries the address of its owner's count, in a hidden word,
  as a held local already does. Then the caller counts it on the right
  owner, whoever returned it. This allows `Core.slice`, `Mini.text`,
  `Dired.nameAt`, `Chunk.at`, `Http.target` and `Json.text`, mends H2,
  and removes about 250 of the 450 lines of 7.3. A procedure type
  must say that its result carries a count (`proc(i: I64): lent
  []U8`). It costs a register on return. It weakens nothing.
- **R2. A local array or record may hold lends** (question 4 of section
  21: yes), with one hold for each owner it holds lends of, all let go
  when the local is assigned whole or the procedure returns. This
  allows `Url` of a `Buf`, `Sh`'s `argv`, and a local `[]Fmt.Arg` of
  several `Buf`s, and removes about 60 lines. It costs a few words in
  the frame. It weakens nothing.
- **R3. A pointer parameter lasts, as STANDARDS says it does** ("a
  pointer, only when it is kept"). An unmarked `^T` parameter may be
  stored. An owner's pointer (`Vec.add`, `Pool.at`) may not be passed
  as a `^T` argument, only dereferenced at the call, `f(p^)` to a `var`.
  This removes the 60 `keep` marks, and it puts the check on the rare
  case, the owner's pointer, not the common one. It weakens nothing.
- **R4. `Vec.get(const v; i: INT): T` and `Vec.set(var v; i: INT;
  keep x: T)`.** A copy of an element holds what was kept, and that
  lasts. This mends `Scan.nameOf` and `Diag.pathOf`. Library only,
  and it weakens nothing.
- **R5. `Buf.leak(var b: Buf.Buf): []U8` and `Vec.leak`.** The owner
  gives its block up for good and is left empty, and the block lasts,
  since no one holds what could free it. This is Rust's `Box::leak`. It
  mends `Diag.say`, `Sym.typeName`, `Parse`'s and `Item`'s kept
  strings, and a test's file. Library only, and it weakens nothing,
  but leak-freedom, which the guarantee doesn't promise (3).
- **R6. Fields exported read-only**, Oberon-2's `len-: INT`, and
  `Buf.took(var b; n: INT)`, checked against the room `spare` made. This
  closes H3 and keeps every read of `b.len` as it is, while the seven
  writes in rmacs become `Buf.cut`. A language change of one mark.
  It weakens nothing, and without it the containers aren't safe.
- **R7. `done` with a lend held is caught when compiling where it
  can be, and otherwise retires.** In one pass, the compiler knows when
  a local was last assigned a lend of `b` and has not been assigned
  since, so at `Buf.done(b)` it can say "`s` still holds a lend of `b`:
  write `s := []` first". That turns six of the eight stops into
  messages. The two through a pointer stay. For those, `done` retires
  the block instead of stopping: question 3 of section 21, answered
  "leak". With H5 settled as "before", the eight become none. It weakens
  leak-freedom, not safety, and the debugging heap can report each
  leak.
- **R8. A checked context pointer.** A type `^ANY`, which any pointer
  from `NEW` converts to, and a conversion back, `^T(p)`, checked
  against a type word that `NEW` writes before the record. A wrong
  type stops the program, as Oberon's type guard does. This mends
  `Conn.state`, `Http.Server.arg`, `Thread.spawn`'s `arg` and the
  tests' casts, about 150 lines, and lets a server keep its state
  without module variables shared across threads. It costs a word per
  record that is ever made `^ANY`, if `NEW` is told so, and a compare
  per conversion. It weakens nothing.
- **R9. Growth with a *writable* lend held stops; with a lend that
  only reads, it retires.** `Vec.add` and `Buf.spare` lend for
  writing, and `bytes` and `all` lend for reading. A write into a
  retired block is lost with no message (A7.4); a stop says where.
  `Buf.str(b, Buf.bytes(b))` still runs. This is a tightening, not a
  relaxation. It costs a second count per owner, and `all` must split
  in two, since today it lends for both.

Some pain has no relaxation that keeps the guarantee:

- **A container over an arena** (`Fmt.eprint`, `Sh`). Making it safe
  needs the container to hold the arena's count for as long as it
  lives: an owner holding a lend, which is a lifetime in a record,
  Rust's apparatus. A module array with an index does it safely, as
  `Sh`'s rewrite shows, at a fixed size. Otherwise such code stays
  unsafe.
- **A record that keeps slices of its own buffer** (`Message`, `Doc`)
  stays spans and accessors, in raz as in Rust. With R1 the accessors
  compile, and that is all the help there is.
- **Freeing records one by one.** `Pool`, or leaking. For an editor
  leaking is the plain choice, and it is safe. `Pool` needs an `alloc`
  that hands out a zeroed slot, for records that hold owners.

With R1 to R8, the port's 895 lines fall to about 400, under 2%. The
contortions left are `Fmt`'s stand-in and `Sh`'s allocator, and no
correct code stops at run time. The holes H1 to H6 are mended by
R1, R6 and two sentences in 6.2 and 7.3.
