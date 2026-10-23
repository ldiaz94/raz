# raz: proposals

What the language or the library might have, met while writing raz.
None is built while the freeze holds; each waits for a later thaw, by
the owner's word, and goes into the report before any code.

## Installed source libraries and RAZ_PATH

**Status.** Approved by the owner on 2026-10-19 and implemented after
this proposal was committed and pushed. This changes the compiler's
module search paths and documents an installation convention; it adds
no language syntax or package manager.

A library should be usable by several programs without adding it as a
Git submodule to each. Install its source modules directly in
`$HOME/.raz/lib`, including any target-specific siblings. The compiler
searches that directory automatically. It does not search subdirectories
or create the directory itself.

`RAZ_PATH` replaces that default with a colon-separated list of module
directories. An unset variable means `$HOME/.raz/lib`; an explicitly
empty value disables user library directories. Empty entries in a list
are ignored, rather than standing for the working directory. Relative
paths are relative to the compiler's working directory. The compiler
does not expand `~` or environment variables inside a path: the shell
can expand them when setting `RAZ_PATH`. If `HOME` is unset or empty,
there is no default user library directory.

The search is the main module's directory, each `-I` directory, the user
library directories, and finally `lib/` beside the compiler. The standard
library is always searched, even with an empty `RAZ_PATH`. Existing
target suffixes, interface checks, duplicate-module errors and the
symbolic-link exception apply to the new directories too. `-I` does not
silently override an installed module.

For example:

```sh
mkdir -p "$HOME/.raz/lib"
install -m644 Json.raz "$HOME/.raz/lib/Json.raz"
raz Main.raz                         # import Json; needs no -I
export RAZ_PATH="$HOME/.raz/lib:$HOME/work/raz-libs"
RAZ_PATH= raz -I deps/json Main.raz  # an isolated dependency selection
```

A library's build file may provide install and uninstall tasks for its
own source files. Robbie can run those tasks, as make or a shell can;
the convention belongs to raz and needs no special robbie feature.
Dependency versions and downloads remain the project's or user's choice.

Document this in the report's module lookup, raz(1), the README and the
compiler guide. Test the unset and empty cases, lists of directories,
paths with spaces, target-specific files and interface checks, duplicate
modules and symbolic links, and use with both compilation and `raz run`.

## What a call does with its arguments, written at the call

**Status.** Not approved. Drafted 2026-10-16 and reviewed twice on
2026-10-17 (the second review's findings are under "Open questions",
at the end of part 1). The owner judged the feature, and its use, not
settled: no change is made for the marks at the call, `ret` or `keep`.
It was drafted as five parts. Three of them went into report
2026-10.33 on their own, without the marks: the library's parameters
by `var` (part 2), a `const` parameter (part 4), and a variant in a
constant (part 5). What is left are the two parts not approved, kept
by their numbers:

1. **Marks at the call** (this section): an argument for a `var`
   parameter is written `var x`, and one for a `keep` parameter
   `keep x`.
3. **`ret` and `keep`** (below): a heading says what a procedure does
   with what it is given, and the compiler holds the body to it.

Nothing is built unless the owner starts it. The report changes first,
as always; the documentation listed below comes with it.

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
| `const x` | reads the caller's variable in place, without a copy, and doesn't change it | nothing | `Opt.number(p, 1, 9)` |
| `var x` | may change the caller's variable | `var x` | `Buf.add(var b, c)` |
| `keep x` | may store it where it outlives the call | `keep x` | `Names.put(var table, keep name, keep 1)` |
| `ret x` | its results may point into it | nothing | `s := Str.trim(line[0..n])` |
| `^T` | keeps a pointer, or takes one for C, an allocator, or what may be `nil` | `ADR(x)`, or a pointer it holds | `Thread.spawn(work, ^U8(ADR(job)))` |

A slice given to an unmarked parameter is a value, two words, but the
elements it points at are the caller's: the procedure may write them,
and nothing at the call says so. `Sys.read(fd, line)` fills `line`,
`COPY(d, s)` fills `d`. A slice is a view of the caller's array, and
lending it is what it is for; the table says so in a note under it.

`var` and `const` are in the language now (report 2026-10.33); `keep`
and `ret` would come with part 3. The table, and the note, go into the report (8), raz(7)
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
   else in a temporary of the statement (report section 8).

```
Arguments  = "(" [ Argument { "," Argument } ] ")" .
Argument   = [ "keep" ] [ "var" ] Expr .
```

Each rule looks at the call and the heading only, so a one-pass
compiler makes them as it reads the call: perhaps 40 lines, beside the
250 to 400 of part 3 (400 to 600, by the second review).

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

**A table a procedure keeps**, a constant (report section 4), as `Sh`'s is now:

```
const Rows: []Opt.Row = [
    Opt.usage("", "Sh [-c script | file]"),
    Opt.option("", 'c', "command", "script", "run script, not standard input")];
...
Opt.init(var p, keep "Sh", keep Rows);
while Opt.next(var p) do ... end;
secs := Opt.number(p, 1, 600);             (* number only reads: const, no mark *)
```

Today's `Opt.init(ADR(p), "Sh", [...])`, with the literal in the call,
is an error once `init` is `keep table`: the literal lives in the
frame, and `keep` can't say "as long as `p`" (part 3, "False alarms").

**A large record only read**, by `const` (report section 8), as `tools/Pretty.raz` has it now:

```
proc is(const sc: Scanner; s: []U8): BOOL;        (* Scan's *)

if Scan.is(sc, "-") or Scan.is(sc, "+") then ... end;
if Scan.among(Scan.text(sc), binaryWords) then ... end;
```

Before 2026-10.33 each of these was `ADR(sc)`; by `var` each would say
`var sc`, and none changes it.

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
```

The compiler already says, since 2026-10.33, that a `const` parameter
can't be changed, and what to write for `ADR(b)` or `p` given to a
`var` or `const` parameter.

### How much noise

Measured by a search of `src/`, `lib/`, `tools/` and `examples/`, about
23,300 lines of code (rough: a search, not the compiler):

- about 630 `ADR`s, before 2026-10.33; most were at calls to the
  library, which now take `x` itself, and would take `var x`;
- about 580 calls of our own procedures with `var` parameters, unmarked
  today: each gains `var`, about one line in 40;
- `keep`: a few dozen calls (`Map.put`, `List.push`, `Vec.push`,
  `Opt.init`, `Opt.scope`, and procedures that pass a kept value on).
  Since it follows the heading, it stands also before values that can't
  end, `keep 1` in `Names.put(var table, keep name, keep 1)`: a word
  each, the price of one rule for every instance;
- `const`: none at the call.

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
  slices, rules 1 to 8, and the swap and map examples; `keep` and
  `ret` from part 3. 5.9: procedure types with marks. 7.3: `ret`. 10: the promise, whose
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
  stands;
  then "What the compiler stops", the four mistakes of the messages
  above, each with its message. Section 16, "FROM PASCAL AND C TO RAZ",
  gains: Pascal's `var` is unmarked at the call, raz's is marked, as C#'s
  `ref` is; C's `&x` becomes `var x` when the callee only changes it,
  and stays `ADR(x)` when it keeps it. Every other example in the
  tutorial is marked. Each runs under `make check`, as now.
- **Volume 2, `doc/raz-lib.md`, and raz-lib(3)**: each module's
  example marked, and `keep` and `ret` where the library has them.
- **`STANDARDS.md`**: `ADR` no longer marks what is kept, `keep` does.
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

Every call to a procedure with a `var` or `keep` parameter: in `src/`, `lib/`, the
tools, the examples, the tests, and rmacs, ravite, rat, rlX11, rloc,
rpg and rsqlite, each when it moves its pin. The mending is mechanical,
and the compiler names it at each place.

**BOOT first.** The release `BOOT` names can't read a marked call, and
it builds `src/` and reads `Sys` and `CAbi`. So this thaw needs a
release that reads the marks, named by `BOOT` (CLAUDE.md, "The compiler
and BOOT"), before `src/` and that part of the library can be marked:
the owner's call, and the first step.

Then, one commit each:

1. The report, `report-history.md`, raz(7): for review.
2. The compiler reads the marks and checks rules 1 to 8, and every
   caller in this repository is marked.
3. `ret` and `keep` in headings and their checks (part 3), and the
   library marked (`Str.trim`, `Map.put`, `List.push`, `Vec.push`,
   `Opt.init`, `Opt.scope`, ...).
4. The tutorial, volume 2, raz-lib(3), `STANDARDS.md`,
   `doc/compiler.md`, `README.md`.
5. The tests: `conform/`, `test/err`, `test/msg`, `test/pretty`, the
   editors.

The examples of parts 2 and 3 are written as the whole thaw makes
them, with the marks of part 1.

### Open questions

The second review, 2026-10-17, read the five parts against `src/`,
`lib/Opt.raz`, `tools/Pretty.raz` and `examples/Words.raz`. It found
the direction sound, and parts 1, 2 and 4 clearly better in `tools/`
and `Opt`, but mostly noise in `src/Parse.raz`, where `var x` stands
on nearly every call. Left open, by the owner's word:

1. **BOOT.** A release of today's compiler can't read the marks
   either, so "BOOT first" can't work as written: it takes two
   releases, one that accepts every new form without requiring it,
   named by `BOOT`, then one that marks `src/` and requires the marks.
2. **An error here.** Part 3's `Names.put(var table, keep buf[0..n], 1)`
   lacks `keep 1`. (The others the review found were in parts 2, 4
   and 5, mended when they went into the report.)
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
8. **`ret` with `const`.** `ret const` given a temporary that holds an
   array would return a slice of the temporary: an error. The heading's
   grammar, `Params = ["ret"] ["keep"] ["var" | "const"] ident ...`,
   and the call's, a designator after `var`. (The rest of `const`'s
   rules are report 2026-10.33's, section 8.)
9. **Procedure types** with fewer marks are assignable, not the same:
   5.10 must say so, for `=`, generic instances and `forward`.
   `Map`'s `eq` can't take a `const` equality.
10. **False alarms to document.** A local container over a local
    buffer, `Scan.init(var s, keep line[0..n])`, is refused though both
    end together (a module variable, a `Buf` or the heap is the way
    out); so is a store through `ADR` of a local.

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
  is not proposed. The way out: the table a constant, which report
  2026-10.33 allows, as part 1's example shows.
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

**Status.** Deferred by the owner on 2026-10-22: not soon, if at all.

## Dividing 128 bits by 64

**Status.** Approved by the owner on 2026-10-23 and implemented in `lib/Math.raz` as `divMod`, since `div` is a reserved word: a code procedure over `div`, with `hi >= d` stopped first.

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
any inlining, but it is a language change, for a thaw. **Taken into
the report (2026-10.35):** the built-ins `ROL(x, n)` and `ROR(x, n)`,
by the owner's word; the compiler has them. rcrypto met the
same (its `RAZ-NOTES.md`): SHA-256 at 32 MB/s with `ror` a procedure,
80 with it written out. On 100 MB of
new files `sauce commit` takes 1.2 s against the Pascal sauce's 0.7,
and `verify` 0.95 s against 0.48: the hashing.

## Less that is undefined

**Status.** Parked by the owner on 2026-10-23 for the safety thaw that follows once the proposals are cleared, with `MEM_PROPOSAL.md`.

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
module, checked at each of those places. Since BOOT's release doesn't
know `unsafe;`, `src/` can't say it until `BOOT` names one that does:
for one release a missing `unsafe;` is a warning, then an error.

Pieces 1 and 2 are small and change no program; 3 is a mend; 4 needs
a thaw.

## Windows

**Status.** Not planned (owner, 2026-10-23).

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

## An enumeration's name read against the type it is given to

**Status.** Not planned (owner, 2026-10-23): 5.7's rule, that the type is never taken from where the name stands, keeps reading local.

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

## A slice that can't be written: `[]const T`

**Status.** Parked by the owner on 2026-10-23 for the safety thaw that follows once the proposals are cleared, with `MEM_PROPOSAL.md`.

raz has no slice whose elements can't be written. A `const` parameter
(report 2026-10.33, section 8) is shallow: the procedure can't change
the record, but it can write through a slice in it, and through a
slice it makes of an array in it. A constant's slices, and every
string literal, point at bytes whose writing "isn't defined" (5.10,
10): the compiler doesn't refuse it, and on a target with read-only
memory the program stops. Nothing in a heading says that `Str.eq`
only reads its slices and `Str.lower` writes them.

```
type Rule = record class: []U8; tag: INT; end;
const Rules: [2]Rule = [{class: "firefox", tag: 2}, {class: "mpv"}];

