# self: the compiler in raz

The port of the Pascal compiler, the **seed** in `../src/`, to raz.
`../PLAN.md`, "Self", says what it is for and the order of its units.

One module to a seed unit, with the seed's name, written to the same
rules: plain code, each module opening with what it is, what it
depends on and what it leaves out. The seed is never edited from here.

    make self        # each unit against the seed's, on the same files
    make self-bench  # the scanner's speed against the seed's

`Chunk` and `Sym` have no input files to read, so each has a dumper
pair, `test/ChunkDump` and `test/SymDump`, that runs one fixed
pseudo-random script of calls on its side and prints all it made or
answered (`Sym` also ends, as an argument says, in the error of a name
declared twice or of too many scopes): the output, the messages and
the status must be the same. `Link` and `Elf` are tested by
`test/LinkDump`, which makes a program of chunks by a script and writes
it as a static, a dynamic and a stripped executable, which must be the
same file; `X64` by `test/X64Dump`, every encoder with operands from a
script, bytes, fixups and listing, and by `test/AsmDump` on the files
`test/genasm.py` makes: a long run of every instruction the assembler
knows, and a file for each of its errors.
`Gen` is tested by `test/GenDump`, a script of calls, valid by
construction (an expression pushes its operands and then operates; a
statement leaves the stack as it found it), that compiles 80 procedures
with every kind of expression, statement, call, check, frame and defer,
and the entry point, static and dynamic: the bytes, fixups, line notes
and listing must be the same.
`Item` is tested by `test/ItemDump`, a script of operands and operations
with mistakes among them (a constant, a variable in the frame, a
register, a slot, another module's or C's, a string, a procedure, a
selector through a pointer, a field, an element or a slice, a call, a
`match`, a `for`, `return`, `COPY`, a variant): each step shows what
it gave, or its message, and goes on, as the parser does after an
error. What each step gave, the messages, and the bytes, fixups, line
notes and listing of the code must be the same, over 60 scripts (a
run ends at its 20th error, as a compile does). The text its messages
point into is `test/ItemDump.txt`.

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
- **Reserved words as names.** The seed's `code` (the text buffer of
  `Chunk`) is `text`; `module` (a record's, an import's) is `home`; an
  object's `link` is `chain`. A seed type `TName` is `Name`, and the
  procedures begin in lower case, as `Scan`'s do.
- **Errors in `Sym`.** `insert` (a name declared twice) and `openScope`
  (too many scopes) show the error and return `Scan.Failed`, as `mark`
  does, for the parser to pass up with `try`. `saveScopes` returns what
  the seed's `var d` gave.
- **Setters.** What other units set in `Chunk` has one each (`setLive`,
  `setAdr`, `setReals`, `setSaves`, `setCurFile`, and `rewindTo` for
  gen's `Redo` and `Rewind`), and `Sym` has `setCurModule`. `Scan.grab`
  is exported for the memory they all take.
- **No `continue`.** The seed's loops that skip to the next round
  (`MarkLive`, the line program, the assembler's statements) have the
  rest of the body in an `else`, or in a procedure of its own.
- **`X64`.** `code` of `Chunk` being reserved, its text is `Chunk.text`;
  `Say` and the rest of the encoder keep their names, in lower case.
  `ConstFn`, the parser's reader of a constant, returns an `ERROR` too,
  and `assemble` returns what it passes up. `mem` marks an offset beyond
  32 bits and goes on, since an operand has nowhere to return an error
  to; the compile ends with the message shown. The listing's text is
  made by `Diag.say`, which keeps it, and only when `-S` asks for it.
- **`Link` and `Elf`.** What `raz.pas` set there has a setter each:
  `Link.setPlaces`, `Elf.needLib`, `noLibs`, `setMainPath`,
  `setStripped` and `X64.setListing`. The file is written by
  `Files.write` and made executable by `Sys.chmod`, in place of one
  `open` with mode 755 (which the umask would trim).
- **`Gen`.** The seed's `Mark` in the middle of a push or a check
  can't give an error back: `newEntry` (the stack's 256 places) and
  `check` (4,096 checks a procedure) show it and go on without doing
  what they couldn't, and the parser's `resetStack` makes the stack
  right again; `endProc` returns its error ("frame too big") and
  `codeProc` the assembler's. A `var` out of the seed became a result
  (`topConst`, `operands`, `deferBegin`); the labels, which are chains
  that a call extends, stay `var`. `inPlace` has a setter. The seed's
  `Call` record is `CallInfo` (the procedure is `call`) and `TLink` is
  `Link`. A `match` on an enumeration takes one name to an arm, and a
  set holds at most 64 names, so `Scan.Sym` (over 64) has none: the
  seed's sets of its names are chains of `=`.
- **`Item`.** The seed's `Mark` ended in a jump, so here every
  routine that can find an error returns an `ERROR` as its last result
  and the ones that call it pass it up with `try`; `Item` shows the
  message and returns what the seed jumped out of, so a script that
  goes on after an error sees the same state. The seed's `Mismatch` of
  two operands is `mismatchOps`, `demoted` and `checks` have setters,
  and `matchBegin`, `toSlot` and `errorChunk` return their value and
  the error. `op2` has a parameter it never read, now `_L`. A message
  is made by `Diag.say` from strings, with no `shortstring` to add up.
  A `Mark` with no place is at the scanner's, as in the seed.
- **No `const` parameter.** The seed's `const x: TItem` is a value
  parameter here, so an item of about 130 bytes is copied at each call
  of `what`, `adrOf`, `notValue` and the others. The result is the
  same; whether the compiler built from this is slower for it is for
  the speed test of step 4 to say. A `const` parameter (a hint that
  the callee won't change it, so that the caller may pass its address)
  would be a language change: it goes on the wish list.
- **Sets of `Scan.Sym`.** The operators a rule names are chains of `=`
  or the helpers `oneOf` and `isRel`; the arms of a `match` on them
  take one name each, so those with two names call a procedure of
  their own (`foldDiv`, `setSubset`).
- **Strings made by the compiler.** A joined string (`"a" + "b"`) and
  an error's text are built in memory from `Scan.grab`, which is never
  freed, in place of `GetMem` and `FreeMem`; the compiler runs once.
- **No bit cast.** A real's bits and back go through a pointer.
- **Speed.** On the 348,025 lines of `test/genbench.py`, 7.6 MB, the
  seed's scanner takes 75 ms and this one 74. It took 121 at first.
  What closed the gap, in the source: a byte loop in place of the slice
  comparison `a[0..n] = b[0..n]` (97 ms), a 256-entry table for the
  bytes of a name (84), and one for the symbols that are a byte each
  (75). What is left for the code generator, which would help every
  module: the slice comparison is slower than the loop it stands for.
  (The seed's `match` on an integer was a chain of compares, each
  loading the selector from the frame and jumping over a `jmp`, where
  FPC makes a jump table; now it makes one too.)
