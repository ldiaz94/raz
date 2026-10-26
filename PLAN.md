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

## 2. The safety thaw: v0.23.0, then v0.24.0

The scope, by the owner's word of 2026-10-26, after reviewing
`MEM_PROPOSAL.md` whole with its appendices. raz doesn't promise memory
safety: `free` stays, so a program can always keep a pointer to what
it freed. The thaw shrinks what is undefined, and fences what can reach
memory it shouldn't, so a reader can find it.

What goes in:

- **An array a call returns lives to the end of its procedure**
  ("Less that is undefined", piece 1; the proposal's F.1). Its slot is
  reserved as a deferred statement's is.
- **A race tears no slice, said**: 7.6 says a slice or variant read and
  written in a race is undefined (piece 3). Said, not prevented: no
  16-byte moves.
- **`[]const T`**, a slice whose elements can't be written; a `[]T`
  goes where one is wanted, never back. String literals are `[]const
  U8`, and a constant's slices `[]const T`, so writing them is an error
  (piece 2 drops out). `Str.trim`, `cut` and `field` take and return
  `[]const U8`. "Left out"'s exported array read as a slice comes with
  it.
- **The fence, Oberon's way**: the unsafe operations are reached
  through a pseudo-module, `import SYSTEM`. `SYSTEM.ADR`, `SYSTEM.PTR`,
  `SYSTEM.SYSCALL`, `SYSTEM.ARGV`; pointer indexing, slicing and
  arithmetic, conversions to and from pointer and procedure types,
  views whose type holds a pointer, procedure or slice, `extern`,
  `link`, code procedures and `check off` are allowed only in a module
  that imports it. A warning for one release, so that `src/` can come
  to it once `BOOT` knows it, then an error.
- **`CAS`, `XCHG` and `XADD` take a variable**, as `INC` does, not an
  address (the proposal's E.4), so atomics need no `SYSTEM`.
- **Library**: `Heap`'s debugging mode (G: freed blocks poisoned and
  held back, guard bytes checked); `Task(T)`, a thread started with no
  cast; `Lock.Guarded(T)`, a value with its lock.

What is left out, and why: `ret` and `keep` (B) and owners that count
what they lend (C), too large for what they close without the rest;
the heap without `free` (D), since `free` stays; atomic slices and the
rest of threads (E), for programs that race only. With them the
guarantee of the proposal's section 3.

The survey of 2026-10-26 (the compiler counting each use, across
`~/r`): about 8,000 fenced uses, 451 of 960 modules. 77% of the `ADR`s
go to a pointer parameter only dereferenced, mended by `var` or
`const`, as `STANDARDS.md` asks; what is left for `SYSTEM` is about
3,000 uses, most in `lib/` (`Sys`, `Rt`, `Heap`, `Map`) and `src/`
(`Scan`, `Link`, `Chunk`). All 31 atomics take `ADR`.

Two releases, by the owner's word of 2026-10-26, since `src/` and the
library it imports (`Buf`, `Files`, `Fmt`, `Heap`, `Mem`, `Out`, `Rt`,
`Str`, `Sys`, and `Lock` and `Bytes` under them) must build with
`BOOT`, which knows neither `[]const` nor `SYSTEM`:

1. The report's text, for the owner to review (drafted 2026-10-26).
2. **v0.23.0, which breaks nothing.** The compiler, a commit a piece,
   each with its part of the report: an array a call returns kept to
   the end of its procedure; atomics on a variable; `[]const T`;
   `SYSTEM`. The old forms are still taken, silently: a string literal
   into a `[]U8`, `ADR` and the rest without `SYSTEM`, an atomic given
   a pointer. The library: `Task`, `Guarded`, `Heap`'s debugging mode.
   Release, and the report's pages checked. **Done** 2026-10-26:
   tagged, released here by `make dist` (CI refused by GitHub's billing,
   as for v0.22.0), its SHA-256 `103eb421...`; the website has v0.22.0
   and v0.23.0; 35 pages. No rewriting tool, by the owner's word:
   v0.24.0's errors point at each place to mend.
3. `BOOT` moved to v0.23.0, a step of its own. **Done** 2026-10-26.
4. **v0.24.0, which enforces it.** Steps 1 to 3 done 2026-10-26: `raz -strict`
   first, `lib/`, `src/`, the tools and tests mended against it by
   agents, then the old forms made errors and the option gone. `lib/`, `src/`, `tools/`,
   `examples/` and the tests mended where the old forms, made errors,
   are found (`ADR` at a parameter only dereferenced becomes `var` or
   `const`; `SYSTEM.` where an address is kept); the programs in `~/r`
   mended the same way, by agents, each its own commit.
   Release.

## 3. The Moss work: v0.25.0

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

From v0.25.0 on: no more thaws. The language changes only to mend a
defect; the library's core (appendix A) only to mend a defect or plug a
very big gap; the rest of the library grows only conservatively, by
what breaks no program, on the owner's word.

## 5. Clean-up: v0.26.0, the last before 1.0

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

No date. raz is 1.0 when use shows it: programs written against v0.26.0
for long enough that no defect is outstanding. Until then it is
0.26.x, mending defects only.
