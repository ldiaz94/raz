# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

v0.9.1, the latest release, is tagged by the owner's word. All before
v0.7.1 is approved by the owner; v0.7.1, v0.8.0, v0.9.0 and v0.9.1 wait
for the owner's review. No milestone is under way.

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
