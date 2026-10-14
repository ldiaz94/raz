# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's history, `doc/report-history.md`, the language's.

v0.11.1, report 2026-10.23 (`Math` exports `bits`, `fromBits` and `mul`), is the latest release; v0.11.0, report 2026-10.22, was the audit of `doc/proposal-10.22.md`; v0.9.1 was the last built by the seed. All before
v0.7.1 is approved by the owner; v0.7.1, v0.8.0, v0.9.0 and v0.9.1 wait
for the owner's review. One milestone is under way: Self.

## Self: the compiler in raz (under way)

For: a compiler written in raz that compiles itself, so that raz needs
no Free Pascal. The Pascal compiler in `seed/` is the **seed**: it is
never edited for this, and stays the one `make check` builds. The new
compiler lives in `src/`, one raz module to a seed unit, the same
names, and has its own targets; nothing in `seed/` or `lib/` changes.

The language gained `try` (report 2026-10.20) for this: the parser's
errors return an `ERROR` (`Scan.Failed`) that `try` passes up to where
it reads on, in place of the seed's `longjmp`.

Each unit is ported in the seed's order (leaves first) and tested on
its own against the seed's, on the same inputs, since no program can
link both. The language and the library are frozen: a gap found goes
on the wish list, a defect is mended.

Steps:

1. `diag` and `scan` (done): the trial. Measure `scan`'s speed against the
   seed's and list what `Sys` and the library lacked. Stop for review:
   if the cost is too high, mend the code generator first.
2. `chunk`, `sym` (2a, done); `link`, `elf`, `x64` (2b, done).
3. `gen` (3a, done: `Gen.raz`, tested by `test/GenDump`, a script of
   calls whose bytes and listing are the same), `item` (3b, done: `Item.raz`, tested by
   `test/ItemDump`, 60 scripts of operations with mistakes in them).
4. `parse`, `raz` (done: `Parse.raz`, `Raz.raz`): the first compiler that
   builds, tested by compiling 409 programs, the library and the compiler
   itself with both and comparing the executables, messages and status;
   452,000 lines a second, the seed's 815,000.
5. Fixpoint (done: `src/fixpoint.sh`, `make fixpoint`): the seed builds `src`, that builds `src`, that builds
   `src` again, and the last two are byte for byte the same (all
   three are, 547,000 bytes: the seed and this compiler make the same
   code from `src/`). `make check` passes on the compiler it made,
   661 tests, and `make bench` gives 493,000 to 870,000 lines a second.
   Then `seed/` is frozen and `self/` is `src/` (the owner's word,
   2026-10-13); the seed is dropped in time, its last tag the bootstrap.

6. Faster (done, the owner's word, 2026-10-13: the compiler built by
   itself took 1.8 times as long as the Pascal one, and 1.3 was the aim).
   `perf` found no hot spot but habits of the code: small blocks cleared
   and copied by `rep`, a record literal made in a temporary and copied,
   an element through a pointer worked out, `try` through a slot of the
   frame, a `var` parameter's address loaded at each use, and a few
   routines of the scanner. `doc/compiler.md`, "Better code, for the
   compiler itself", has each, with what it measured and what did not
   help. The compiler takes 506 ms of 359 for the 348,025-line program,
   1.4 times (1.36 by cycles; before 657 of 359, 1.8 times); `make
   bench`, 678,000 lines a second. The seed's code is no longer what
   `src/` makes, so `seed-check` no longer compares `Gen`, `Item` or
   the executables, only messages and statuses, and the fixpoint is of
   stage 2 and 3.

Done when step 5 passes with `make check` and `make bench` on the
compiler it made, and the budget of lines kept.

## Next, when the owner says

- The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
- The compiler's last 0.1 of the 1.3: an inliner for the small procedures
  that are one expression (`Gen.drop`, `X64.mem`, `Chunk.put1`, `Scan.tokPos`)
  would take call overhead off some 15% of the instructions; `chooseRegs`
  reads each procedure twice, which is 13% of the time; and `Mem`, `Item`
  and `Adr` are records copied at each call that passes them on.
- A port to aarch64, to measure one: a new `gen.pas`, an encoder and
  assembler for it, and its ELF.

## Wishes, for a later thaw

What the language or the library might have, met while writing raz;
none is built while the freeze holds.

- **`inline`, a hint.** `proc zeros(v: U64): U64; inline;`, placed as
  `forward` is: the compiler copies the procedure into each call
  instead of calling it. A hint an implementation may ignore, so a
  program means the same everywhere and `conform/` is untouched. This
  compiler would take it for a procedure whose body is a single
  `return e`, with value parameters, in the same module, and refuse
  the mark on any other: the call site's arguments go to temporaries
  and `e` is read again there (`SaveScan`/`RestoreScan`, as for
  generic instances), its parameters bound to them. About 100 lines.
  Measured (2026-10-13): `test/bench/Grep` with its two helpers
  inlined by hand ran 188 ms against 250, 30% off the kernel's own
  time, since the loop's values then stay in registers, not the
  frame; FPC `-O2` with `inline` gains as much. `tools/Pretty` gained
  nothing: its small procedures cost their work, not their calls.
  Dropped as a language change (2026-10-13): a hint means nothing a
  program can see, and this compiler can inline by itself, with no
  keyword. Debugging would be settled by keeping the callee's lines
  in the line table as rows that aren't statements (DWARF's
  `is_stmt`): gdb steps over them, `Rt` still tells a failure at its
  expression; only `Rt.trace` loses the callee's frame.
  Measured on rat's 26 MB workload (477 ms): its hot procedures are
  almost never a single `return e`, and inlining those by hand gained
  nothing. What did gain, 12%, was hoisting the fast path of two small
  procedures into their callers by hand: `Width.cells` (`if c < 300H
  then return 1`) and `Screen.unsplit` (a guard, then rare work),
  called for every character. An inliner for that, statements and
  early returns and procedures without results, is several times the
  size; the same 12% is a few lines in rat. Revisit only if more
  programs show it.
- **A `const` parameter.** `proc what(const x: Item): []U8;`: the callee
  may not change `x` (nor take its address), so the caller may pass the
  address of a record or array without a copy, and the program means the
  same. Met in Self step 3b, where the seed's `const x: TItem` (about 130
  bytes) became a value parameter, copied at every call. Measured in Self
  step 4: not what stands out, the compiler's profile is flat
  (`Scan.tokPos` is 9%).
