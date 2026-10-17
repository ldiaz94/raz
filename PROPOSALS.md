# raz: proposals

What the language or the library might have, met while writing raz.
None is built while the freeze holds; each waits for a later thaw, by
the owner's word, and goes into the report before any code.

## IMMINENT - APPROVED: what a call does with its arguments, written at the call

**Status.** Approved by the owner, 2026-10-16, for the next thaw, and
revised on 2026-10-17 after a review of how it reads in real code. A
second review, the same day, found the questions listed at the end of
part 1, "Open questions"; the owner judged the feature, and its use,
not yet settled, and left them open. Only part 2 goes ahead, on its
own and without the marks (2026-10-17). It is five parts, made in one
thaw so that programs break once:

1. **Marks at the call** (this section): an argument for a `var`
   parameter is written `var x`, and one for a `keep` parameter
   `keep x`.
2. **The library's parameters by `var`, not by pointer** (below): the
   `ADR` that stands at nearly every call to the library goes.
3. **`ret` and `keep`** (below): a heading says what a procedure does
   with what it is given, and the compiler holds the body to it.
4. **A `const` parameter** (below): a record or array only read is
   passed in place, unmarked, so that `var` at a call always means a
   change.
5. **A constant holds a variant** (below): so that a table a procedure
   keeps, as `Opt.init`'s, can be a constant, not a literal in the
   frame.

Nothing is built until the owner starts the milestone. The report
changes first, as always; the documentation listed below comes with
it.

### The problem: a call hides what it does

A heading says whether a parameter is changed, kept or lent; the call
doesn't. This line of `src/Scan.raz` reads a character:

```
v := utf8(cur.pos);
```

It also moves `cur.pos` past it, since the heading is
`proc utf8(var pos: INT): INT`. Nothing at the call says so. Pascal
and Oberon leave it so; C#'s `ref`, Swift's `&` and Rust's `&mut`
write it at the call.

`keep` would hide its promise in the same way. Here the map keeps the
name it is given, which must outlive the call; a reader of the call
can't tell:

```
_ := Names.put(table, name, 1);
```

Today `ADR` stands in for a mark, badly. `STANDARDS.md` says `ADR` at a
call means the callee keeps what it is given, but the library takes
`^T` where it keeps nothing, so `ADR` stands at nearly every call
(`Buf.add(ADR(b), c)`), and says nothing.

### What a procedure does with what it is given

| Heading | The procedure | At the call | Example |
|---|---|---|---|
| no mark | reads it while the call runs, then lets go | nothing | `Str.eq(a, b)` |
| `const x` | reads the caller's variable in place, without a copy, and doesn't change it | nothing | `Opt.at(p)` |
| `var x` | may change the caller's variable | `var x` | `Buf.add(var b, c)` |
| `keep x` | may store it where it outlives the call | `keep x` | `Names.put(var table, keep name, keep 1)` |
| `ret x` | its results may point into it | nothing | `s := Str.trim(line[0..n])` |
| `^T` | keeps a pointer, or takes one for C, an allocator, or what may be `nil` | `ADR(x)`, or a pointer it holds | `Thread.spawn(work, ^U8(ADR(job)))` |

A slice given to an unmarked parameter is a value, two words, but the
elements it points at are the caller's: the procedure may write them,
and nothing at the call says so. `Sys.read(fd, line)` fills `line`,
`COPY(d, s)` fills `d`. A slice is a view of the caller's array, and
lending it is what it is for; the table says so in a note under it.

`var` is in the language now; `keep` and `ret` come with part 3, `const`
with part 4. The table, and the note, go into the report (8), raz(7)
and the tutorial as they are here.

### The rules

1. **`var` at the call.** An argument for a `var` parameter is written
   `var` and a variable: `var b`, `var p^`, `var a[i]`, `var r.f`.
   Leaving the mark out is an error; so is writing it for a parameter
   that isn't `var`. This holds for every call: of a procedure, of
   another module's, of a procedure value, of a generic module's
   instance.
2. **`keep` at the call.** An argument for a `keep` parameter is
   written `keep` and the argument, whatever its type, as `var` is:
   `Counts.put(var counts, keep 5, keep 7)`. The map does keep the 5.
   Where the argument can't end, an `INT` or a literal, nothing is
   checked, but the mark stands. So the mark follows the heading alone:
   a generic module's body reads the same in every instance, as
   `Bag(T)` calling `L.push(var l, keep x)` must, and a call never
   hangs on fields of a record it can't see.
3. **Both.** An argument for a `keep var` parameter is written
   `keep var x`, in the heading's order.
4. **`ret`** is never written at the call. It is about the result,
   which the compiler checks where it is returned or stored (part 3);
   and the calls it is on, `Str.trim`, `cut` and `field`, are the most
   common ones.
5. **Built-in procedures** take no marks: `INC(v)`, `DEC(v)`,
   `NEW(p, a)`, `COPY(d, s)`. They are the report's own words, and
   their names say what they change. `extern` procedures have no `var`
   or `keep` parameters, and so take none.
6. **What follows `keep`.** `keep` is a mark, not a name, when the
   token after it is a name, a number, a string or character literal,
   `{`, `[`, `var`, `-`, `not` or `~`: anything that starts an
   argument and can't follow a name in one. Before `(`, `^`, `.`, `,`,
   `)` or an operator between two operands it is the name `keep`:
   `keep(x)`, `keep^`, `keep.f` and `keep + 1` are what they are today.
   An argument that starts with `(` is written without it: `keep a + b`,
   not `keep (a + b)`. `keep [` is the mark before an array literal or
   the empty slice, `keep []`; an array literal lives in the frame
   (part 3), so a kept one is an error unless it is a constant's.
7. **Procedure types** say `const`, `var` and `keep` as headings do
   (5.9), so a call through a procedure value is marked as a call by
   name.
8. **`const`** is never written at the call: the procedure neither
   changes nor keeps what it is given. Its argument is any expression
   of the parameter's type; a variable is passed in place, and anything
   else in a temporary of the statement (part 4).

