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

The compiler is about 11,500 lines of raz, written in itself: one pass, no
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
| `BOOT` | The release that builds `src/`, by its tag and its tarball's SHA-256 |
| `lib/` | The library, in raz; the compiler finds it beside itself |
| `examples/` | Small programs, each with the output it should give |
| `tools/Doc.raz` | Prints what a module exports, with its comments |
| `tools/Pretty.raz` | The formatter: fixes indentation and spacing |
| `tools/Test.raz` | `raztest`: builds and runs a program's tests, `-j` at once; `make install` puts it on PATH, `doc/raztest.1` says how |
| `site/` | The website: home page, the tours "Raz, Set, Go" and "More Raz", the report and the latest release's tarball, as plain files in `site/public/`; `make site` rebuilds them, with the report's two PDFs (`make pdf`) |
| `editor/` | Support for vim and emacs |
| `conform/` | The conformance suite: what every implementation must do |
| `sbcl/` | An example: a second compiler, in Common Lisp for SBCL, written from the report alone and kept as a reference; it passes `conform/` and builds `src/` into a compiler that makes the same bytes. Not part of the build |
| `test/` | This compiler's own tests, and the scripts that run them |

## Building

The compiler is written in raz, so building it takes a raz: the
release `BOOT` names. `make` fetches that release's tarball into
`build/boot/` (by curl, or by `gh` where the repository is private),
checks its SHA-256 against `BOOT`'s, and has its `raz` build the
compiler, `src/`, in the repository's root, against this `lib/`. On a
machine with no network, put the tarball in `build/boot/` by hand.
Each release is built by the one before it, back to v0.19.0, which the
first compiler, in Free Pascal, built; git has that compiler, in
`seed/` at v0.19.0, so raz can be built again from source alone. `make
fixpoint` has the compiler build itself and checks that the result is
the same file.

    make            # ./raz
    make install    # ~/.local/bin/raz, its library and tools in
                    # ~/.local/lib/raz, as the release's tarball has them,
                    # and its manual pages, raz(1), raz(7),
                    # raz-tutorial(7) and raz-lib(3)
    make uninstall  # removes them again

Both take `PREFIX=/usr/local` (or another place) instead of `~/.local`.

The tests need only a shell; the editor checks run if vim or
emacs is installed.

    make check      # every example and test, against what it should give
    make bench      # the compiler's speed on a program of 350,000 lines
    make prev-bench # the same against BOOT's: more than a tenth slower fails
    make kernels    # the code's speed against FPC -O2's (apt-get install fp-compiler)
    make stress     # 40,000 threads, started and joined
    make gdb        # gdb stops at a line of raz and names it
    make fmt        # the library, examples, tools and site programs are formatted
    make loc        # the compiler's lines
    make pdf        # build/raz.pdf and build/raz-lib.pdf, the two volumes, by pandoc and Chromium
    make dist       # build/raz-V-linux-x86_64.tar.gz, the release's tarball
    make site       # site/public/, the website, by site/Build.raz, pandoc and pdfinfo
    make site-source # /source/, its releases and HTTP clone store, by site/Source.raz, git and ladle
    make site-check # the site's release selection, against small real repositories

## Using it

    raz [-I dir]... [-o file] [-Werror] [-S] [-s] [-noprofile] [-libc glibc|musl] [-base addr] [-bare] Main.raz
    raz run [option]... Main.raz [arg]...
    raz -h
    raz --version

`raz -h` says the options, and `man raz` says more. `man
raz-tutorial` is a tour of the language, `man 7 raz` the language at
a glance, and `man raz-lib` the library, made from its sources.

`raz Main.raz` compiles module `Main` and every module it imports, and
writes the executable `Main`. A module `Name` lives in `Name.raz`, found
in the main module's directory, then in each `-I` directory, then in
the user library directories, then in `lib`. A module whose code depends
on the system comes in one file per target, `Name.linux-x86_64.raz`
before `Name.raz`; the compiler checks
that all of them export the same things.

Install third-party source modules directly in `$HOME/.raz/lib` to use
them from any project without `-I` or a Git submodule. Keep their
target-specific files beside them; directories are not searched
recursively. A library's makefile or Robfile can provide install and
uninstall tasks for its own files. For example, for a library `Json`:

```sh
mkdir -p "$HOME/.raz/lib"
install -m644 Json.raz "$HOME/.raz/lib/Json.raz"
raz Main.raz                         # import Json; needs no -I
```

`RAZ_PATH` replaces the default directory with a colon-separated list:

```sh
export RAZ_PATH="$HOME/.raz/lib:$HOME/work/raz-libs"
RAZ_PATH= raz -I deps/json Main.raz  # use only the project's dependency
```

An unset `RAZ_PATH` uses `$HOME/.raz/lib`; an empty one disables user
libraries while keeping the standard library. With no nonempty `HOME`,
there is no default. Empty list entries are ignored. Relative paths
start at the compiler's working directory; the compiler does not expand
`~` or variables within them. Duplicate modules are errors across all
search directories, with the report's symbolic-link exception, so `-I`
does not override an installed module. Projects that need particular
dependency versions can set `RAZ_PATH` for their build.

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
out only the profiler. `-base addr` loads the program at `addr`, not
400000H, in the low or the top 2 GB, as a kernel may want, and
`-bare` makes one for the bare machine: no arguments are read and no
signal handlers set.

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
  enumerations and sets, procedure types. `LEN(s)` and `PTR(s)` take a
  slice apart into a length and a pointer, for a record or for C, an
  empty one too.
