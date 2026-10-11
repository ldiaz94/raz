# Working on raz

Read `PLAN.md` (the plan, ground rules, steps) and `doc/raz.md` (the
language report) first. The report defines the language; where the
plan disagrees, the report wins and the plan is fixed.

## Setup and checks

    apt-get install -y fp-compiler   # Free Pascal 3.2.2, if fpc is missing
    make raz       # the compiler, ./raz; its library is lib/
    make check     # every example and test against its expected output
    make bench     # must report at least 400,000 lines a second
    make loc       # lines of the compiler; the code column is the budget
    make tests     # the small Pascal tests of scan, x64, link and elf
    make gdb       # gdb stops at a line of a test and names it
    make stress    # 40,000 native threads; make check runs a small version
    make fmt       # lib/, examples/ and tools/ are formatted
    make install   # raz on PATH via ~/.local (PREFIX=...); make uninstall

`make check` also runs `tools/Doc.raz` and `tools/Pretty.raz`, the
report's whole examples, each library module's own `main` (its test),
and the vim and emacs support headless where they are installed
(`apt-get install -y vim emacs-nox`): each example must indent back
exactly as written.

`make check` must pass before every commit. Tests: `test/run/X.raz`
with `X.expect` (stdout), optional `X.status` and `X.args`; modules they
import in `test/run/mods`. `test/err/X.raz` must fail to compile with
the text in `X.err`. `test/pretty/X.raz` must format to `X.expect`.
Examples in `examples/` work the same way.

## How we work

- Work goes stage by stage. A stage starts only on the owner's explicit
  go-ahead; within it, one commit per step, pushed as it is done, then
  stop for review. Never start a stage, or change the report's
  language, without being asked.
- Language changes go into `doc/raz.md` first, for the owner to review,
  before any code.
- Commits: author
  `Luis <42945842+ldiaz94@users.noreply.github.com>`, unsigned
  (`--no-gpg-sign`), no attribution trailer. Push to `main`. No pull
  requests unless asked.
- Budget: about 6,000 lines of code (blank and comment lines not
  counted), within 10%; at least 400,000 lines of raz a second.
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
the library. New work starts only on the owner's word. Keep
`doc/compiler.md`'s table of lines and its routine names true when the
compiler changes. Left for later at the owner's word: a rewrite of
var parameters.

A release is an annotated tag `vX.Y.Z` on `main`, its message what
`raz --version` will print (`raz 0.3.0, report 2026-10.0`); `make
check` passes first. The compiler takes its version from `git
describe` (`build/version.inc`, made by `make`). Pushing the tag runs
`.github/workflows/ci.yml`, which checks it and makes the GitHub
release with a tarball of `raz` and `lib/`; it also checks every push
to `main`. `README.md`'s "Versions" gives the commands. v0.3.0 is
the first.

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
- Several results come back through a hidden pointer; a code procedure
  returns two in rax and rdx.
- `NEW(p, a)` requires `a: ^Mem.Allocator` and calls its `alloc` field:
  the one library type the compiler knows by name. `Rt.fail` and
  `Rt.eq` are found by name too.
- A set literal takes its type from its first name when nothing else
  gives it; `{}` needs a known type. String constants can be indexed
  and sliced.
- A deferred statement's frame slots stay reserved for the rest of its
  procedure.
- A program uses C if a module it uses (not one read only for an
  interface check) has an `extern` or a `link` of a library. `static`
  in `link static;` is not a reserved word.
- C symbols are reached through quadwords the loader fills in
  (GLOB_DAT), with no PLT; the executable exports nothing. In a C
  program the entry point stores C's `exit` in `Rt.cExit`, found by
  name like `Rt.exit`, before any module body runs.
- Past an extern's parameters, a string goes as a C string and an
  integer constant as an `I64`.
- A real constant is held as an F64; one typed `F32` holds a value an
  F32 can hold. An `F32` in a register is its low 32 bits; the upper
  ones are left as they fall.
- `Heap` and `Out` lock with `Lock`, a spinlock that yields, since they
  serve C's threads and `Thread`'s alike; `Thread.Mutex` is a futex.
- Every failed check says "index out of range"; some errors point at
  the symbol after the offending expression. Error messages are to be
  improved later, all together.
