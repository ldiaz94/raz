# Working on raz

Read `doc/raz.md` (the language report, volume 1) and
`doc/compiler.md` (the guide to the compiler) first; `doc/raz-lib.md`
is volume 2, the library, `doc/report-history.md` what each version of
the report changed, and `PROPOSALS.md` what waits for a thaw. The
report defines the language.

## Setup and checks

    apt-get install -y fp-compiler   # Free Pascal 3.2.2, if fpc is missing
    make raz       # the compiler, ./raz, built from src/ by the seed; its library is lib/
    make check     # every example and test against its expected output
    make bench     # must report at least 400,000 lines a second
    make kernels   # test/bench's kernels against FPC -O2's twins
    make loc       # lines of the compiler, by rloc; the last, code, is the budget
    make tests     # the small Pascal tests of scan, x64, link and elf
    make seed-check  # src/ against the seed: scan to x64, then the messages and statuses of every program
    make fixpoint  # the seed builds src, that builds src, that again: the last two agree
    make gdb       # gdb stops at a line of a test and names it
    make stress    # 40,000 native threads; make check runs a small version
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
work the same way, compiled with `-Werror`, as are the tools and the
library's tests: they must have no warnings.

## How we work

- The compiler, `src/`, is raz, in the language of the report and with
  the library of `lib/`; it must build with the seed (`seed/`, Free
  Pascal 3.2.2, `{$mode objfpc}{$H-}`: records, pointers, shortstrings;
  no classes, ansistrings, exceptions, dynamic arrays or SysUtils), so
  it uses nothing the seed doesn't know until a release makes a new
  seed.
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
  compiler writer's knowledge; at least 400,000 lines of raz a second.
- Clarity comes first, before speed and size: the compiler must be a
  model of plain code that a beginner can follow. Every rewrite of the
  code it makes is explained where it is done, with the code before
  and after, and in `doc/compiler.md`.
- Style: clarity over cleverness; each unit opens with what it is, what
  it depends on and what it leaves out; comments say why. Match the
  report's plain, short prose in documentation.

## Where things stand

v0.15.0, report 2026-10.27 (a slice of the frame returned is an
error; `Sys`'s `openMode`, `syncAll`, `lock`, `linkInfo` and
`Info.ino`; `Buf.spare`, and `Buf` stopping when out of memory; `Vec`,
a growable array), what porting sauce asked for, is the latest
release. `src/` is the
compiler in raz, built by itself (Self, done); the seed in `seed/` is
frozen, and v0.9.1 was the last release it built. The compiler takes
1.4 times the Pascal one's time; `make kernels` measures `test/bench`
against FPC `-O2`. Next: what the owner chooses. What
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
and 10.26 for `INT` and views).

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
to `main`. `README.md`'s "Versions" gives the commands. v0.3.0 is
the first. The tarball has `tools/`, which the website offers from
0.7.1 on.

`test/libc` runs its programs over `lib/Sys.raz`, the C one, through
a link in its `mods`. A test or example without `.expect` is only
compiled (`examples/Window.raz` needs a display).

## The compiler and the seed

`src/` is the compiler, in raz: one module to a
seed unit, the same names. `seed/`, the Free Pascal compiler it was
ported from, is the **seed**: frozen at its last version, kept to build
`src/` the first time and as the reference its units are tested
against, and to be dropped in time. Never edit the seed; a difference
found is told to the owner.

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
- No `BOOL` to integer conversion (left out until needed).
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
  in `link static;` is not a reserved word.
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
  and the library it imports (`Str`, `Bytes`, ...), use neither views
  nor the widening of 2026-10.26, since the seed builds them, until a
  release makes a new seed.
- A returned slice of the frame (report 2026-10.27, 7.3) is caught by
  `Item.frame`, which sees only the expression: a slice held first in a
  local slice variable or a record, stored, or come back from a call,
  isn't, and is left undefined (10). `ret` and `keep`, in
  PROPOSALS.md, would close it; the owner keeps it open for now.
- `Buf.add`, `str` and `spare`, and `Vec`'s growing, stop the program
  when the allocator has no room; `room` asks first.
- An `extern` module variable is read-only for an importer, as the
  report says of every exported variable (3).
- Warnings come only for a module with no errors. A procedure naming
  itself doesn't use it; a type named by a pointer in its own
  declaration does. An enumeration's names are never warned of, nor a
  generic module's parameters; a generic module is warned of in its
  first instance only. Assigning a variable whole (`x :=`, `a, b :=`)
  doesn't read it; anything else does.
