# raz in SBCL

A second compiler for raz, written in Common Lisp for SBCL from the
report alone: `doc/raz.md`, the language, and `doc/raz-lib.md`, the
library. It shares no code with the compiler in `src/`, and its library,
`lib/` here, is written afresh from volume 2. It follows report
2026-10.23 and passes the conformance suite, `conform/`: 301 of 301.

    make            # ./raz, from src/*.lisp (needs sbcl)
    make check      # conform/, run from the directory above
    ./raz [-I dir]... [-o exe] [-S] file.raz

`-S` also writes the Lisp it made to `exe.lisp`. With `RAZ_DEBUG` set
in the environment, a mistake of the compiler's own comes with a
backtrace.

## How it works

The compiler reads each module once, front to back, checking it and
turning it into Lisp as it goes. Each procedure becomes a `DEFUN`. At
the end the compiler compiles them with SBCL into its own image and
saves the image, program and all, as the executable, which starts at
`START` in `src/rt.lisp`.

| File | What |
|---|---|
| `src/package.lisp` | the packages: `RAZ`, and `RAZP` for the program's procedures |
| `src/scan.lisp` | the scanner: UTF-8 checked, then tokens |
| `src/types.lisp` | types, their layout, and sameness (5.10) |
| `src/rt.lisp` | the run time the compiled code calls |
| `src/comp.lisp` | what the rest share: modules, names, items, frames, the data block |
| `src/expr.lisp` | expressions, conversions, built-ins and calls |
| `src/stmt.lisp` | statements |
| `src/decl.lisp` | declarations, procedures, modules and generic instances |
| `src/driver.lisp` | the command line, and the executable |

**Memory.** Every raz variable lives at an address, as `ADR` needs.
The module variables, string literals, constant arrays and records,
and the errors' messages lie in one block, the data, mapped at
`200000000000H`, so that the compiler knows each of their addresses.
A procedure's parameters, variables and temporaries lie in its frame,
on a raz stack of 256 MB that each thread maps for itself; a frame is
zeroed as the procedure starts.

**Values.** In Lisp an integer, a pointer, an `ERROR` or a set is an
integer, kept within its type's range; a `BOOL` is `T` or `NIL`; a
real a `DOUBLE-FLOAT` or `SINGLE-FLOAT`. An array, a record, a variant
or a slice is handled by its address. An `ERROR` is the address of a
slice of its message, so `MSG` reads it there. A procedure value is an
index into a table of the program's procedures; one given to C becomes
a C function made by SBCL, so C can call it back, from its own threads
too.

**Results.** A procedure returns its results as Lisp's multiple values;
for each record, array, variant or slice among them the caller passes
the address of a place to put it.

**Deferred statements** are copied, by the compiler, to each place
their statement list can be left: its end, and each `return`, `try`
and `break` that leaves it. Nothing about them is kept as the program
runs, and a stop, `Rt.exit` or `Sys.exit` runs none of them, as 7.7
wants.

## This implementation's choices (appendix A)

- **The target** is `linux-sbcl`: Linux, on the machine SBCL runs on.
  A module's files are looked for as `Name.linux-sbcl.raz`,
  `Name.linux.raz`, `Name.sbcl.raz` and `Name.raz`. An address, and
  so `INT`, is 8 bytes; reals are there; bytes are little-endian.
- **Separate compilation**: none. Every module of a program is
  compiled together, and no object file is written.
- **Atomics**: `CAS` is the machine's, through SBCL; `XCHG` and `XADD`
  loop on it.
- **The calling convention** is SBCL's for raz procedures, and C's
  (System V) where raz meets C, for `extern` procedures and callbacks.
- **Code procedures.** The target's machine is SBCL, so its assembly
  language is Lisp: each instruction, up to its `;`, is a Lisp form,
  read in the package `RAZ`, which sees the parameters by their names
  in capitals, and the value of the last is the result. A code
  procedure returns no record, array or slice. The library uses them
  for the few things only the run time can do (`Rt`'s end, `Math`,
  threads, signals). x86 code procedures aren't this target's.
- **`SYSCALL`** goes through the C library's `syscall()`, with
  x86-64's numbers. A program that makes the system calls SBCL itself
  relies on (signals' handlers, `clone`) is on its own.
- **`Out`'s buffer**, `Sys.outSize`, is 4 KB.
- **The executable** is an SBCL image, about 36 MB, which starts in a
  few milliseconds. It carries the names of the procedures, which a
  stop and `Rt.trace` print, but no line numbers for a debugger.
- **Failures.** A failed check, a division by zero and a `nil`
  procedure are checked by the compiled code; a `nil` pointer or a bad
  address is caught by SBCL; a stack overflow by either: past the raz
  stack, or past SBCL's own (256 MB). Each prints where it was, as far
  as it can tell, and the calls under way, without their variables,
  then runs `Rt.atExit`'s procedures and ends with status 2. SBCL may
  also say on standard error that it used a stack's guard page.
- **Messages.** One error is reported, as `file:line:col: what`, and
  the compiler stops with status 1. It gives no warnings, and takes
  `-Werror` and does nothing with it.
- **Every program uses C**, in that SBCL's run time is a C program. A
  module that says `link static` still must not be in a program with
  an `extern` or a `link` of a library, which the compiler reports.

## The library

`lib/` has every module of volume 2: the core (`Rt`, `Out`, `Mem`,
`Arena`, `Lock`, `Str`, `Buf`, and `Sys`) and the rest (`Heap`, `Fmt`,
`List`, `Map`, `Sort`, `Math`, `Files`, `Opt`, `Thread`, `C`,
`Bytes`), in raz, over `SYSCALL` and a few code procedures.

- `Sys` makes Linux's system calls; `spawn` forks and runs the
  program; `catch` has SBCL's run time handle the signals and write
  each to a pipe, the fd it gives.
- `Thread` runs each thread as one of SBCL's, on a raz stack of its
  own; `Mutex` is a futex.
- `Heap` keeps eight free lists, of blocks of 16 to 2048 bytes, and
  gives a bigger block, or one aligned to more than 16 bytes, pages of
  its own. It refuses a negative size, and an alignment that isn't a
  power of 2 up to a page.
- `Bytes`: volume 2 names its procedures but not their parameters.
  Here they are `index(s, b)`, `last(s, b)` and `count(s, b)` for a
  byte `b: U8`, and `find(s, sub)`, each an `INT`, -1 for none.

## Beyond conform/

It compiles the raz compiler, `src/` (with `-I build/src` for its
`Version`), in about 4 seconds. That compiler, run on SBCL, passes
`conform/`, and makes executables byte for byte the same as the native
one's, its own included.

Of the reference compiler's own tests, `test/run` and `examples/`, all
pass whose expected output this target can give: the rest are x86
code procedures (`Asm`, `Atomic`, `Edge`, `Results`, `Simd`, `Single`,
`Cpu`) and a module only for `linux-x86_64` (`Target`). Of
`test/err`, it rejects every program the report makes an error; the
others are that compiler's own limits, its warnings under `-Werror`
and its assembler.
