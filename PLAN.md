# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

No milestone is under way. v0.7.1, the manual, and v0.8.0, better code
again, are tagged, by the owner's word to finish both; all before
v0.7.1 is approved by the owner, and v0.7.1 and v0.8.0 wait for the owner's
review. Next comes what the owner chooses, of the list below.

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
  Open: where gdb and a failure place a line inside an inlined
  procedure, the callee's or the caller's.
