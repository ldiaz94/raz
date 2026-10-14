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

The compiler is about 10,700 lines of raz, written in itself: one pass, no
intermediate form, no optimizer. It writes x86-64 machine code and the
ELF executable itself, with no assembler or linker, and compiles about
500,000 lines a second.

## What's here

| Path | What |
|---|---|
| `doc/raz.md`, `doc/raz-lib.md` | The report: the language (volume 1) and the library (volume 2) |
| `doc/compiler.md` | A guide to reading the compiler, file by file |
| `doc/raz.1`, `doc/raz.7`, `doc/raz-tutorial.7` | The manual pages: the command, the language at a glance, a tour; `make man` makes the library's, raz-lib(3), from `lib/` |
| `src/` | The compiler, in raz |
| `seed/` | The first compiler, in Free Pascal: frozen, kept only to build `src/` the first time |
| `lib/` | The library, in raz; the compiler finds it beside itself |
| `examples/` | Small programs, each with the output it should give |
| `tools/Doc.raz` | Prints what a module exports, with its comments |
| `tools/Pretty.raz` | The formatter: fixes indentation and spacing |
| `site/` | The website: home page, the tours "Raz, Set, Go" and "More Raz", the report and the latest release's tarball, as plain files in `site/public/`; `make site` rebuilds them, with the report's two PDFs (`make pdf`) |
| `editor/` | Support for vim and emacs |
| `conform/` | The conformance suite: what every implementation must do |
| `test/` | This compiler's own tests, and the scripts that run them |
| `PLAN.md` | The plan: the milestone under way and its steps |

## Building

The compiler is written in raz, so building it takes a raz. The first
time there is none, and Free Pascal 3.2.2 (`apt-get install fp-compiler`)
builds the seed, the Pascal compiler in `seed/`, which builds the
compiler, `src/`, in the repository's root. Free Pascal is needed for
nothing else, and `make fixpoint` has the compiler build itself and
checks that the result is the same file.

    make            # ./raz
    make install    # ~/.local/bin/raz, its library and tools in
                    # ~/.local/lib/raz, as the release's tarball has them,
                    # and its manual pages, raz(1), raz(7),
                    # raz-tutorial(7) and raz-lib(3)
    make uninstall  # removes them again

Both take `PREFIX=/usr/local` (or another place) instead of `~/.local`.

The tests need a shell and Python 3; the editor checks run if vim or
emacs is installed.

    make check      # every example and test, against what it should give
    make bench      # the compiler's speed on a program of 350,000 lines
    make stress     # 40,000 threads, started and joined
    make gdb        # gdb stops at a line of raz and names it
    make fmt        # the library, examples and tools are formatted
    make loc        # the compiler's lines
    make tests      # tests of the scanner, encoder and linker on their own
    make pdf        # build/raz.pdf and build/raz-lib.pdf, the two volumes, by pandoc and Chromium
    make dist       # build/raz-V-linux-x86_64.tar.gz, the release's tarball
    make site       # site/public/, the website, by pandoc and python3

## Using it

    raz [-I dir]... [-o file] [-Werror] [-S] [-s] [-noprofile] Main.raz
    raz run [option]... Main.raz [arg]...
    raz -h
    raz --version

`raz -h` says the options, and `man raz` says more. `man
raz-tutorial` is a tour of the language, `man 7 raz` the language at
a glance, and `man raz-lib` the library, made from its sources.

`raz Main.raz` compiles module `Main` and every module it imports, and
writes the executable `Main`. A module `Name` lives in `Name.raz`, found
in the main module's directory, then in each `-I` directory, then in
`lib`. A module whose code depends on the system comes in one file per
target, `Name.linux-x86_64.raz` before `Name.raz`; the compiler checks
that all of them export the same things.

An error is shown with its file, line and column, the line of source
underlined, and notes and help where they help: where a name is
declared, a name spelled almost alike. The compiler goes on to find
the others, up to 20. It warns of what is declared and never used,
and of a variable assigned but never read, unless its name starts with
`_`; `-Werror` makes warnings errors. `-S` prints the main module's
code instead of writing it: each line of source, and under it the
instructions made for it. `-s` strips what is there for finding faults:
the symbols and line numbers, the places a failure is told by, and the
profiler, so hello, world is 7 KB instead of 28; `-noprofile` leaves
out only the profiler.

