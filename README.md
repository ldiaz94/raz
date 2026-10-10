# jed

jed (Polish *jeden*, one) is a small systems language in Wirth's
tradition, for x86-64 Linux. A jed program can lay a record over a
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
    $ ./jed examples/Hello.jed
    $ examples/Hello
    hello, world

The compiler is under 5,000 lines of Free Pascal: one pass, no
intermediate form, no optimizer. It writes x86-64 machine code and the
ELF executable itself, with no assembler or linker, and compiles about
a million lines a second.

## What's here

| Path | What |
|---|---|
| `doc/jed.md` | The language report: the definition of jed |
| `doc/compiler.md` | A guide to reading the compiler, file by file |
| `src/` | The compiler, in Free Pascal |
| `lib/` | The library, in jed; the compiler finds it beside itself |
| `examples/` | Small programs, each with the output it should give |
| `tools/Doc.jed` | Prints what a module exports, with its comments |
| `editor/` | Support for vim and emacs |
| `test/` | Tests, and the scripts that run them |
| `PLAN.md` | How the compiler was built, step by step |

## Building

The compiler needs Free Pascal 3.2.2 (`apt-get install fp-compiler`)
and builds into the repository's root:

    make            # ./jed

The tests need a shell and Python 3; the editor checks run if vim or
emacs is installed.

    make check      # every example and test, against what it should give
    make bench      # the compiler's speed on a program of 350,000 lines
    make stress     # 40,000 threads, started and joined
    make gdb        # gdb stops at a line of jed and names it
    make loc        # the compiler's lines
    make tests      # tests of the scanner, encoder and linker on their own

## Using it

    jed [-I dir]... [-o file] Main.jed
    jed --version

`jed Main.jed` compiles module `Main` and every module it imports, and
writes the executable `Main`. A module `Name` lives in `Name.jed`, found
in the main module's directory, then in each `-I` directory, then in
`lib`. A module whose code depends on the system comes in one file per
target, `Name.linux-x86_64.jed` before `Name.jed`; the compiler checks
that all of them export the same things.

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

The report, `doc/jed.md`, says all of it in about 900 lines.

## The library

`Rt` (ending the program, checks), `Sys` (system calls), `Out`
(buffered output), `C`, `Lock`, `Thread` (threads without C), `Mem`,
`Heap`, `Arena`, `Str`, `Buf`, `Fmt`, `List(T)` and `Map(K, V; hash,
eq)`. `tools/Doc.jed` prints any of them:

    $ ./jed -o Doc tools/Doc.jed && ./Doc lib/Str.jed

Each library module's `main` is its test, which `make check` runs.

## Editors

`editor/vim` holds a syntax file, an indent file and file type
detection: add it to `runtimepath`. `editor/emacs/jed-mode.el` is a
major mode: put it on `load-path` and `(require 'jed-mode)`. Both
colour the language and indent it as the examples are indented.

## Versions

The compiler says which version of the report it follows:

    $ ./jed --version
    jed 0.3.0, report 2026-10.0

A version of the report is named by its month and a count; the report's
last section says what each version changed.

## Not here

Other systems and processors (Mach-O, PE, aarch64), an optimizer,
separate compilation, records passed to C by value, thread-local
variables, and type information for debuggers.
