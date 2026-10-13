# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

v0.9.0, better code for reals, with `Bytes` and slices in code
procedures (reports 2026-10.18 and 10.19), is tagged by the owner's
word. All before v0.7.1 is approved by the owner; v0.7.1, the
manual, v0.8.0, better code again, and v0.9.0 wait for the owner's
review. v0.9.1, by the owner's word, adds `tools/` to the tarball,
for the programs that build with the raz on PATH: rat, rterm, rloc.

## Done: better code for reals

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
2. Done: **Reals on the stack in xmm registers.** A real on the value
   stack is held in xmm8 to xmm11, loaded and stored there with
   `movsd`, a constant read from read-only data, and an operation takes
   its right operand from memory as it is. Jacobi 251 ms to 129, NBody
   375 to 225; rat within noise.
3. Done: **An element of an array as the machine has it.** NBody's
   time went mostly to its addresses, not its reals: `x[i]`, of an
   array of the module, was a copy, a shift, a `lea` and an add before
   its load. Now an element of an array in the frame or a chunk is the
   operand `[base + i * 8]`, as one of a slice in registers is. NBody
   225 ms to 147; rat within noise.
4. Done: **An offset as the machine has it.** Jacobi's index
   arithmetic, `s[i * N + j - 1]`, added its constant before the load;
   now a word's constant offset waits on the stack, carried through
   `+`, `-` and `*` by a constant, and an element's operand takes it as
   its displacement: `[r13 + r9 * 8 - 8]`. Jacobi 129 ms to 106; rat
   within noise.
5. Done: **Real variables in xmm registers.** The busiest four reals
   of a procedure live in xmm12 to xmm15, each written through to its
   slot, from which the trap report reads it and a call's return loads
   it, as System V keeps no xmm register through a call. NBody 147 ms
   to 116; rat within noise.

All told: Jacobi 3.1 times FPC `-O2`'s time to 1.3, NBody 4.4 to 1.4;
rat and the integer kernels as they were; 9,131 lines of code. Left:
Jacobi's index, worked out for each element where FPC shares it, which
one pass can't; NBody's call to `Math.sqrt`, an instruction to FPC;
a comparison of reals that jumps without making a `BOOL`, which
neither kernel needs.

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
