# Handover, 2026-10-17

v0.20.0 is done on `main`; nothing is tagged. This says what to tag
where, how, and what to check. Delete this file once the three tags
below are pushed and their releases checked.

## What to tag

These sessions can push to `main` but not tags, so the tags are the
owner's to add. Each is an annotated tag whose message is what
`raz --version` prints at that commit; pushing it runs
`.github/workflows/ci.yml`, which checks the commit and makes the
GitHub release with its tarball. Tag in this order, oldest first, and
push them one at a time, since each release's CI builds `src/` with
the release `BOOT` names, which must exist first:

| Tag | Commit | Message | Tarball's SHA-256 |
|---|---|---|---|
| `v0.18.1` | `88b18ba` ("Docs for v0.18.1: ...") | `raz 0.18.1, report 2026-10.32` | what `site/public/download/raz-0.18.1-linux-x86_64.tar.gz.sha256` says |
| `v0.19.0` | `51a90a6` ("Report 2026-10.33 is followed; ...") | `raz 0.19.0, report 2026-10.33` | `217448cb6521c76a28d71499d70a5dfdebc2dbcbc81d6d41ed9d9590005772ed` |
| `v0.20.0` | `086e55c` ("Docs for v0.20.0: ...") | `raz 0.20.0, report 2026-10.34` | `bfa954d27d759e4ca7f7f33debb4705f25d5c05a097d86aa28b3260048b5d9cc` |

    git tag -a v0.18.1 -m 'raz 0.18.1, report 2026-10.32' 88b18ba
    git push origin v0.18.1
    git tag -a v0.19.0 -m 'raz 0.19.0, report 2026-10.33' 51a90a6
    git push origin v0.19.0
    # wait for v0.19.0's release (Actions, "ci"), and check its sum:
    #   gh api repos/ldiaz94/raz/releases/tags/v0.19.0 --jq '.assets[].name'
    #   gh release download v0.19.0 -p '*.tar.gz' && sha256sum raz-0.19.0-*.tar.gz
    # it must be BOOT's; only then:
    git tag -a v0.20.0 -m 'raz 0.20.0, report 2026-10.34' 086e55c
    git push origin v0.20.0

`086e55c` is "Docs for v0.20.0"; the commit after it, "site: v0.19.0
and v0.20.0", changes only `site/`, `make dist` (which lends a
fetched BOOT tarball to its checkout) and this file, so the tag stays
on the docs commit, as v0.18.1's did. Check before tagging that `make
check` passes there. The sums of v0.19.0 and v0.20.0 are also in
`site/public/download/*.sha256`, which the website serves.

Before v0.19.0's release exists, CI on every push to `main` fails at
`src/boot.sh` (it can't fetch the tarball `BOOT` names); that is
expected, and goes once the tag is pushed. v0.18.1 and v0.19.0 were
built by the Pascal seed, so their CI installs `fp-compiler` (their
own `ci.yml` says so).

## Why the sums can be trusted

`make dist` makes the same tarball, byte for byte, wherever it runs.
Without the tags, the tarballs here were made with the version given
by hand: v0.19.0's by building `51a90a6` in `/tmp/raz-dist` with
`build/version.inc` set to `'0.19.0'` (its Makefile predates
`VERSION`), which gave BOOT's sum, the same that the session before
got with a local tag; v0.20.0's by `make dist REV=<commit>
VERSION=0.20.0`, which the Makefile now takes for this, twice, with
the same sum; its `raz --version` says `raz 0.20.0, report
2026-10.34`. So CI's
tarball for each tag must have the sum in the table; if one differs,
the website's copy is wrong and must be replaced by CI's before
anyone pins it (the site keeps a tarball once it has it).

## What v0.20.0 did

- v0.19.0 builds `src/` (`BOOT`, `src/boot.sh`); the Pascal seed and
  its tests (`make tests`, `seed-bench`) went; `make prev-bench`
  compares this compiler with BOOT's. CI needs no `fp-compiler`.
- `Buf.bytes` and `Sys.entryKind` take `const`.
- `src/`'s `Item`s only read take `const` where callgrind counts a
  gain (16 routines, 0.4% of the instructions); the 11 that word an
  error keep a value.
- Report 2026-10.34, the tenth thaw, by the owner's word: `PTR(s)`, the
  address a slice starts at, unchecked, so an empty slice gives what it
  holds. The compiler's messages point to it (a slice where a pointer
  is wanted says `PTR(s)` and `LEN(s)`). `conform/` has `Ptr` and ten
  errors; the tutorial (section 6) and the tour (lesson 7, "A slice's
  pointer") show it; raz(7), the editors, README, CLAUDE.md and
  `doc/compiler.md` say it.
- `make dist` and `make site` take releases not tagged yet (`VERSION`,
  `RELEASES`); the website offers 0.19.0 and 0.20.0.

Each commit passed `make check`; the fixpoint, `bench`, `prev-bench`
and `fmt` passed at the end. The report is 32 pages by `make pdf`
(pandoc 3.8 and Chromium; this container's pandoc, 3.1.3, is too old,
so a newer one was fetched into the session's scratch space).

## What comes next

Not started; each the owner's call.

1. Once v0.20.0 is released and its sum checked: `BOOT` names v0.20.0
   (a commit of its own). Then `src/` and the library it imports may
   use `PTR`: `Sys`'s private `bytes` (both `Sys` files), which turns a
   slice into a pointer or `nil`, gives way to `PTR`. `write`, `read`
   and `send` keep their test for an empty slice, which is behaviour
   (no call is made), not a guard.
2. `PROPOSALS.md` holds what waits for a later thaw.
