# raz: the plan to 1.0

What is left before raz is 1.0, in order, by the owner's word of
2026-10-23. raz takes no proposals; what is left is the Moss work below,
its proposals kept in the appendix, and nothing else is planned.
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
`MEM_PROPOSAL.md` (in git to 2026-10-26) whole with its appendices.
raz doesn't promise memory safety: `free` stays, so a program can
always keep a pointer to what it freed. The thaw shrinks what is
undefined, and fences what can reach memory it shouldn't, so a reader
can find it.

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
   agents, then the old forms made errors and the option gone.
   Released 2026-10-26 as v0.24.0; the programs in `~/r` follow, the
   owner's five first (dwa, concha, mosaico, rat, notis). `lib/`, `src/`, `tools/`,
   `examples/` and the tests mended where the old forms, made errors,
   are found (`ADR` at a parameter only dereferenced becomes `var` or
   `const`; `SYSTEM.` where an address is kept); the programs in `~/r`
   mended the same way, by agents, each its own commit.
   Release.

## 3. The Moss work: v0.25.0

The scope, by the owner's word of 2026-10-26: what makes raz a better
freestanding and portable compiler, nothing for Moss alone. `Host` is
in. `-moss` (the branch `moss-startup-args-v1`) is not: Moss supplies
its own start under item 4's contract, so raz knows no system's calls
but Linux's. Of the implementation limits, the report's least and this
compiler's errors past its own are in; compiling imports from the
leaves and queuing instances, so the compiler fits a small stack, are
dropped for good: Moss gives the compiler a larger stack instead.
Report 2026-10.38 (993cd63) holds the language's part.

1. Merge the branch `moss-platform-boundary`'s two plain fixes (a file's
   identity from `Sys.info`; a main file at the root), rebased on main.
2. `Host`, as "The compiler on another host" in the appendix asks:
   five procedures, `Files.argCount`, a host chosen by staging, its tests
   in `sh`, not Python; rebased and merged. Moss's `RAZ_PORT.lock` then
   pins main.
3. What the compiler asks of `Sys`, `Rt` and `Files`, written down in
   `doc/compiler.md` and held by a test.
