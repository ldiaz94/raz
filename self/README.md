# self: the compiler in raz

The port of the Pascal compiler, the **seed** in `../src/`, to raz.
`../PLAN.md`, "Self", says what it is for and the order of its units.

One module to a seed unit, with the seed's name, written to the same
rules: plain code, each module opening with what it is, what it
depends on and what it leaves out. The seed is never edited from here.

    make self        # each unit against the seed's, on the same files
    make self-bench  # the scanner's speed against the seed's

`check.sh` builds a dumper for each side, `test/ScanDump.pas` over the
seed's units and `test/ScanDump.raz` over these, and has both read the
library, the examples, every test of the compiler and a file for each
message the scanner makes (`test/genlex.py`) and for hundreds of reals
that are hard to read exactly (`test/genreals.py`): the output, the
messages and the status must be the same.

## What the port found

Not the seed's to mend; for the owner to choose.

- **Names.** An exported variable is read-only outside its module, so
  what the parser sets in the seed's `diag` and `scan` (`quiet`,
  `werror`, `recovery`, `skipping`) have setters. The `sbuf` array,
  which can't be sliced outside, is `strBytes`.
- **Going on after an error.** raz has no `setjmp`, and the seed's parser
  ends its errors in a jump back to the statement or declaration being
  read, which is how it reports up to 20 errors in a run. The language
  gained `try` (report 2026-10.20) for this: `Scan.mark` and the others
  show the error and return `Scan.Failed`, which the parser passes up
  with `try` to where it reads on. `test/Recover.raz` is the pattern.
- **`NO_COLOR` set to nothing.** `Sys.env` gives "" for a variable that
  is unset and for one that is empty, so the port reads the second as
  the first. no-color.org says a variable that is empty doesn't turn
  colour off, so the port is the one that follows it and the seed
  differs; no test depends on either.
- **Strings are slices.** A message is a `[]U8` made by `Diag.say`,
  which keeps what it makes: messages are made only to be shown. A name
  from `nameOf` stays valid, since names are kept in chunks that are
  never moved; the seed's was a copy.
- **No bit cast.** A real's bits and back go through a pointer.
- **Speed.** On the 348,025 lines of `test/genbench.py`, 7.6 MB, the
  seed's scanner takes 75 ms and this one 74. It took 121 at first.
  What closed the gap, in the source: a byte loop in place of the slice
  comparison `a[0..n] = b[0..n]` (97 ms), a 256-entry table for the
  bytes of a name (84), and one for the symbols that are a byte each
  (75). What is left for the code generator, which would help every
  module: a `match` on an integer is a chain of compares, each loading
  the selector from the frame and jumping over a `jmp` (`je L1; jmp L2`),
  where FPC makes a jump table; and the slice comparison is slower than
  the loop it stands for.
