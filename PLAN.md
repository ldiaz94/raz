# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's history, `doc/report-history.md`, the language's.

v0.11.1, report 2026-10.23, is the latest release. All before v0.7.1
is approved by the owner; v0.7.1, v0.8.0, v0.9.0 and v0.9.1 wait for
the owner's review. No milestone is under way: the last, Self (the
compiler in raz, built by itself), is done, and `seed/` is frozen.

## Next, when the owner says

- The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
- The compiler's last 0.1 of the 1.3: an inliner for the small procedures
  that are one expression (`Gen.drop`, `X64.mem`, `Chunk.put1`, `Scan.tokPos`)
  would take call overhead off some 15% of the instructions; `chooseRegs`
  reads each procedure twice, which is 13% of the time; and `Mem`, `Item`
  and `Adr` are records copied at each call that passes them on.
- A port to aarch64, to measure one: a new `Gen.raz`, an encoder and
  assembler for it, and its ELF.

## Wishes, for a later thaw

What the language or the library might have, met while writing raz;
none is built while the freeze holds.

- **`inline`, a hint** (dropped, 2026-10.13): a hint means nothing a
  program can see, and this compiler can inline by itself, with no
  keyword. Measured: `test/bench/Grep` with its helpers inlined by hand
  ran 30% faster; rat's hot procedures gained nothing from it, but 12%
  from hoisting two fast paths by hand (`Width.cells`,
  `Screen.unsplit`), which is an inliner several times the size. Revisit
  only if more programs show it.
- **A `const` parameter.** `proc what(const x: Item): []U8;`: the callee
  may not change `x` (nor take its address), so the caller may pass the
  address of a record or array without a copy, and the program means the
  same. Met in Self step 3b, where the seed's `const x: TItem` (about 130
  bytes) became a value parameter, copied at every call. Measured in Self
  step 4: not what stands out, the compiler's profile is flat
  (`Scan.tokPos` is 9%).
