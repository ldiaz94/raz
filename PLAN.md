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
- [x] 7. rat, rlX11, rmacs and ravite on this raz, in their own
      repositories: the four copies of UTF-8 encoding go to
      `Str.encode`.
- [x] 8. The freeze, in CLAUDE.md and the report's first section: the
      language changes only to mend a defect; the library grows only by
      what breaks nothing; wishes go to a list for a later thaw. README,
      `doc/compiler.md`'s table, the report's version and the
      compiler's; tag `v0.5.0`.

## Proposed, v0.6.0: raz to be rebuilt by anyone

Under way: steps 1 to 4 are done, step 3 set aside since. The owner
has agreed the rest, to step 10, to be done without stopping. The freeze
doesn't hold for this work, by the owner's word.

**For:** a language a person alone can implement again, from the
report, on any machine, in weeks; programs that run on small machines
as well as large; code within reach of a simple optimising compiler,
without one.

**Done when:** the report alone is enough to rebuild raz, with a
conformance suite to say when a rebuild is done; the report has a
system integer and optional reals, and leaves separate compilation to
the implementation; it has array constants, joined string constants
and `match` on integers; the parser reaches the machine only through
`gen`, the boundary a port writes again, and the back end keeps its
values in registers as Wirth's compilers do; `make bench` still
passes; the compiler is within the new budget below; `v0.6.0` is
tagged.

**Kept out:** a second back end (aarch64 is the milestone after, to
measure a port); an optimiser; separate compilation: object files, an
IR written down, and a tool to show them (the report leaves it to the
implementation, and a whole program compiles in well under a second);
the wishes below.

- [x] 1. The report as it stands, made complete: the whole grammar;
      the readings in CLAUDE.md moved into the report; what every
      implementation must do set apart from what each may choose
      (code procedures, `SYSCALL`, `extern`'s convention, how several
      results come back, the text of messages); the core a port must
      have (the language, `Rt` and `Out`, over writing, exiting and
      getting memory) and what it may leave out. No language change.
      For review before anything else.
- [x] 2. The report, the new language, for review before any code: the
      system integers `INT` and `UINT`, the size of an address, which
      `LEN`, indexes, sizes and `p - q` give, and through which
      integers and pointers convert (the owner's choices), and how
      they convert to and from `I64`; a module's own choice to leave
      out its checks of indexes and slices; exported variables read only
      outside their module; `CAS`, `XCHG` and `XADD` on words, not
      only on 8 bytes; byte order, and what a packed record promises
      on a machine that can't read a misaligned word; reals a
      target may leave out; object files, a module's interface and its
      IR, and a generic's instances in them, named by their arguments
      and the fingerprints they were built from.
- [x] 3. The IR, in its own document, `doc/ir.md`, for review: proposed, a stack
      code close to what the parser asks of `gen` today, with types
      and places, so that a back end turns its stack into registers and
      an interpreter of it stays small. Set aside by the owner: the
      compiler compiles the whole program at once, so nothing needs
      the IR written down; `doc/ir.md` is removed, and git keeps it.
- [x] 4. The tests split: a conformance suite any implementation
      passes, apart from this compiler's own messages.
- [x] 5. The system integer.
- [x] 6. Optional reals: a target says whether it has them.
- [x] 6a. `+` joins string constants (report, section 4).
- [x] 6b. Array constants: `const P: [5]I64 = [...]`, in read-only
      data, used as a variable that can't be changed (section 4).
      Done so that a string constant is the same mechanism.
- [x] 6c. `match` on integers: constants and inclusive ranges as
      labels, no value in two, `else` required (7.4); compares and
      branches, no jump table. `examples/Sh.raz`'s chains of `elsif`
      become `match`.
- [x] 7. The parser reaches the machine only through `gen`: calls of
      a stack machine, with the kind of each value (a word, a 64-bit
      integer, an `F32`, an `F64`) and the place in the source, and no
      x86-64 in the parser; a port is a new `gen`. Every test gives
      the same output as before.
- [x] 8. Wirth's register stack in the x86-64 `gen`: the value at
      depth `d` is held in register `d`, not pushed. The registers in
      use are saved around a call, and spilled to the frame when an
      expression is deeper than the registers; the stack is empty when
      deferred statements run, a `return`'s results kept in the frame
      meanwhile; `rax`, `rdx` and `rcx`, which division and shifts
      need, aren't in the stack. `make bench` still passes.
- [ ] 9a. Failures caught by the code where the machine can't: a
      `nil` test before a dereference or a call through a procedure
      value, a stack limit at each procedure's start, a zero test
      before a division; chosen per target. A `nil` test is left out
      only where the offset falls in the unmapped page at address 0.
      On x86-64 that means a field past 4,095 bytes still gets one.
- [ ] 9b. Assembly procedures in place of byte procedures: the
      target's own syntax (appendix A), for the instructions the
      encoder knows and a few of the system's, bytes for the rest.
- [ ] 9c. `raz -S`: each line of source with its instructions, named
      by the encoder as it makes them, not by a disassembler.
- [ ] 9d. The trap report: on a failed check or a trap, the calls
      under way, each with its variables by name and value, from
      tables the compiler writes; `Rt.trace` gives the same on
      demand.
- [ ] 9e. A profiler in `Rt`: a program run with `RAZ_PROFILE` set
      samples where it is, and at its end says which procedures and
      lines took the time.
- [ ] 10. `doc/compiler.md`, README, the report's version and the
      compiler's; tag `v0.6.0`.

The budget, by the owner's word: a soft limit of 8,000 lines of code,
with the compiler documented and commented throughout, most of all
where it is obscure, not obvious, or needs a compiler writer's
knowledge.

## Wishes, for a later thaw

What the language or the library might have, met while writing raz;
none is built while the freeze holds.

Taken into v0.6.0: `match` on integers, array constants, joining
string constants.

## After v0.5.0

The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
