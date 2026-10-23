# Working on raz

Read `doc/raz.md` (the language report, volume 1) and
`doc/compiler.md` (the guide to the compiler) first; `doc/raz-lib.md`
is volume 2, the library, `doc/report-history.md` what each version of
the report changed, and `PROPOSALS.md` what waits for a thaw. The
report defines the language.

## Setup and checks

    make raz       # the compiler, ./raz, built from src/ by the release BOOT names; its library is lib/
    make check     # every example and test against its expected output
    make bench     # must report at least 400,000 lines a second
    make prev-bench  # the compiler's speed against BOOT's: more than a tenth slower fails
    make kernels   # test/bench's kernels against FPC -O2's twins (apt-get install -y fp-compiler)
    make loc       # lines of the compiler, by rloc; the last, code, is the budget
    make fixpoint  # BOOT's release builds src, that builds src, that again: the last two agree
    make gdb       # gdb stops at a line of a test and names it
    make stress    # 40,000 native threads; make check runs a small version
    make alpine    # test/libc in an Alpine container, over musl (docker)
    make fmt       # lib/, examples/ and tools/ are formatted
    make install   # raz on PATH via ~/.local (PREFIX=...); make uninstall

`make check` also runs `tools/Doc.raz` and `tools/Pretty.raz`, the
report's whole examples, the tutorial's (`doc/raz-tutorial.7`, each
against the output the page shows after it, its status in `test/man`), each library module's own `main` (its test),
and the vim and emacs support headless where they are installed
(`apt-get install -y vim emacs-nox`): each example must indent back
exactly as written.

`make check` must pass before every commit. The conformance suite,
`conform/`, holds what any implementation must do (`conform/check.sh`
says how it is laid out); `test/` holds what is this compiler's alone:
its messages, its limits, its target. A test goes in `conform/` when
the report alone fixes its output and status, and keeps to the
language and the library a target can't leave out. Tests:
`test/run/X.raz` with `X.expect` (stdout), optional `X.status`,
`X.stderr` and `X.args`; modules they import in `test/run/mods`.
`test/err/X.raz` must fail to compile with the text in `X.err` (all of
standard error), given the compiler options in `X.args` if there is
one. `test/msg` holds this compiler's `X.stderr` and `X.err` for the
programs in `conform/`.
`test/pretty/X.raz` must format to `X.expect`. Examples in `examples/`
work the same way, compiled with `-Werror`, as are `test/libc`, the
tools and the library's tests: they must have no warnings.

## How we work

- The compiler, `src/`, is raz, in the language of the report and with
  the library of `lib/`; it must build with the release `BOOT` names
  (v0.20.0), so it, and the modules of `lib/` it imports, use nothing
  that release doesn't know until `BOOT` names a newer one.
- Work goes by milestones, each a release, set by the owner. A milestone
  starts only on the owner's explicit go-ahead; within it, one commit
  per step, pushed as it is done, then stop for review. Never start a
  milestone, or change the report's language, without being asked.
- Language changes go into `doc/raz.md` first, for the owner to review,
  before any code.
- Commits: author
  `Luis <42945842+ldiaz94@users.noreply.github.com>`, unsigned
  (`--no-gpg-sign`), no attribution trailer. Push to `main`. No pull
  requests unless asked.
- Budget: never past 14,000 lines of code (raised from 8,500, then
  from 11,000, by the owner's word, who dropped the soft limit; blank and
  comment lines not counted), with the compiler documented and
  commented throughout, most of all where it is obscure or needs a
  compiler writer's knowledge; at least 400,000 lines of raz a second;
  the report, `doc/raz.md`, under 40 pages as `make pdf` renders it,
  checked by hand after each milestone (32 at report 2026-10.34).
- Clarity comes first, before speed and size: the compiler must be a
  model of plain code that a beginner can follow. Every rewrite of the
  code it makes is explained where it is done, with the code before
  and after, and in `doc/compiler.md`.
- Style: clarity over cleverness; each unit opens with what it is, what
  it depends on and what it leaves out; comments say why. Match the
  report's plain, short prose in documentation. `STANDARDS.md` says
  how raz is written here: a parameter is a value, `var`, or, only
  when it is kept, a pointer; no `ADR` where `var` serves.

## Where things stand

The website's `/source/` browser and releases are built by ladle,
pinned with its checksum under `site/tools/`. `make site` builds the
main pages and then the source site. Wrangler runs `make site-source`
before uploading, so the generated Git store stays out of this
repository. `site/README.md` gives the build, release records and
checks. `site/releases` lists website releases whose tags aren't
pushed yet (none now); it never makes a tag.