```
Arguments  = "(" [ Argument { "," Argument } ] ")" .
Argument   = [ "keep" ] [ "var" ] Expr .
```

Each rule looks at the call and the heading only, so a one-pass
compiler makes them as it reads the call: perhaps 40 lines, beside the
250 to 400 of part 3, the 30 to 60 of part 4 and the 20 of part 5.

### Examples

**Swapping**, from the tutorial (4):

```
proc swap(var a, b: INT);
var t: INT;
begin
    t := a; a := b; b := t;
end;

swap(var x, var y);
```

**A procedure that changes a place deep in a record**, from
`src/Scan.raz`:

```
v := utf8(var cur.pos);           (* cur.pos moves past the character *)
bigMul(var num, 10, digit);       (* num changed; 10 and digit read *)
bigSub(var num, d);               (* num changed; d read *)
```

**A buffer.** `examples/Sh.raz`'s `readWord`, today:

```
Buf.init(ADR(b), ADR(arena.base));
while (at < LEN(s)) and not special(s[at]) do
    ...
    | 39:  Buf.add(ADR(b), s[at]); INC(at);
    | '$': dollar(ADR(b));
    | else: Buf.add(ADR(b), s[at]); INC(at);
    end;
end;
text := Buf.bytes(ADR(b));
```

and after the thaw:

```
Buf.init(var b, ADR(arena.base));      (* b set up; the arena is an allocator: a pointer *)
while (at < LEN(s)) and not special(s[at]) do
    ...
    | 39:  Buf.add(var b, s[at]); INC(at);
    | '$': dollar(var b);
    | else: Buf.add(var b, s[at]); INC(at);
    end;
end;
text := Buf.bytes(b);                  (* only read: no mark *)
```

The marks are as many as the `ADR`s were, and shorter; now they are
true. `Buf.bytes(b)` has none, and the one pointer left,
`ADR(arena.base)`, stands out as what it is.

**Passing on what the procedure was given.** A `var` parameter is a
variable, and is marked like any other:

```
proc dollar(var b: Buf.Buf);
begin
    ...
    Buf.str(var b, Sys.env(s[start..at]));
end;
```

**What the program holds by pointer** is given as `p^`:

```
proc emit(w: ^Writer; c: U8);
begin
    Buf.add(var w^.out, c);
end;
```

**A map that keeps its keys:**

```
(* import Names := Map([]U8, INT, Str.hash, Str.eq);
   table: Names.Map and heap: Heap's allocator, module variables *)
proc count(name: []U8);
var k: []U8; ok: BOOL;
begin
    k, ok := Str.copy(heap, name);                               (* a copy, on the heap *)
    if ok then _ := Names.put(var table, keep k, keep 1); end;
    _ := Names.put(var table, keep "main", keep 1);              (* a literal never ends *)
end;

proc lookup(name: []U8): INT;
var n: INT; found: BOOL;
begin
    n, found := Names.get(table, name);    (* only read: no mark *)
    ...
end;
```

**A map that keeps nothing that can end.** The marks stand, as the
heading says, though nothing is checked:

```
(* import Counts := Map(INT, INT, hashInt, eqInt) *)
_ := Counts.put(var counts, keep 5, keep 7);
```

**A generic module calling another.** One body serves every instance:

```
module Bag(T);
import Mem, L := List(T);
var l: L.List;

proc add*(keep x: T);
begin
    _ := L.push(var l, keep x);
end;
```

**A table a procedure keeps**, a constant (part 5), as `Sh`'s becomes:

```
const Rows: []Opt.Row = [
    Opt.usage("", "Sh [-c script | file]"),
    Opt.option("", 'c', "command", "script", "run script, not standard input")];
...
Opt.init(var p, keep "Sh", keep Rows);
while Opt.next(var p) do ... end;
if Opt.at(p) > 1 then ... end;             (* at only reads: const, no mark *)
```

Today's `Opt.init(ADR(p), "Sh", [...])`, with the literal in the call,
is an error once `init` is `keep table`: the literal lives in the
frame, and `keep` can't say "as long as `p`" (part 3, "False alarms").

**A large record only read**, by `const` (part 4), from `tools/Pretty.raz`:

```
proc is(const sc: Scanner; s: []U8): BOOL;        (* Scan's *)

if Scan.is(sc, "-") or Scan.is(sc, "+") then ... end;
if Scan.among(Scan.text(sc), binaryWords) then ... end;
```

Today each of these is `ADR(sc)`; by `var` each would say `var sc`,
and none changes it.

**A list of names a procedure keeps, passed on.** The parameter is
`keep` in turn, so the promise travels up:

```
(* import Seen := List([]U8) *)
proc remember(var l: Seen.List; keep name: []U8);
begin
    _ := Seen.push(var l, keep name);
end;

remember(var seen, keep "start");
```

**`keep var`: a reader that keeps a slice of the caller's buffer.**

```
proc start(var r: Reader; keep var page: [4096]U8);
begin
    r.rest := page[0..0];
    r.page := page[0..LEN(page)];
end;

var page: [4096]U8;                       (* a module variable *)
...
start(var rd, keep var page);
```

**A procedure value.**

```
type Step = proc(var s: State): BOOL;

proc run(step: Step; var s: State);
begin
    while step(var s) do end;
end;
```

**What stays a pointer**, and so keeps `ADR`:

```
NEW(node, ADR(arena.base));                     (* an allocator *)
t, err := Thread.spawn(work, ^U8(ADR(job)));    (* kept by the thread *)
XNextEvent(dpy, ADR(ev));                       (* C *)
p := Sys.mmap(size);                            (* bytes, not a variable *)
```

**A slice's elements, lent unmarked:**

```
n := Sys.read(fd, line);           (* fills line[0..n] *)
Str.lower(word);                   (* writes word's bytes *)
```

**`ret`, unmarked:**

```
s := Str.trim(line[0..n]);         (* s points into line *)
key, rest, ok := Str.cut(s, "=");  (* both point into s *)
```

