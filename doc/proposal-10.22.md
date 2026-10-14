# Proposal: report 2026-10.22

Three changes that take rules out of the language and the conformance suite. Neither adds a feature.
Nothing in `doc/raz.md` or the code changes until the owner approves
this; it is a thaw of the freeze (CLAUDE.md), so it needs the owner's
word.

## 1. `INT` and `UINT` are names for `I64` and `U64`

**Now.** `INT` and `I64` are two types of one size. An `INT` goes
silently into an `I64`, and the two never mix in an expression
(5.1, 5.10, 6.1). The widening applies to assignment, arguments and
`return n, m`, and not to `a, b := f(x)`, `return f(x)`, `for` or
`INC`/`DEC`. A program that holds an `I64` from a library next to a
length gets `I64 and INT are different types` (`conform/err/IntMix`).

**Proposed.** `INT` is another name for `I64`, and `UINT` for `U64`,
as `type Count = I64;` already is (5.10). A target has 64-bit
addresses (appendix A no longer lets the target choose their size);
no target of this compiler has had any other.

**Report text.**

- 5.1: the table rows become `INT` = `I64` and `UINT` = `U64`. The
  paragraph after the table reads: "`INT` is the everyday integer:
  lengths, indexes and sizes are `INT`s. It is the integer a pointer
  converts to (6.7), and a word the atomic built-ins work on (6.8).
  `INT` is `I64`, `UINT` is `U64`." Drop "`INT` and `I64` are two
  types … which may drop bits on a smaller target" and "A type bigger
  than the largest `INT` in bytes is an error".
- 5.10: drop the last bullet (`INT` to `I64`), and the paragraph's
  "Results passed on whole need the same types exactly … an `INT`
  widens as above".
- 6.1: drop "whatever their sizes", and the example `i < LEN(s)`;
  "Two integer types of different names are one type if one is
  another name for the other" is already 5.10's rule. Drop "On a
  target whose `INT` is narrower, a pointer's offset is cut".
- Appendix A, "The target": drop "the size of an address, and so of
  `INT`".

**What it costs.**

- Every valid program stays valid and means the same. A program
  that had two procedures' types, or two generic instances, told
  apart by `INT` against `I64` now has one type (no such program is
  in `lib/`, `src/`, `examples/` or `tools/`).
- A target with 32-bit addresses is no longer expressible. None is
  planned.
- Messages say `I64` where they said `INT`; `test/msg` changes with
  them.
- `conform/err/IntMix` stops being an error and goes; `test/` gets
  the same for `UINT`. No new tests.

**What it saves.** The compiler's `coerce` and its exact twin, the
list of places that widen and the list that don't, the `INT`/`UINT`
cases in constant folding and the `Results passed on whole` rule: an
estimated 150–250 lines in this compiler, and one rule fewer for
every reader.

## 2. A variable is not exported

**Now.** `var x*: T;` exports `x` read-only: other modules read it but
can't assign it, pass it by `var`, `INC` it, take its `ADR`, slice an
array in it or `match` it in place (3, "Exports"). The rule is one
paragraph and a handful of conditions in every place that names a
variable.

**Proposed.** Only constants, types, procedures and the fields of
records are exported. `*` after a variable's name is an error: "a
variable isn't exported; export a procedure that returns its value".
A module shares state through procedures (`Heap.heap()` for
`Heap.heap`), or a pointer to the data.

**Report text.**

- 3, "Exports": replace the paragraph from "An exported variable can
  be read" to "…or a procedure that returns a slice of it." with "A
  variable can't be exported; a module shares its state by exporting
  procedures that read and change it."
- 5.x and appendix B: `*` is not part of the grammar of a variable's
  name.
- 12: drop "An exported variable can't be changed, passed by `var`
  or …" from 2026-10.x's entry; it describes a rule that is gone.

**What it costs.** This one is real work in what is already written:

- `lib/` has one exported variable, `Heap.heap`. It becomes
  `Heap.allocator()`.
