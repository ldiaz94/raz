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
- **Going on after an error.** raz has no `setjmp`: `Jump.raz` is the
  two in assembly, which the parser's recovery needs. The assembler has
  no `jmp reg`, so it is written `db 0FFH, 0E1H;`.
- **`NO_COLOR` set to nothing.** `Sys.env` gives "" for a variable that
  is unset and for one that is empty, so the port reads the second as
  the first, as no-color.org has it. The seed reads it as set.
- **Strings are slices.** A message is a `[]U8` made by `Diag.say`,
  which keeps what it makes: messages are made only to be shown. A name
  from `nameOf` stays valid, since names are kept in chunks that are
  never moved; the seed's was a copy.
- **No bit cast.** A real's bits and back go through a pointer.
- **Speed.** On the 348,025 lines of `test/genbench.py`, 7.6 MB, the
  seed's scanner takes 75 ms and this one 83 ms. Two things cost the
  rest: a slice comparison, `a[0..n] = b[0..n]`, is 25% slower than the
  same bytes in a loop, and a procedure call to ask whether a byte is
  in a name (a table now). The compiler could mend the first.