### What the compiler says

Each message names the mending, at the argument:

```
Sh.raz:94:21: b: write `var b`: Buf.add may change it
Sh.raz:115:23: b: Buf.bytes only reads it: no `var`
Count.raz:12:27: name: write `keep name`: Names.put keeps it
Count.raz:14:34: 7: write `keep 7`: Counts.put keeps it
Count.raz:9:27: key[0..4]: kept by Names.put, but it points into this procedure's frame
Sh.raz:60:28: [...]: kept by Opt.init, but an array literal lives in this procedure's frame: make it a constant
Pretty.raz:123:19: sc: Scan.is only reads it (const): no `var`
Scan.raz:41:5: sc: a const parameter can't be changed
Sh.raz:88:14: ADR(b): Buf.init takes `var b`, not a pointer
Sh.raz:151:14: p: Buf.add takes `var p^`, not a pointer
```

The last two are part 2's mending, `ADR(x)` to `var x` and `p` to
`var p^`.

### How much noise

Measured by a search of `src/`, `lib/`, `tools/` and `examples/`, about
23,300 lines of code (rough: a search, not the compiler):

- about 630 `ADR`s; most are at calls to the library that part 2 turns
  into `var x`: the same count, shorter, and true;
- about 580 calls of our own procedures with `var` parameters, unmarked
  today: each gains `var`, about one line in 40;
- `keep`: a few dozen calls (`Map.put`, `List.push`, `Vec.push`,
  `Opt.init`, `Opt.scope`, and procedures that pass a kept value on).
  Since it follows the heading, it stands also before values that can't
  end, `keep 1` in `Names.put(var table, keep name, keep 1)`: a word
  each, the price of one rule for every instance;
- `const`: none at the call, and some 40 `var`s and `ADR`s fewer, where
  a large record is only read (`Opt`, `Scan` in the tools, `Item` in
  `src/`).

So most of the marks stand where an `ADR` stands today. What is new is
the 580, and those are the calls, like `utf8(cur.pos)`, that change a
variable with nothing to say so.

### `ADR` afterwards