v0.21.0, report 2026-10.34, the language unchanged, is for a kernel:
the assembler knows a kernel's instructions (`cli`, `lgdt`, `mov` to
`cr3`, `in`, `out`, ...); `raz -base` sets the load address, in the low
or the top 2 GB; `raz -bare` makes a program for the bare machine, which
reads no arguments and runs no body of `Rt`. `BOOT` names v0.20.0, and
`Sys` takes `PTR` where it had its private `bytes`. `MEM_PROPOSAL.md`
proposes a memory-safe raz, for a thaw.
v0.20.0, report 2026-10.34, before it: v0.19.0 builds `src/` and the
Pascal seed is gone; `Buf.bytes`, `Sys.entryKind` and `src/`'s `Item`s
only read take `const`; and the tenth thaw, by the owner's word,
`PTR(s)`, a slice's pointer, with messages that point to it.
v0.19.0, report 2026-10.33, before it: the ninth thaw, a `const`
parameter, a variant in a constant, and the library taking `var`,
`const` or a value where it took a pointer (`Arena`, `Buf`, `Files`,
`Fmt`, `List`, `Lock`, `Map`, `Opt`, `Str`, `Sys`'s directories,
`Thread`'s `Mutex`, `Vec`; and `tools/Scan.raz`), which breaks calls
written with `ADR`; the compiler's message names the mending.
v0.18.1, report 2026-10.32, before it: v0.18.0's thaw (a
constant typed `[]T` may be `[]`, the empty slice, as may a constant's
slice part), with `Vec.pop` and `Sys.Info.links`, and a constant's
slice part naming another module's array constant, a defect mended;
and library growth that breaks no program: `Buf.cut`, `Out.lines`,
`Thread.signal`, and in `Opt` `spelt` and `refuse`, a `-h` of a
scope's own, a value that may be left out (`[name]`) and `number` with
no top.
v0.17.0's thaw before it: `INT` at least 16 bits, and `U8`, `I8` and
`I16` widening to it; an enumeration's name written with its type, and
shared; `continue`; `[]` as the empty slice; `Width`. `src/` is the
compiler in raz, built by itself (Self, done); the Pascal seed, the
release compiler to v0.9.1 and what built `src/` to v0.19.0, is in git
at v0.19.0. The compiler takes 1.4 times the Pascal one's time; `make
kernels` measures `test/bench` against FPC `-O2`. What
each version of the report changed is in `doc/report-history.md`, and
what each step did is in git; don't repeat it here.

rmacs (emacs's keys) and ravite (vim's), the two editors written in
raz, live in repositories of their own, each pinning the raz commit it
builds with; they use `tools/Scan.raz` as a tool, not part of the
library. rat, rlX11 and rloc are other users of `Sys`.

**The freeze.** Since v0.5.0 the language changes only to mend a
defect, and the library grows only by what breaks no program written
for it. A wish for more, the owner's or yours, goes in
`PROPOSALS.md`, for a later thaw; it isn't built. Thaws happen only by the
owner's word (v0.6.0, reports 2026-10.13 to 10.23, 10.25 for strings,
10.26 for `INT` and views, 10.33 for `const` parameters, variants
in constants and the library by `var`, and 10.34 for `PTR`).

**The reserved words and the module names are settled.** That a word
is reserved, however common (`code`, `to`, `packed`, `forward`, `set`,
...), and that the names of modules are one space with the library's
(3, "Names are flat"), so that a program's module may clash with one of
the library's, now or later, are never brought up: not as a defect, a
proposal, an awkwardness or a note, in raz or in any program or library
written in it. A name that is taken is renamed, and nothing is said of
it.

The parser reaches the machine only through `Gen.raz`. Keep
`doc/compiler.md`'s table of lines and its routine names true when the
compiler changes.

A release is an annotated tag `vX.Y.Z` on `main`, its message what
`raz --version` will print (`raz 0.3.0, report 2026-10.0`); `make
check` passes first. The compiler takes its version from `git
describe` (`build/version.inc`, made by `make`). Pushing the tag runs
`.github/workflows/ci.yml`, which checks it and makes the GitHub
release with a tarball of `raz` and `lib/`; it also checks every push
to `main`. A release whose tag isn't pushed yet goes to the website
by `make site RELEASES="vX.Y.Z=COMMIT"`, its tarball made by `make
dist REV=COMMIT VERSION=X.Y.Z`, the same as the tag's will be. `README.md`'s "Versions" gives the commands. v0.3.0 is
the first. The tarball has `tools/`, which the website offers from
0.7.1 on.

`test/libc` runs its programs over `lib/Sys.raz`, the C one, through
a link in its `mods`; `make check` runs them again with `-libc musl`
where musl's loader is installed (`apt-get install -y musl
musl-tools`), and compares `tools/cabi.c`'s output, with `cc` and
`musl-gcc`, with `lib/CAbi.linux-x86_64.raz`, which is never edited
by hand. A test or example without `.expect` is only
compiled (`examples/Window.raz` needs a display).

## The compiler and BOOT

`src/` is the compiler, in raz: one module to a unit of the Pascal
compiler it was ported from, the same names. The release `BOOT` names,
by its tag and its tarball's SHA-256, builds it: `src/boot.sh` fetches
the tarball into `build/boot/` (curl, or `gh api` for a private
repository: CI gives it `GH_TOKEN`), checks the sum and puts its `raz`
there with today's `lib/` beside it. Each release is built by the one
before it, back to v0.19.0, which the Pascal seed built; the seed is in
git at v0.19.0 (`seed/`), and a comment in `src/` that names "the
seed" means it. `make check`, the fixpoint and `conform/` are the
compiler's tests. Moving `BOOT` to a newer release, once its tag is
pushed and CI's tarball has the SHA-256 `make dist` gives here, is a
step of its own, by the owner's word; then `src/` may use what that
release brought. `fpc` is needed only for `make kernels`' Pascal twins.

`sbcl/` is an example, not part of the build: a second compiler, in
Common Lisp, written from the report alone and kept as a reference
(`sbcl/README.md`).

## Readings of the report already taken

These are how the compiler behaves; keep them unless the owner says
otherwise.

- A named and an anonymous type built alike are the same; `type A = B`
  is an alias. A hex literal above high(I64) is a `U64`.
- `p^.f` and `p^[i]` are explicit; `p[i]` on a pointer to an array is
  an error. A statement starts with a name, so `^T(x)^ := v` isn't one.
- A `BOOL` converts to every integer type, 0 or 1 (report 2026-10.36),
  in `convert`'s integer branch with no code of its own, as a `BOOL`'s
  value is already 0 or 1; of a constant it folds. No integer to
  `BOOL`: the error's help says `x # 0`.