proc shout(const r: Rule);
begin
    r.class[0] := 'F';        (* allowed today: writes the constant's bytes, undefined *)
end;
```

The proposal: a slice type may say its elements are read only,
`[]const T`, as a pointer type says `^VOLATILE T`.

- Its elements can be read and sliced, and not written: no `s[i] :=`,
  no `COPY` into it, no `var` argument or `ADR` of an element, no
  `INC` of one. A slice of it is `[]const T` too.
- A `[]T` goes where a `[]const T` is wanted, as `U8` widens to `INT`;
  never the other way. A procedure that only reads a slice takes
  `[]const T`, and every caller's `[]T` still fits it: `Str.eq(a, b:
  []const U8)`, `Sys.write(fd: INT; s: []const U8)`, `Out.str`. Those
  changes break no program.
- A record field may be `[]const U8`, so a record, a constant's above
  all, can hold slices that can't be written: `type Rule = record
  class: []const U8; ... end`, and `shout` above is refused.

What a procedure returns of its argument is the hard part. `Str.trim(s:
[]const U8): []const U8` would hand a caller with a `[]U8` back a
slice it can't write, and break the caller that does. Either such
procedures keep `[]U8` until `ret` (above) can say "of the same kind
as the argument", or they come in pairs. This is where D's `inout` and
C++'s `const` overloads went; neither is small.

A second step, for a thaw: a string literal and a constant's slices
are `[]const U8` and `[]const T`, so that writing them is an error,
not undefined, and section 10 loses a case. It breaks every program
that keeps a literal in a `[]U8` variable or field, which is most of
them, `Opt`'s rows included; each is mended by writing `[]const U8`
where nothing writes the bytes.

Precedent: C's `const char *`; D's `const(T)[]`; Rust's `&[T]` and
`&mut [T]`; ulam, the other language here, makes `[]T` read only and
writes `[]var T` for one that may be written, which is the safer
default but breaks every raz program.

Costs: the report, 5.3, 5.10 and 10, and 8 for `const` parameters,
which could then read their slices as `[]const`, making `const` deep
for slices; the compiler, a flag on a slice type, as `vol` is on a
pointer, checked where an element is written, about 60 to 100 lines;
the library, its read-only slice parameters, a long list but each
change one word.

Met in the discussion of `const` parameters (2026-10-17): "If a const
can still be written, what's the point?", and "Can records have
constant slices?"

## For a kernel: three changes to the compiler

**Status.** Done in v0.21.0 (2026-10-17), all three: `raz -base`, `raz -bare`, and the privileged instructions.

Not the language's but this compiler's, kept together since they serve
one end: a raz program run on the bare machine, a unikernel, with no
operating system under it. None is needed for one: a kernel can be
made today, with a boot stub of its own that enters long mode, `db`
for the instructions the assembler lacks, and either a library of its
own beside a copy of `raz` (the library is read from beside the
compiler) or a handler for `syscall` that does what `Rt` and `Sys` ask
of Linux. Each piece below takes away one of those work-arounds, and
stands on its own.

**1. A load address chosen at the command line.** Done (2026-10-17):
`raz -base ADDR`, a multiple of the page, the program wholly in the low
or the top 2 GB (`doc/compiler.md`, the linker).

**2. A program with no `Rt` body.** Done (2026-10-17): `raz -bare`
reads no `argc` and `argv`, runs no body of `Rt` and gives it no
profiler. It still gives `Rt` the places, by stores alone, so that a
failed check says where it was, which the proposal had left out as
`-s` does (`doc/compiler.md`, the command line).

**3. The privileged instructions in the assembler.** Done (2026-10-17):
`cli`, `sti`, `iretq`, `swapgs`, `lgdt`, `lidt`, `ltr`, `invlpg`,
`mov` to and from the control registers, `rdmsr`, `wrmsr`, `in`, `out`,
`wbinvd`, `xsave` and `xrstor` (`doc/compiler.md`, the assembler).

What is still left to a kernel's own code, with all three: zeroing
the bss and a stack aligned to 16 bytes before `_start`, as Linux
gives; the boot stub, since no common loader enters an ELF64 file in long mode but
Firecracker (GRUB's Multiboot2 and QEMU's PVH enter in 32-bit mode,
and the assembler makes only 64-bit code); interrupt stubs that save
the XMM registers, since the compiler's code uses them; and, if the
compiler's code ever writes below `rsp`, which isn't yet checked, an
IST stack for each interrupt.

Met in the question "how difficult to create a simple amd64 unikernel
in raz?" (2026-10-17).

## `Sys.setsid`: a session of a process's own

**Status.** Approved by the owner on 2026-10-23 and implemented in both backends.

Library growth that breaks no program: one procedure, beside `fork`,
in `Sys.raz` (C's `setsid`) and `Sys.linux-x86_64.raz` (system call
112).

    (* A new session and process group, led by this process, with no
       controlling terminal: its process id, or minus an errno (-1,
       EPERM, if it leads a process group already, as a process just
       forked doesn't). *)
    proc setsid*: INT;

A daemon forks, and its child calls `setsid` so that the terminal it
was started from is no longer its own: closing that terminal sends it
no `SIGHUP`, and the terminal's job control doesn't reach it. Without
it, a program can ignore `SIGHUP` and `SIGINT` (`Sys.ignore`), but
stays in the terminal's session and process group, so job control and
any other signal sent to the group still reach it.

Met in rabble, whose daemon (its `PLAN.md`, from 0.2.0) is started by
the client with `fork` and must outlive the terminal (2026-10-21).

## The local time zone

**Status.** Not planned (owner, 2026-10-23): rzone answers it outside raz.

Library growth that breaks no program: a module, `Zone`, that tells
the offset from UTC of the user's time zone at a given time, so that a
program can show times as its user's clock does.

    (* The local zone's offset from UTC, in seconds east, at the time
       t (seconds since 1970 UTC), and its abbreviation ("CEST"); 0 and
       "UTC" if no zone can be read. *)
    proc offset*(t: I64): (INT, []U8);

The zone is the one `TZ` names, as a file under `/usr/share/zoneinfo`
(`TZ=Europe/Madrid`) or a path (`TZ=/etc/localtime`); with `TZ` unset,
`/etc/localtime`. The file is TZif, versions 1 to 4, read once and
kept: its transitions, and the POSIX rule in its footer for the times
past the last one. A `TZ` written as a POSIX rule itself
(`CET-1CEST,M3.5.0,M10.5.0/3`) is read too. No C: the same on every
target, with or without libc, so a program's times don't change with
the target it is built for.

Met in rabble, which shows every time in UTC, in the screen and in its
logs, since the library has no zone (2026-10-21).

## Implementation limits, and a compiler for a small stack

**Status.** To investigate; nothing decided.

The report names no implementation limits: how deep expressions,
statements, imports and generic instances may nest, how long a name or
a string may be. A compiler for a small machine that rejects a deep
nesting is then arguably not a raz compiler at all. C settles it with
its translation limits (C99 §5.2.4.1: 63 levels of nested parentheses,
15 of nested includes, and so on): every compiler must take at least
that much, and may take more. The proposal: a short section in the
report giving the least each compiler must accept, and saying that a
compiler that goes past its own limit stops with an error naming it,
never a crash. It changes the report, not the language.

Behind it, three things in this compiler that need no change to the
report at all, so that it runs in a small stack:

1. **Nesting.** Each level of a nested expression costs about 1 KiB
   of stack. A constant expression with 64 nested parentheses fails a
   64 KiB stack and passes 256 KiB; 256 of them fail 256 KiB and pass
   1 MiB. A limit from the section above, checked in the parser, makes
   the stack a program needs bounded and known.
2. **Imports.** `importModule` compiles an imported module in the
   middle of the one importing it, on the same stack, so the stack
   grows with the depth of the chain of imports. Ordering the modules
   first and compiling them from the leaves, in a loop, keeps whole
   program compilation and a stack that doesn't grow; symbol files, as
   Wirth's compilers have, would do it too, but must then carry a
   generic module's body.
3. **Instances.** `makeInstance` keeps the declaration under way aside
   in arrays on the stack (`[MaxFwd]PType`, `[MaxFwd]Diag.Pos`,
   `[MaxNames]INT`, several KiB) for every instance it nests. A list
   of instances still to make, made between declarations, would keep
   none.

Not yet measured: which of these filled the stack when the stripped
compiler, given one more `-I` directory, overflowed 64 KiB building
itself, where the ordinary self-build fit.

Met in moss (`docs/raz-port.md`): its stored programs get a guarded
64 KiB stack, and a native compiler must fit, or the stack must grow
(2026-10-22).

## `Sys.blocking`: whether a descriptor's reads and writes wait

**Status.** Approved by the owner on 2026-10-23 and implemented in both backends.

Library growth that breaks no program: one procedure, beside
`setBlocking`, in `Sys.raz` (C's `fcntl` with `F_GETFL`) and
`Sys.linux-x86_64.raz` (system call 72, `F_GETFL`, as `setBlocking`
already makes it).

    (* Whether reads and writes on fd wait, as they do at first: 1 if
       they do, 0 if they return -11 (EAGAIN) at once, or minus an
       errno. *)
    proc blocking*(fd: INT): INT;

`setBlocking` sets the flag but nothing reads it, so a library that
must make a caller's descriptor non-blocking for a while can't put it
back as it found it: it can only guess. rnet's `Tls.accept` makes the
socket it is given non-blocking for the handshake and, on failure,
makes it blocking again, as `Sys.accept` gives it; a caller that gave
it a non-blocking one gets it back changed. With `blocking`, it would
note the flag first and restore that. A test, too, can't check that a
descriptor was put back without it.

Met in rnet, after a review of its STARTTLS (2026-10-22).

## Base64 in `Str`

**Status.** Approved by the owner on 2026-10-22 and implemented in
`lib/Str.raz`, with the interface below; `out` too short stops the
program at the byte it lacks, as any slice does. Decoding also rejects
padding bits that are not 0 (RFC 4648, section 3.5 allows it).

Library growth that breaks no program: three procedures in `Str.raz`,
beside `hexVal` and `toHex`, of base64 as RFC 4648 (4) has it: its
alphabet, `A` to `Z`, `a` to `z`, `0` to `9`, `+` and `/`, and `=` to
pad the last group to four.

    (* The bytes base64 makes of n bytes: 4 for each 3, or part of 3. *)
    proc base64Size*(n: INT): INT;

    (* s in base64 into out, which holds base64Size(LEN(s)) bytes at
       least: the bytes written. *)
    proc base64*(s, out: []U8): INT;

    (* s, base64, decoded into out, which holds LEN(s) div 4 * 3 bytes at
       least: the bytes written; false if s isn't base64, its length
       not a multiple of 4, a byte outside the alphabet, or padding
       anywhere but at the end. *)
    proc unbase64*(s, out: []U8): (INT, BOOL);

The caller gives the room, as `Fmt` and the rest of `Str` have it, so
nothing is allocated. Decoding is strict: line breaks and missing
padding, which MIME and some programs allow, are the caller's to take
out or put back first.

Programs each carry their own copy meanwhile: rnet's `Ws`, for the
WebSocket handshake's accept key, and `Smtp`, for AUTH PLAIN, the same
twenty lines twice in one library; flojo, for the terminal's clipboard
(OSC 52), its own fifteen. HTTP's Basic authentication and data URLs
want it as well, and want decoding too, which none of those copies
does.

Left out: base64url (RFC 4648, 5), for JWTs, which is the same with
`-` and `_` and usually no padding; a flag, or a second pair of
procedures, if a program needs it.

Met in rnet, whose `Smtp` copied `Ws`'s (2026-10-22); listed in
`~/r/RAZ-GAPS.md` before that, from rnet and flojo.

## A library that says which raz it was written for

**Status.** Approved by the owner on 2026-10-22 and implemented: the deprecation step as policy alone, with no mark (`doc/raz-lib.md`, `README.md`); the note from a library's `RAZ-VERSION` (`Diag`, `Parse`); and `--version` naming the commit with no tag (`Makefile`).

0.19 moved the library from pointers to `var` and `const` parameters,
and every library pinned to an older raz stopped building: rnet, rjson,
rfetch, rj and arno needed fixes, and alba, clima and linia carried
their own JSON reader meanwhile. The errors were loud but far from the
cause: "can't use ^Buf as Buf" inside rjson, read by someone building
clima. The report says the library "grows only by what breaks no
program", and the move broke all of them. Three small pieces, none of
them syntax.

**A deprecation step.** A change to the standard library that breaks
programs keeps the old form for one minor version beside the new, the
old one marked so that a call to it is a warning naming the new one:

    (* deprecated: Buf.add(var b, ...) *)
    proc addOld*(b: ^Buf; s: []U8);

How the mark is written is the open question: a comment the compiler
reads is a pragma in disguise; a word like `obsolete` before `proc` is
a reserved word for a rare case. The step could also be policy alone,
with no mark: the release notes list the old forms and the next
version removes them.

**An error says whose module it is in.** An error in a module found
through `-I` or `RAZ_PATH` names the directory it came from and, if
that directory holds a file `RAZ-VERSION` (one line, `0.21`), the raz
it was written for:

    /home/luis/.raz/lib/Json.raz:41: can't use ^Buf as Buf
      (a library written for raz 0.18; this is raz 0.21)

The compiler only reads the file; it never refuses to build. A library
that has none is no worse off than today.

**`raz --version` says its commit** when `git describe` finds no tag,
as from a shallow fetch, instead of "unknown" (rcrypto pins a commit
and always sees "unknown").

Met in rnet, rjson, rfetch, rj, arno, alba, clima and linia (0.19),
and rcrypto (`--version`).

## Sys for a server

**Status.** Approved in part by the owner on 2026-10-23 and implemented in both backends: `closeWrite`, `peer` (its record is `Remote`, since `Peer` is taken by `receive` and `reply`), `socketPair`, `nonblocking` and `errConnAborted`. `closeOnExec` is unneeded now that every open closes on exec. A send that doesn't wait (`sendNow`), a fifo (`makeFifo`) and an owner (`Info.uid`, `Info.gid`, `chown`) followed on 2026-10-23. Keepalive and an abstract Unix socket wait for a second program.

Library growth that breaks no program. Programs that serve sockets
(rabble's relay and daemon, dwa's broker, rdbus, awizo, arno's te
protocol) each declare a few C procedures or make system calls with
`SYSCALL` in a `.linux.raz` file, for what any server needs. Each piece
below stands alone; together they are about a dozen procedures in
`Sys.raz` and `Sys.linux-x86_64.raz`.

- **`shutdown`.** `proc closeWrite*(fd: INT): INT;` ends this side's
  writing, `SHUT_WR`, so the peer reads an end and can still answer
  on the same socket (te's protocol; rabble wakes a thread waiting in
  a handshake with it). Met in dwa, rabble, arno.
- **Who is at the other end.** `proc peer*(fd: INT): (Peer, INT);`
  with `Peer` the address of a TCP peer (family, address bytes, port)
  and, for a Unix socket, the peer's uid and pid (`SO_PEERCRED`). A
  server can log who connected and a broker can check that its client
  is the same user, instead of trusting a 0700 directory. Met in
  rabble, dwa.
- **A pair of sockets.** `proc socketPair*(): (INT, INT, INT);` the two
  ends and 0, or minus an errno. Met in rdbus's tests and rabble's
  relay.
- **A send that doesn't wait.** `proc sendNow*(fd: INT; s: []U8): INT;`
  (`MSG_DONTWAIT`): -11 where `send` would wait, without making reads
  non-blocking too. Met in rdbus.
- **Opening without waiting.** `nonblocking` and `closeOnExec` among
  `Access`. (`closeOnExec` falls away if "Sys for files and
  memory" makes it the default.) Opening a fifo to write waits for a reader, and a fifo
  given where a file was expected waits for a writer. Met in mosaico,
  awizo, surco, raudio.
- **A fifo.** `proc makeFifo*(path: []U8; mode: INT): INT;`. Met in
  awizo.
- **An owner.** `Info.uid`, `Info.gid` and `proc chown*(path: []U8;
  uid, gid: INT): INT;`, so a save through rename keeps the owner and a
  daemon can check that its directory is the user's. Met in dwa,
  rabble.
- **Keepalive.** `proc keepAlive*(fd: INT; idle, interval, count:
  INT): INT;` rather than a general `setsockopt`, whose value is a
  pointer and a length of any type. Met in rabble.
- **An abstract Unix socket.** `connect` passes `2 + LEN(path)` as the
  address's length when the path starts with a zero byte, so Linux's
  abstract names (D-Bus's `unix:abstract=`) are reached. A fix, not a
  procedure. Met in rdbus.
- **`errConnAborted`** (-103), which `accept` gives for a client gone
  before it was taken. Met in rabble.

**Waiting**, the one piece that changes a procedure's answer, and so
better as a new procedure than a change to `readyFor`:

    (* Waits up to ms milliseconds (ms < 0: as long as it takes) until
       one of fds may be read or written as each of its wants says, and
       sets each one's ready. The number ready, 0 on a timeout, or minus
       an errno. *)
    proc poll*(var fds: []Poll; ms: INT): INT;

with `Poll = record fd: INT; read, write: BOOL; ready: BOOL; end`.
It takes as many as it is given (`readyFor` stops at 64, so dwa's
broker serves 31 editors), answers every ready descriptor in one call
(`readyOf` gives only the first, so awizo takes two rounds and rabble
rotates its clients so that the first doesn't starve the rest), gives
the place in the list, not the fd, and tells a timeout from an error
(both are -1 today). `readyFor` and `readyOf` stay, written over it.
Whole milliseconds stay too: surco rounds up, and a wait in
nanoseconds is `ppoll`, Linux's, for one program.

Each item is listed in `~/r/RAZ-GAPS.md` under "Standard library: Sys,
files, processes".

## Sys for running a program

**Status.** Approved by the owner on 2026-10-22 and implemented in both `Sys` backends, all four. `spawn` also gives -13 (EACCES), as `exec` does, for a program found that can't be run.

Library growth, but two of the four change what `spawn` and `wait`
do, so they need the owner's word on whether a change of behaviour
counts as breaking.

- **`spawn` says a program isn't there.** Today a missing program
  still gives a pid, and the child exits 127, which a caller can't tell
  from the program's own 127; clima, alba, sauce and raztest search
  `PATH` first, about 20 lines each, and sauce still reads curl's 127
  as "cannot run curl". `spawn` searches `PATH` in the parent, as
  `exec` already does, and gives -2 (ENOENT) before it forks. A
  program found but failing in `execve` (not executable, a bad
  interpreter) still exits 127, since only the child sees that; a
  close-on-exec pipe would carry its errno back, at the cost of a pipe
  per spawn.
- **Ignored signals stay ignored.** `spawn` and `exec` give the child
  every signal as at first, SIG_IGN included, where `execve` keeps an
  ignored one ignored: a robbie under `nohup` runs its recipes without
  it, and ssh run by fdn doesn't keep SIGPIPE ignored. A
  `Program.keepIgnored: BOOL`, false as today, keeps them.
- **`fds` with `tty`.** With `tty`, the pseudo-terminal is all three
  files and `fds` is ignored, so dwa's background job that should read
  `/dev/null` waits on a terminal nobody types to. A non-zero `fds[i]`
  replaces the terminal for that file; zero keeps it.
- **`wait` without the stopped.** `wait` always asks for stopped
  children (WUNTRACED), so a program waiting for `$EDITOR` loops past
  Ctrl-Z (notis, fdn). `proc waitExit*(pid: INT): (INT, Status, INT);`
  waits only for an end, or `wait` takes `stopped: BOOL`, which
  changes its signature.

`PATH` read empty as unset (pict) stays: the library volume says so,
and it is `execvp`'s choice.

## An investigation: where a hot loop's time goes

Not a change: a measurement, whose report would say whether register
allocation, inlining (see "Inlining a procedure that only returns"),
or neither is worth its weight in the compiler.

What is known, from rcrypto, rat and sauce:

| Code | MB/s | Against |
|---|---|---|
| ChaCha20, `quarter` on a `var x: [16]U32` | 40 | 78 written out on sixteen locals; OpenSSL scalar 589 |
| Poly1305, arithmetic on locals, no calls | 491 | |
| AES-128 bitsliced, 115 gates on 130 local `U64`s | 23 | GHASH 180 |
| SHA-256 with `ROR` | 76 | 40 before `ROR` |

and rat's parser, which inlines `Utf8.take` by hand because the call
costs 7 to 10 per cent.

The steps: a `bench/` of these few kernels, each in its plain form and
its hand-tuned one; their `raz -S` read side by side, counting loads
and stores of locals, spills and calls; then the same kernel with the
generator changed by hand (a local kept in a register across a loop, a
small procedure inlined) to put a number on each. The outcome is a
page here saying which change buys what, and none is made before it.

Listed in `~/r/RAZ-GAPS.md` as "A state in an array or behind a `var`
is slow" and "No procedure is inlined".

## A width in `Fmt`

**Status.** Approved by the owner on 2026-10-22 and implemented in `lib/Fmt.raz`, with `lowHex` as a case of `Arg`; a width is at most four digits.

Library growth that breaks no program. `Fmt` has only `{}`, so seven
programs pad by hand: arno, rat, notis and poczta each have a
two-digit helper for times, surco writes `m:ss` and its cover files'
lower-case hashes with loops of its own, rttf writes `U+00E9` and raz's
own `Prop` a fixed-width hex name.

The proposal: a width between the braces, and a zero before it to pad
with zeros, right-aligned:

    Fmt.print("{2}:{02}", [Fmt.int(m), Fmt.int(s)]);    (* " 3:07" *)
    Fmt.print("U+{04}", [Fmt.hex(0E9H)]);              (* "U+00E9" *)

A value wider than the width is written whole. A minus pads on the
right (`{-10}`), for columns of names. Zeros go after a sign: `{04}` of
-7 is `-007`. Nothing else: no precision (`Fmt.real` has `places`), no
other fill, no named or numbered arguments.

And a lower-case hexadecimal: a case `lowHex(h: U64)` beside `hex`, or
`{x}` against `{X}`, which is a second letter in the format for a thing
an argument could say. The argument is the plainer.

`{` followed by anything but `}` or a width is printed as it stands
today, so no format changes meaning unless it already had `{2}` in it,
which printed `{2}`.

Settled by "One exponent letter: `Fmt` writes `E`", below.

## Selectors after a `^T(e)` conversion

**Status.** Not planned (owner, 2026-10-23): it makes unchecked code shorter and adds nothing a named pointer type can't do; `BYTES` serves the checked uses.

A conversion through a pointer type's name is a designator, so
selectors follow it: with `PR = ^R` and `PU = ^U8`, `PR(ADR(r))^.b`
and `PU(ADR(r))[0..4]` compile today. The same conversion written out
is the grammar's own factor, `"^" ["VOLATILE"] Type "(" Expr ")"`, and
takes none: `^R(ADR(r))^.b` is "a conversion can't be dereferenced",
and `^U8(ADR(r))[0..4]` is "can't use ^U8 as []U8", the slice read as
part of the operand. So a program declares a pointer type, or a
variable, for one read through a C struct or one slice of raw memory.

The proposal: that factor takes selectors, as a named conversion does.

    Factor = ... | "^" ["VOLATILE"] Type "(" Expr ")" { Selector } | ...

`^U8(p)[0..n]` is a slice of `n` bytes from `p`; `^XMapEvent(ADR(ev))^.window`
is one field of an event. Nothing new is checked or left unchecked: the
selectors are a pointer's, as they are after `PU(p)`. A statement still
starts with a name or `try`, so `^T(x)^ := v` stays out (the report
says so already, and a view, `mem[a].(I64) := v`, writes it). What is
text with an error today gets a meaning, and nothing else changes.

Met in znaczy, raudio, rcrypto and linia (the slice) and rx11 (the
dereference).

## The limits of an integer type: `MIN(T)` and `MAX(T)`

**Status.** Approved by the owner on 2026-10-22, a twelfth thaw. In the report, 2026-10.36 (sections 4, 6.1 and 6.8), and in the compiler (2026-10-23).

Programs write `7FFFFFFFFFFFFFFFH` for the largest `I64` and `-10^12`
for "below anything real", and nothing ties either to its type: change
a field from `I64` to `I32` and the constant still compiles, wrong.
Oberon has `MIN` and `MAX` of a basic type for this.

The proposal: two built-in procedures, for an integer type `T` only:

| Call | Result |
|---|---|
| `MIN(T)` | the smallest value of `T`, an untyped constant |
| `MAX(T)` | the largest value of `T`, an untyped constant |

`MIN(U64)` is 0, `MAX(U64)` is 18446744073709551615, `MIN(I64)` is
-9223372036854775808, so the constants need the compiler's
`U64`-and-`I64` range, which constant folding already has. A name for
another type, an enumeration, a set or a real, is an error: an
enumeration has `LEN`-like answers of its own, and a real's limits
(an infinity, the largest finite) are a separate question. Two words
taken among the built-ins, which a program can't declare anyway.

Met in mosaico, rfuzz and raudio.

## `OFFSET(T, f)`, and `SIZE` of a field

**Status.** Approved by the owner on 2026-10-23, with the twelfth thaw. In the report, 2026-10.36 (4, 6.1 and 6.8), and in the compiler (2026-10-23).

A record handed to C by pointer must match C's struct byte for byte;
a field one word off is read wrong with no error. mosaico and rx11 test
their Xlib records against C's `offsetof` and `sizeof`, and today
measure an offset on a dummy variable, `INT(ADR(v.f)) - INT(ADR(v))`:
a run-time value, a variable declared for it, and pointer arithmetic
where the test means "where `f` is". rx11's `test/layout.sh` copies
each field's type out of the source text, since `SIZE` takes only a
type.

The proposal, two additions to the built-in procedures:

| Call | Result |
|---|---|
| `OFFSET(T, f)` | the byte offset of field `f` in the record type `T`, an untyped constant |
| `SIZE(T.f)` | the size of field `f` of the record type `T`, an untyped constant |

`f` is one field name; a path, `OFFSET(T, a.b)`, would be the sum of
two and is left out, and so is a variant, whose cases share their
place. `SIZE` still takes no
variable: `T.f` names a type's field, not storage, so `SIZE` stays a
question about types.

C has `offsetof`; Modula-2 and Oberon kept such things in `SYSTEM`,
and raz has no `SYSTEM`. It is constant folding of what the compiler
already knows, and it is also what a view through raw memory wants,
`mem[a + OFFSET(Hdr, len)].(U32)`, in place of a number, and what a
kernel's `code` procedures would want if their operands take constants.

Met in mosaico and rx11.

## The compiler on another host: `Host`, and what it asks of the library

**Status.** Built on the branch `moss-platform-boundary` (3eded0c),
which Moss pins: there raz compiles programs, rebuilds itself byte for
byte, and builds again after a restart (moss c606069,
`docs/native-raz.md`). Waiting for the owner's word on the questions
below before it is rebased and merged.

The host is the system the compiler runs on; the target, the system
its program will run on. Until the branch they were one, Linux, and
the compiler reached Linux outside `Sys`: `Parse.identity` read a
`struct stat` by `SYSCALL(4)` into a guessed `[18]INT`; `Raz` read
`ARGC()` and `ARGV()`, found the library through `/proc/self/exe`,
probed two loader paths for musl, and ran a program by `memfd_create`
and `execve`; `Elf` set mode 755. The branch does three things.

**1. A file's identity from `Sys.info`** (2644329). Its `dev` and
`ino`, so the parser makes no system call of its own. A plain fix:
merge it.

**2. A main file at the root, and a directory ending in `/`**
(3eded0c). `/Main.raz` has `/` as its directory, not `""`, and a
directory given as `lib/` doesn't make `lib//Sys.raz`. A plain fix:
merge it.

**3. `Host`, a module of what the compiler asks of its host**
(bb03e48): `argCount`, `arg`, `libraryDir`, `preferMusl`, `canRun`,
`canLinkC`, `writeExecutable`, `prepareRun`, `execute`. `src/Host.raz`
is Linux's; Moss stages the compiler's sources with its own
`Host.raz` (27 lines: the library at `/lib`, no run, no C, no mode
bits) and its own `Sys`, `Rt` and `Files`.

Questions before the merge:

**a. A smaller `Host`.** Two of its nine procedures are there only
because `Raz` reads the command line by built-ins:
- `argCount` and `arg` go if the library has the count beside
  `Files.arg`: a `Files.argCount()`, which Moss's `Files` gives from
  `Sys.argc`. `Files.arg` is already the library's, and Moss already
  replaces it.
- `preferMusl` and `canLinkC` are one question, which C library to
  link against: `Host.cLibrary(): CLib` with `CLib = (none, glibc,
  musl)`, or keep the two booleans.
- `canRun` goes if `prepareRun` is called while the command line is
  read, before any source, so that its error is the refusal.
That leaves `libraryDir`, `cLibrary`, `writeExecutable`, `prepareRun`
and `execute`: five procedures, each a real difference between hosts.

**b. How a host is chosen.** The branch stages: copy `src/`, put the
host's `Host.raz` in place of raz's, build. The main directory is
searched first, so `-I` alone can't replace it, which is right: a
module isn't silently replaced. The other way is a target name, as
`Sys.linux-x86_64.raz` is chosen today from fixed suffixes: a
`-os moss` that makes the suffixes `.moss-x86_64`, `.moss`, `.x86_64`,
`""`, so that `Host.moss.raz` and `Sys.moss.raz` are found beside the
generic files. That puts Moss's files in raz's tree, and raz would
then know of Moss. The proposal is to keep staging, raz knowing
nothing of any host but Linux, and to document it in
`doc/compiler.md` as the one way to build for another host.

**c. What the compiler asks of the library, written down.** Moss's
`Sys` has 23 exported procedures against Linux's 104, and is enough.
`doc/compiler.md` should list what the compiler and the modules it
imports (`Rt`, `Mem`, `Heap`, `Lock`, `Arena`, `Out`, `Fmt`, `Buf`,
`Str`, `Bytes`, `Files`) use of `Sys`, `Rt` and `Files`, as Moss's
`docs/raz-port.md` measured it, and a test should hold it: the
compiler built against a `Sys` with only those exports. Then a change
to the compiler that reaches for one more of `Sys` is seen in raz,
not in Moss's next build. The test host on the branch
(`test/host/Host.raz`) checks the `Host` side only.

**d. The stack.** A self-build passed in 64 KiB of stack on Linux,
but 64 nested parentheses don't, and Moss gives a stored program 1
MiB. That is "Implementation limits, and a compiler for a small
stack", above; the merge needn't wait for it.

**e. The tests in Python.** The branch adds `test/compiler-host.py`
(177 lines) and grows `test/library-path.py`, which came with
RAZ_PATH. raz's tests are otherwise `sh`, as a public project's
should be, needing nothing but a shell to run. The proposal is to
write both in `sh` before the merge.

**f. Before the merge, in any case.** The system call numbers in
`Host.raz` named as constants, as `Raz` had them (`MemfdCreate`,
`MfdCloexec`, `Execve`); a comment on every procedure; the new section
of `doc/compiler.md` made as short and plain as the rest; a rebase on
main (`doc/compiler.md` and `src/Raz.raz` conflict). Moss's
`RAZ_PORT.lock` then pins a commit on main.

## Constants built from constants

**Status.** Approved by the owner on 2026-10-23, with the twelfth thaw. In the report, 2026-10.36, and in the compiler (2026-10-23).

Three small changes to what a constant may be written with, and a defect. Each stands
alone; none changes what a program that compiles today means.

- **A named constant as an element.** `const Y: [2]R = [X, {a: 2}]`,
  with `X` a record constant, is "expected a literal of R", and so is
  `[X, [3, 4]]` with `X` an array constant, and `{a: X}` for an array
  field. A named integer is taken (`[N, 2]` compiles), and so is a
  named array constant for a slice part (`[R1, R2]` for a `[][]INT`).
  The report already allows it: the value is "a literal of constants",
  and its elements may be "arrays, records and variants of these". So
  this is a defect of the compiler, mended with no change to the
  report: where an array, record or variant is wanted, a constant of
  that type stands for its literal. Met in mgla.
  **Recommendation:** take, as a defect mended. Fixed in 065335a
  (2026-10-22).

- **A literal for a slice part.** `const T: [][]INT = [[1, 2], [3]]`
  is "a constant slice is a string, an array constant of its elements
  or []", and so is `{r: [1, 2]}` for a `[]INT` field. Each row must be
  named first, `R1: []INT = [1, 2];`, and the table written `[R1, R2]`,
  or the rows flattened into one slice walked by counts, as raudio's
  Sbr test does. The proposal, one clause of 4: where a slice part is
  wanted, an array literal of its element type makes an array constant
  of its own, with no name, as `[]` there makes the empty slice. `[]`
  stays the empty slice. Met in raudio.
  **Recommendation:** take, since the named rows say nothing the
  literal doesn't.

- **An `ERROR` constant named by another.**
  `const Short*: ERROR = PictBase.Short;` is "an error is made from a
  string", so an interface module can't pass on the errors of the
  modules under it, and its callers import a second module only to
  compare. The proposal, a sentence of 5.8: an `ERROR` constant whose
  value is another `ERROR` constant is that same error, not a new one,
  and `Short = PictBase.Short` holds. Only a string makes a new error,
  as now. Met in pict.
  **Recommendation:** take, since the alternative is a second import
  on every caller.

- **A comma after the last element.** `[a, b,]` is "expected an
  expression", so a table written one row a line, by hand or by a
  program, treats its last row apart, and adding a row changes two
  lines. The proposal, in the grammar:

      | "[" [ Expr { "," Expr } [ "," ] ] "]"
      | "{" [ Element { "," Element } [ "," ] ] "}"

  for array, record and set literals alike; not for calls, parameter
  lists or `match` labels. `Pretty` keeps the comma where a literal
  runs over lines and drops it where it fits on one. Met in rtui.
  **Recommendation:** take, since a generated table is the common case
  for literals this long.

## A record's procedure field that takes the record

**Status.** Proposed 2026-10-22, collated from RAZ-GAPS.md.

A record that carries its own callback can't give the callback the
record:

```
type Lines = record each: proc(var r: Lines; s: []U8); n: INT; end;
    (* "Lines isn't declared" *)
```

Only the base type of a pointer may name a type declared later (4), so
the callback takes `^Lines` and is called with `ADR(l)`, which by
`STANDARDS.md` says the callee keeps it, and it doesn't. Met in znaczy.

The proposal, a clause of 4: the type of a parameter or result of a
procedure type may also name a type declared later in the same `type`
section. A procedure value is an address whatever its signature, so
the record's size doesn't depend on it; a call through the field
comes after the section, when `Lines` is whole. Nothing that compiles
today changes. In the compiler, the pointer's forward reference
reused where a signature is read in a `type` section.

**Recommendation:** take, since the workaround puts a false `ADR` at
every call.

## A `match` arm names its case as everywhere else

**Status.** Approved by the owner on 2026-10-23, with the twelfth thaw. In the report, 2026-10.36, and in the compiler (2026-10-23).

An arm takes a case written alone, or with its type when the type is
the module's own (`| K.a:`). An imported case can't be written as
everywhere else outside its module:

```
import Xml;
...
if x.kind = Xml.done then ... end;     (* qualified here *)
match x.kind of
| Xml.done: ...                        (* "Xml isn't a case of Xml.Kind" *)
| Xml.Kind.text: ...                   (* the same *)
| done: ...                            (* taken: a name this module otherwise hasn't *)
```

The same holds for a variant's cases (`| Ev.circle(r):`). Met in
rslack, rxml and fraco.

This is the complement of "An enumeration's name read against the type
it is given to": an arm already reads a bare name against the matched
type. The proposal, a sentence of 7.4: an arm on an enumeration or a
variant names its case alone or as it is written anywhere else, with
its type, its module, or both (`done`, `Kind.done`, `Xml.done`,
`Xml.Kind.done`), and a qualified name must be a case of the matched
type. The bare form stays, so nothing breaks. A wrong qualified name
says so: "Ev.dot isn't a case of Xml.Kind".

**Recommendation:** take, since the natural spelling is refused with a
message that doesn't say what to write.

## Two warnings

**Status.** Approved by the owner on 2026-10-23 and implemented in `Parse` and `Scan`.

Compiler warnings, which are the implementation's own (10, appendix
A): no change to the report, and `-Werror` builds break only where the
text is in fact doubtful.

