# raz: the plan to 1.0

What is left before raz is 1.0, in order, by the owner's word of
2026-10-23. `PROPOSALS.md` takes nothing new; what it still holds open is
the safety thaw and the Moss work below, and nothing else is planned.
Each step is a release, started on the owner's go-ahead; within it, one
commit per piece, the report first for any change to the language.

## 1. Release what is done: v0.22.0

**Done** 2026-10-23: tagged, its release and tarball made here by `make
dist` (CI was refused by GitHub's billing), and `BOOT` moved to it.
`make alpine` couldn't pull its image without a Docker Hub login.

Report 2026-10.36, the twelfth thaw: `MIN`, `MAX`, `ABS`, `CLZ`, `CTZ`,
`POPCOUNT`, `INT(b)`, `OFFSET`, `SIZE(T.f)`, `BYTES`, `FILL`, a qualified
case in an arm, slice and `ERROR` constants, a record's procedure field
that takes the record; the library's growth since v0.21.0 (`Fmt`, `Str`,
`Files`, `Sys`, `Math`, `Opt`, `Heap.sure`, `Vec`, `Arena`); inlining a
procedure that only returns, and `COPY`, `FILL` and array parameters made
fast.

- Check: `make check`, `make fixpoint`, `make bench`, `make prev-bench`,
  `make kernels`, `make alpine`, the report's pages (35 at 10.36).
- Tag `v0.22.0`; then, as a step of its own, move `BOOT` to it, so that
  `src/` and the library it imports may use what 10.36 brought.

## 2. The safety thaw: v0.23.0

From `MEM_PROPOSAL.md`, with "Less that is undefined", "A slice that
can't be written: `[]const T`", "What a call does with its arguments"
(its part 3, `ret` and `keep`), and "Left out"'s exported array read as
a slice.

1. The owner chooses the scope. The proposal's parts stand alone:
   A, the fence (`unsafe;`, which modules may reach memory they
   shouldn't); B, lending (`ret` and `keep`, the returned-slice hole
   closed); C, owners that count what they lend. Appendices 4 to 7 find
   holes in its body, and C is much the largest. A then B, each a step
   of its own, is the smaller way.
2. The body of what is chosen is revised against its appendices.
3. The report's text, for the owner to review; then the compiler, the
   library, and the programs in `~/r` it breaks, each mended.
4. Release, and the report's pages checked.

## 3. The Moss work: v0.24.0

1. Merge the branch `moss-platform-boundary`'s two plain fixes (a file's
   identity from `Sys.info`; a main file at the root), rebased on main.
2. `Host`, as "The compiler on another host" in `PROPOSALS.md` asks:
   five procedures, `Files.argCount`, a host chosen by staging, its tests
   in `sh`, not Python; rebased and merged. Moss's `RAZ_PORT.lock` then
   pins main.
3. What the compiler asks of `Sys`, `Rt` and `Files`, written down in
   `doc/compiler.md` and held by a test.
4. "A freestanding program, stated", "The assembler's instructions" and
   "Implementation limits, and a compiler for a small stack".
5. Release.

## 4. The hard freeze

From v0.24.0 on: no more thaws. The language changes only to mend a
defect; the library's core (appendix A) only to mend a defect or plug a
very big gap; the rest of the library grows only conservatively, by
what breaks no program, on the owner's word.

## 5. Clean-up: v0.25.0, the last before 1.0

The files that served the thaws are made a record, short and true:

- `PROPOSALS.md` and `MEM_PROPOSAL.md`: what was built is in the report,
  `doc/report-history.md` and git; each shrinks to a short index of what
  was decided, and what was left out with its reason, or goes.
- `~/r/RAZ-GAPS.md` and each repository's `RAZ-NOTES.md` (or `RAZ.md`):
  closed, each saying so at its top; a gap since mended is marked.
- `CLAUDE.md` (raz's and `~/r`'s): "Where things stand" cut to the
  present; the readings of the report checked one by one against the
  compiler and the report, and folded into the report where they are
  the language's, not this compiler's.
- `doc/compiler.md`'s table and routine names, `README.md`,
  `doc/raz-lib.md` and the man pages checked against the code;
  `STANDARDS.md` against the library.
- The programs in `~/r` that pin an older raz (rmacs, ravite, rnet, ...)
  moved to the release.

## 6. 1.0

No date. raz is 1.0 when use shows it: programs written against v0.25.0
for long enough that no defect is outstanding. Until then it is
0.25.x, mending defects only.
