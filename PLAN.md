# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

## v0.5.0: the library, then the freeze

**For:** a library with which raz can do most of what the programs in
`~/lib` do, concha included: files, processes and job control,
signals, time, sockets, and the few routines every program ends up
writing for itself. Then the language is frozen, softly, so that the
editors, rat and rlX11, and the book, have a fixed target.

**Done when:** report 2026-10.9 is all in the library; `examples/Sh.raz`,
a small shell, runs its test; rat, rlX11, rmacs and ravite build with
it; the freeze is written down; `v0.5.0` is tagged.

**Kept out, on purpose:** what `~/lib` keeps as libraries over the
system, written later in raz over `Sys`: DNS, TLS, time zones, JSON,
regular expressions, compression. Also `umask`, resource limits, user
ids, `exec` without a fork, `ioctl` and UDP sockets that aren't
connected: `SYSCALL` reaches them, and each comes in when a second
program needs it. The compiler doesn't change.

Every `Sys` export is written twice, in `Sys.linux-x86_64.raz` and in
`Sys.raz` over the C library, and tested through both (`test/libc`).

- [x] 1. The report, version 2026-10.9: every new and changed export of
      `Sys`, `Str`, `Map`, `Sort`, `Math` and `Fmt` (section 11), for
      review before any code.
- [x] 2. `Sys`, files: `open` with a set of `Access`, `seek`, `Info`'s
      `mtime` and `mode`, `chmod`, `readLink`, `symlink`, `removeDir`,
      `setWorkDir`.
- [x] 3. `Sys`, programs: `pipe`, `spawn` of a `Program`, `wait` of any
      child with its `Status`, process groups and the terminal's
      foreground, `pid`; signals caught on a file descriptor. Rat
      breaks here: `spawn` changes.
- [x] 4. `Sys`, the rest: `clock`, `now`, `sleep`, `random`;
      `connectTcp`, `connectUdp`, `listen`, `listenTcp`, `accept`.
- [x] 5. `Str.encode`, `Str.decode`, `Str.toInt`; `Map.remove` and
      `Map.next`; `Sort`; `Math`; `Fmt.real`. Each module's `main`
      tests it.
- [x] 5a. Asked for rloc, and every program after it: `Opt`, a
      command line read through one table, after `~/lib/getopt`.
      getopt(3)'s rules with GNU's long options (`-lw`, `-b dev`,
      `--bar=dev`, `--`); the usage line and a sentence for every
      mistake made from the table, so they can't drift from it;
      `-h` and `--help` answered; no global state. `Files` moves from
      `tools` to the library, and `Opt` reads its words with
      `Files.arg`. The report first, for review; then the module,
      its test in its `main`, and `Doc`, `Pretty` and `Mutate` on it.
      Kept out: concha's completion from the table, until asked.
- [x] 6. `examples/Sh.raz`: pipelines, redirection, `cd`, `&`, `wait`,
      and Ctrl-C to the job in the foreground, in a few hundred lines.
      Its test runs scripts given with `-c`.
- [ ] 7. rat, rlX11, rmacs and ravite on this raz, in their own
      repositories: the four copies of UTF-8 encoding go to
      `Str.encode`.
- [x] 8. The freeze, in CLAUDE.md and the report's first section: the
      language changes only to mend a defect; the library grows only by
      what breaks nothing; wishes go to a list for a later thaw. README,
      `doc/compiler.md`'s table, the report's version and the
      compiler's; tag `v0.5.0`.

## Proposed, v0.6.0: raz to be rebuilt by anyone

Not started; it waits for the owner's go-ahead, and it lifts the
freeze for what it names, and nothing else.

**For:** a language a person alone can implement again, from the
report, on any machine, in weeks; programs that run on small machines
as well as large; code within reach of a simple optimising compiler,
without one.

**Done when:** the report alone is enough to rebuild raz, with a
conformance suite to say when a rebuild is done; the report has a
system integer, optional reals and object files; the compiler goes
through an IR, which is what an object file holds, and keeps its
values in registers as Wirth's compilers do; `make bench` still
passes; a new code budget is written down; `v0.6.0` is tagged.

**Kept out:** a second back end (aarch64 is the milestone after, to
measure a port); an optimiser; the wishes below.

- [ ] 1. The report as it stands, made complete: the whole grammar;
      the readings in CLAUDE.md moved into the report; what every
      implementation must do set apart from what each may choose
      (code procedures, `SYSCALL`, `extern`'s convention, how several
      results come back, the text of messages); the core a port must
      have (the language, `Rt` and `Out`, over writing, exiting and
      getting memory) and what it may leave out. No language change.
      For review before anything else.
- [ ] 2. The report, the new language, for review before any code: the
      system integer, the size of an address, which `LEN`, indexes and
      sizes give (the owner's choice), and how it converts to and from
      `I64`; reals a
      target may leave out; object files, a module's interface and its
      IR, and a generic's instances in them, named by their arguments
      and the fingerprints they were built from.
- [ ] 3. The IR, in its own document, for review: proposed, a stack
      code close to what the parser asks of `gen` today, with types
      and places, so that a back end turns its stack into registers and
      an interpreter of it stays small.
- [ ] 4. The tests split: a conformance suite any implementation
      passes, apart from this compiler's own messages.
- [ ] 5. The system integer.
- [ ] 6. Optional reals: a target says whether it has them.
- [ ] 7. The parser emits the IR and the x86-64 back end reads it;
      every test gives the same output as before.
- [ ] 8. Wirth's register stack in the back end: a value is held in
      one of a stack of registers, not pushed.
- [ ] 9. Object files: written for each module, read in place of its
      source when they are current; instances kept once each by the
      linker.
- [ ] 10. `doc/compiler.md`, README, the budget, the report's version
      and the compiler's; tag `v0.6.0`.

## Wishes, for a later thaw

What the language or the library might have, met while writing raz;
none is built while the freeze holds.

- `case` on integers and characters: `match` takes variants only, so
  a choice among numbers is a chain of `elsif` (`examples/Sh.raz`).
- Constant arrays: a table of numbers is assigned in a procedure, as
  `Math`'s bits of 2/pi are, or kept in a variable.
- Joining string constants, `"a" + B`: a test's expected text is
  written out whole each time (`Opt`'s test).

## After v0.5.0

The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
