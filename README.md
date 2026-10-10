# raz

raz (Polish for *one*, as in counting) is a small systems language in Wirth's
tradition, for x86-64 Linux. A raz program can lay a record over a
device's registers, read and write memory exactly as written, take part
in lock-free algorithms, make system calls and call C libraries. It has
no garbage collector and no hidden run time: what the program does is
what its text says.

```
module Hello;
import Out;

proc main*;
begin
    Out.str("hello, world\n");
end;

end Hello.
```

    $ make
    $ ./raz examples/Hello.raz
    $ examples/Hello
    hello, world

The compiler is under 5,000 lines of Free Pascal: one pass, no
intermediate form, no optimizer. It writes x86-64 machine code and the
ELF executable itself, with no assembler or linker, and compiles about
a million lines a second.

## What's here

| Path | What |
|---|---|
| `doc/raz.md` | The language report: the definition of raz |
| `doc/compiler.md` | A guide to reading the compiler, file by file |
| `src/` | The compiler, in Free Pascal |
| `lib/` | The library, in raz; the compiler finds it beside itself |
| `examples/` | Small programs, each with the output it should give |
| `tools/Doc.raz` | Prints what a module exports, with its comments |
| `tools/Pretty.raz` | The formatter: fixes indentation and spacing |
| `editor/` | Support for vim and emacs |
| `test/` | Tests, and the scripts that run them |
| `PLAN.md` | How the compiler was built, step by step |

## Building

The compiler needs Free Pascal 3.2.2 (`apt-get install fp-compiler`)
and builds into the repository's root:

    make            # ./raz

The tests need a shell and Python 3; the editor checks run if vim or
emacs is installed.

    make check      # every example and test, against what it should give
    make bench      # the compiler's speed on a program of 350,000 lines
    make stress     # 40,000 threads, started and joined
    make gdb        # gdb stops at a line of raz and names it
    make fmt        # the library, examples and tools are formatted
    make loc        # the compiler's lines
    make tests      # tests of the scanner, encoder and linker on their own

## Using it

    raz [-I dir]... [-o file] Main.raz
    raz run [-I dir]... Main.raz [arg]...
    raz --version

`raz Main.raz` compiles module `Main` and every module it imports, and
writes the executable `Main`. A module `Name` lives in `Name.raz`, found
in the main module's directory, then in each `-I` directory, then in
`lib`. A module whose code depends on the system comes in one file per
target, `Name.linux-x86_64.raz` before `Name.raz`; the compiler checks
that all of them export the same things.

`raz run Main.raz a b` compiles the same way, then runs the program
with the arguments `a b`, writing no file: its output and exit status
are the command's.

A program that calls no C is a static executable of a few kilobytes,
holding only the code it reaches. One that declares an `extern`
procedure is linked dynamically against the C library, and starts
through it. Either way, gdb finds its procedures by name and its lines
by number.

## The language, briefly

- Integers of 8 to 64 bits, signed and unsigned, which wrap; `BOOL`,
  `F32`, `F64`. No conversion happens unless it is written.
- Arrays, slices (`[]T`, checked), pointers (unchecked), records laid
  out as C lays them out, packed records, variants with `match`,
  enumerations and sets, procedure types.
- `^VOLATILE T`: every access through it is one instruction of its
  size, in the order written. `CAS`, `XCHG`, `XADD`, `FENCE`.
- Several results, `ERROR` values compared by identity, `defer`.
- Modules with bodies; generic modules with type and procedure
  arguments, `Map(K, V; hash, eq)`.
- Every variable starts at zero, and behaviour is defined everywhere
  but through pointers.
- `extern` procedures and variables from C; code procedures written as
  bytes of machine code; `SYSCALL`.

The report, `doc/raz.md`, says all of it in about 900 lines.

## The library

`Rt` (ending the program, checks), `Sys` (system calls), `Out`
(buffered output), `C`, `Lock`, `Thread` (threads without C), `Mem`,
`Heap`, `Arena`, `Str`, `Buf`, `Fmt`, `List(T)` and `Map(K, V; hash,
eq)`. `tools/Doc.raz` prints any of them:

    $ ./raz -o Doc tools/Doc.raz && ./Doc lib/Str.raz

Each library module's `main` is its test, which `make check` runs.

## Editors

`editor/vim` holds a syntax file, an indent file and file type
detection: add it to `runtimepath`. `editor/emacs/raz-mode.el` is a
major mode: put it on `load-path` and `(require 'raz-mode)`. Both
colour the language and indent it as the examples are indented.

`tools/Pretty.raz` formats a whole file the same way: it fixes the
indentation, 4 spaces a level, and the spaces around operators and
after `,` and `;`, and keeps every line break and comment where it is.

    $ ./raz -o Pretty tools/Pretty.raz
    $ ./Pretty Module.raz       # prints it, formatted
    $ ./Pretty -w *.raz         # rewrites those that aren't, and names them

## Versions

The compiler says its own version and that of the report it follows:

    $ ./raz --version
    raz 0.3.0, report 2026-10.0

The compiler's version is git's name for the commit it was built from:
`0.3.0` at the tag `v0.3.0`, `0.3.0-5-g38d29a8` five commits past it.
A release is a tag `vX.Y.Z` pushed to GitHub, which builds it, checks
it, and attaches `raz` with its `lib/` to the release.

A version of the report is named by its month and a count; the report's
last section says what each version changed.

## Not here

Other systems and processors (Mach-O, PE, aarch64), an optimizer,
separate compilation, records passed to C by value, thread-local
variables, and type information for debuggers.

## License

ISC; see `LICENSE`.
