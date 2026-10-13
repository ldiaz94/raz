# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

Better code for reals is under way, by the owner's word. v0.7.1, the
manual, and v0.8.0, better code again, are tagged; all before v0.7.1
is approved by the owner, and v0.7.1 and v0.8.0 wait for the owner's
review.

## Now: better code for reals

For: code with reals near FPC `-O2`'s, as integer code is. raz keeps a
real in an integer register and copies it to xmm0 or xmm1 and back
for each operation; its variables are always in memory. A 2-D Jacobi
sweep took 3.1 times FPC's time. No change to the language. Each step
is measured on the kernels and on rat, as v0.8.0's were, and one that
buys less than 2% on both is reverted and noted here.

1. Done: **Two kernels of reals.** `test/bench/Jacobi`, a sweep of a
   grid of `F64`s, each point the mean of its neighbours: loads, adds
   and a constant; and `NBody`, bodies under gravity: real variables,
   a square root and a division in the inner loop. raz 3.1 and 4.4
   times FPC's time.
2. **Reals on the stack in xmm registers.** A real on the value stack
   is held in xmm8 to xmm11, loaded and stored there with `movsd`, a
   constant read from read-only data, and an operation takes its right
   operand from memory as it is.
3. **Real variables in xmm registers**, where that pays: measured, and
   kept only if it does.

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
