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
- [ ] 6. `examples/Sh.raz`: pipelines, redirection, `cd`, `&`, `wait`,
      and Ctrl-C to the job in the foreground, in a few hundred lines.
      Its test runs scripts given with `-c`.
- [ ] 7. rat, rlX11, rmacs and ravite on this raz, in their own
      repositories: the four copies of UTF-8 encoding go to
      `Str.encode`.
- [ ] 8. The freeze, in CLAUDE.md and the report's first section: the
      language changes only to mend a defect; the library grows only by
      what breaks nothing; wishes go to a list for a later thaw. README,
      `doc/compiler.md`'s table, the report's version and the
      compiler's; tag `v0.5.0`.

## After v0.5.0

The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