- `src/` has some sixty, most of them the compiler's own state:
  `Scan.tok`, `Scan.ival`, `Chunk.pc`, `Gen.depth`, `Link.textOff`,
  `Diag.errors`, `Sym.tInt` and the like. Each becomes a procedure
  or, for a group, one record the module owns and exports a pointer
  to. The compiler reads `Scan.tok` in its inner loops; each read
  becomes a call (the compiler has no inliner; PLAN.md, "Next"),
  and the compiler's 650,000 lines a second would drop by an amount
  I haven't measured. That is the reason to weigh this change.
- A program that exports a variable no longer compiles. The fix is
  mechanical and the error says it.
- `conform/err/Export{Adr,AsSlice,Assign,Elem,Inc,Slice,VarParam}`,
  `NoteExport` and their `test/msg` twins become one test: that `*`
  on a variable is an error.

**What it saves.** The read-only flag and its checks in `ADR`,
slicing, `var` arguments, `INC`, `NEW`, assignment and `match`, and
the message for each, in every implementation: an estimated 120–200
lines in this compiler, and eight of the 235 error tests.

**An alternative that keeps most of the saving.** Keep exported
variables read-only, as now, and drop only the cases that need a
special rule: no array or record is exported by value (a module
exports a pointer to it, as the report already advises), so
"slice an array in it" and "`match` on a copy" can't arise. That
keeps `Scan.tok` and the compiler's speed, and removes the odd cases,
for about half the saving.

## 3. Conformance covers valid programs only; warnings leave the report

**Now.** `conform/err/` holds 235 programs the report calls errors, and
an implementation passes only if each one fails to compile
(`conform/check.sh`; appendix A: "A program that is an error in this
report is one in every implementation"). Section 10 also tells the
compiler what to warn of (unused names, a dropped result) and defines
`-Werror`.

**Proposed.**

- `conform/` holds `run/` only. An implementation conforms if it
  compiles every valid program there and each runs as the report
  says, with the output and status expected. `conform/err/` and the
  loop that runs it in `check.sh` go; the programs move to `test/err/`
  with their `.err` files, where this compiler's own tests live, and
  `test/msg`'s twins merge with them.
- The report still says what is not valid raz ("is an error"). What an
  implementation does with an invalid program is its own: it should
  say so and stop, as this compiler does, but one that compiles it,
  or compiles it to something else, still conforms. Appendix A's
  "Messages and warnings" line becomes "What it does with a program
  that isn't valid, the text of its messages, and which warnings it
  gives".
- Section 10's "Messages" paragraph, on the form of an error, the 20
  errors, skipping to the next statement and "did you mean", and the
  paragraph on warnings, are moved to `doc/compiler.md` under "This
  compiler's choices". `-Werror` is an option of this compiler's, not
  of the language (it is already a command-line matter, appendix A).
- Failed checks at run time (an index out of range, a nil pointer, a
  division by zero) stay in the report and in `conform/run`: they are
  how a valid program behaves, with status 2 and a message on
  standard error whose text is the implementation's.

**What it costs.** An implementation can no longer be shown to reject
what the report forbids, so a program valid on one compiler may not
be on another; this compiler keeps its diagnostics and its tests, and
that is where portability is held. Nothing changes for a program that
compiles today.

**What it saves.** For another implementation, the whole checker's
rejecting half: it needs to resolve names and types of valid programs,
not to find the fault in an invalid one. In the Ref compiler that
half (every `error_at`, `suggest`, the warning pass, unused-name
tracking and `coerce`'s rejections) is a large share of the 3,000
lines of `expr.c` and `check.c`; I'd put it at a third, but have not
counted. For this compiler nothing is removed by the change itself.

## Order, if approved

1. Report: `doc/raz.md` (the sections above and an entry in 12), the
   grammar in appendix B, `doc/compiler.md` where it names the rules.
2. `conform/` and `test/`: the tests named above.
3. `conform/check.sh` and the move of `conform/err` to `test/err`.
4. The compiler: `src/`, one commit per step as CLAUDE.md says; then
   `make check`, `make fixpoint`, `make bench`.
5. Library and `src/` rewrites for change 2.

Changes 1 and 3 can go alone; change 2 should wait for a measurement of what
the accessors cost the compiler.
