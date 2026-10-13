# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

v0.9.1, the latest release, is tagged by the owner's word. All before
v0.7.1 is approved by the owner; v0.7.1, v0.8.0, v0.9.0 and v0.9.1 wait
for the owner's review. One milestone is under way: Self.

## Self: the compiler in raz (under way)

For: a compiler written in raz that compiles itself, so that raz needs
no Free Pascal. The Pascal compiler in `src/` is the **seed**: it is
never edited for this, and stays the one `make check` builds. The new
compiler lives in `self/`, one raz module to a seed unit, the same
names, and has its own targets; nothing in `src/` or `lib/` changes.

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
5. Fixpoint (done: `self/fixpoint.sh`, `make fixpoint`): the seed builds `self`, that builds `self`, that builds
   `self` again, and the last two are byte for byte the same (all
   three are, 547,000 bytes: the seed and this compiler make the same
   code from `self/`). `make check` passes on the compiler it made,
   661 tests, and `make bench` gives 493,000 to 870,000 lines a second.
   Then the seed's last tag is the bootstrap, and the split of `src/` from
   the rest is the owner's to decide.

Done when step 5 passes with `make check` and `make bench` on the
compiler it made, and the budget of lines kept.

## Next, when the owner says

- The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
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