- **A relation of `BOOL`s beside `and` or `or`.** In raz the relations
  bind tighter than `and` and `or`, so
  `(b[i] = 0) # (i >= 2) and (i < 9)` is
  `((b[i] = 0) # (i >= 2)) and (i < 9)`. It was meant the Pascal way,
  and a test passed for the wrong reason. The warning: an `=` or `#`
  whose operands are `BOOL`s, written unparenthesised as an operand of
  `and` or `or`:

      a # b and c is (a # b) and c: put the # of two BOOLs in parentheses

  Comparing integers is untouched, so `i < n and a[i] # 0` stays
  quiet. Met in rcrypto.
  **Recommendation:** take, since the slip is silent and the fix is a
  pair of parentheses.

- **`\0` before a digit.** `"\01"` is a zero byte and `1`; a reader who
  knows C reads one octal byte. Moss's keyboard table,
  `"\0\01234567890-="`, cost a bug. The warning, in a string or a
  character where `\0` is followed by `0` to `7`:

      \0 is a zero byte and the digit after it is itself: write \x00 to keep them apart

  Met in moss (and dwa's tests have the same text, in a comment).
  **Recommendation:** take, as a few lines in `Scan` for a bug already
  paid for.

## A `BOOL` as an integer: `INT(b)`

**Status.** Approved by the owner on 2026-10-23, with the twelfth thaw. In the report, 2026-10.36 (6.7), and in the compiler (2026-10-23).

Moved here from the list of what to leave out, because three programs
met it and one of them for a reason an `if` can't serve. 6.7 says
there is no conversion between `BOOL` and integers, left out until
needed. Programs now write `8 + Ord(b)` as an `if` (raudio, surco's
Lyrcheck). Constant-time code needs a comparison as a mask with no
branch: rcrypto rebuilds each test from byte differences,
`INT((d - 1) shr 31)`, since an `if` would branch on a secret.

The proposal, one row of 6.7's table:

| From | To | Result |
|---|---|---|
| `BOOL` | integer | 0 for `false`, 1 for `true` |

`U64(a = b)` is 0 or 1, and `0 - U64(a = b)` the mask. Only this way:
no integer to `BOOL` (`x # 0` says it). In a constant it folds. The
compiler has the comparison's `setcc` already, so it is computed
without a branch; the report doesn't promise that (no word of it says
anything of time), but this compiler does it.

