# Working on raz

Read `PLAN.md` (the milestone under way and its steps), `doc/raz.md`
(the language report) and `doc/compiler.md` (the guide to the
compiler) first. The report defines the language; where the plan
disagrees, the report wins and the plan is fixed.

## Setup and checks

    apt-get install -y fp-compiler   # Free Pascal 3.2.2, if fpc is missing
    make raz       # the compiler, ./raz; its library is lib/
    make check     # every example and test against its expected output
    make bench     # must report at least 400,000 lines a second
    make kernels   # test/bench's kernels against FPC -O2's twins
    make loc       # lines of the compiler, by rloc; the last, code, is the budget
    make tests     # the small Pascal tests of scan, x64, link and elf
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

- The compiler is Free Pascal 3.2.2, `{$mode objfpc}{$H-}`: records,
  pointers, shortstrings. No classes, ansistrings, exceptions, dynamic
  arrays or SysUtils.
- Plans go by milestones, each a release (`PLAN.md`). A milestone
  starts only on the owner's explicit go-ahead; within it, one commit
  per step, pushed as it is done, then stop for review. Never start a
  milestone, or change the report's language, without being asked.
- Language changes go into `doc/raz.md` first, for the owner to review,
  before any code.
- Commits: author
  `Luis <42945842+ldiaz94@users.noreply.github.com>`, unsigned
  (`--no-gpg-sign`), no attribution trailer. Push to `main`. No pull
  requests unless asked.
- Budget: a soft limit of 10,000 lines of code, never past 11,000
  (raised from 8,500 by the owner's word, for better code; blank and
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

Steps 1-18 are done: the language, the tools (`tools/Doc.raz`, and
the formatter, `tools/Pretty.raz`, over the shared `tools/Scan.raz`),
`README.md` and the guide to the compiler, `doc/compiler.md`. Stage 5
made two editors, which now live in repositories of their own, each
pinning the raz commit it builds with: rmacs (emacs's keys) and
ravite (vim's). What they needed of the system went into `Sys` (report
2026-10.2, approved): the terminal, files, directories and the
environment. `tools/Scan.raz` is theirs to use, as a tool, not part of
the library. Stage 4, diagnostics (steps 19-27), is done; so are
stage 6, the language of report 2026-10.3 (steps 42-47), and stage 8,
one module to a name (report 2026-10.5, step 51), and stage 7, `Sys`
for rlX11 and rat (reports 2026-10.4 and 10.7, steps 49a-c), with
`Info`'s `file` and `symlink` for rloc (2026-10.6, step 49d), and
stage 9, several results in place of var parameters (2026-10.8,
steps 52-53), and v0.5.0, the library of report 2026-10.9, which the
compiler says it follows, and v0.7.0, better code, and v0.7.1, the manual: `raz(1)`,
`raz-tutorial(7)`, `raz(7)` and `raz-lib(3)`, made by `tools/Doc.raz`
from `lib/`, and v0.8.0, better code again: slices in registers,
parameters left in rdi and rsi, operands as the machine has them,
`while` tested at the bottom, and one line table, DWARF's, and
v0.9.0, better code for reals: reals on the stack and the
busiest real variables in xmm registers, and an array's element and a
constant offset as operands, measured on two kernels of reals,
`Jacobi` and `NBody`. `make kernels` measures `test/bench` against
FPC `-O2`. Next, by `PLAN.md`: what the owner chooses.

**The freeze.** Since v0.5.0 the language changes only to mend a
defect, and the library grows only by what breaks no program written
for it. A wish for more, the owner's or yours, goes on the list in
`PLAN.md`, for a later thaw; it isn't built. v0.6.0 was such a thaw,
by the owner's word: report 2026-10.12; the compiler follows 2026-10.19,
whose `Sys` writes without waiting, for rat's pastes (10.13), and
whose blank, `_ := f(x)`, drops a result that is otherwise warned of
(10.14), and whose `Math` has `pow`, the logarithms to 2 and 10,
rounding and the inverse functions, and `Sys` `space` (10.15), and
whose constants may be records and tables of them, with `Str.copy`
(10.16), and `COPY` (10.17), also by the owner's word, and whose code
procedures take and return slices (10.18), and whose library has
`Bytes` (10.19). Its parser
reaches the machine only through `gen.pas`. Keep
`doc/compiler.md`'s table of lines and its routine names true when the
compiler changes.

A release is an annotated tag `vX.Y.Z` on `main`, its message what
`raz --version` will print (`raz 0.3.0, report 2026-10.0`); `make
check` passes first. The compiler takes its version from `git
describe` (`build/version.inc`, made by `make`). Pushing the tag runs
`.github/workflows/ci.yml`, which checks it and makes the GitHub
release with a tarball of `raz` and `lib/`; it also checks every push
to `main`. `README.md`'s "Versions" gives the commands. v0.3.0 is
the first; v0.9.1, report 2026-10.19, the latest: v0.9.0 with
`tools/` in the tarball, which the website offers from 0.7.1 on.

`test/libc` runs its programs over `lib/Sys.raz`, the C one, through
a link in its `mods`. A test or example without `.expect` is only
compiled (`examples/Window.raz` needs a display).

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
  name like `Rt.exit`, before any module body runs.
- Past an extern's parameters, a string goes as a C string and an
  integer constant as an `INT`.
- A real constant is held as an F64; one typed `F32` holds a value an
  F32 can hold. An `F32` in a register is its low 32 bits; the upper
  ones are left as they fall.
- `Heap` and `Out` lock with `Lock`, a spinlock that yields, since they
  serve C's threads and `Thread`'s alike; `Thread.Mutex` is a futex.
- A failed check says what failed and with what values, at the place
  of the offending expression. A signal is told at the place of the
  statement it stopped in, or of the procedure for a stack overflow in
  its prologue. The handlers run on a stack of their own: `Rt`'s for
  the main thread, and one in each `Thread` thread's mapping. C's
  threads have none, so a stack overflow in one ends the program by
  the signal with no message.
- The smallest value of a signed type divided by -1 stops the program
  (SIGFPE), as 6.1 says, `mod` as `div`; for a type narrower than 64
  bits the code makes the division fault, as the machine wouldn't. In
  a constant it is an error, as dividing by zero is.
- `INT` widens to `I64` (and `UINT` to `U64`) wherever a value is
  assigned, passed or returned, `return a, b` included; not in `a, b :=
  f(x)`, `return f(x)`, a `for` or `INC`/`DEC`. An untyped constant
  converts to a pointer, as an `INT`.
- Another module's exported variable, or a field or array element of
  it, is read-only: an `extern` one too. A slice in it may be sliced,
  since that can't change the variable; an array in it may not.
- Warnings come only for a module with no errors. A procedure naming
  itself doesn't use it; a type named by a pointer in its own
  declaration does. An enumeration's names are never warned of, nor a
  generic module's parameters; a generic module is warned of in its
  first instance only. Assigning a variable whole (`x :=`, `a, b :=`)
  doesn't read it; anything else does.