4. "A freestanding program, stated", "The assembler's instructions" and
   "Implementation limits, and a compiler for a small stack" (the
   report's least and the errors only), in the appendix.
5. Release. Done 2026-10-26: v0.25.0, report 2026-10.38.

## 4. The hard freeze

From v0.25.0 on: no more thaws. The language changes only to mend a
defect; the library's core (appendix A) only to mend a defect or plug a
very big gap; the rest of the library grows only conservatively, by
what breaks no program, on the owner's word.

v0.25.1, 2026-10-29, the report unchanged, on the owner's word:

- `Sys.errReadOnly* = -30` (EROFS), beside `errNoSpace` in `lib/Sys.raz`
  and `lib/Sys.linux-x86_64.raz`, and in `doc/raz-lib.md`'s list. It is
  the standard library's part of `Sys`, not the core, and a new name
  breaks no program. Done. arkusz's `Asheetio` names it for itself
  (`ReadOnlyFs`) and may now take `Sys.errReadOnly`.
- `raz -q check` and `raz -q words`, for an editor's language server
  (raz-lsp, `~/r/raz-lsp`): the compiler, not the language. Done.

v0.25.2, 2026-10-29, the report unchanged: `raz -q def`, where the name
at the cursor is declared, for raz-lsp's hover and go to definition.
v0.25.3, 2026-10-29: `raz -q def` on a module, used or imported, gives
its `module` line.

## 5. arm64 macOS: v0.26.0

Started by the owner's word of 2026-11-15: raz on an Apple Silicon Mac,
natively, as a second target, `darwin-arm64`. Report 2026-11.0 names
it and changes no language (section 3, appendix A).

**The shape.** `Gen` is the only unit that knows the machine, and
`Exe` (`Exe.linux.raz`, once `Elf`) the only one that knows the executable, so the port is new
units beside them, not a change to `Parse` or `Item`:

- `A64.raz`, beside `X64.raz`: arm64's instructions encoded, branches
  within a procedure, and the assembler for code procedures (Arm's
  syntax, the instructions the library's code procedures use; `db` for
  any other).
- `Gen.arm64.raz`, beside `Gen.x86_64.raz`: the same
  calls, the stack machine kept in arm64's registers; Apple's calling
  convention (x18 never touched, a frame record in x29, the arguments
  past a variadic C procedure's own on the stack); every address by
  `adrp` and `add`, since macOS runs no executable at a fixed address;
  the atomics by the LSE instructions every Apple processor has.
  Two things x86 does for free and arm64 doesn't, which the report
  binds: a division by zero, or the smallest value by -1, stops the
  program (arm64's `sdiv` gives 0), so it is checked; a real out of an
  `I64`'s range, or a NaN, gives the smallest `I64` (arm64's `fcvtzs`
  saturates), so it is mended after.
- `Exe.darwin.raz`, beside `Exe.linux.raz`: a Mach-O executable for dyld, linked
  to libSystem, as every macOS program must be; C's symbols bound into
  a table of quadwords, as GLOB_DAT does now; every address in data
  rebased, since the program is position-independent; its symbol table
  for lldb's backtraces; and an ad-hoc code signature, SHA-256 hashes
  of its pages, without which arm64 macOS won't run it; and line
  numbers for lldb, as DWARF in `__DWARF` (below).
- `Host.darwin.raz`: the library beside the compiler by
  `_NSGetExecutablePath`, C always, a program run from a file written
  and made executable (no `memfd_create`).
- `Link`: the places in data that hold an address, listed for
  `Exe.darwin.raz`'s rebasing.

A compiler compiles for the system it runs on, as now: its target is
the one it was built for, its back end and executable chosen at its
build by the target's suffixes (section 3), `Gen.arm64.raz` and
`Host.darwin.raz` as `Sys.linux-x86_64.raz` is today. No `-target`.
A compiler for one system that runs on another is built by staging,
as appendix (b) proposes for Moss: `src/cross.sh` copies `src/` with
the other target's files in place. It is needed once, for the first
Mac compiler, and wherever a release for one system is made on the
other.

**The library.** Over libSystem, through `lib/Sys.raz`, the C one,
with `CAbi.darwin-arm64.raz` made by `tools/cabi.c` on the Mac, never
by hand. `Rt.darwin-arm64.raz`: the signals and their own stack, the
place a fault stopped at from the Mac's `ucontext`, and `framePtr`,
`liveRegs`, `here` and `sigReturn` in arm64. `Thread.darwin.raz` over
pthreads, its `Mutex` on `os_unfair_lock`. `Bytes.arm64.raz`. `Math`'s
`sqrt`, `mul` and `div128` and `Str`'s code procedure move into
`.x86_64` files with arm64 twins: no generic file keeps machine code.
None of it breaks a program.

**Steps**, one commit each, `make check` passing first (in a
linux/amd64 container on the Mac until there is a Mac compiler):

1. Report 2026-11.0, for the owner's review. (This commit.)
2. Done. A container to build and check in on the Mac (`make docker-check`),
   the budget raised to 18,000 in `CLAUDE.md` and `doc/compiler.md`,
   and the Makefile and scripts made to run on BSD's tools as on GNU's
   (`sed -i`, `stat`, `sha256sum`).
3. Done. `Gen.raz` to `Gen.x86_64.raz`, `Elf.raz` to `Exe.linux.raz` (the
   unit `Exe`), `Host.raz` to `Host.linux.raz`, `src/cross.sh`: what
   Linux's compiler makes unchanged, byte for byte.
4. Done. `A64.raz`: arm64's encoder, jumps within a procedure, and
   the assembler in Arm's syntax (`bl p`, `b p`, `adr xN, v` for names),
   checked against Apple's assembler (clang's, `llvm-mc`'s bytes) by
   `test/a64`; Chunk's arm64 fixup kinds, `fxBranch26`, `fxPage21` and
   `fxPageOff12`, and `Scan.setBang` for a pre-index's `!`. What it
   left for later, `Link`'s patching of those kinds, `Gen.arm64.raz`
   importing `A64`, and padding with `brk`, came with 5a.
5. `Gen.arm64.raz`, in pieces, each run on the Mac (owner, 2026-11-15):
   first a bare `Exe.darwin.raz` (a signed Mach-O over libSystem, no line
   numbers) and an `Rt` that only exits, built by the staged cross
   compiler in the container; then values and operations; jumps and
   checks; calls and frames; reals; atomics, deferred statements, the
   entry point.

   5a, done: programs made by the cross compiler (`src/cross.sh
   darwin-arm64`) run on the Mac, `test/mac` by `make mac-check`. In
   `Gen.arm64.raz`: frames, constants, variables, the integer
   operations but division, comparisons and jumps, elements and slices
   unchecked, calls with arguments in registers, C's calls, code
   procedures and the entry point; every other routine notes "not yet
   on arm64" on its procedure, an error if the program uses it.
   `Exe.darwin.raz`: a signed Mach-O over libSystem, its rebases and
   binds dyld's opcodes, no line numbers. `Link`: arm64's fixups, Mach-O's
   paged layout, the rebases. `lib/Rt.darwin-arm64.raz`: exit through C's
   exit, one procedure at exit, fail and stop by `write`. As the interface
   check of `Rt` reads `Rt.raz`, and so compiles `Sys` over C, also
   `lib/CAbi.darwin-arm64.raz`, from `tools/cabi.c` on the Mac, and a
   code procedure skipped in a file read only for its interface.

   5b, done: division and its checks (by zero, the smallest by -1, in
   every width), the checks of indexes, slices, views and enumerations
   with their stubs for `Rt.fail`, arguments past x7 on the stack,
   results in memory through x8, Apple's variadic calls, `try`, deferred
   statements, jump tables, `compareSeq`, copies past 256 bytes, `ABS`
   of an integer; and, since `Out` needs them, the atomics and `COPY`.
   `SYSTEM.SYSCALL` is an error on the Mac, Linux's only (report 6.8).
   `lib/Rt.darwin-arm64.raz` says what failed with its values, by its
   address, runs 32 procedures at exit, and tells a nil pointer or
   procedure and a stack overflow by a handler of SIGSEGV and SIGBUS.
   `make mac-check` runs conform/run too and counts it: 91 of 111 pass,
   the others needing reals (13), `FILL` (4, `Heap`'s among them),
   `CLZ`, `ROL`, or `SYSCALL` (`SystemImport`, Linux's only). Left of
   step 5 (5c): the reals, `FILL`, `NEW`'s zeroing, the counts of bits
   and the rotations.
6. `Exe.darwin.raz`'s line numbers for lldb (its rebases came with
   5a); `Host.darwin.raz`.
7. The library: `CAbi`, `Sys`, `Rt`, `Thread`, `Bytes`, `Math`, `Str`.
8. `test/` and `conform/` passing on the Mac; what differs by target
   (signals' words, errors' numbers) in files of the target's.
9. The first Mac compiler, by the staged cross compiler; it builds
   itself; `make fixpoint` on the Mac; `make bench` at 400,000 lines a
   second there.
10. The release: two tarballs, `linux-x86_64` and `darwin-arm64`;
    `BOOT` names one for each host, with its sum.

**The owner's answers**, 2026-11-15:

a. The budget is 18,000 lines of code.
b. The names are `darwin-arm64`.
c. No CI for now: the Mac's tarball is made here by `make dist`.
d. The port is v0.26.0; the clean-up and 1.0 move one on.
e. Line numbers for lldb are in v0.26.0 (below).

**Line numbers on the Mac.** `Exe.linux.raz` writes DWARF 4 already: the line
table `makeLines` makes, target-blind, and the one compile unit
`putDebug` writes. lldb reads DWARF from an executable's `__DWARF`
segment, as it does Go's, so `Exe.darwin.raz` writes the same three sections,
`__debug_line`, `__debug_info` and `__debug_abbrev`, there, unloaded,
before `__LINKEDIT`; `make gdb`'s twin drives `lldb --batch`. About 50
lines, `makeLines` and `putDebug` shared by the two writers.

## 6. Clean-up: v0.27.0, the last before 1.0

The files that served the thaws are made a record, short and true:

- `PROPOSALS.md` and `MEM_PROPOSAL.md`: gone, done early (2026-10-26);
  what was built is in the report, `doc/report-history.md` and git.
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

## 7. 1.0

No date. raz is 1.0 when use shows it: programs written against v0.27.0
for long enough that no defect is outstanding. Until then it is
0.27.x, mending defects only.

## Appendix: the Moss work, as proposed

The four proposals 3 builds, kept from `PROPOSALS.md` (in git to
2026-10-26) when it and `MEM_PROPOSAL.md` went: what the thaws built is
in the report, `doc/report-history.md` and git.
### The compiler on another host: `Host`, and what it asks of the library

**Status.** Built on the branch `moss-platform-boundary` (3eded0c),
which Moss pins: there raz compiles programs, rebuilds itself byte for
byte, and builds again after a restart (moss c606069,
`docs/native-raz.md`). Waiting for the owner's word on the questions
below before it is rebased and merged.

The host is the system the compiler runs on; the target, the system
its program will run on. Until the branch they were one, Linux, and
the compiler reached Linux outside `Sys`: `Parse.identity` read a
`struct stat` by `SYSCALL(4)` into a guessed `[18]INT`; `Raz` read
`ARGC()` and `ARGV()`, found the library through `/proc/self/exe`,
probed two loader paths for musl, and ran a program by `memfd_create`
and `execve`; `Elf` set mode 755. The branch does three things.

**1. A file's identity from `Sys.info`** (2644329). Its `dev` and
`ino`, so the parser makes no system call of its own. A plain fix:
merge it.

**2. A main file at the root, and a directory ending in `/`**
(3eded0c). `/Main.raz` has `/` as its directory, not `""`, and a
directory given as `lib/` doesn't make `lib//Sys.raz`. A plain fix:
merge it.

**3. `Host`, a module of what the compiler asks of its host**
(bb03e48): `argCount`, `arg`, `libraryDir`, `preferMusl`, `canRun`,
`canLinkC`, `writeExecutable`, `prepareRun`, `execute`. `src/Host.raz`
is Linux's; Moss stages the compiler's sources with its own
`Host.raz` (27 lines: the library at `/lib`, no run, no C, no mode
bits) and its own `Sys`, `Rt` and `Files`.

Questions before the merge:

**a. A smaller `Host`.** Two of its nine procedures are there only
because `Raz` reads the command line by built-ins:
- `argCount` and `arg` go if the library has the count beside
  `Files.arg`: a `Files.argCount()`, which Moss's `Files` gives from
  `Sys.argc`. `Files.arg` is already the library's, and Moss already
  replaces it.
- `preferMusl` and `canLinkC` are one question, which C library to
  link against: `Host.cLibrary(): CLib` with `CLib = (none, glibc,
  musl)`, or keep the two booleans.
- `canRun` goes if `prepareRun` is called while the command line is
  read, before any source, so that its error is the refusal.
That leaves `libraryDir`, `cLibrary`, `writeExecutable`, `prepareRun`
and `execute`: five procedures, each a real difference between hosts.

**b. How a host is chosen.** The branch stages: copy `src/`, put the
host's `Host.raz` in place of raz's, build. The main directory is
searched first, so `-I` alone can't replace it, which is right: a
module isn't silently replaced. The other way is a target name, as
`Sys.linux-x86_64.raz` is chosen today from fixed suffixes: a
`-os moss` that makes the suffixes `.moss-x86_64`, `.moss`, `.x86_64`,
`""`, so that `Host.moss.raz` and `Sys.moss.raz` are found beside the
generic files. That puts Moss's files in raz's tree, and raz would
then know of Moss. The proposal is to keep staging, raz knowing
nothing of any host but Linux, and to document it in
`doc/compiler.md` as the one way to build for another host.

**c. What the compiler asks of the library, written down.** Moss's
`Sys` has 23 exported procedures against Linux's 104, and is enough.
`doc/compiler.md` should list what the compiler and the modules it
imports (`Rt`, `Mem`, `Heap`, `Lock`, `Arena`, `Out`, `Fmt`, `Buf`,
`Str`, `Bytes`, `Files`) use of `Sys`, `Rt` and `Files`, as Moss's
`docs/raz-port.md` measured it, and a test should hold it: the
compiler built against a `Sys` with only those exports. Then a change
to the compiler that reaches for one more of `Sys` is seen in raz,
not in Moss's next build. The test host on the branch
(`test/host/Host.raz`) checks the `Host` side only.

**d. The stack.** A self-build passed in 64 KiB of stack on Linux,
but 64 nested parentheses don't, and Moss gives a stored program 1
MiB. That is "Implementation limits, and a compiler for a small
stack", above; the merge needn't wait for it.

**e. The tests in Python.** The branch adds `test/compiler-host.py`
(177 lines) and grows `test/library-path.py`, which came with
RAZ_PATH. raz's tests are otherwise `sh`, as a public project's
should be, needing nothing but a shell to run. The proposal is to
write both in `sh` before the merge.

**f. Before the merge, in any case.** The system call numbers in
`Host.raz` named as constants, as `Raz` had them (`MemfdCreate`,
`MfdCloexec`, `Execve`); a comment on every procedure; the new section
of `doc/compiler.md` made as short and plain as the rest; a rebase on
main (`doc/compiler.md` and `src/Raz.raz` conflict). Moss's
`RAZ_PORT.lock` then pins a commit on main.
### A freestanding program, stated

**Status.** Proposed 2026-10-22, collated from RAZ-GAPS.md.

"For a kernel: three changes to the compiler" made a raz program run on
the bare machine; Moss, a kernel in raz, now boots on it. What it found
is less a missing feature than missing words: what a `-bare` program
must give the compiler, and what it may count on, are known only by
reading `Gen.entryPoint` and `Raz`. Five items, each standing alone.
The sixth thing Moss met, `jmp rax` read as a jump to a label, was a
bug, fixed in ac3c464.

**1. The runtime ABI, written down.** A section of `doc/compiler.md`,
"A program with its own `Rt`", saying what the compiler asks of `Rt`
and what a program's start may count on:
- **Required:** `proc exit*(status: INT);`, which never returns (the
  compiler puts `ud2` after its call), and
  `proc fail*(what, a, b, len: INT; at: UINT; name: ^U8; rdi, rsi: UINT);`,
  with the kinds of `what` as `lib/Rt.raz` gives them (0 an index, 1 a
  slice, 2 an enumeration, 3 a backward slice of a pointer, 4 a nil
  pointer, 5 a division by zero, 6 a stack overflow, 7 a view), named
  constants in the text, not bare numbers.
- **Optional, found by name when declared:** `places`, `calls`,
  `teller`, `place`, `placer` (item 5), `startProfile` and `profiler`
  (never under `-bare`), `cExit` (only with C, which `-bare` refuses).
- **The entry:** `_start` runs every used module's body but `Rt`'s,
  then `main`. Under `-bare` it reads nothing from the stack and aligns
  nothing: the loader or boot stub enters it with the bss zeroed and
  `rsp` a multiple of 16, as Linux does.
- **`main` returning:** allowed. `Rt.exit` is then called with `main`'s
  result, or 0 for `proc main*`.
- **The panic hook:** `Rt.fail` is it. A kernel's `fail` prints and
  halts; nothing else is needed, and no second hook is proposed.

A test holds it: `test/run/` builds a `-bare` program against a
smallest `Rt` of `exit` and `fail` alone, run under Linux, whose
`exit` and `fail` make the system call themselves.

Met in Moss (`docs/raz-findings.md` §2), which copied the stock
signatures.

**Recommendation:** take; it is words and one test, and the contract
already exists.

**2. A recipe for an interrupt's entry.** Before any attribute or
generated stub, a tested recipe in `doc/compiler.md`, beside item 1,
stating what the compiler's code may assume and so what a stub must
restore:
- **What the compiler's code uses:** System V's caller-saved
  registers, `rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8` to `r11`, all of
  `xmm0` to `xmm15`, and the flags; the direction flag is clear at
  every call (the compiler's copies use `std` and `cld` and leave it
  clear).
- **The red zone:** whether the compiler ever writes below `rsp`. Not
  checked today ("For a kernel" leaves it open); it is to be checked
  and the answer written down. If it never does, an interrupt needs no
  IST stack for that reason.
- **The stub:** a `code` procedure per vector that pushes 0 where the
  CPU pushes no error code, pushes the vector, saves the caller-saved
  registers, aligns `rsp` to 16, saves the SSE state (`fxsave` or
  `xsave` to an aligned area), `cld`, calls an ordinary procedure
  `proc handle(vector, code: INT; frame: ^Frame)`, restores, drops the
  two words and `iretq`.

It is testable on Linux: `iretq` from ring 3 to ring 3 is allowed, so
`test/run/Interrupt.raz` builds a frame by hand, jumps to the stub, has
the handler compute with reals, and checks on return that every
register the stub promised to keep is kept. The stub needs items 3 and
"The assembler's instructions", 1 (`push` of a constant, `cld`).

Met in Moss (`docs/raz-findings.md` §4): its handlers use only `rax`
and make no call, which is safe but no recipe.

**Recommendation:** take; a kernel's first stub is where the calling
convention is easiest to get wrong, and a test on Linux keeps it right.

**3. A code procedure names a procedure or a global.** In a code
procedure, a name of the module's scope, or a qualified one, that is a
procedure or a global variable stands for its address, as an operand
of three forms only:

    call fault;              (* a procedure, rip-relative *)
    jmp fault;
    lea rax, [ticks];        (* a procedure or a global *)

Each makes a reference to that chunk, so the linker keeps what is
named, as any call does. No other operand takes a name, and no type is
checked: a code procedure is the target's, and its author already
answers for the convention. The assembler gets the names as it gets
constants, by a function the parser hands in beside `ConstFn`.

Moss stores `UINT(fault)` in a slot at start and calls through a
register (`docs/raz-findings.md` §5), so the slot must be filled
before the first fault, which nothing checks.

**Recommendation:** take; three operand forms remove a hand-off that
can be forgotten, and the recipe in item 2 needs `call handle`.

**4. A program brings its own `Rt`.** A `src/Rt.raz` beside the main
module meets `lib/Rt.raz`, and "a program has one module of each name"
refuses it, rightly. Moss copies the compiler beside an empty `lib/`.
Two ways out:
- **Staging,** as "The compiler on another host" proposes for the
  compiler's own sources: copy `raz` beside a library of the program's
  own. Nothing in raz changes; only words in `doc/compiler.md`. Every
  freestanding project then carries a copied compiler, and its library
  is all or nothing.
- **`raz -lib DIR`:** the library is `DIR`, not the one beside the
  compiler. A kernel's `-lib` is a directory holding its own `Rt` and
  `Sys` and, by symbolic links, whichever of raz's modules it takes
  (`Str`, `Fmt`, `Buf`). The duplicate check stays as it is. On the
  `Host` branch it is one line over `Host.libraryDir`; today a few
  lines in `Raz.raz` and raz(1).

The option is the smaller for its users and nearly as small in raz;
staging stays the way for the compiler on another host, where the
whole of `src/` is replaced anyway.

**Recommendation:** take `-lib`; a few lines save every freestanding
program a copy of the compiler.

**5. Symbols without `Rt`'s places.** Without `-s` the compiler links
`places`, `calls`, `teller`, `place` and `placer` and stops with "Rt
has no places" where `Rt` lacks one, and `-noprofile` doesn't help, so
Moss builds with `-s` and loses the symbol table a debugger reads.
Two things are tied that needn't be: the ELF's symbols and lines, for
a debugger, and the places, for `Rt` to say where a check failed.
The change: each of the five is linked only when `Rt` declares it,
`calls` with `teller` and `place` with `placer`, a pair or neither; `-s`
still strips both. A kernel then keeps its symbols for GDB and gives
`fail` the raw address, or declares `places` and decodes them itself.

A hosted program's `Rt` is raz's, which declares all five, so no
program changes. One that writes its own `Rt` and misspells `places`
loses its places silently; item 1 lists the names.

Met in Moss (`docs/raz-findings.md` §3).

**Recommendation:** take; it is a test on each name in `Raz.raz` and
gives a kernel its symbols back.

### The assembler's instructions

**Status.** Proposed 2026-10-22, collated from RAZ-GAPS.md.

The report leaves which instructions the assembler knows to the
implementation, and `db` gives any other. That stays. What is missing
is a rule for when an instruction joins, and the few that programs
have already written in `db`.

**1. `push` of a constant, and `cld` and `std`.** `push imm8` and
`push imm32` (6A, 68, sign-extended to 64 bits), and `cld` and `std`
in `Plain`. The encoder already writes `cld` and `std` for the
compiler's copies; only the assembler's table lacks them. Moss's
exception stubs write all three with `db`, and every stub of
"A freestanding program, stated", 2, needs them.

**Recommendation:** take; three entries the encoder half has, and an
interrupt stub can't be written without them.

**2. When an instruction joins, and the SHA and shuffle ones now.**
The rule, in `doc/compiler.md` beside the assembler: an instruction
joins when a program writes it in `db`, it is a family's member the
tables already hold (a code in `PackedOps`, an entry in `Plain`), and
its bytes are checked against GNU `as` in `test/run/`, as
`AsmKernel.raz` does. Anything else stays `db`, which is the permanent
answer for an instruction no program uses twice. By that rule, now:
- `paddd`, `punpcklqdq`, `punpckhqdq` into `PackedOps` (66 0F FE, 6C,
  6D);
- `pshufb` (66 0F 38 00) and `palignr` (66 0F 3A 0F, with a byte),
  two more forms, three-byte opcodes;
- `sha256rnds2` (0F 38 CB, `xmm0` implied), `sha256msg1` (0F 38 CC),
  `sha256msg2` (0F 38 CD).

Sauce's SHA-NI hash is 123 `db` lines assembled by GNU `as`, nothing
checking a byte against its mnemonic; with these it is read as written.
AES-NI, `pclmulqdq`, AVX and the rest wait for a program. (`movd` and
`movq`, `pxor`, `pshufd`, `movdqu`, `movdqa`, `pmovmskb` are there
already.)

**Recommendation:** take; a rule stops the list growing by wish, and
eight instructions turn sauce's 123 unchecked lines into checked ones.

**3. `raz -S`'s listing, stated.** raz(1) gives the listing's form, so
a tool may read it:
- a blank line, then a procedure's name as `Module.name:`;
- a source line: its number right-aligned in 6 columns, two spaces,
  the line's text;
- an instruction: its offset in the procedure right-aligned in 14
  columns, two spaces, the instruction as the assembler would read it,
  a jump within the procedure giving its target as an offset.

Only the main module's live procedures, in the order they were made;
nothing is disassembled. A change to the form is then a change to the
manual, and rcrypto's constant-time guard (`tools/branches.sh`), which
counts conditional jumps by reading these three kinds of line, breaks
loudly instead of silently. A test in raz holds the form against a
small program's listing.

**Recommendation:** take; it is a paragraph of raz(1) and one test,
for a form that already doesn't change.
### Implementation limits, and a compiler for a small stack

**Status.** To investigate; nothing decided.

The report names no implementation limits: how deep expressions,
statements, imports and generic instances may nest, how long a name or
a string may be. A compiler for a small machine that rejects a deep
nesting is then arguably not a raz compiler at all. C settles it with
its translation limits (C99 §5.2.4.1: 63 levels of nested parentheses,
15 of nested includes, and so on): every compiler must take at least
that much, and may take more. The proposal: a short section in the
report giving the least each compiler must accept, and saying that a
compiler that goes past its own limit stops with an error naming it,
never a crash. It changes the report, not the language.

Behind it, three things in this compiler that need no change to the
report at all, so that it runs in a small stack:

1. **Nesting.** Each level of a nested expression costs about 1 KiB
   of stack. A constant expression with 64 nested parentheses fails a
   64 KiB stack and passes 256 KiB; 256 of them fail 256 KiB and pass
   1 MiB. A limit from the section above, checked in the parser, makes
   the stack a program needs bounded and known.
2. **Imports.** `importModule` compiles an imported module in the
   middle of the one importing it, on the same stack, so the stack
   grows with the depth of the chain of imports. Ordering the modules
   first and compiling them from the leaves, in a loop, keeps whole
   program compilation and a stack that doesn't grow; symbol files, as
   Wirth's compilers have, would do it too, but must then carry a
   generic module's body.
3. **Instances.** `makeInstance` keeps the declaration under way aside
   in arrays on the stack (`[MaxFwd]PType`, `[MaxFwd]Diag.Pos`,
   `[MaxNames]INT`, several KiB) for every instance it nests. A list
   of instances still to make, made between declarations, would keep
   none.

Not yet measured: which of these filled the stack when the stripped
compiler, given one more `-I` directory, overflowed 64 KiB building
itself, where the ordinary self-build fit.

Met in moss (`docs/raz-port.md`): its stored programs get a guarded
64 KiB stack, and a native compiler must fit, or the stack must grow
(2026-10-22).