`ADR` stays, for the pointers `STANDARDS.md` lists: an allocator, what
may be `nil`, what the program holds by pointer already, C and memory
that is bytes, and a pointer a procedure keeps (`Thread.spawn`'s `arg`).
The marks of part 3 don't follow a pointer, so `ADR` at a call still
says "kept, or not a variable", unchecked, as now; with the library on
`var`, it is rare enough in ordinary code to be read so.

### What the documentation gains

The thaw is not done until each of these is:

- **The report, `doc/raz.md`.** 8: the grammar above; "Parameters"
  becomes "Parameters and arguments", with the table and its note on
  slices, rules 1 to 8, and the swap, map and `const` examples; `keep`
  and `ret` from part 3, `const` from part 4. 4: a constant may hold a
  variant (part 5), with `Opt`'s table as the example. 5.9: procedure
  types with marks. 7.3: `ret`. 10: the promise, whose
  exceptions shrink to `ADR`, C, code procedures and `check off`.
  1, "A first look": its example marks its calls. Every example in the
  report is marked. About two pages; the report stays under 40 (31
  now), counted by `make pdf`.
- **`doc/report-history.md`**: the version's entry, with the mending:
  `ADR(x)` to `var x`, `p` to `var p^`, `var` and `keep` at each call
  the compiler names.
- **raz(7)**, the language at a glance: under PROCEDURES, the table, as
  a list, and one line for each of `var`, `keep` and `ret` at the call;
  THE GRAMMAR IN BRIEF gains `Argument`; BUILT-IN PROCEDURES says they
  take no marks.
- **The tutorial, raz-tutorial(7).** Section 4 marks `swap(var x, var y)`
  and says why. A new section after 6, "WHAT A CALL DOES WITH ITS
  ARGUMENTS": the table; a whole program, with its output, that counts
  the words of its input in a `Map([]U8, INT)` with a `Buf`, using
  `var`, `keep`, `ret` and `const`, each said in a sentence where it
  stands, and taking its options from a constant table of `Opt`;
  then "What the compiler stops", the four mistakes of the messages
  above, each with its message. Section 16, "FROM PASCAL AND C TO RAZ",
  gains: Pascal's `var` is unmarked at the call, raz's is marked, as C#'s
  `ref` is; C's `&x` becomes `var x` when the callee only changes it,
  and stays `ADR(x)` when it keeps it. Every other example in the
  tutorial is marked. Each runs under `make check`, as now.
- **Volume 2, `doc/raz-lib.md`, and raz-lib(3)**: every signature of
  part 2, each module's example marked, and a note in each changed
  module of what changed.
- **`STANDARDS.md`**: "Parameters: a value, `var`, or a pointer" becomes
  "a value, `const`, `var`, or a pointer": a large record or array only
  read is `const`, not `var`, so that `var` at a call always means a
  change; `ADR` no longer marks what is kept, `keep` does; "The library
  until a thaw" goes.
- **`doc/compiler.md`**: where the marks are read and checked, the
  checks of part 3 and the set each value carries, with the code
  before and after, and the table of lines.
- **`README.md`**: its examples marked.
- **Tests.** `conform/`: a program for each rule, run and error;
  `test/err` and `test/msg`: each message above; `test/pretty`: the
  marks formatted; the vim and emacs support indent and colour `var`
  and `keep` at a call.
- **`sbcl/`**, the reference compiler from the report alone, follows
  the report.

### What it breaks, and the order of the work

Every call to a procedure with a `var` or `keep` parameter, and every
call to the library's procedures of part 2: in `src/`, `lib/`, the
tools, the examples, the tests, and rmacs, ravite, rat, rlX11, rloc,
rpg and rsqlite, each when it moves its pin. The mending is mechanical,
and the compiler names it at each place.

**The seed first.** The seed, frozen, can't read a marked call, and it
builds `src/` and reads `Sys` and `CAbi`. So this thaw needs the new
seed a release makes (CLAUDE.md, "The compiler and the seed") before
`src/` and that part of the library can be marked: the owner's call,
and the first step.

Then, one commit each:

1. The report, `report-history.md`, raz(7): for review.
2. The compiler reads the marks and checks rules 1 to 7.
3. The library's signatures (part 2), and every caller in this
   repository mended.
4. `ret` and `keep` in headings and their checks (part 3), and the
   library marked (`Str.trim`, `Map.put`, `List.push`, `Vec.push`,
   `Opt.init`, `Opt.scope`, ...).
5. `const` parameters (part 4), and the library's and `src/`'s large
   records only read moved to it.
6. Constants holding variants (part 5), and `Sh`'s and `Opt`'s tables
   made constants.
7. The tutorial, volume 2, raz-lib(3), `STANDARDS.md`,
   `doc/compiler.md`, `README.md`.
8. The tests: `conform/`, `test/err`, `test/msg`, `test/pretty`, the
   editors.

The examples of parts 2 and 3 are written as the whole thaw makes
them, with the marks of part 1.

### Open questions

The second review, 2026-10-17, read the five parts against `src/`,
`lib/Opt.raz`, `tools/Pretty.raz` and `examples/Words.raz`. It found
the direction sound, and parts 1, 2 and 4 clearly better in `tools/`
and `Opt`, but mostly noise in `src/Parse.raz`, where `var x` stands
on nearly every call. Left open, by the owner's word:

1. **The seed.** A release of today's compiler can't read the marks
   either, so "the seed first" can't work as written: it takes two
   releases, one that accepts every new form without requiring it,
   made the seed, then one that marks `src/` and requires the marks.
2. **Errors here.** `Opt.at` and `operand` move the `Parser` (`at`
   runs `next` to the end), so they are `var`, not `const`; the table
   row and part 1's `Opt.at(p)` are wrong. `Sys.entryKind` reads a
   `Dir` of 8 KB on Linux: `const` or `var`, not a value. Part 3's
   `Names.put(var table, keep buf[0..n], 1)` lacks `keep 1`. Part 5's
   table has a row part 1's lacks. Report 4 must let a variant's case
   stand in a constant expression.
3. **A hole in part 3's exception for `var`.** `proc fill(var r: R);
   begin r.s := r.buf[0..4]; end;` passes, since `r` points where it
   pointed; a caller's local `r` copied to a module variable then
   points into a dead frame. Mend: the caller's variable and what its
   slices point at as two places, the exception covering the second.
4. **Part 3's cost.** A local points wherever anything assigned to it
   does, which needs a closure over local-to-local assignments at
   `end` (`w, rest := Str.field(rest)`), and bits for locals, value
   parameters and `match`'s names: 400 to 600 lines, not 250 to 400.
5. **Rule 6.** Its list contradicts itself: `keep - 1` and `keep[i]`
   are expressions today, and `Sys.closeAllBut(keep: []INT)` indexes
   `keep[i]`; `keep ^U8(p)` can't be marked. Proposed: decide by the
   heading, which is known when the argument is read: at a `keep`
   parameter a leading `keep` is the mark; elsewhere a name.
6. **`keep` before what can't end is noise**: `keep 5`, `keep "Sh"`,
   and `keep k + 1`, which reads as `(keep k) + 1`. Proposed: optional
   before a constant or a basic or pointer type, required where the
   type carries a slice or is another module's record. It partly undoes
   rule 2's "the heading alone": one rule and some noise, or less noise
   and an exception.
7. **A mark that lends nothing in a plain heading**, `keep n: INT`,
   costs every call a word. Proposed: a warning, but on a module
   parameter's type or a procedure with a body for each target.
8. **`const`'s rules.** Check 4 must cover `match`'s names and views;
   whether a slice's elements count as "a part of it" (they shouldn't);
   a constant argument passed in place, not copied; `ret const` given a
   temporary that holds an array, an error. The heading's grammar,
   `Params = ["ret"] ["keep"] ["var" | "const"] ident ...`, and the
   call's, a designator after `var`.
9. **Procedure types** with fewer marks are assignable, not the same:
   5.10 must say so, for `=`, generic instances and `forward`.
   `Map`'s `eq` can't take a `const` equality.
10. **Constants holding variants.** `match`'s names on one are read
    only; a pointer field takes only `nil`; an untyped `const D = dot`;
    padding zero; 30 to 40 lines, not 20.
11. **False alarms to document.** A local container over a local
    buffer, `Scan.init(var s, keep line[0..n])`, is refused though both
    end together (a module variable, a `Buf` or the heap is the way
    out); so is a store through `ADR` of a local.

### Part 2: the library's parameters by `var`, not by pointer

Most of the library's procedures take what they work on as `^T`:
`Buf.str(ADR(b), s)`, `Vec.push(ADR(v), x)`, `Lock.take(ADR(l))`. None
keeps it past the call; each reads or changes it and returns. That is
what `var` is for (8), and with it the call is `Buf.str(var b, s)`. As it
is, `ADR` stands at nearly every call a program makes to the library,
and says nothing: a reader can't tell the few places where a pointer
is kept from the many where it isn't. `STANDARDS.md` says how our own
code chooses; this would bring the library to it.

The proposal, procedure by procedure, from reading each one:

- **To `var`** (it changes what it is given): `Arena.init`, `reset`,
  `done`; `Buf.init`, `room`, `add`, `str`, `spare`, `cut`, `reset`,
  `done`, and the `Buf` that `Files.load`, `Files.read`, `Fmt.write`,
  `Str.join` and `Str.replace` write into; every procedure of `List`;
  `Lock.take`, `give`; `Map.init`, `put`, `remove`, `done`; the
  procedures of `Opt` that change the `Parser` (`init`, `next`,
  `operand`, `scope`, ...); `Sys.openDir`, `nextEntry`, `closeDir`;
  `Thread.lock`, `unlock`; `Vec.init`, `room`, `push`, `pop`, `add`,
  `tryPush`, `tryAdd`, `resize`, `reset`, `done`.
- **To a value** (it only reads a record of a few words): `Buf.bytes`,
  `Vec.all`, `Map.get`, `Map.next`, `Sys.entryKind`.
- **To `const`** (it only reads a record of many words; part 4):
  `Opt.at`, and whichever other procedure of `Opt` a reading shows only
  reads the `Parser`.
- **Staying pointers**: an allocator, `^Mem.Allocator`, everywhere
  (`NEW` takes one, and `^Arena(a)` needs one); `Mem.pages`, `unmap`,
  `Sys.mmap`, `munmap`, `mapFile`, which are bytes, not variables;
  `Thread.spawn`'s `arg`, which is kept, and the `^Thread` it gives,
  which `join` and `signal` take as the program holds it; `Rt.fail`,
  which the compiler calls.

What it costs: it breaks every program that calls these, `src/`,
rmacs, ravite, the tools and the library's own tests among them. The
mending is mechanical, `ADR(x)` to `var x` at each such call, and `p`
to `var p^` where a program holds the thing by pointer, and the
compiler's message for a `^T` given to a `var` names it. The seed
knows `var` parameters but not the marks of part 1, so with them
`src/` and the library it imports wait for the new seed. Alone, this
part changes volume 2 and `raz-lib.3`, not the report.

Met in rpg and rsqlite, whose `Query`, `Result` and `Stmt` went from
`^T` to `var` and to values, and whose own calls to `Buf` couldn't.

### Part 3: marking what a procedure does with what it is given: `ret` and `keep`

#### The hole

A procedure's locals, its value parameters and the array literals it
passes as slices live in its frame, which is gone once it returns. A
slice that still points there afterwards reads whatever the next call
put in its place, and writes into it. Section 7.3 catches the plain
case, a slice of a local returned at once:

```
proc short(h: Hex): []U8;    (* Hex = [64]U8 *)
begin
    return h[0..8];          (* an error: h is the procedure's own copy *)
end;
```

It can't catch the same slice once it has passed through a call,
since the caller can't see what the callee returns a slice of:

```
proc head(var h: Hex): []U8;
begin
    return h[0..8];          (* fine: h is the caller's *)
end;

proc short: []U8;
var h: Hex;
begin
    return head(h);          (* a slice of short's frame; not caught *)
end;
```

Nor the other way, a slice given to a procedure that keeps it:

```
proc remember(name: []U8);
var buf: [16]U8;
begin
    ...
    _ := Names.put(var table, keep buf[0..n], 1);   (* the map, on the heap, keeps a slice of buf *)
end;
```

Section 10 leaves both undefined. The marks close them: each parameter
says what the procedure may do with what it is given, the compiler
holds the procedure's body to its heading, and a caller trusts the
heading without seeing the body. Each check needs only the procedure
it is in, so a one-pass compiler can make it.

#### Words

**Carrying a slice.** A type carries a slice if it is a slice, or an
array, record or variant with one in it: `[]U8`, `[4][]U8`,
`Sys.Program`, `Fmt.Arg`. `INT`, `[64]U8` and every pointer type don't.
What a pointer points at is not followed: a slice reached through a
pointer, `p^.s`, is the heap's or a module's, as far as the marks
know.

**Where a value points.** Every value that carries a slice has, for
the compiler, a set of places its slices may point into:

- **the frame**, this call's own: a slice of a local array, of a
  value parameter's array, or an array literal used as a slice;
- **a parameter `p`**: what `p` lends. For a value parameter, that is
  what its slices point at, which is the caller's business, not this
  frame. For a `var` or `const` parameter whose type holds an array,
  it is also the caller's variable itself: `h[0..8]` of `var h: Hex`
  points into `h`. One whose type holds no array, as a `Scanner`, lends
  only what its slices point at, as a value parameter does, so
  `return Scan.text(n)` of a local `n: Scanner` is not frame-bound
  when `n.src` isn't.
- **nowhere that ends**: module variables, constants, string literals,
  and anything reached through a pointer.

A value made from others points wherever any of them does: a slice, a
field, an element or a view of `x` points where `x` does; a record, a
variant or an array literal built from parts, wherever the parts do; a
call's result, wherever its arguments for `ret` parameters do (below).
A local variable that carries a slice points wherever anything
assigned to it anywhere in the procedure does, wherever the assignment
stands, since a loop can run a `return` after an assignment written
below it. **Frame-bound** means pointing into the frame.

**Outliving the call.** A place outlives the call if it is a module
variable, anything reached through a pointer (`p^.f`, `p^[i]`), or a
`var` parameter of this procedure. A value stored there, or returned,
leaves the frame.

#### No mark

A parameter without a mark is only used while the call runs. The
procedure may read it, copy its bytes (`COPY`, `Buf.str`), keep it in
locals and pass it to other calls' unmarked or `ret` parameters. It
may not return what it points at, nor store it anywhere that outlives
the call. This is what most procedures do: `Str.eq`, `Str.find`,
`Buf.str`, `Sys.write`, `Fmt.print`, `Map.get`'s key.

#### `ret`

```
proc trim(ret s: []U8): []U8;
```

`ret s` says: the results may point where `s` points. In the body,
returning a slice of `s` is allowed; in the caller, the result points
wherever the argument given for `s` did.

```
proc greet: []U8;
var line: [80]U8; n: INT;
begin
    n := Sys.read(Sys.stdin, line);
    Out.str(Str.trim(line[0..n]));     (* fine: used here, in the frame *)
    return Str.trim(line[0..n]);       (* an error: frame-bound through trim's ret *)
end;

proc word(ret s: []U8): []U8;
begin
    return Str.trim(s);                (* fine: points where s does, and s is ret *)
end;

proc word2(s: []U8): []U8;
begin
    return Str.trim(s);                (* an error: s isn't ret here *)
end;
```

`ret` lends something when the parameter carries a slice, or is a
`var` or `const` parameter whose type holds an array (it lends the
caller's variable), of a procedure with a result that carries a slice.
Elsewhere, `ret n: INT`, `ret a: [4]U8` or on a procedure whose results
carry no slice, it lends nothing, and is allowed: a mark is leave to
do something, not a claim that it is done. Two cases need that. A
generic module's parameter may be any type, and a procedure with two
bodies, one for each target, has one heading: `Sys.nextEntry`'s `Dir`
holds the entry's bytes in an array on Linux, where `ret` lends them,
and a C pointer over C, where it lends nothing.

With several results, `ret` covers them all: in `cut(ret s: []U8;
sep: []U8): ([]U8, []U8, BOOL)` both slices may point into `s`. With
several `ret` parameters, a result may point where any of them does,
and the caller takes the result as pointing where all of their
arguments do.

#### `keep`

```
proc put(var m: Map; keep k: K; keep v: V): BOOL;
```

`keep k` says: what `k` points at may outlive the call; the procedure
may store it in a place that does. In the caller, an argument for a
`keep` parameter leaves the frame as a store would: it must not be
frame-bound, and if it points where one of the caller's own
parameters does, that parameter must be `keep` too.

```
(* import Names := Map([]U8, INT, Str.hash, Str.eq);
   table: Names.Map and heap: Heap's allocator, module variables *)
proc count(name: []U8);
var key: [32]U8; k: []U8; ok: BOOL;
begin
    _ := Names.put(var table, keep name, keep 1);       (* an error: name isn't keep here *)
    _ := Names.put(var table, keep key[0..4], keep 1);  (* an error: frame-bound to a keep *)
    _ := Names.put(var table, keep "main", keep 1);     (* fine: a literal never ends *)
    k, ok := Str.copy(heap, name);
    if ok then _ := Names.put(var table, keep k, keep 1); end;   (* fine: copied to the heap *)
end;
```

`keep` lends something on a parameter that carries a slice, or a
`var` parameter whose type holds an array; on another, `keep n: INT`,
it lends nothing and is allowed, as `ret` is. At the call it is
written all the same (part 1, rule 2).

One exception keeps the common loop free of marks: a `var` parameter
may be given a value that points only where it already pointed, so
`s := s[1..LEN(s)]` with `var s: []U8` needs no `keep`. The caller's
variable is no worse off.

#### Both, and the order

`ret keep v: T` is both. The marks come before `var`, and each
mark covers the group it starts, so `(ret s, t: []U8)` marks both;
`(ret s: []U8; sep: []U8)` marks only `s`. `ret` and `keep` are not
reserved words: they are marks only before a parameter's name, as
`static` is a mark only in `link static;`. `proc f(ret: INT)` is a
parameter named `ret`.

#### What the compiler checks, all of it

In each procedure:

1. `return e`, each result: `e` must not be frame-bound, and every
   parameter it points at must be `ret`.
2. A store into a place that outlives the call, `M.x := e`,
   `p^.f := e`, or `v := e` for a `var` parameter `v` or a part of it
   (`v.f := e`, `v[i] := e`): `e` must not be
   frame-bound, and every parameter it points at must be `keep`, but
   for the exception above. `COPY` into such a place is no such store:
   it copies bytes, not where they point.
3. An argument for a call's `keep` parameter, as 2.
4. A `const` parameter, or a part of it, is never assigned, given to
   a `var` parameter, nor to `ADR` (part 4).

Checks 1 to 3 on a local variable's value wait for the procedure's
`end`, when everything assigned to it is known.

#### Procedure values, generic modules, and the rest

**Procedure types** carry the marks, `proc(ret s: []U8): []U8`. A
procedure with fewer `ret` and `keep` marks than a procedure type may
stand where that type is wanted, since it does less than the type
allows: a procedure without `ret` can stand where `ret` was allowed,
not the other way. `const` and `var` must match, as `var` must now
(5.9): they change how the argument is passed.

**Generic modules.** A mark is allowed on a parameter whose type is a
module parameter, `keep v: T`, whatever `T` will be. The body is
checked in each instance: `Map(INT, INT)`'s `put` would pass without
`keep`, `Map([]U8, INT)`'s wouldn't, so the library marks its generic
modules for the instance that needs it. Calls write the marks the
heading has, in every instance (part 1, rule 2).

**`extern` procedures** take no marks: C is outside the promise of
section 10 already. **Code procedures** take them, and are trusted:
there is no body to check.

**`ADR`** gives a pointer, which the marks don't follow; a pointer to
a local that outlives it stays undefined, as section 10 says. So does
a slice reached through such a pointer, and a thread given a pointer
to its spawner's locals.

#### False alarms

The rules are sure, not exact: they reject some programs that were
right.

- **A record that lives in the frame, filled through a pointer.**
  `examples/Sh.raz` does

  ```
  Opt.init(var p, keep "Sh", keep [Opt.usage(...), Opt.option(...)]);
  ```

  `Opt.init` keeps its table in `p`, so it needs `keep table`, and
  the array literal is frame-bound: an error, though `p` is a local
  and dies with the literal. `keep` can't say "as long as `p`";
  saying that needs lifetimes on records, Rust's whole apparatus, which
  is not proposed. The way out: the table a constant, which part 5
  allows, as part 1's example shows.
- **A local variable used twice.** One slice variable that holds a
  slice of a local buffer early on and a result to return later is
  frame-bound throughout. Two variables cure it.
- **Several `ret` parameters.** A result is taken to point at all of
  them, though it may point at one.

#### What it breaks

Every procedure, in the library or a program, that returns or keeps
what a parameter points at stops compiling until it is marked: a
thaw. In the library, by a search of the headings: `Str.trim`,
`trimLeft`, `trimRight`, `cut` and `field` (`ret`); `Map.put`,
`List.push`, `Vec.push` and `Vec.tryPush` (`keep`: they store a `T`);
`Opt.init` (`keep name` and `keep table`) and `Opt.scope` (`keep
name`), and `Sh`'s call of `init`, as above; `Sys.nextEntry` (`ret`,
lending on Linux only). Not marked: `Str.copy` (its result is the allocator's),
`Sys.env` and `readLink` (their own buffer), `Buf.str` and
`Fmt.write` (they copy), `Map.get`. In sauce, `Svec.push` and `add`
(`keep`), and what returns a slice of its argument.

#### What it costs

Reports: 5.9 (procedure types), 7.3, 8 (parameters), 10 (the promise,
whose exceptions shrink to `ADR`, C, code procedures and `check
off`), appendix B. The compiler: a set of the places a value points
into, carried with each value as its type is, a 64-bit set (the frame
and up to 63 parameters); the same on each local; the checks above,
and a list per procedure of the checks that wait for its `end`.
Perhaps 250 to 400 lines; no cost at run time, and little at compile
time.

Precedent: D's `scope` and `return scope` (DIP1000) are `keep`'s
opposite and `ret`; Rust's lifetime elision reads a call's result as
`ret` does. D's experience is that the corners (fields, generics,
procedure values) take years; the narrow form here leaves record
lifetimes out, and so the first false alarm above, on purpose.

### Part 4: a `const` parameter

```
proc is*(const sc: Scanner; s: []U8): BOOL;
proc text*(ret const sc: Scanner): []U8;
```

A `const` parameter is the caller's variable itself, as a `var` one
is, and the procedure may only read it: it may not assign it or a
part of it, give it to a `var` parameter, nor take its `ADR`. Nothing
is copied, whatever its size. Its argument is any expression of the
parameter's type: a variable is passed in place; anything else, a
call's result, a literal, an expression, goes in a temporary of the
statement, and its address is passed.

It is passed by its address always, so what it means is plain: if the
variable changes while the procedure runs, through a `var` parameter,
a pointer or another thread, the procedure sees the change.
`f(var x, x)`, with `f`'s second parameter `const`, reads `x` as it now
is. (Ada leaves the choice of copy or address to the compiler, and a
program that depends on it is wrong; raz fixes the address, which is
the cheaper and the one a reader expects.)

It is never marked at the call: the procedure neither changes nor
keeps what it is given (part 1, rule 8). With it, `STANDARDS.md` says:
a record or array only read is a value when it is a few words, and
`const` when it is more; `var` is for what is changed. So `var` at a
call always means a change, and the marks of part 1 stay true.

A `const` parameter whose type holds an array lends the caller's
variable to `ret`, as a `var` one does (part 3, "Words"). A procedure
type says `const` where its procedure does, and two signatures are
alike only if their `const`s are (5.9). A code procedure receives a
`const` parameter's address in a register, as a `var` one's; `extern`
procedures take none.

Met in porting the compiler to raz, where the seed's `const x: TItem`
(about 130 bytes) became a value parameter, copied at every call.
Measured once the port built: not what stands out, the compiler's
profile is flat (`Scan.tokPos` is 9%). Met again here, where `Opt`'s
`Parser` and the tools' `Scanner`, many words, are only read by many
procedures, and `var` for them would be a mark that isn't true.

Costs: the report, 8 and 5.9; the compiler, 30 to 60 lines: the word
in a heading, passing as `var` does, the temporary, and the checks
above. The seed knows `const` parameters in Pascal, not in raz; `src/`
uses them after the new seed, as it does the marks.

### Part 5: a constant holds a variant

Today a typed constant holds no variant (4: "no variant and no other
pointer"), and `src/Parse.raz` says "a constant holds no variant". So a
table of `Opt.Row`s, a variant, can't be a constant, and part 3 makes
the literal table at `Opt.init`'s call an error. The plain place for
such a table is a constant:

```
const Rows: []Opt.Row = [
    Opt.usage("", "Sh [-c script | file]"),
    Opt.option("", 'c', "command", "script", "run script, not standard input"),
    Opt.sub("", "run", "run the file named")];
```

A variant's case built from constants, `Opt.usage("", "...")`, or a
case without fields, `dot`, is a constant of the variant's type, and a
variant may stand among a constant's elements and fields as a record
may. Its bytes are as 5.6 lays them out: the case's number, then its
fields, the rest zero. Nothing else changes: a constant is still read
only, and a `match` on one works as on a variable.

Costs: the report, 4, one line; the compiler, the variant's branch of
the constant writer in `Parse.raz`, which writes the tag and the
case's fields as it writes a record's: about 20 lines.

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

## Less that is undefined

Section 10 lists what isn't defined: a stale or made-up pointer,
indexing through a pointer, a slice kept after its frame is gone, a
slice of an array a call returned kept past its statement, an index
out of range under `check off;`, writing a string's bytes, a code
procedure that breaks its rules, and C. Some of these can be closed at
little cost; the rest can be fenced, so that a reader sees which
modules can reach memory they shouldn't. Four pieces, each standing on
its own, the cheapest first.

**1. An array a call returns lives to the end of its procedure.**
Section 8 says it lives to the end of its statement. Its slot in the
frame would stay reserved for the rest of the procedure instead, as a
deferred statement's slots already do, so that `s := f('a')[0..4]` is
defined until the procedure returns; in a loop the slot holds the
latest call's array. Section 10 loses a case, and what is left of it
is a slice leaving its frame (7.3), which `ret` and `keep`, above,
would close. It breaks nothing; the cost is a frame larger by each
such call's array.

**2. Writing a string's bytes stops the program, or changes them.**
Two outcomes instead of any: where the target has read-only memory,
the string constants are in it, and a write stops the program as a
bad address (section 10), as this compiler's already does, since they
are in rodata; where it hasn't, the write changes the constant for the
rest of the run, everywhere its bytes are shared. Which of the two is
the target's (appendix A). It breaks nothing.

**3. A race tears no slice.** 7.6 says a variable written by one
thread while another reads it holds a value it had, or a mixture of
their bytes, and that nothing else becomes undefined. For a slice
that is a defect: a mixture of one slice's address and another's
length is indexed, checked, against the wrong length, and reaches any
memory; a variant's tag torn from its fields is the same. The mend:
a slice, a variant, or a record holding either, read or written in a
race, is the exception of section 10, said so in 7.6. A pointer, a
word on every target, tears into nothing new. This is a defect, which
the freeze allows mending.

**4. Fencing the rest: `unsafe;`.** A module that does any of the
following says `unsafe;` after its links and its `check` line, and it
is an error to do them in one that doesn't:

- `ADR`, and `p + i`, `p - i`, `p[i]` and `p[lo..hi]` on a pointer;
- converting an integer to a pointer or a procedure, or one pointer
  or procedure type to another;
- a view, `v.(T)`, whose `T` holds a pointer, a slice or a procedure
  (one to integers, reals and their arrays stays safe);
- `check off;`, `extern`, `link`, code procedures and `SYSCALL`.

`unsafe`, like `static` in `link static;`, is a word only there. In a
program none of whose modules says it, what is left undefined is
short: a pointer used after `Heap.free` or an arena's reset gave back
what it points at, and a slice leaving its frame (7.3). The library's
modules that need it (`Rt`, `Mem`, `Heap`, `Arena`, `Bytes`, `Sys`,
`Thread`, ...) say it, as a program trusts them; `grep unsafe` lists
the rest. It breaks every module that does one of these and doesn't
say it: rmacs, ravite, the tools and ten of `src/`'s modules (by
`ADR`), each mended by one line, which
the compiler's message names. The compiler's cost is a flag on the
module, checked at each of those places. Since the seed doesn't know
`unsafe;`, `src/` can't say it until a release makes a new seed: for
one release a missing `unsafe;` is a warning, then an error.

Pieces 1 and 2 are small and change no program; 3 is a mend; 4 needs
a thaw.

## Windows

A Windows target would keep volume 2 as it is: it describes the
library on a Unix target. Windows has no stable system calls, no
signals, no fork, no termios, and fds that are handles, so its `Sys`
can't be the one volume 2 gives. Appendix A's core already lets a
target leave out all of `Sys` past writing, ending the program and
getting memory: a Windows target gives the core, and what else it has
in a module of its own (`Win`), told on a page of its own beside
volume 2. Volume 1 needs at most a sentence, that `link static;`
means no C library where there are no system calls to make. The
compiler needs a PE writer and Microsoft's calling convention.

## A slice's pointer

A slice is two words: the address its elements start at, and how many
there are (5.3). `LEN(s)` gives the second; nothing gives the first.
A program that needs it writes `ADR(s[0])`, the address of the first
element. That works only when there is a first element: when `s` is
empty, `s[0]` is an index out of range, and the program stops.

Where it bites is a program that keeps bytes as a pointer and a
length, as an interpreter keeps a string value:

```
type Value = record kind: Kind; n: INT; p: ^U8; end;

proc strVal(s: []U8): Value;
begin
    return {kind: kStr, n: LEN(s), p: ADR(s[0])};   (* stops when s is "" *)
end;
```

It compiles, and passes every test that has no empty string in it;
the first `""` stops the program. So every place that turns a slice
into a pointer must test first:

```
proc strVal(s: []U8): Value;
begin
    if LEN(s) = 0 then return {kind: kStr}; end;    (* n is 0, p nil *)
    return {kind: kStr, n: LEN(s), p: ADR(s[0])};
end;
```

The library does the same before each call to C: `Sys.write` over C
returns 0 for an empty `s` before it writes `C.write(fd, ADR(s[0]),
LEN(s))`. The test is easy to forget and says nothing about what the
program means.

The proposal: a built-in `PTR(s)`, the address the slice or array `s`
starts at, a `^T` for a `[]T` or `[n]T`, with no check. For a slice
that isn't empty it is `ADR(s[0])`. For an empty one it is what the
slice holds: `nil` for a slice variable as it starts (section 4), and
for one cut empty from another, `t[3..3]`, an address that mustn't be
read through, as the end of an array mustn't. With it:

```
proc strVal(s: []U8): Value;
begin
    return {kind: kStr, n: LEN(s), p: PTR(s)};
end;
```

The way back is there already: `v.p[0..v.n]` is the slice again
(6.4), empty when `v.n` is 0, whatever `v.p` is. Reading through the
pointer is as unchecked as through any pointer; `PTR` only stops the
program from failing where nothing is read.

It costs a row in the table of 6.8. A predeclared name can be hidden
(section 3), so it breaks no program.

Met in concha's `Ccore`, in `bufVal` and `listVal`, and in `Sys` over
C, before each call that takes a buffer.

## An enumeration's name read against the type it is given to

Two enumerations of a scope may share a name, and then the name alone
is an error: "the type is never taken from where the name stands"
(5.7). So a table of records, which names its enumerations on every
row, must write the type out on each row where the name is shared,
though the field says which enumeration it is:

```
type
    MenuAction = (close, run, complete);
    BlockKind = (time, run, window);
    MenuKey = record sym: INT; act: MenuAction; end;
    Block = record kind: BlockKind; arg: []U8; end;
const
    MenuKeys: []MenuKey = [{sym: 13, act: run}];   (* an error: MenuAction.run or BlockKind.run *)
    Blocks: []Block = [{kind: run, arg: "date"}];   (* and so is this *)
```

Adding `BlockKind`, with its `run`, broke `MenuKeys`, which had
compiled until then: a name added to one table reaches into the other.

The proposal: where a value is given to a place whose type is an
enumeration, a name of that enumeration written alone is that name,
though another enumeration of the scope has it too. The places are the
right side of an assignment, a field of a record or variant written
with braces, a value parameter, a `return`, and the other side of a
relation with a value of the type. Everywhere else, and wherever the
rule of 5.7 names something already (a constant, a variable or a
procedure of the scope that isn't an enumeration's name), it stays as
it is. A program that compiles today means the same; only some of the
programs refused today compile, so it breaks none.

It costs a line of 5.7, and in the compiler, a type passed down to the
lookup of a name where the parser knows it.

Met in mosaico's `Mconfig`, where `MenuAction.run` and a status block's
kind `run` met; the block's kind was renamed `command`.
