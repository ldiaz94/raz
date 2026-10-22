# Testing: Rand, Check, Prop and raztest

A plan for testing raz programs: three library modules and a tool, all
shipped with raz, so that a public project needs nothing past raz, make
and sh to use them. Each step is a commit of its own, useful alone;
after each, stop for review.

## Why here

- Every program has the library, and a program's make already builds
  `tools/Pretty.raz` for `fmt`; `raztest` is found the same way.
- Today ~180 `check`/`expect` helpers are written by hand across ~/r,
  four projects carry a PRNG of their own (rjson, pict, sauce, tasta),
  and each Makefile hand-rolls its test loop and summary.

## The pieces

| Piece | Where | Size | What |
|---|---|---|---|
| `Rand` | `lib/Rand.raz` | ~40 | a seeded generator, splitmix64 |
| `Check` | `lib/Check.raz` | ~80 | assertions, failures on stderr, status by `Rt.atExit` |
| `Prop` | `lib/Prop.raz` | ~300 | properties and fuzzing over recorded choices, with shrinking |
| `raztest` | `tools/Test.raz` | ~700 | finds, builds and runs tests; colour, reports, watch |

**Rand.** `init(r, seed)`, `next(r): U64`, `below(r, n)` (no bias),
`range(r, lo, hi)`, `seed(): U64` (fresh, from `Sys.random`, to print
and replay). No reals until a user needs them.

**Check.** `ok(cond, what)`, `str(what, got, want)` (escaped),
`int(what, got, want)`, `mute(on)` and `mutedFailures()` for Prop. A failure is a block on
standard error:

    FAIL what
      got:  "..."
      want: "..."

and a program with failures ends with `Check: F of N failed` and status
1, by a procedure registered with `Rt.atExit` (which may call
`Rt.exit` itself), so there is no `done` to forget. A passing run says
nothing. The status and this text are the whole contract with
`raztest`; a bare `./Mod` or a make loop works as before.

**Prop.** A property is `proc(var s: Prop.Source)` that draws values
(`int(s, lo, hi)`, `bool(s)`, `bytes(s, max, buf)`, `pick(s, n)`) and
checks them with `Check`. A case is the bytes it drew (as Hypothesis
does), so shrinking works on those bytes (cut chunks, zero, lower) and
replays the property: no shrinker per type, no closures. A number is 8
bytes, big-endian, lowered as a whole; `bytes` puts before each byte
one that may end them, so that they shrink one by one. A property
reading only `bytes` is a byte fuzzer. While searching, `Check` is
muted; the smallest failing case is run again aloud and saved to
`test/seeds/<name>`; saved seeds are replayed first, every run.
`PROP_SEED` replays a run's fresh cases, `PROP_CASES` sets how many
(100), `PROP_TIME=60` fuzzes for a minute, `PROP_DIR` moves the seeds;
a case that crashes is saved at exit.

**raztest.** Finds modules with `proc main*` in `src/` and `test/*.raz`
(`-I`, default `src`); builds with `-Werror`; runs them, `-j n`, a
timeout each, `-r pattern`; times each; shows a test's output only when
it fails; colour on a terminal unless `CI` or `NO_COLOR`; a summary and
the status. `--tap`, `--junit file` (a module is a case, its `FAIL`
blocks the failure). `-w` reruns every test when a `.raz` beside the
tests or in `-I` changes (raz builds fast; import tracking isn't worth
its lines), by polling file times (Sys has no inotify: a gap). `--seed`, `--fuzz 60s`
set `PROP_*`. Left out: `.cn`, sh and pty tests, which stay in make. A
Makefile uses `raztest` when it's there and its own loop when not.

## Steps

1. `Rand`, with its self-test.
   Done: `lib/Rand.raz`, splitmix64.
2. `Check`; the library's self-tests use it.
   Done: `lib/Check.raz`.
3. `raztest`: finding, building, running, `-j`, timeouts, colour,
   summary; `test/check.sh`'s library loop uses it. `TOOLS` gains
   `Test`; `make install` puts `raztest` on PATH; `doc/raztest.1`.
   Done: `tools/Test.raz`.
4. `raztest --tap`, `--junit`.
   Done.
5. `raztest -w`.
   Done.
6. `Prop`, with its self-test.
   Done: `lib/Prop.raz`.
7. Volume 2: `Rand`, `Check` and `Prop` go into `doc/raz-lib.md` as
   standard library (not core: `conform/` is untouched), with whole
   examples, once the first users have settled them; one report
   version. `STANDARDS.md` says how a module tests itself with them.
   Done: report 2026-10.36, `doc/raz-lib.md`, `STANDARDS.md`.
8. robbie: `robbie -w`, in its own repository.

After the release that brings them: rjson, pict and sauce take `Rand`
and `Prop` (rjson's `Random.raz`, JSONTestSuite as seeds; pict's fuzz;
sauce's `Fuzz.raz` draws), and projects take `Check` and `raztest` as
their files are touched, with no sweep. `desktop.7` names `raztest`
once it is installed.

## Left out

Coverage-guided fuzzing (the compiler would have to count branches);
tests in doc comments (no library comment holds a whole example; the
report's and the tutorial's are already run); a shared pty harness
(belongs with rtui or rterm); `Check` naming the failing line (`Rt`
knows places but exports none: a gap).