**Recommendation:** take, since Oberon has `ORD(b)` and a constant-time
mask has no other plain spelling.

## Counting bits: `CLZ`, `CTZ` and `POPCOUNT`

**Status.** Approved by the owner on 2026-10-22, with `MIN` and `MAX`. In the report, 2026-10.36, and in the compiler (2026-10-23).

raz has `ROL` and `ROR` (report 2026-10.35) but nothing that counts
bits, so programs loop. raudio's Rice decoder finds the one bit that
ends a unary code by shifting until it meets it (`Bitio.unary`); oku's
`Grid.count` asks `d in s` for each of nine digits to learn how many a
set holds. The library meets the same three times in `Bytes`: `highest`
is a loop, the lowest set byte is found by a multiply, and `count` sums
bits by a multiply, each with a paragraph to explain it. Oberon has
none of these; C compilers, Go (`math/bits`), Rust and Zig all do, as
one instruction each on every machine raz targets.

The proposal: three built-in procedures, beside `ROL` and `ROR` in 6.8.

| Call | Result |
|---|---|
| `CLZ(x)` | the number of zero bits above the highest one in `x`, an `INT`; the width of `x`'s type if `x` is 0; `x` of an unsigned integer type |
| `CTZ(x)` | the number of zero bits below the lowest one in `x`, an `INT`; the width of `x`'s type if `x` is 0; `x` as for `CLZ` |
| `POPCOUNT(x)` | the number of one bits in `x`, an `INT`; `x` of an unsigned integer type, or a set, whose members it counts |

