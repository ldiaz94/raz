# Resuming the arm64 macOS port

Stopped 2026-11-15, by the owner's word. The plan is PLAN.md section 5;
its "Where it stands" says the same as this, shorter. Delete this file
when the port is done.

## Where things are

- **`main`**, pushed: steps 1 to 7, each checked before its commit
  (`make docker-check` 0 failed, 9 skipped; `make mac-check` all
  passing; the fixpoint; x86-64's output unchanged byte for byte).
- **`wip-darwin-step9`**, a local branch, not pushed (f87c668): step 9
  as far as it got, never checked; it was stopped during its last
  `make docker-check`. It holds:
  - `src/bootstrap.sh`: `make raz` on the Mac through the container,
    while no release has a Mac tarball;
  - `BOOT` naming a tarball per host, `src/boot.sh` choosing by `uname`;
  - `make fixpoint` and `make bench` natively on the Mac;
  - `raz run` no longer leaving its file in `$TMPDIR`;
  - `make dist` for darwin-arm64;
  - changes to `src/cross.sh`, `src/fixpoint.sh`, `src/bench.sh`, the
    Makefile, `src/Exe.darwin.raz`, `src/Host.darwin.raz`, CLAUDE.md,
    PLAN.md and `doc/compiler.md`.
- **Not started:** step 8, `make check` natively on the Mac (`test/`'s
  expectations per target where the Mac differs), and step 10, the
  release, which waits for the owner's word.

## What works on the Mac today (from `main`)

- `src/cross.sh darwin-arm64`, run in the container, builds a cross
  compiler: Linux-hosted, making Mach-O for arm64 macOS.
- `make mac-check` compiles with it in the container and runs natively:
  test/mac, all of conform/run (SystemImport aside: SYSCALL is Linux's),
  the library's tests and test/libc (ExecveC aside: /proc is Linux's),
  and lldb stopping at a line (`make lldb`).
- `HOST=darwin src/cross.sh darwin-arm64` stages a native compiler that
  runs on the Mac: `--version`, compiling, `raz run`.

## To resume

1. Start Docker Desktop (Rosetta on for amd64); `make docker-image`.
2. `git checkout wip-darwin-step9`, and read `git diff main`.
3. `make docker-check`: it must end `0 failed, 9 skipped`.
4. `make mac-check`: all must pass.
5. Finish what step 9 lacks (PLAN.md 5's step 9), check `make
   fixpoint` and `make bench` natively on the Mac (at least 400,000
   lines a second), then merge into `main` and push.
6. Step 8: `make check` with the native `./raz`.
7. Step 10, on the owner's word: v0.26.0, two tarballs, `BOOT` per host.

## Known limits on the Mac

- A frame holds at most 16 MB: test/run/ThreadOverflowC doesn't compile.
- `Thread.Mutex` is `os_unfair_lock`: the thread that locks it unlocks it.
- `Bytes` is plain raz there, no NEON.
- Under Rosetta, the container skips 9 tests Rosetta breaks (its own
  descriptors 3 to 6, its mmap under `ulimit -v`, a stack fault's
  locals); each says why.
- The compiler is about 16,700 lines of code of the 18,000 budget.