At run time, a failed check says where it is and what failed, as in
`Main.raz:12:9: index 7 is out of range for a length of 5`, and ends
the program with status 2. A program stopped by a signal says where it
was and why first: a `nil` pointer, a `nil` procedure, a stack
overflow, a bad address or a division fault. Either then says the
calls under way, each with its variables:

    Main.raz:12:9: index 7 is out of range for a length of 5
      in Main.get at Main.raz:12:9: i = 7, n = 5
      in Main.main at Main.raz:20:5: count = 3

`Rt.trace` says the same at any time.

A program run with `RAZ_PROFILE` set in its environment is sampled
every millisecond of its time; at its end it says which procedures, and
which places in the source, took the most of it: each procedure's time
in its own code, and its total, with the procedures it called.

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
- `and`, `or` and `not` for `BOOL`s; `&`, `|`, `xor` and `~` for bits;
  `=` on arrays and strings.
- Several results, `ERROR` values compared by identity, `defer`.
- Modules with bodies; generic modules with type and procedure
  arguments, `Map(K, V; hash, eq)`.
- Every variable starts at zero, and behaviour is defined everywhere
  but through pointers.
- `extern` procedures and variables from C; code procedures written in
  the target's assembly language; `SYSCALL`.

The report, `doc/raz.md` and `doc/raz-lib.md`, says all of it in about 2,100 lines.

## The library

`Rt` (ending the program, failed checks, signals), `Sys` (system calls), `Out`
(buffered output), `C`, `Lock`, `Thread` (threads without C), `Mem`,
`Heap`, `Arena`, `Str`, `Bytes`, `Buf`, `Fmt`, `Math`, `Files`, `Opt` (a command
line read through one table), `List(T)`, `Map(K, V; hash, eq)` and
`Sort(T; less)`. Section 11 of the report gives each one's interface,
and `tools/Doc.raz` prints it from the module's file:

    $ ./raz -o Doc tools/Doc.raz && ./Doc lib/Str.raz

Each library module's `main` is its test, which `make check` runs; the
generic ones, which can't run alone, are tested in `conform/run`.

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

Two editors are written in raz, each in a repository of its own that
pins the raz it is built with: rmacs, with emacs's keys, and ravite,
with vim's. Both colour raz through `tools/Scan.raz`.

## Versions

The compiler says its own version and that of the report it follows:

    $ ./raz --version
    raz 0.11.0, report 2026-10.22

The compiler's version is git's name for the commit it was built from:
`0.11.0` at the tag `v0.11.0`, `0.11.0-5-g38d29a8` five commits past it.
To release, check `main` and tag it; the tag's message is what
`raz --version` will print:

    $ make check
    $ git tag -a v0.11.0 -m 'raz 0.11.0, report 2026-10.22'
    $ git push origin v0.11.0

GitHub then builds and checks the tag, and makes a release of it with
a tarball of `raz`, its `lib/` and its manual pages, made by `make
dist`. A tag pushed before the workflow existed is released from the
Actions tab: run "ci" with its name. Then `make site` adds the new
tag's tarball to the website's `download/` (it builds it from the tag,
apart from the tree at hand); commit `site/public/` and push to publish
it. Every release since 0.7.1 stays there, at its own name, and is
never made again, so that its SHA-256 holds: programs pin raz by it.

A version of the report is named by its month and a count; the report's
last section says what each version changed.

Since v0.5.0 the language is frozen, softly: it changes only to mend a
defect, and the library grows only by what breaks no program. Wishes
wait on a list in `PLAN.md`, for a later thaw; v0.6.0 was one, for a
language anyone can build again from its report.

## Not here

Other systems and processors (Mach-O, PE, aarch64), an optimizer,
separate compilation, records passed to C by value, thread-local
variables, and type information for debuggers.

## License

ISC; see `LICENSE`.