- `for`: the step is a constant; the loop never steps past the limit, so
  it can't wrap; afterwards the variable holds the last value it took;
  the body may assign it. Leave as is.
- Two results that are each a single value of a word at most, not a
  real, come back in rax and rdx, and so does a slice, as from a code
  procedure (owner's word, v0.7.0); other several results, and records,
  through a hidden pointer.
- `NEW(p, a)` requires `a: ^Mem.Allocator` and calls its `alloc` field:
  the one library type the compiler knows by name. `Rt.fail` is
  found by name too.
- A set literal takes its type from its first name when nothing else
  gives it; `{}` needs a known type. String constants can be indexed
  and sliced.
- A deferred statement's frame slots stay reserved for the rest of its
  procedure.
- A generic instance first used in a procedure, or in the module's
  body, is made before that code begins: `InstancesFor` reads ahead
  for the import's name, since code can't be compiled inside other
  code. Its arguments are read then, in the scope there.
- A program uses C if a module it uses (not one read only for an
  interface check) has an `extern` or a `link` of a library. `static`
  in `link static;` is not a reserved word. It is linked against
  glibc, or musl (`/lib/ld-musl-x86_64.so.1`, needing `libc.so`) by
  `-libc musl` or on a machine with musl's loader and not glibc's.
  `lib/Sys.raz` and `CAbi` are read for the interface check when
  BOOT's release builds `src/`, so they keep to its language, as the
  modules `src/` imports do.
- `Sys` gives minus Linux's errnos on every target; `Sys.raz` maps the
  C library's through `CAbi.errnos`.
- C symbols are reached through quadwords the loader fills in
  (GLOB_DAT), with no PLT; the executable exports nothing. In a C
  program the entry point stores C's `exit` in `Rt.cExit`, found by
  name like `Rt.exit`, before any module body runs; and, if the
  program has `Thread`, `pthread_create` and `pthread_join` in
  `Thread.cCreate` and `Thread.cJoin`, so that `Thread` makes C's
  threads there and serves programs with C and without.
- Past an extern's parameters, a string goes as a C string and an
  integer constant as an `INT`.
- A real constant is held as an F64; one typed `F32` holds a value an
  F32 can hold (the report says so, 2). An `F32` in a register is its low 32 bits; the upper
  ones are left as they fall.
- `Heap` and `Out` lock with `Lock`, a spinlock that yields, since they
  serve C's threads and `Thread`'s alike; `Thread.Mutex` is a futex.
- A failed check says what failed and with what values, at the place
  of the offending expression. A signal is told at the place of the
  statement it stopped in, or of the procedure for a stack overflow in
  its prologue, and the program ends by `Rt.exit(2)`, after its
  `atExit` procedures, as a failed check does (report 2026-10.22; a
  fault inside `Out`'s or `Heap`'s lock would hang there). The handlers run on a stack of their own: `Rt`'s for
  the main thread, and one in each `Thread` thread's mapping, made
  by clone or by C. Threads a program makes with `pthread_create`
  itself have none, so a stack overflow in one still ends the program
  by the signal with no message.
- The smallest value of a signed type divided by -1 stops the program
  (SIGFPE), as 6.1 says, `mod` as `div`; for a type narrower than 64
  bits the code makes the division fault, as the machine wouldn't. In
  a constant it is an error, as dividing by zero is.
- `INT` widens to `I64` (and `UINT` to `U64`) wherever its value goes
  to one: assigned, passed, returned, in `a, b := f(x)` and `return
  f(x)`, a `for`'s bounds, `INC`/`DEC`'s step, and where it meets an
  `I64` in an operator (report 2026-10.26, 5.10 and 6.1). Never to a
  `U64`, nor an `I64` back to an `INT`.
- A view, `v.(T)`, is `v`'s item with `T` for its type: nothing is
  copied. A variable kept in a register goes to memory for it, as for
  `ADR`. Another module's variable may be viewed, and not written. A
  view that runs past its end fails as kind 7 of `Rt.fail`. `src/`,
  and the library it imports (`Str`, `Bytes`, `Sys`, ...), may use
  views and the widening now that v0.19.0 builds them; they use
  neither yet.
- A returned slice of the frame (report 2026-10.27, 7.3) is caught by
  `Item.frame`, which sees only the expression: a slice held first in a
  local slice variable or a record, stored, or come back from a call,
  isn't, and is left undefined (10). `ret` and `keep`, in
  PROPOSALS.md, would close it; the owner keeps it open for now.
- An empty slice constant, `const E: []T = [];` (report 2026-10.32),
  is 16 zero bytes in read-only data, read as an array constant is;
  `LEN` of it is no constant. A constant's slice part takes `[]`, and
  names a constant whole, of any module, by its type, not its text.
- An array a call returns is a temporary of the statement (report
  2026-10.28, 8): a slice of it kept past the statement is undefined
  (10), and isn't caught.
- `Buf.add`, `str` and `spare`, and `Vec`'s growing, stop the program
  when the allocator has no room; `room` asks first.
- `Sys.handle`'s handler only notes the signal, with `XCHG`; it is
  installed without `SA_RESTART`, so a call it breaks into is -4, which
  `Out` and `Files` try again. Over C, `ready` and `readyFor` try `poll`
  again after EINTR only when no signal `handle` took broke in.
- `U8`, `I8` and `I16` widen to `INT`, `U8` and `U16` to `UINT`, one
  step only (a `U8` into an `I64` is written), and not in `return f(x)`
  (report 2026-10.31). An operator's result on them (`made`) doesn't
  widen; a conversion's does, `U8(a + b)` too.
- An enumeration's name shared in its scope with another enumeration's
  is written with its type; shared with anything else, the name alone is
  that other declaration. A `match` arm on an enumeration or a variant
  (report 2026-10.36, 7.4) takes a case alone, found among the matched
  type's own whatever the scope holds, or qualified as anywhere else
  (`Kind.done`, `Xml.done`, `Xml.Kind.done`), read by `qualIdent`; a
  qualified case of another type is an error naming both.
- `Width` follows glibc's `wcwidth` but gives a control 0, and 0 to the
  format characters glibc counts as 1 (Egyptian hieroglyph controls,
  interlinear annotation), but for the prepended concatenation marks.
- An `extern` module variable is read-only for an importer, as the
  report says of every exported variable (3).
- Warnings come only for a module with no errors. A procedure naming
  itself doesn't use it; a type named by a pointer in its own
  declaration does. An enumeration's names are never warned of, nor a
  generic module's parameters; a generic module is warned of in its
  first instance only. Assigning a variable whole (`x :=`, `a, b :=`)
  doesn't read it; anything else does.
- A `const` parameter (report 2026-10.33) is a `var` one never changed:
  passed by address always, its `Obj` `isVar` and `isConst`, an item of
  it `ro`. A slice of its array may be made, to read; through it the
  caller's array may be written, which the report says (8). An argument
  that isn't a variable, or is a packed field, a view or volatile, goes
  in a temporary of the statement. `match` on a `const` parameter or a
  constant gives names that are only read. Procedure types compare
  `const` as `var`. It is unused if never read, as a value parameter.
- A variant in a constant must be typed; `const D = dot;` is an error
  that says to write its type. Its case is read by name (`constCase`).
- The library takes a `var` for what it changes and `const` for a record
  or array it only reads (report 2026-10.33); `Buf.bytes` and
  `Sys.entryKind` came to it in v0.20.0, with the seed gone. `src/`
  takes an `Item` as `const` only where callgrind counts a gain, on the
  paths every compile goes through; the routines that word an error
  take a value. Measured: a `Map` passed as a value, four
  words, made a loop of `get` half again as slow as `const`. A trace
  shows no `var` or `const` parameter. `Fmt`'s `format` and `put` keep
  `^Buf.Buf`, since `nil` is standard output there.
- `PTR(s)` (report 2026-10.34) is a slice's first word, read with no
  check; of an array or a string constant, its address, refused wherever
  a slice of all of it is (a packed record's misaligned field, a view,
  through `^VOLATILE`, another module's array). `PTR("")` is the
  string's place in read-only data, not `nil`; an empty slice cut from
  another keeps its place. `PTR([])` is an error, since `[]` has no
  type there, and its help says it would be `nil`. A slice where its
  element's pointer is wanted, and a pointer where a slice is, are
  errors whose help names `PTR(s)` and `LEN(s)`, or `p[0..n]`.
- `ROL(x, n)` and `ROR(x, n)` (report 2026-10.35) are done at `x`'s
  own width, `rol al, cl` for a `U8`, with no mask of the count: x86
  takes it modulo 32 or 64, and a byte's or a word's rotation goes
  round modulo 8 or 16 itself. A negative count is taken modulo the
  width as a shift's is, `n & (w - 1)`: `ROL(x, -1)` is `ROR(x, 1)`.
  The result is a built-in's, not an operator's, and widens (`made`
  is false). Of two constants they fold, in a constant too.
- `MIN(T)` and `MAX(T)` (report 2026-10.36) are untyped constants, but
  `MAX(U64)` and `MAX(UINT)`, above `high(I64)`, keep their type, as a
  hex literal above it is a `U64`. A `T` not an integer type is an
  error; `MAX(x)` of a variable is "x isn't a type".
- `CLZ(x)`, `CTZ(x)` and `POPCOUNT(x)` (report 2026-10.36) give an
  `INT`, a constant of one when `x` is. They use only baseline x86-64,
  no `lzcnt`, `tzcnt` or `popcnt`: `bsr` or `bsf` on all 64 bits (a
  narrow value's upper ones are zero), with `jnz` past setting the
  count of 0 to the width; `POPCOUNT` by `Bytes.count`'s sums of two,
  four and eight bits and a multiply by `0101...H`, in rax and rdx. A
  set's `POPCOUNT` counts its bits the same way.
- `SIZE(T.f)` and `OFFSET(T, f)` (report 2026-10.36): the type is read
  by `parseType`, where a name before a `.` must be a module's, so
  `M.T` is read whole and a `.` past the type is a field's,
  `SIZE(M.T.f)` too. `T` must be a record type (a variant is refused,
  with help); a path `a.b` is refused, its help naming `a`'s type.
  `BYTES(x)`: of a slice, its `PTR` and `LEN * SIZE(T)`, with no check
  of what holds the slice (a `const` one, another module's, a field of
  a packed record), as for `PTR`; of anything else, a variable's
  address and size, refused, as `ADR` refuses, for what is only read,
  and, beyond `ADR`, for a volatile variable; a constant of any kind
  is no variable. `T` is refused by the view's `notPlain`. The result
  keeps `x`'s `frame`, so the bytes of a local are caught by
  `notOfFrame` as far as a slice of it is.