The width is the type's, as for `ROL`: `CLZ(U8(1))` is 7, `CLZ(U64(1))`
is 63. Defining 0 rather than leaving it undefined, as C does, costs a
test where the machine's instruction doesn't give the width (x86-64's
baseline `bsr` and `bsf`); `lzcnt`, `tzcnt` and `popcnt`, which the
compiler's assembler already knows, are newer than the baseline, so
the compiler emits `bsr` or `bsf` with a test, and the multiply that
`Bytes` uses for `POPCOUNT`, unless the target says the instructions
are there. A set goes to `POPCOUNT` and not to `LEN`, which already
means a fixed number of elements and would read as the size of the
set's type.

Why three and not one: `CLZ` is what reads a code from the top bit
down (Rice, Golomb, UTF-8's lead byte, a log base 2), `CTZ` what walks
the members of a bit mask from the bottom, and `POPCOUNT` what counts.
Each can be written from another only in a way that needs a comment.
Three words among the built-ins, which a program can't declare anyway.
It breaks nothing.

Met in raudio, oku and the library's own `Bytes`.

**Recommendation:** take; three one-instruction built-ins replace loops
and multiplies that each need a paragraph.

## The bytes of a variable or a slice: `BYTES(x)`

**Status.** Approved by the owner on 2026-10-23, with the twelfth thaw. In the report, 2026-10.36 (6.8 and 7.3), and in the compiler (2026-10-23).

A view, `v.(T)`, reads one value from bytes, and can't be sliced,
since it has no address (6.9). So a program that has words and wants
their bytes takes an unchecked pointer: raudio writes a `[]I32` of
samples to a file through `p := ^U8(PTR(s))` and `p[0..LEN(s) * 4]`
(`Ao.bytesOf`); surco's Engcheck reads a file into a `[]I32` the same
way; rcrypto wipes each hash state through `p := ^U8(ADR(c));
RcBytes.wipe(p[0..SIZE(Ctx)])`, with a `p` that says nothing. "Selectors
after a `^T(e)` conversion" makes the last one expression,
`^U8(ADR(c))[0..SIZE(Ctx)]`, but it stays unchecked: the length is
written by hand and nothing ties it to `c`.

The proposal: one built-in procedure.

| Call | Result |
|---|---|
| `BYTES(x)` | the bytes of `x` as a `[]U8`: for a slice `s: []T`, its `LEN(s) * SIZE(T)` bytes; for a variable of any other type `T`, its `SIZE(T)` bytes |

```
n := Sys.write(fd, BYTES(samples));     (* samples: []I32 *)
n := Sys.read(fd, BYTES(words));        (* fills words: []I32 *)
RcBytes.wipe(BYTES(c));                 (* c: Ctx, all of it *)
```

`T` must be a type a view may take (6.9): integers, reals, pointers,
and records and arrays of these alone, the types for which any bytes
are a value. So writing through the slice can make nothing mean
nothing, which is why a `BOOL`, a set, an enumeration, a slice, a
variant or a procedure, or a record holding one, is an error. The
slice is checked as any slice is; its length comes from the type, not
from the program. A variable given to `BYTES` follows the rules for a
slice of it: a local's bytes can't be returned (7.3); a `const`
parameter, a view and a volatile variable are errors, as `ADR` of them
is; a string constant is an error, as writing its bytes isn't defined.
The bytes are in the target's order (appendix A), as a view's are.

It is `PTR` and `SIZE` made one checked expression, about 30 lines in
the compiler. It breaks nothing. With "Filling bytes: `Bytes.fill`", below, an array
of words is zeroed as `Bytes.fill(BYTES(a), 0)`.

Met in raudio, surco and rcrypto.

**Recommendation:** take; it replaces an unchecked pointer and a
hand-written length with one checked expression.

## Filling: `FILL(d, x)`

**Status.** Approved by the owner on 2026-10-23, with the twelfth thaw. In the report, 2026-10.36 (6.8), and in the compiler (2026-10-23): `rep stos` of the element's width, a loop of stores for a short run, or a record copied forward.

`COPY` copies and `NEW` zeroes, but nothing sets the elements of an
array or a slice already in hand. rttf clears each glyph's raster a
byte at a time (`clear`), its `Pgm` the same for an image, a
`Buf.spare` slice is cleared by a loop, and raudio zeroes a `[576]F32`
with a loop or a helper. Pascal has `FillChar`, C `memset`.

rat fills with a value that isn't zero, on its hottest path: each
pixel row of a cell's background is `U32` pixels of the cell's colour,
some 4 million pixels for a full redraw of a 3440 by 1440 window. The
loop for it was most of `Draw.paint`'s time, itself 81 per cent of
rat's on full redraws, as its counter had lost its register to
`paint`'s busier variables; moved into a procedure of its own it has
one, and rat's time on full redraws fell by 30 per cent. Even then a fill does better:
libc's `wmemset`, against the loop with its counter in a register,
fills runs of 10 `U32`s in 0.6 of the time, and of 4 million in a
third. A `Bytes.fill(s: []U8; b: U8)`, as this proposal first was,
can't serve it: a colour's four bytes differ.

The proposal: one built-in procedure, a statement, as `COPY` is.

| Call | Result |
|---|---|
| `FILL(d, x)` | sets every element of `d`, an array or a slice of elements of type `T`, to `x`, a value of `T` |

```
FILL(w^.band[row..row + w^.cellW], U32(l.bg));    (* a row of pixels *)
FILL(window, 0.0);                                (* window: [576]F32 *)
FILL(raster, 0);                                  (* raster: []U8 *)
```

`d` is written as `COPY`'s destination is, and `x` is assigned to each
element as by `:=`. An element of one, two, four or eight bytes is
stored with `rep stos` of that width, or with moves when there are
few, as `zeroBytes` does; any other is stored once and copied forward
from there. A zero of any type is `rep stosb`, as `NEW`'s zeroing is.

It breaks nothing, and leaves `Bytes.fill` out: a slice of bytes is
filled as any other. It is not a wipe: an optimizer may leave out a
fill that nothing reads after, as it may any write (7.6). Its size in
the compiler is not yet measured.

Met in rttf, raudio and rat.

**Recommendation:** take; one statement for a loop every buffer-handling
program writes, as fast as the machine fills, for any element type.

## `COPY` forwards unless it must go back

**Status.** Approved by the owner on 2026-10-23 and implemented in `Gen.copySlice`: backwards only when the destination starts inside the source, and then by words; up copies 8 to 25 times faster.

`COPY` is right when its two sides overlap (6.8), and the compiler
makes it so by copying backwards whenever the destination is above
the source (`Gen.copySlice`): `std`, `rep movsb` down from the last
byte, `cld`. That is right, but it goes backwards for every copy to a
higher address, overlapping or not, and a backward `rep movsb` gets
none of the processor's fast copying: it moves a byte at a time. Ten
million copies between the two halves of one `[4096]U32`, never
overlapping:

| Elements | Down | Up |
|---|---|---|
| 10 `U32`s | 66 ms | 510 ms |
| 1000 `U32`s | 390 ms | 9,800 ms |

rat meets it drawing a scaled font: each pixel row of a cell is copied
to the rows under it, a higher address in the same image, for every
cell drawn.

The proposal, the compiler's alone, as the report already says what
`COPY` does: copy backwards only when the destination starts inside
the source (`rsi < rdi < rsi + rcx`, one more comparison), and
forwards otherwise. A backward copy that must be made could go by
words, eight bytes at a time down to the last few, rather than by
`rep movsb`.

It breaks nothing: no program can tell, but by its time.

Met in rat.

**Recommendation:** take; one comparison in `copySlice` for a copy up
to eight times faster at ten elements and twenty-five at a thousand.

## A slice of a `const` parameter, returned

**Status.** Approved by the owner on 2026-10-23, with the twelfth thaw. In the report, 2026-10.36 (7.3), which the compiler already did; a conformance test holds it.

7.3 says a slice of a `var` parameter, of a module variable, or of
what a pointer points at may be returned, and says nothing of a
`const` one. rimap's `proc sectionOf(const p: Part): []U8; begin
return p.section[0..p.sectionLen]; end;` compiles and works, but the
report doesn't promise it, so rimap leaves its callers to slice the
field themselves.

A `const` parameter is the caller's variable read in place (8), as a
`var` one is, so its slice is the caller's, not this procedure's
frame. When the argument isn't a variable it is a temporary of the
caller's statement, and a slice of it kept past that statement is
already the exception of section 10. The rule only has to say so.

The proposal, 7.3's sentence:

> A slice of a `var` or `const` parameter, of a module variable, or of
> what a pointer points at may be returned: none of them is this
> procedure's frame. For a `const` parameter given a temporary, the
> slice lives to the end of the caller's statement (section 8).

Only the report changes; the compiler already accepts it. It breaks
nothing. Whether the caller may write through the slice it gets back
is the question of "A slice that can't be written: `[]const T`", which
this doesn't settle.

Met in rimap.

**Recommendation:** take; a sentence promises what the compiler already
does.

## What wiping can't reach, said in appendix A

**Status.** Approved by the owner on 2026-10-23, with the twelfth thaw. In the report, 2026-10.36 (appendix A); no code.

A wipe through `^VOLATILE U8` is never left out (7.6), but it writes
only what the program can name. A spilled register, a statement's
temporary, a value parameter's copy and an array a call returned are
the compiler's, and stay in memory after the procedure returns, until
something else writes there. rcrypto found that its wipes can't reach
them, and nothing in the report says they exist. C has the same limit
and says nothing either; OpenSSL's `OPENSSL_cleanse`, which rnet's
`Tls.wipe` calls, wipes only what it is given.

The proposal: a paragraph in appendix A, among what an implementation
says of itself, and no feature.

> **Copies.** A procedure's frame may hold copies of its variables
> that the program can't name: registers saved to it, temporaries of
> its statements, its value parameters, and arrays its calls return.
> This implementation leaves them where they are when the procedure
> returns; they last until the stack is used again. A wipe (7.6)
> reaches only the variables it is given. A secret is best kept in
> one variable, passed by `var` or `const` or by pointer, never by
> value, and wiped there.

Zeroing a frame on return, by a word on the procedure or a flag, was
weighed and left: it costs every call of such a procedure a write of
its frame, and still misses registers and the kernel's copies of a
thread's state. It breaks nothing.

Met in rcrypto.

**Recommendation:** take; a paragraph says a limit every program that
wipes must know.

## Sys for files and memory

**Status.** Approved by the owner on 2026-10-23 and implemented in both backends, all items: `mapRead`, `protect`, and `open`, `openMode`, `openRead`, `create` and `openDir` closing on exec, with `keepOnExec(fd, true)` to keep one.

Library growth, but the last item changes what `open` does, so it
needs the owner's word on whether that counts as breaking. Each item
stands alone; each is in both `Sys.raz` (the C library) and
`Sys.linux-x86_64.raz` (system calls).

- **A file mapped to be read.** `mapFile` maps to read and write,
  shared, so a file opened only to read (a dictionary that isn't the
  user's to write) can't be mapped: `mmap` fails with EACCES. znaczy
  makes the system call itself in a `Zmap.linux.raz` (30 lines), and
  raudio's Inmem does the same.

      (* The first size bytes of the file fd, which may be open only to
         read, mapped to be read only: writing there stops the program.
         nil if it can't be; munmap gives them back. *)
      proc mapRead*(fd, size: INT): ^U8;

  C's `mmap` with `PROT_READ` and `MAP_PRIVATE`; system call 9 with
  the same. Met in znaczy, raudio. **Recommendation:** take, two
  programs carry a Linux-only file for it.

- **Memory that can't be touched.** A test that puts its input against
  a guard page, so that a read one byte out of range stops it, calls
  `SYSCALL(10, ...)` itself and is tied to Linux; raudio's Inmem grows
  a large mapping readable a step at a time, so that the bytes never
  move.

      (* Lets the pages from p, size bytes from a page boundary, be read
         and written as read and write say; neither, and touching them
         stops the program. 0, or minus an errno. *)
      proc protect*(p: ^U8; size: INT; read, write: BOOL): INT;

  C's `mprotect`; system call 10. With `mmap` it serves raudio's
  reserve too: map the most it will hold, `protect` it all to neither,
  and open it as it fills. Met in rttf, raudio. **Recommendation:**
  take, the one portable way to a guard page.

- **Files closed in a program exec starts.** `pipe`, sockets and
  `memFile` are closed across `exec`; a file `open` gives is not, so a
  fifo mosaico holds reaches every program it starts, unasked, and it
  calls `keepOnExec(fd, false)` after each open. `openMode`, `open`,
  `openRead` and `create` would pass `O_CLOEXEC`, and their comments
  say "closed in a program exec starts" as `pipe`'s does;
  `keepOnExec(fd, true)` keeps one open. `spawn`'s `fds` are unchanged,
  since `dup2` in the child clears the flag. This makes the
  `closeOnExec` access in "Sys for a server" unneeded (`nonblocking`
  stays). A program that hands an opened file to an exec'd one by its
  number, without `fds`, must then say `keepOnExec`. Met in mosaico.
  **Recommendation:** take, one rule for every descriptor Sys makes.

## Files: what programs write over Sys

**Status.** Approved by the owner on 2026-10-22 and implemented in `lib/Files.raz`, all three; `Files.write` is written over `writeAll`.

Library growth that breaks no program. Each is portable, written in
`Files.raz` over procedures `Sys` already has, so neither backend nor
Moss's `Sys` grows.

- **Writing all of it.** A `write` may be short (a pipe, a socket) or
  broken by a signal, and each program carries its loop; `Files.write`
  has one, but only for a whole file it creates.

      (* Writes all of s to fd, again after a short write or a signal:
         0, or minus the errno of the write that failed. *)
      proc writeAll*(fd: INT; s: []U8): INT;

  `Files.write` is then written over it. Met in surco (Sjournal), and
  the loop is in most programs that write to a pipe.
  **Recommendation:** take, the loop every writer to a pipe needs.

- **A path made absolute and plain.** surco makes `-r` and a playlist
  absolute with an `extern` to C's `realpath(3)`; dwa's
  `Docs.canonical` does `setWorkDir`, `workDir` and `setWorkDir` back,
  which is wrong with threads.

      (* Adds to b the absolute path of the file at path, with no ".",
         "..", or symbolic link in it: 0, or minus an errno (-2, ENOENT,
         if a part of it isn't there). *)
      proc realPath*(path: []U8; var b: Buf.Buf): INT;

  About 40 lines over `workDir`, `linkInfo` and `readLink`, with a
  bound on links followed (-40, ELOOP). Met in surco, dwa.
  **Recommendation:** take, two programs and the workaround is wrong.

- **Removing a tree.** A sauce clone cut short leaves
  `<dir>.sauce-clone`, since removing a tree is a walk of `openDir`,
  `remove` and `removeDir`; a test that makes a directory to work in
  has the same walk to clean up.

      (* Removes the file at path and, if it is a directory, all within
         it, without following a symbolic link: 0, or minus the first
         errno. *)
      proc removeTree*(path: []U8): INT;

  Over `openDir`, `entryKind`, `linkInfo`, `remove` and `removeDir`,
  about 30 lines. Met in sauce. **Recommendation:** take, easy to get
  wrong (a link to a directory followed) and wanted by every test with
  a scratch directory.

## Sys for signals and the process

**Status.** Approved by the owner on 2026-10-23 and implemented in both `Sys` backends and `Rt`, all four: `ignored`, `findEnv` (which `env` is written over), `processors` and `Rt.exitStatus`.

Library growth that breaks no program. The first three are in both
`Sys` backends; the last is in `Rt`.

- **Whether a signal is ignored.** A program started in the
  background or under `nohup` starts with some signals ignored, and
  should leave those alone, as a shell does, rather than `handle` or
  `catch` them. `handle` and `ignore` don't say what was there, so
  robbie asks the kernel through `rt_sigaction` in an `Rsig.linux.raz`.

      (* Whether the signal sig does nothing now, as ignore(sig, true)
         or the program that started this one left it. *)
      proc ignored*(sig: INT): BOOL;

  C's `sigaction` with no new action; system call 13 the same.
  Independent of `keepIgnored` in "Sys for running a program", which is
  about the child. Met in robbie. **Recommendation:** take, any
  program that takes SIGINT or SIGHUP should ask it first.

- **An environment variable unset or empty.** `env` gives `""` for
  both, but `TZ` unset means `/etc/localtime` and `TZ=` means UTC, so
  alba and rzone walk `envAt` themselves.

      (* The value of the environment variable name and true, or "" and
         false if it isn't set. *)
      proc findEnv*(name: []U8): ([]U8, BOOL);

  `env` stays, written over it. Met in alba, rzone, surco.
  **Recommendation:** take, three programs walk `envAt` for it.

- **How many processors.** `raztest -j` would default to it, as
  `make -j$(nproc)` does, and defaults to 1; rayo makes
  `SYSCALL(204)` itself.

      (* The number of processors this program may run on, at least 1. *)
      proc processors*: INT;

  C's `sched_getaffinity` and `CPU_COUNT`; system call 204, counting
  the bits. Moss's gives 1. Met in raztest, rayo.
  **Recommendation:** take, two programs and no portable way without it.

- **How the program ends, for `atExit`.** A procedure `Rt.atExit`
  registered can't tell an end by `exit(0)` from a failed check or
  `Rt.stop`, so surco's log can't note a crash.

      (* The status exit was given, while the procedures atExit
         registered run; 0 before. *)
      proc exitStatus*: INT;

  `Rt.exit` sets it before running them. A failed check and `stop`
  both end with 2, which is enough to note a crash. Met in surco.
  **Recommendation:** take, three lines and nothing else can say it.

## Numbers in the library

**Status.** Approved in part by the owner (2026-10-22 and 23) and implemented: `Str.toU64`, `Math.tanh`, `Math.roundEven`, `Fmt.short` and `Fmt` writing `E`. `ABS`, `min`, `max` and `clamp` wait.

### An unsigned decimal reader: `Str.toU64`

Library growth that breaks no program. `Str.toInt` stops at the largest
`I64`, so a `U64` written by `Fmt.uint`, such as a `Rand.seed` read back
from `$PROP_SEED`, needs a loop of its own (raz's own `Prop.decimal`).
`toHex` already gives a `U64`; decimal should too:

    (* s as a decimal number, digits only; false if it isn't one, or a
       U64 can't hold it. *)
    proc toU64*(s: []U8): (U64, BOOL);

No sign: a `-` is no `U64`, and a `+` nobody writes. `Opt.number`
stays on `toInt`.

Met in raz's `Prop`.

**Recommendation:** take; it is the reader for what `Fmt.uint` writes.

### `ABS`, and `min`, `max` and `clamp` of integers

**Status.** `ABS` approved by the owner on 2026-10-23, with the twelfth thaw, and in the report, 2026-10.36 (6.1 and 6.8); the compiler waits for the owner's review of that text. `min`, `max` and `clamp` dropped (owner, 2026-10-23): a two-line `if` each.

Library and language growth that breaks no program. `Math` is `F64`
only and there are no built-ins, so rat writes `min` and `max` in Draw,
Font, Layout and Shapes, `abs` in Shapes and `clamp` in Rat; raudio's
Tags and rabble's Remote the same; mgla and fraco each write a 4-line
`abs` of an `F64`.

The proposal, in two parts. A built-in, as Oberon has it, for every
numeric type, since one name serves integers and reals and no
procedure can:

| Call | Result |
|---|---|
| `ABS(x)` | `x` without its sign, of `x`'s type; for an integer, `-x` if `x < 0`, so the smallest `I64` gives itself, as `-x` does |

And three procedures in `Math`, of `INT`, the type that indexes and
counts:

    (* The smaller of a and b. *)
    proc min*(a, b: INT): INT;
    (* The larger of a and b. *)
    proc max*(a, b: INT): INT;
    (* x, or lo if it is below lo, or hi if it is above hi. *)
    proc clamp*(x, lo, hi: INT): INT;

`MIN` and `MAX` are taken for a type's limits ("The limits of an
integer type"), so these are lower-case procedures, not built-ins.
`Math`'s opening line then says "and `min`, `max` and `clamp` of
`INT`". Left out: the same of `F64`, which no program asked for.

Open: `ABS` touches the report (6.8's table), so it may move to
the language proposals, beside `MIN(T)` and `MAX(T)`.

Met in rat, raudio, rabble, mgla, fraco.

**Recommendation:** take; five programs write the same four lines.

### `Math.tanh`

Library growth that breaks no program. `Math`'s header leaves the
hyperbolic functions out "until a program needs them"; mgla soft-clips
its mix with tanh, written `1 - 2/(exp(2x)+1)`, which loses every digit
near 0.

    (* The hyperbolic tangent of x, from -1 to 1. *)
    proc tanh*(x: F64): F64;

fdlibm's, over a private `expm1` (which `Math.pow` and `exp` already
come close to). `sinh` and `cosh` stay left out, as the header says,
until a program needs them.

Met in mgla.

**Recommendation:** take; the header's own rule says when, and mgla is it.

### Rounding a half to even: `Math.roundEven`

Library growth that breaks no program. `Math.round` takes a half away
from 0, as C's `round` does: `round(2.5)` is 3.0. Pascal's `Round`, and
IEEE 754's default, take it to the even one, 2.0, and a program that
must give Pascal's numbers (alba's, raudio's `Sbr`) writes its own,
where the case of `x + 0.5` rounding up is easy to get wrong.

    (* The whole number nearest x; a half to the even one, as IEEE 754's
       default and Pascal's Round have it. *)
    proc roundEven*(x: F64): F64;

Met in alba and raudio.

**Recommendation:** take; two programs, and the edge cases are subtle.

### The fewest digits that read back: `Fmt.short`

Library growth that breaks no program. `Fmt.real(x, places)` writes a
fixed number of places; nothing writes a real as briefly as it can be
written and still read back as itself. arkusz carries 150 lines for it
(`Afmt`: base-10^9 big numbers, and the halves to the neighbouring
`F64`s); fraco writes its own decimals for a deep zoom's centre, which
needs up to 17 places; alba prints coordinates.

A case of `Arg`:

    (* r in the fewest digits that Math.toReal reads back as r; with an
       exponent below 1E-4 and from 1E15 on, as real writes one. *)
    short(r: F64);

The result is unique (Steele and White; Ryu's answer). It costs a
correctly rounded conversion, so about arkusz's 150 lines, moved into
`Fmt`; `Fmt.real` keeps its own fast path.

Left out: arkusz's exact 17-digit expansion (`sci(x, digits)`), which
`short` makes unneeded for the round trip, and rounding the 17-digit
text again as Pascal's `Str` does, which gives `45.1603` for
`Fmt.real(45.16025, 4)` where the binary value, below the half, gives
`45.1602`: that is Pascal's double rounding, not a fault in `Fmt`.

Met in alba, arkusz and fraco.

**Recommendation:** take; three programs, and the hard part is the
library's to do once.

### One exponent letter: `Fmt` writes `E`

**Status.** Approved by the owner on 2026-10-22 and implemented in `lib/Fmt.raz`.

A change to output. `Fmt.real` writes `1.50e17`; the language reads a
real's exponent as `E` only (report section 2), so a value a program
prints can't be pasted into code (rayo). `Math.toReal` reads both.

The proposal: `Fmt` writes `E`, as the report's own numbers are
written, `1.50E17`. Reading `e` in the compiler instead would add a
spelling to the report. A test that compares printed exponents changes
by one letter; raz's own `Fmt` test is one.

This settles the open question in "A width in `Fmt`".

Met in rayo.

**Recommendation:** take; one letter for the language and its library.

## Memory, Buf and Vec

**Status.** Proposed 2026-10-22, collated from RAZ-GAPS.md.

### An allocator that stops when memory runs out: `Heap.sure`

**Status.** Approved by the owner on 2026-10-22 and implemented in `lib/Heap.raz`.

Library growth that breaks no program. `Buf` and `Vec` stop the program
when the allocator has no room; `NEW(p, Heap.heap)` and `Mem.alloc`
give `nil`, so rat checks and stops in about a dozen places. A
procedure that allocates or stops can't be written for every `T`, but
an allocator can, and `NEW` is already generic:

    (* The heap, but running out of memory stops the program, as
       Buf.add does, instead of giving nil: for NEW where nil would be
       a bug nobody checks for. *)
    sure*: ^Mem.Allocator;

`NEW(p, Heap.sure)` then gives a `p` or stops, with `Rt.trace`. Its
`free` is the heap's. Ten lines, and nothing new to learn.

Met in rat.

**Recommendation:** take; one variable makes every `NEW` safe without a
check at each.

### Freeing back to a mark: `Arena.mark` and `Arena.release`

**Status.** Approved by the owner on 2026-10-23 and implemented in `lib/Arena.raz`.

Library growth that breaks no program. `Arena` frees only everything at
once, so fdn's recursive walk, which makes a few strings per entry,
gives each back to the heap by hand. An arena that goes back to where
it stood gives one line per level:

    (* Where ar stands now, for release. *)
    proc mark*(const ar: Arena): INT;

    (* Everything allocated from ar since mark m freed at once; a mark
       past where it stands stops the program. *)
    proc release*(var ar: Arena; m: INT);

A mark is the arena's `used`, so each is a line. `reset` is
`release(ar, 0)`, and stays for its name.

Met in fdn.

**Recommendation:** take; two lines in `Arena` replace a free per string.

### Inserting and removing in the middle of a `Vec`

**Status.** Approved by the owner on 2026-10-23 and implemented in `lib/Vec.raz`.

Library growth that breaks no program. dwa's edit takes lines out and
puts others in by resizing around a `COPY` by hand, twice, where the
overlapping copy's direction is the thing to get wrong.

    (* n zero elements opened at i, those from i on moved up; i from 0
       to v.len. Stops the program, as push does, if there is no room. *)
    proc insert*(var v: Vec; i, n: INT);

    (* The n elements from i taken out, those after them moved down;
       i + n at most v.len. *)
    proc remove*(var v: Vec; i, n: INT);

`insert` gives zeros, as `add` and `resize` do, for the caller to fill
in `all(v)[i..i + n]`. Left out: a `tryInsert`, until a program wants
one.

Met in dwa; any editor's lines, and a list kept in order, want it.

**Recommendation:** take; it is the one `Vec` operation that is easy to
get wrong by hand.

## Strings, base64 and text for C

**Status.** Approved by the owner on 2026-10-23 and implemented in `lib/Str.raz` and `lib/Fmt.raz`: `fromC`, `toC`, `base64With` and `unbase64With` with `Base64` and `Base64Url`, and `Fmt.into`.

### A slice of a C string, and a C string of a slice

Library growth that breaks no program. C gives a `^U8` ending in a zero
byte (an X resource's value, a class hint's name), which awizo counts
by hand to make a `[]U8`. The other way, a path for C's `open` or
`realpath` must be followed by a zero, which callers copy into a
`[PathMax + 1]U8` by hand.

    (* The bytes at p up to its zero byte, not copied; "" for nil. *)
    proc fromC*(p: ^U8): []U8;

    (* s copied into out with a zero byte after it, for C: out holds
       LEN(s) + 1 bytes at least. *)
    proc toC*(s, out: []U8): ^U8;

`toC` gives `PTR(out)`, so the call reads as what C is given:
`C.realpath(Str.toC(path, room), ...)`. `out` too short stops the
program, as a slice does. Left out: a `CStr` type, which would say in
a signature that a zero follows; that is a language question, and
`Sys` takes `[]U8` already.

Met in awizo and surco; every binding to a C library meets both.

**Recommendation:** take; the two ends of every C call that takes or
gives text.

### Base64 in another alphabet, unpadded

Library growth that breaks no program. `Str.base64` has RFC 4648's
section 4 alphabet, padded. Section 5's, `-` and `_` and no padding, is
PKCE's and JWTs', and IMAP's modified UTF-7 is `,` for `/`, unpadded:
roauth carries 13 lines over `Str.base64`, rimap 40 of hand-packed
6-bit letters. "Base64 in `Str`" left this out until a program needed
it; two do.

    const
        (* The alphabets of RFC 4648, sections 4 and 5. *)
        Base64* = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        Base64Url* = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    (* s in base64 with the 64 letters of alphabet into out, which
       holds base64Size(LEN(s)) bytes at least, padded with = if pad:
       the bytes written. *)
    proc base64With*(s, out, alphabet: []U8; pad: BOOL): INT;

    (* s decoded as base64With wrote it, into out, which holds
       (LEN(s) + 3) div 4 * 3 bytes at least: the bytes written; false
       as unbase64 says, or, without pad, for a length that leaves one
       letter over. *)
    proc unbase64With*(s, out, alphabet: []U8; pad: BOOL): (INT, BOOL);

`base64` and `unbase64` become `base64With(s, out, Str.Base64, true)`
and stay, for the common case. rimap passes its own alphabet.

Met in roauth and rimap.

**Recommendation:** take; two programs, and the existing proposal named
this as the way to grow.

### Formatting into a caller's slice: `Fmt.into`

Library growth that breaks no program. `Fmt.write` goes only to a
`Buf`, which needs an allocator, so a library with no heap (rxml, for
"... on line 12"; rttf and magma are the same kind) joins pieces by
hand with `Str.fromInt`. `Buf` says the core has no heap to assume;
`Fmt` should then work without one.

    (* f formatted into out as write formats it: the bytes written, and
       false if out was too short and the text is cut there. *)
    proc into*(out: []U8; f: []U8; args: []Arg): (INT, BOOL);

Cut short, not stopped: the length of formatted text isn't known
before, as base64's is. Inside, `put` writes to a target that is a
`Buf`, a slice, or standard output, in place of today's `^Buf.Buf` or
`nil`.

Met in rxml.

**Recommendation:** take; it makes `Fmt` usable in the no-heap core
`Buf` itself is written for.

## `Opt`

**Status.** Approved by the owner on 2026-10-23 and implemented in `lib/Opt.raz`, both.

### A negative number as an operand

A change to what `Opt` reads, for scopes it can't hurt. `alba -33.87
151.21` is "unknown option -3", and `--` changes the command line the
user types, so alba reads its arguments by hand and loses `Opt`'s help
and mistakes.

The proposal: in a scope with no option whose letter is a digit, a
word of a `-` and then a digit is an operand, and so ends the options
as any operand does. A scope that gives a digit a letter (`head -5`
style) reads it as today. No new procedure; the library volume's list
of rules gains a line.

Met in alba.

**Recommendation:** take; one rule, no interface, and it lets a numeric
program keep `Opt`.

### A mistake in the operands, with the synopsis: `Opt.misuse`

Library growth that breaks no program. `Opt.fail` writes the program's
sentence alone, for "no command; see keep -h". The one that adds the
synopsis lines, as `Opt`'s own mistakes and `refuse` do, is the private
`mistake`, so raztest's "no tests named", a mistake in the operands,
comes without the usage a user needs.

    (* The program's own mistake, written as Opt's are, with the
       scope's synopsis lines after it, and status 2. *)
    proc misuse*(const p: Parser; text: []U8);

It is `mistake` with `text` as its one argument. A flag on `fail`
would read worse at the call.

Met in raztest.

**Recommendation:** take; three lines, and no workaround without
copying the table's synopsis by hand.

## A freestanding program, stated

**Status.** Proposed 2026-10-22, collated from RAZ-GAPS.md.

"For a kernel: three changes to the compiler" made a raz program run on
the bare machine; Moss, a kernel in raz, now boots on it. What it found
is less a missing feature than missing words: what a `-bare` program
must give the compiler, and what it may count on, are known only by
reading `Gen.entryPoint` and `Raz`. Five items, each standing alone.
The sixth thing Moss met, `jmp rax` read as a jump to a label, was a
bug, fixed in ac3c464.

**1. The runtime ABI, written down.** A section of `doc/compiler.md`,
"A program with its own `Rt`", saying what the compiler asks of `Rt`
and what a program's start may count on:
- **Required:** `proc exit*(status: INT);`, which never returns (the
  compiler puts `ud2` after its call), and
  `proc fail*(what, a, b, len: INT; at: UINT; name: ^U8; rdi, rsi: UINT);`,
  with the kinds of `what` as `lib/Rt.raz` gives them (0 an index, 1 a
  slice, 2 an enumeration, 3 a backward slice of a pointer, 4 a nil
  pointer, 5 a division by zero, 6 a stack overflow, 7 a view), named
  constants in the text, not bare numbers.
- **Optional, found by name when declared:** `places`, `calls`,
  `teller`, `place`, `placer` (item 5), `startProfile` and `profiler`
  (never under `-bare`), `cExit` (only with C, which `-bare` refuses).
- **The entry:** `_start` runs every used module's body but `Rt`'s,
  then `main`. Under `-bare` it reads nothing from the stack and aligns
  nothing: the loader or boot stub enters it with the bss zeroed and
  `rsp` a multiple of 16, as Linux does.
- **`main` returning:** allowed. `Rt.exit` is then called with `main`'s
  result, or 0 for `proc main*`.
- **The panic hook:** `Rt.fail` is it. A kernel's `fail` prints and
  halts; nothing else is needed, and no second hook is proposed.

A test holds it: `test/run/` builds a `-bare` program against a
smallest `Rt` of `exit` and `fail` alone, run under Linux, whose
`exit` and `fail` make the system call themselves.

Met in Moss (`docs/raz-findings.md` §2), which copied the stock
signatures.

**Recommendation:** take; it is words and one test, and the contract
already exists.

**2. A recipe for an interrupt's entry.** Before any attribute or
generated stub, a tested recipe in `doc/compiler.md`, beside item 1,
stating what the compiler's code may assume and so what a stub must
restore:
- **What the compiler's code uses:** System V's caller-saved
  registers, `rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8` to `r11`, all of
  `xmm0` to `xmm15`, and the flags; the direction flag is clear at
  every call (the compiler's copies use `std` and `cld` and leave it
  clear).
- **The red zone:** whether the compiler ever writes below `rsp`. Not
  checked today ("For a kernel" leaves it open); it is to be checked
  and the answer written down. If it never does, an interrupt needs no
  IST stack for that reason.
- **The stub:** a `code` procedure per vector that pushes 0 where the
  CPU pushes no error code, pushes the vector, saves the caller-saved
  registers, aligns `rsp` to 16, saves the SSE state (`fxsave` or
  `xsave` to an aligned area), `cld`, calls an ordinary procedure
  `proc handle(vector, code: INT; frame: ^Frame)`, restores, drops the
  two words and `iretq`.

It is testable on Linux: `iretq` from ring 3 to ring 3 is allowed, so
`test/run/Interrupt.raz` builds a frame by hand, jumps to the stub, has
the handler compute with reals, and checks on return that every
register the stub promised to keep is kept. The stub needs items 3 and
"The assembler's instructions", 1 (`push` of a constant, `cld`).

Met in Moss (`docs/raz-findings.md` §4): its handlers use only `rax`
and make no call, which is safe but no recipe.

**Recommendation:** take; a kernel's first stub is where the calling
convention is easiest to get wrong, and a test on Linux keeps it right.

**3. A code procedure names a procedure or a global.** In a code
procedure, a name of the module's scope, or a qualified one, that is a
procedure or a global variable stands for its address, as an operand
of three forms only:

    call fault;              (* a procedure, rip-relative *)
    jmp fault;
    lea rax, [ticks];        (* a procedure or a global *)

Each makes a reference to that chunk, so the linker keeps what is
named, as any call does. No other operand takes a name, and no type is
checked: a code procedure is the target's, and its author already
answers for the convention. The assembler gets the names as it gets
constants, by a function the parser hands in beside `ConstFn`.

Moss stores `UINT(fault)` in a slot at start and calls through a
register (`docs/raz-findings.md` §5), so the slot must be filled
before the first fault, which nothing checks.

**Recommendation:** take; three operand forms remove a hand-off that
can be forgotten, and the recipe in item 2 needs `call handle`.

**4. A program brings its own `Rt`.** A `src/Rt.raz` beside the main
module meets `lib/Rt.raz`, and "a program has one module of each name"
refuses it, rightly. Moss copies the compiler beside an empty `lib/`.
Two ways out:
- **Staging,** as "The compiler on another host" proposes for the
  compiler's own sources: copy `raz` beside a library of the program's
  own. Nothing in raz changes; only words in `doc/compiler.md`. Every
  freestanding project then carries a copied compiler, and its library
  is all or nothing.
- **`raz -lib DIR`:** the library is `DIR`, not the one beside the
  compiler. A kernel's `-lib` is a directory holding its own `Rt` and
  `Sys` and, by symbolic links, whichever of raz's modules it takes
  (`Str`, `Fmt`, `Buf`). The duplicate check stays as it is. On the
  `Host` branch it is one line over `Host.libraryDir`; today a few
  lines in `Raz.raz` and raz(1).

The option is the smaller for its users and nearly as small in raz;
staging stays the way for the compiler on another host, where the
whole of `src/` is replaced anyway.

**Recommendation:** take `-lib`; a few lines save every freestanding
program a copy of the compiler.

**5. Symbols without `Rt`'s places.** Without `-s` the compiler links
`places`, `calls`, `teller`, `place` and `placer` and stops with "Rt
has no places" where `Rt` lacks one, and `-noprofile` doesn't help, so
Moss builds with `-s` and loses the symbol table a debugger reads.
Two things are tied that needn't be: the ELF's symbols and lines, for
a debugger, and the places, for `Rt` to say where a check failed.
The change: each of the five is linked only when `Rt` declares it,
`calls` with `teller` and `place` with `placer`, a pair or neither; `-s`
still strips both. A kernel then keeps its symbols for GDB and gives
`fail` the raw address, or declares `places` and decodes them itself.

A hosted program's `Rt` is raz's, which declares all five, so no
program changes. One that writes its own `Rt` and misspells `places`
loses its places silently; item 1 lists the names.

Met in Moss (`docs/raz-findings.md` §3).

**Recommendation:** take; it is a test on each name in `Raz.raz` and
gives a kernel its symbols back.

## The assembler's instructions

**Status.** Proposed 2026-10-22, collated from RAZ-GAPS.md.

The report leaves which instructions the assembler knows to the
implementation, and `db` gives any other. That stays. What is missing
is a rule for when an instruction joins, and the few that programs
have already written in `db`.

**1. `push` of a constant, and `cld` and `std`.** `push imm8` and
`push imm32` (6A, 68, sign-extended to 64 bits), and `cld` and `std`
in `Plain`. The encoder already writes `cld` and `std` for the
compiler's copies; only the assembler's table lacks them. Moss's
exception stubs write all three with `db`, and every stub of
"A freestanding program, stated", 2, needs them.

**Recommendation:** take; three entries the encoder half has, and an
interrupt stub can't be written without them.

**2. When an instruction joins, and the SHA and shuffle ones now.**
The rule, in `doc/compiler.md` beside the assembler: an instruction
joins when a program writes it in `db`, it is a family's member the
tables already hold (a code in `PackedOps`, an entry in `Plain`), and
its bytes are checked against GNU `as` in `test/run/`, as
`AsmKernel.raz` does. Anything else stays `db`, which is the permanent
answer for an instruction no program uses twice. By that rule, now:
- `paddd`, `punpcklqdq`, `punpckhqdq` into `PackedOps` (66 0F FE, 6C,
  6D);
- `pshufb` (66 0F 38 00) and `palignr` (66 0F 3A 0F, with a byte),
  two more forms, three-byte opcodes;
- `sha256rnds2` (0F 38 CB, `xmm0` implied), `sha256msg1` (0F 38 CC),
  `sha256msg2` (0F 38 CD).

Sauce's SHA-NI hash is 123 `db` lines assembled by GNU `as`, nothing
checking a byte against its mnemonic; with these it is read as written.
AES-NI, `pclmulqdq`, AVX and the rest wait for a program. (`movd` and
`movq`, `pxor`, `pshufd`, `movdqu`, `movdqa`, `pmovmskb` are there
already.)

**Recommendation:** take; a rule stops the list growing by wish, and
eight instructions turn sauce's 123 unchecked lines into checked ones.

**3. `raz -S`'s listing, stated.** raz(1) gives the listing's form, so
a tool may read it:
- a blank line, then a procedure's name as `Module.name:`;
- a source line: its number right-aligned in 6 columns, two spaces,
  the line's text;
- an instruction: its offset in the procedure right-aligned in 14
  columns, two spaces, the instruction as the assembler would read it,
  a jump within the procedure giving its target as an offset.

Only the main module's live procedures, in the order they were made;
nothing is disassembled. A change to the form is then a change to the
manual, and rcrypto's constant-time guard (`tools/branches.sh`), which
counts conditional jumps by reading these three kinds of line, breaks
loudly instead of silently. A test in raz holds the form against a
small program's listing.

**Recommendation:** take; it is a paragraph of raz(1) and one test,
for a form that already doesn't change.

## `Doc` for a library's pages

**Status.** Approved by the owner on 2026-10-23 and implemented in `tools/Doc.raz`, both.

`tools/Doc.raz` writes raz-lib(3) from `lib/`, and other libraries
have started to use it for their own pages. Two changes let them.

**1. A comment that heads a group of constants.** A comment just
before `const`, `type` or `var`, on lines of its own, is the group's:
`Doc` writes it once, before the group's declarations, as it writes a
module's own comment, and each declaration keeps the comment just
before it as now. Today `section` reads past the keyword and drops it
(checked: each constant then shows alone), so mosaico's `Mxlib` has a
comment line for each of its 237 constants where one before each group
would halve the file. In mdoc the group's comment is filled text before
the literal display; in plain text, the comment as written.

**Recommendation:** take; a few lines in `section` keep a comment the
standards already ask for.

**2. `Doc man` writes the modules, not the page.** Today it writes
raz-lib(3)'s `.Dd`, `.Dt`, NAME, DESCRIPTION and SEE ALSO, fixed in the
tool, and a `Date` constant in `Doc.raz` dated by hand. The change:
`Doc man Module.raz ...` writes only what is now between `.Sh MODULES`
and `.Sh SEE ALSO`; raz's `Makefile` puts the head and tail around it
from `doc/raz-lib.head` and `doc/raz-lib.tail` (or one file with a
marker line), and the date lives with the page, not the tool. rcrypto's
`tools/man3.sh`, which cuts Doc's page between the two `.Sh` lines and
sets its own around it, then just wraps it, as raz does. Title, name
and description from the command line were the other way; three
options to replace two small files is the larger.

**Recommendation:** take; it makes `Doc man` serve any library, and
`Doc.raz` loses its fixed text and its date.

## Left out

What the collation of 2026-10-22 recommended leaving out, each with its
reason; it is marked "Not planned" in `~/r/RAZ-GAPS.md`.

**Status.** Confirmed by the owner on 2026-10-23, but for the exported
array, parked with `[]const T`.

### The language


- Several values are assigned at once only from a call — two statements say it; `a, b := b, a` would need a rule that every right side is read before any is stored.
- No conditional compilation — a constant module chosen by `-I` is the Wirth idiom, and `if Fake then` on a constant already reads as one program.
- Records don't compare with `=` — padding, reals (`-0.0`, NaN) and slices make a byte compare wrong; a `same` procedure says what equal means. Confirmed by the owner, 2026-10-22.
- No type of its own for an array — a one-field record keeps two hashes apart, as it keeps generic arrays (owner's idiom).
- No exporting a record's fields as a whole — each `*` is the reader's mark of what is public; `Mxlib` is a C mirror, made by a program.
- An exported array can't be read as a slice outside its module — a slice can be written through; "A slice that can't be written: `[]const T`" in PROPOSALS.md would answer it. Parked by the owner on 2026-10-23, with `[]const T`, for the safety thaw.
- An exported variable can't be assigned from outside — Oberon's read-only export; a setter shows who writes.
- A generic instance isn't reachable through the module that imported it — no bug: an import's name is never exported (3); export a type of the instance, or import it again.
- `I32` doesn't widen to `INT` — `INT` may be 16 bits (5.1), so the widening would not hold everywhere.
- Common words are reserved — settled.
- Text built at run time needs a `Buf` — with no collector a `+` of texts has no owner for its result; `Fmt.write` into a `Buf` is it.
- Every string a record keeps is freed by hand — no collector; an `Arena` per record frees all of them at once.
- Nothing in the report says anything of time — this is about constant-time code, not clocks (rzone doesn't answer it); a sentence would bind every later optimiser, and rcrypto isn't to be depended on.
- An `ERROR` carries no text from the other end — an `ERROR` is an identity as big as an address; text from a peer belongs in a result field.
- A module's test drags its imports into every user — costs compile time and a few bytes; a comment `(* for the test *)` on the import tells the reader.

### Bits and bytes


- **`Buf` gives memory back unwiped.** — a program with secrets sizes
  its `Buf` with `Buf.room` and calls `Tls.wipe(Buf.bytes(b))` before
  `Buf.done`, as roauth does; a wipe in the library would duplicate
  rnet's `Tls` backends.
- **No hash but FNV, and no wipe the compiler can't drop.** — hashing
  and wiping go through rnet's `Tls` backends (`Tls.sha256`,
  `Tls.wipe`); `Ws`'s SHA-1 and the two 8-line wipes in `Smtp` and
  `Imapnet` move to `Tls` in rnet, and raz gains nothing.

### Sys and Files


- No reserving address space — `mmap` of the most it will hold, then
  `protect`, serves raudio; `MAP_NORESERVE` alone is not worth a
  procedure.
- `Sys.openDir` gives no order — sorting the names is a few lines with
  `Sort`, in the one program.
- No glob — one program (robbie), and which wildcards it takes is that
  program's choice; a `*` over `openDir` is about 40 lines.
- A signal noted just before a `wait` doesn't break it — already
  answered: `catch` SIGCHLD with the others and wait in `ready` on
  catch's fd (child, signal or deadline at once), then `wait(pid,
  false)`; `ignore(sig, false)` gives a caught signal its default back.
  Worth a paragraph in the library volume (written there), not a procedure.
- No word from the kernel when a file changes — inotify is Linux's,
  with no match in the C backend's other systems or Moss; a 300 ms
  look serves.
- No sleep a signal breaks into — `ready(-1, ms)` is that sleep for
  `handle`, and `ready` on catch's fd for `catch`.
- No sockets but streams and datagrams to addresses — netlink and HCI
  are Linux's, for one program.
- No user's name — the password database with NSS needs the C
  library, which mosaico links anyway.
- `Sys.rawMode` doesn't flush typed-ahead input — keys typed ahead are
  usually meant for the program; flushing would lose them.
- No positional read (`pread`, `fadvise`) — `seek` then `read` serves
  the one program; `fadvise` is a hint, fine as a `SYSCALL`.
- No `madvise` in `Sys` — `munmap` then `mmap` gives pages back.

### Numbers, strings, memory and Opt


- No fixed-capacity string — one program, a record of a length and an array, three lines.
- `Math.toReal` refuses `.5` and `5.` — it reads reals as the language writes them, and arkusz's 3-line `withZeros` serves its one user.
- `Math.toReal` is slow far from 10^0 — a fast path (Eisel and Lemire) is 60 lines and a table for one program's benchmark.
- `Math.pow` is not correctly rounded, and `Math.exp(y * Math.ln(x))` is worse — within an ulp as the header promises; correct rounding costs far more than one bit is worth.
- `Opt` has no GNU reordering, and does not say a `--` ended the options — options ending at the first operand is `Opt`'s stated rule, so that a command's own options pass through.
- `Opt` carries no completion words — completion is concha's, one program, and the table would grow for every user.
- A zero `Buf` or `Vec` isn't usable — deliberate: the core assumes no heap, and `init` says which allocator.
- Joining texts into a kept `[]U8` costs a `Buf` and a copy — `Str.join` then `Str.copy` is two calls, for one program.
- Case is ASCII only — Unicode case maps are large tables for one program; rrem has them.
- `Vec` gives no pointer to an element already in it — `Nodes.all(v)[k].next := m` already sets a field in place.
- No lenient base64 reader in `Str` — mail's junk is rmime's to handle; its 30 lines serve the one reader that meets it.
- `Check.int` takes `I64` — an `I32` widening to `I64` is the language's question, and one call site converts.
- `Rand` has no shuffle — `Rand` isn't generic, and Fisher and Yates over `below` is four lines. Confirmed by the owner, 2026-10-22.
- `Fmt.real(x, n)` rounds the binary value, not the decimal text — the Pascal double rounding is left; the round-trip need is met by `Fmt.short` above.

### Freestanding programs and tools


- `Doc` fills a list — rcrypto's paragraphs read as well, and a line
  indented further already means code, which a list's continuation
  would muddle.
