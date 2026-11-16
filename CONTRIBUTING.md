# Contributing to raz

raz is defined by its report, `doc/raz.md` and `doc/raz-lib.md`, and
the language is frozen: it changes only to mend a defect. What helps
most is finding where the compiler or the library does other than the
report says.

## What is welcome

- **Defect reports.** The compiler or the library doing other than the
  report says, a crash of the compiler, wrong code, a wrong message.
- **Defect fixes**, for such a defect.
- **Documentation and tooling.** A mistake or an unclear passage in the
  report, the manual pages or the guides; the editor support; the
  examples.

Language proposals and new features are unlikely to be accepted. That a
word is reserved, and that module names share one space with the
library's, are settled.

## How

Everything goes through GitHub issues. Pull requests are not taken.

A report gives:

- `raz --version`;
- the smallest program that shows the defect;
- what it does, and what the report says it should do, with the
  section.

A fix is offered only after the defect is agreed in its issue. It:

- mends one thing, with a test: in `conform/` if the report alone fixes
  the output, else in `test/` (`conform/check.sh` and `test/check.sh`
  say how they are laid out);
- passes `make check` and `make fmt`;
- follows `STANDARDS.md` and keeps the compiler's style: plain code a
  beginner can follow, a comment saying why, each rewrite explained
  where it is done and in `doc/compiler.md`;
- keeps `src/` to what the release in `BOOT` can build;
- carries a `Signed-off-by:` line (`git commit -s`), certifying the
  [Developer Certificate of Origin](https://developercertificate.org/).

Every patch is reviewed before it is applied, and may be rewritten.

## Tools, AI included

A tool, an AI model among them, may help write a report or a patch. You
are its author: you must have read and understood every line, and be
able to answer for it in review. Reports and patches made by a tool on
its own are closed.

## Licence

raz is under the ISC licence (`LICENSE`), and so is every contribution.
