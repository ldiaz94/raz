# Proposal: report 2026-10.22

Made from an audit of `doc/raz.md` against `conform/` and `test/`
(about 500 rules: ~260 pinned by `conform/`, ~130 only by `test/`, ~60
by no test, ~25 unsettled or in conflict). It mends defects in the
report and trims it; it adds no feature. Nothing in `doc/raz.md` or the
code changes until the owner approves each part (CLAUDE.md: a thaw).

Decided by the owner (2026-10-14):

- `INT` and `UINT` stay distinct from `I64` and `U64`. (The first
  version of this proposal made them aliases; dropped.)
- Exported variables stay as they are. (The first version banned them;
  dropped. Exported constants stay on `PLAN.md`'s wishes list.)
- Conformance keeps the error programs, but only for errors that
  change a program's meaning; warnings and the form of messages leave
  the report.
- Every run-time stop exits with status 2.
- The library past the core leaves `conform/`.
- The report is split in two volumes, after the fixes.

## 1. What is an error, and what is free

**Now.** Section 10 tells the compiler what to say (the form of a
message, "up to 20" errors, skipping to the next statement, "did you
mean", which warnings, `-Werror`), and Appendix A says all of that is
the implementation's. The two contradict.

**Proposed.**

- Section 10's "Messages" and warnings paragraphs move to
  `doc/compiler.md`, "This compiler's choices". `-Werror` is this
  compiler's option. Appendix A's line becomes "the text and number of
  its messages, and which warnings it gives".
- The report states the rule once: an implementation must reject a
  program that is an error because accepting it would give it a
  meaning the report cannot define: a type error, an undefined or
  repeated name, an assignment to what is read-only, a missing or
  wrong `main`, a cycle of modules. A fault that is only a lint (an
  unused name, a dropped result) is not an error of the language.
- `conform/err` is sorted by that rule: what is a language error stays
  and is judged by status alone; a lint-like test moves to `test/err`.

**Costs.** A pass over the 235 error tests. Nothing for a valid program.

## 2. Run-time stops exit with status 2

**Now.** A failed check exits with status 2 (6.8, `Rt.stop`); a nil
pointer, division by zero or stack overflow stops the program "on
every target", and this compiler dies by the signal (139, 136), so
`conform/` cannot pin it.

**Proposed.** Section 10: any stop of a running program (a failed
check, a nil pointer, a division by zero, a stack overflow) says why on
standard error, whose text is free, and exits with status 2. The
compiler's handlers (`Rt`) end the program with status 2 rather than by
the signal; `conform/` gets a program for each.

**Costs.** `Rt`'s handlers and the tests that expect 139/136 (`test/`);
a stack overflow in a C thread still ends by the signal (no handler
stack there, CLAUDE.md).

## 3. Readings the report doesn't have

CLAUDE.md lists readings the compiler took where the report is silent.
They go into the report, short, or the compiler changes:

- 5.10 and 6.1: where `INT` widens to `I64` (assignment, argument,
  `return a, b`) and where it does not (`a, b := f(x)`, `return f(x)`,
  `for`, `INC`/`DEC`); an untyped constant converts to a pointer.
- 3: another module's exported variable is read-only: an array or
  record in it cannot be sliced or `match`ed in place.
- 2: the non-reserved words are `static`, `check` and `off` (the
  report says only `static` in one place).
- 7.4: which types `match` takes; `lo .. hi` with `lo > hi` is an
  error; `defer defer f` is an error ("that would leave it" says less).
- 10: `main` takes no parameters.
- 6.1: the type of a shift whose left operand is an untyped constant.
- 2: a real constant of type `F32` is the nearest `F32` (the compiler
  rounds twice, through `F64`: it follows the report or the report
  says so).

## 4. The library core, and the second volume

Appendix A's core is `Rt`, `Out`, `Mem`, `Arena`, `Lock`, `Str` and
`Buf`. `conform/run` imports `Heap`, `Fmt`, `List`, `Map` and `Sort`
too. The five leave `conform/` (their tests go to `test/`; each
module's own `main` stays its test). The report still defines them.

## 5. Trimming

To `doc/compiler.md`, or out: the "Separate compilation" paragraph and
its twin in Appendix A, the executable and gdb sentences, the NASM
bullet (kept short), the library table that repeats the listings,
`Heap`'s nine sizes, the 64-descriptor and 107-byte numbers, `Sort`'s
complexity claim, `Sys.rawMode`'s key list, and the version history of
section 12 (a changelog, not the language). Whether `Opt` stays in
the report or only in `raz-lib(3)` is open.

## 6. Two volumes

After 1-5: volume one is sections 1-10, the core library, the grammar
and Appendix A; volume two is the rest of the library. `tools/Doc.raz`,
`make check`'s example runs and `README.md` follow the files.

## Tests to add (conform/)

From the audit's NONE rows that the report fixes: zero initial values
per kind, order of evaluation, a variant `match` that runs, generic
instances run once, a `defer` not reached doesn't run, a failed check
skips pending defers, `Sys.exit` skips `atExit`, `Str`'s byte-order
procedures (core), and the run-time stops of 2.

## Order, if approved

1. Report 1, 2, 3 and 5, in `doc/raz.md` and `doc/compiler.md`: one commit each; stop for review.
2. `conform/` and `test/`: the sorting of 1, the moves of 4, the tests above.
3. The compiler: `Rt`'s status (2), the readings that change code.
4. The split (6).