- `^VOLATILE T`: every access through it is one instruction of its
  size, in the order written. `CAS`, `XCHG`, `XADD`, `FENCE`.
- `and`, `or` and `not` for `BOOL`s; `&`, `|`, `xor` and `~` for bits;
  `=` on arrays and strings.
- Strings are `[]U8`, in UTF-8; raw strings between backquotes run over
  lines and keep the indent of the code around them; `match` takes a
  string.
- Several results, `ERROR` values compared by identity, `defer`.
- Modules with bodies; generic modules with type and procedure
  arguments, `Map(K, V; hash, eq)`.
- Every variable starts at zero, and behaviour is defined everywhere
  but through pointers.
- `extern` procedures and variables from C; code procedures written in
  the target's assembly language; `SYSCALL`.

The report, `doc/raz.md` and `doc/raz-lib.md`, says all of it in about 2,800 lines.

## The library

`Rt` (ending the program, failed checks, signals), `Sys` (system calls), `Out`
(buffered output), `C`, `Lock`, `Thread` (threads, with C or without), `Mem`,
`Heap`, `Arena`, `Str`, `Bytes`, `Buf`, `Fmt`, `Math`, `Files`, `Opt` (a command
line read through one table), `Width` (the columns of a terminal text takes), `List(T)`, `Map(K, V; hash, eq)`,
`Vec(T)` (a growable array), `Task(T)` and `Guarded(T)` (threads that take a value, and a value with its lock) and `Sort(T; less)`. Volume 2 of the report, `doc/raz-lib.md`, gives each one's interface,
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

## CI image

`containers/ci/` builds an x86-64 Linux image with released raz 0.21.0,
its library and tools, pinned concha and robbie, and Debian build tools.
Its [README](containers/ci/README.md) gives the build and checks.
The image revision is `0.21.0-debian12-r1`.

`registry/` prepares a separate Cloudflare Worker and R2 registry for
public Docker pulls and authenticated pushes. Its [README](registry/README.md)
gives deployment and publishing steps. The container workflow validates
the image and registry; publishing is an explicit manual option and
needs a deployed registry and its publisher secret.

## Versions

The compiler says its own version and that of the report it follows:

    $ ./raz --version
    raz 0.25.0, report 2026-10.38

The compiler's version is git's name for the commit it was built from:
`0.25.0` at the tag `v0.25.0`, `0.25.0-5-g38d29a8` five commits past it.
To release, check `main` and tag it; the tag's message is what
`raz --version` will print:

    $ make check
    $ git tag -a v0.25.0 -m 'raz 0.25.0, report 2026-10.38'
    $ git push origin v0.25.0

GitHub then builds and checks the tag, and makes a release of it with
a tarball of `raz`, its `lib/` and its manual pages, made by `make
dist`. A tag pushed before the workflow existed is released from the
Actions tab: run "ci" with its name. Then `make site` adds the new
tag's tarball to the website's `download/` (it builds it from the tag,
apart from the tree at hand); commit `site/public/` and push to publish
it. A release whose tag isn't pushed yet goes there too, by `make site
RELEASES="v0.25.0=COMMIT"`: `make dist REV=COMMIT VERSION=0.25.0` makes
the tarball the tag will, byte for byte. Every release since 0.7.1 stays there, at its own name, and is
never made again, so that its SHA-256 holds: programs pin raz by it.
From 0.15.0 on, `make dist` makes the same tarball, byte for byte,
wherever it runs, so GitHub's and the website's agree. Once a release
is out, `BOOT` may name it, and the next one is built by it: then
`src/` may use what it brought.

The website's [source browser](https://raz.lucelad.workers.dev/source/)
has the files, history and [release pages](https://raz.lucelad.workers.dev/source/releases/).
Each supported version has its compiler archive, a separate source
archive and SHA-256s. The same address is a git remote:

    git clone https://raz.lucelad.workers.dev/source/

`site/releases` records existing website distributions whose tags
are not pushed yet, so a plain `make site` keeps offering them. Both
the home page and ladle's release pages use this list. Existing
`download/` URLs and compiler archives keep their exact bytes.
[Building the site](site/README.md) gives the complete procedure.
`make site` runs ladle after building the normal pages and merges its
headers under `/source/`. The source output stays ignored; Wrangler's
build hook regenerates it before `npx wrangler deploy` uploads the
site. Commit the main pages, scripts and pinned builder, then push
`main` for the existing Cloudflare deployment.

A version of the report is named by its month and a count; the report's
last section says what each version changed.

Since v0.5.0 the language is frozen, softly: it changes only to mend a
defect, and the library grows only by what breaks no program. A library
change that must break programs keeps the old form for one minor version
beside the new; the release notes list the old forms, and the next
version removes them. Thaws, by the owner's word, changed it since;
the last, for safety, was v0.24.0, and v0.25.0 the last change. It is
now frozen hard: no more thaws, the language mended only where it does
other than the report says.

## Not here

Other systems and processors (Mach-O, PE, aarch64), an optimizer,
separate compilation, records passed to C by value, thread-local
variables, and type information for debuggers.

## License

ISC; see `LICENSE`.
