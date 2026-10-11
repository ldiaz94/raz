# raz: the plan

raz (Polish for *one*, as in counting) is a small systems language in Wirth's
tradition: full control of memory, volatile access, atomics, calls into
C, generic modules. Its compiler is meant to be read in a long weekend:
under 6,000 lines of Free Pascal, one pass, no IR, no optimizer, writing
x86-64 machine code and the ELF file itself.

The language is defined by `doc/raz.md`. Where this plan and the report
disagree, the report wins and this plan is fixed.

## Ground rules

- The compiler is Free Pascal 3.2.2, `{$mode objfpc}{$H-}`: records,
  pointers, shortstrings. No classes, ansistrings, exceptions, dynamic
  arrays or SysUtils.
- The compiler stays near 6,000 lines of code (5,000 until stage 4,
  which bought its diagnostics with the rest) (not counting blank and
  comment lines), within 10%, and compiles at least 400,000 lines of
  raz a second, from reading the sources to writing the executable.
  `make loc` and `make bench` measure them, and a step that breaks
  either limit isn't done.
- Clarity over cleverness. Every unit opens with a header comment: what
  it is, what it depends on, what it leaves out. Comments say why, and
  what wherever a layout or encoding isn't obvious.
- One commit per step, as
  `Luis <42945842+ldiaz94@users.noreply.github.com>`, unsigned,
  with no attribution trailer.
- Work stops after every stage for review. A stage starts only on an
  explicit go-ahead; within it, each step is committed and pushed as it
  is done.
- Not in scope for now: man pages, QEMU or bare metal tests, aarch64,
  macOS and Windows (Mach-O, PE), an optimizer.

## Decisions

1. Source files end in `.raz`, one module per file, named after it.
2. "Not equal" is `#`.
3. Every statement ends in `;`, including `end;` and `until x;`. Every
   match arm starts with `|`, the `else` arm too.
4. Code generation is a stack machine through `rax`: no register
   allocation, and every access the program writes is one instruction
   in source order. Volatile is therefore a type rule; the code
   generator honours it by doing nothing clever.
5. Every procedure uses the System V calling convention, so any
   procedure with scalar parameters can be handed to C as a callback.
6. Records are laid out as C lays them out.
7. Modules are compiled together, from source, in one run: no symbol
   files, no separate compilation. A generic module is compiled once
   per distinct list of arguments, its types and its procedures.
8. Tree shaking: the linker keeps only the procedures, variables and
   literals reachable from the entry point.
9. Variadic arguments exist only to call C. raz code gets the same
   effect from a slice of a variant (`Fmt.print`).
10. Strings are `[]U8`. The language compares them with `=`; the rest
    is a library.

## The compiler, in reading order

Lines after stage 3, all of them and those of code (neither blank nor
only comment), as `make loc` counts them:

| File | Lines | Code | What |
|---|---|---|---|
| `src/scan.pas` | 548 | 471 | Symbols, literals, comments, error messages |
| `src/sym.pas` | 508 | 422 | Types, objects, scopes, layout |
| `src/x64.pas` | 680 | 546 | Code buffer, chunks, fixups, line notes, instruction encoder |
| `src/gen.pas` | 1,414 | 1,240 | Items: loading, storing, copying, frames, calls |
| `src/parse.pas` | 1,816 | 1,685 | Declarations, statements, expressions, built-ins |
| `src/link.pas` | 131 | 95 | Tree shaking, layout, patching |
| `src/elf.pas` | 424 | 350 | Static and dynamic ELF, symbol table, line numbers |
| `src/raz.pas` | 183 | 145 | The command line, the entry points |
| total | 5,704 | 4,954 | |

## Steps

Stage 1: the core

- [x] 1. Language report, `doc/raz.md`. Reviewed and approved before
      any more code.
- [x] 2. Scanner and symbol table, `scan.pas` and `sym.pas`, written
      against the report; they compile.
- [x] 3. Machine code, `x64.pas`.
- [x] 4. Linking and output, `link.pas` and `elf.pas`: tree shaking,
      static ELF, symbol table. A hand built chunk runs.
- [x] 5. Parser and code generator, `gen.pas` and `parse.pas`:
      everything in the report except multiple results, errors,
      enumerations and sets, record literals, `defer`, `NEW`, generic
      modules and `extern`. Module bodies, per-target modules and their
      interface check, and code procedures are in.
- [x] 6. `lib/Rt.raz`, `lib/Sys.linux-x86_64.raz`, `lib/Out.raz`;
      examples (hello, args, variants and slices, volatile, a code
      procedure); `make check` runs them against expected output;
      `make bench` times the compiler on generated raz.

Stage 2: the rest of the language

- [x] 7. Multiple results and errors; `INC` and `DEC`.
- [x] 8. Enumerations and sets, record literals, `defer`; examples.
- [x] 9. `NEW`; `lib/Mem.raz`, `lib/Arena.raz`, `lib/Heap.raz`.
- [x] 10. Generic modules, with type and procedure arguments;
      `lib/Str.raz`, `lib/Buf.raz`, `lib/Fmt.raz`; examples.

Stage 3: calling C, and what comes with it

- [x] 11. `extern proc`, `extern var` and `link`; dynamic ELF, start
      through `__libc_start_main`. A plain `lib/Sys.raz` over the C
      library, the default for targets with no file of their own.
      Examples with `printf` to `stdout`, and an X11 window, reading
      `XEvent` as an array of words through pointer conversions.
      Ending a program: the entry point calls `Rt.exit(status)`, which
      runs the procedures registered with `Rt.atExit`, then ends it;
      `Rt.fail` runs them too. A buffered `lib/Out.raz`: 4 KB, flushed
      at each newline when standard output is a terminal, when full,
      by `Out.flush`, and at exit. The report says how to mix `Out`
      with C's `stdio`: flush one before using the other.
- [x] 12. `F32`: arithmetic, conversions, calls; real literals become
      untyped constants that take `F32` or `F64`.
- [x] 13. A thread-safe `lib/Heap.raz`: its bad sizes refused, and a
      marker in each block's header so that freeing a block twice, or
      one it never gave out, stops the program; `Out` locks its buffer.
      An example with threads from `pthread_create`.
      Native threads for programs without C, in
      `lib/Thread.linux-x86_64.raz`: `spawn` on an `mmap`ed stack with
      a guard page, through `clone` and a small code procedure; `join`
      and a `Mutex` through `futex`. `link static;` marks a module that
      needs a program without C; the compiler refuses a program that
      uses both.
- [x] 14. Line numbers for gdb: `.debug_line`, with the least of
      `.debug_info` and `.debug_abbrev` that gdb needs.

Tools

- [x] 15. Versions first: the report says its version, by date
      (`2026-10.0`, then `.1` for the next change that month), and
      ends with what each version changed; `raz --version` prints its
      own and the report's, `raz 0.3.0, report 2026-10.0`. Each
      finished stage is tagged, `v0.3.0` for stage 3. Then
      `tools/Doc.raz`, a raz program: prints a module's own
      comment, the one before `module`, then its exported
      declarations, each with the comment just before it; and pulls
      out the examples of `doc/raz.md` that are whole modules.
      `make check` also compiles those examples, running the ones with
      a `main`, and runs each library module's `main` as its test.
      The test runner stays in the Makefile: it must work when the
      compiler doesn't. (Tagging is left for later, at the owner's
      word.)

- [x] 16. Editor support: `editor/vim` (`syntax/raz.vim`, `indent/raz.vim`
      by `shiftwidth()`, and `ftdetect/raz.vim`, which sets 4 spaces)
      and `editor/emacs/raz-mode.el` (indenting by `raz-indent-offset`,
      4 unless set). Both colour reserved words, basic types, built-in
      procedures, numbers, characters, strings and nested comments.
      `make check` loads each, headless, on the examples. And a stress
      test of native threads, `make stress`: 40,000 threads spawned and
      joined, about 200 alive at once and waiting on one `Mutex`, so a
      stack `join` failed to free would run the process out of mappings;
      `spawn` under a low thread limit fails with `Thread.Failed`. A small
      version of it runs in `make check`.

Wrap up

- [x] 17. `README.md` and `doc/compiler.md`, a guide to reading the
      compiler file by file.

Later

- [x] 18. `tools/Pretty.raz`, a formatter that keeps every line break
      and comment where it is: it fixes indentation (4 spaces a level)
      and the spaces around operators and after `,` and `;`, and
      leaves formatted code as it is. It shares with `Doc.raz` a
      scanner that keeps comments, `tools/Scan.raz`. `make fmt` checks
      that `lib/`, `examples/` and `tools/` come through unchanged, and
      `make check` does too, with the cases in `test/pretty`.

Stage 4: diagnostics

Messages second to none: each error exact and alone, with the source
under it, notes and suggestions; every error in a run, not just the
first; warnings for what is never used; and run-time failures that say
what failed and where. The budget grows to 6,000 lines for it.

A message looks like this, with colour when standard error is a
terminal and `NO_COLOR` is unset:

```
T.raz:5:10: error: y isn't declared
    5 |     x := y + 1;
      |          ^
help: did you mean x?
T.raz:3:5: note: x is declared here
    3 | var x: I64;
      |     ^
raz: 1 error
```

How messages are worded, for every step that writes one: lowercase,
no full stop, the report's plain words; name the things involved
(`a`, an `I64`) rather than describe them; say what was expected and
what was found; one fact per line, the rest in notes and help.
Symbols are quoted with `"`, names and types are not.

The work splits between the main model, which designs the machinery
and writes the tricky code (marked *main*), and subagents on weaker
models, which do the wide, mechanical parts against an interface the
main model has fixed first (marked *agent*). Agents work one per
file, so that they can run side by side without touching each
other's lines; each runs `make check` before handing back, and the
main model reads every diff before it is committed.

- [x] 19. The report first, for review before any code: messages,
      warnings and `-Werror` in section 10, run-time messages in
      sections 6.5 and 10, report version `2026-10.1`. *main*
- [x] 20. `src/diag.pas`, the one place messages are made: a position
      (a file and a stretch of bytes, its line and columns worked out
      only for a message); the source excerpt
      and its underline, colour, notes and help; counting errors and
      warnings, the summary, `-Werror`, the exit status. `Mark` and
      `Fatal` move there. `test/err` and `test/pretty` keep working:
      `X.err` becomes the whole message, without colour, and the
      Makefile compares all of it. *main*; regenerating and checking
      the 57 `.err` files, *agent*.
- [x] 21. Exact positions. An item and a statement remember where
      they start, so an error points at the whole offending
      expression, not the symbol after it; a missing `;`, `then` or
      `end` points just after the symbol before it. The scanner keeps
      the previous symbol's end. The machinery, *main*; moving each
      of the 200 `Mark` calls onto the right position, *agent*, one
      per file.
- [x] 22. Going on after an error. Each statement and declaration is
      a recovery point (`setjmp`): an error jumps back to it, the
      scanner rereads it from its start and skips to its end, and the
      parser carries on with the next; no error site goes on past its
      error, so none needs reviewing. A name not declared is declared
      with a poison type where it is first used, as are the names of a
      declaration with an error, and errors in a construct that uses
      poison aren't reported. A symbol at the start of a line ends a
      skip: it starts the next declaration, and its procedure is given
      up. Code is still generated, then thrown away; at most 20 errors;
      an error in the text, or a module with errors, stops the run.
      *main*.
      `tools/Mutate.raz`, which deletes, doubles and swaps symbols in
      the tests that compile; `make check` runs it with fixed seeds
      and fails on a crash or two messages at one place. Writing it
      and sorting what it finds, *agent*; the fixes in `gen.pas`,
      *main*.
- [x] 23. Every message reworded to the rules above, each with a test
      in `test/err` that pins its position too. *agent*, one per file
      (`scan.pas`, `parse.pas` in two halves, `gen.pas`, the rest),
      against a list of messages and their tests the main model writes
      first; *main* reviews the wording as a whole.
- [x] 24. Notes and help. Objects remember where they are declared:
      "declared here", "the first one is here", "the signature is
      here". The checks on `main` in `raz.pas` point at
      it, so that every error has a place (the fuzzer finds them). Did you mean: the closest name by edit distance in the
      scopes in reach, in a module's exports, among the built-ins
      (`len` for `LEN`). Slips from other languages: `!=`, `==`, `=`
      for `:=`, `&&`, `||`, `!`, `elif`, a missing `then` or `do`, a
      missing import. The machinery, *main*; the catalogue of slips
      and their tests, *agent*.
- [x] 25. Warnings: an unused import; an unused constant, type,
      variable or procedure that isn't exported; an unused parameter
      of a procedure written in raz; a variable assigned but never
      read. A name starting with `_` is never warned about. `-Werror`
      makes them errors, and `make check` builds `lib/`, `examples/`
      and `tools/` with it. The machinery, *main*; clearing the
      warnings it finds in `lib/`, `examples/` and `tools/`, *agent*.
- [x] 26. Run-time messages. A failed check says which and with what
      values: `index 7 is out of range for a length of 5`, the slice,
      the enumeration position, at file, line and column. A table from
      code addresses to lines goes into the executable, and `Rt` sets
      handlers for SIGSEGV and SIGFPE that print where the program was
      and why (a `nil` pointer, a `nil` procedure, stack overflow, a
      bad address, a division fault) before it dies by that signal.
      Run tests gain an optional `X.stderr`. And the lowest `I64`
      divided by -1 stops the program with SIGFPE, as the report says
      (6.1), and is told as a division fault.
      The compiler and `Rt`,
      *main*; the tests, *agent*.
- [x] 27. `doc/compiler.md` (its table and routine names), `README.md`
      and `CLAUDE.md` brought up to date; `make loc` within 6,000 and
      10%, `make bench` at 400,000 lines a second. *agent*, checked by
      *main*.

Stage 5: ravite, an editor

(The editors have since moved to repositories of their own, rmacs with
emacs's keys and ravite with vim's, each pinning the raz it builds
with; what follows is how they were made here.)

ravite (raz visual text editor) is a terminal editor written in raz,
good enough to write raz in every day, with emacs's keys. It lives in
`ravite/`. Its first version had vim's keys (steps 28 to 33); the
owner chose emacs's instead, with more of emacs: buffers, the
minibuffer, ido, a small dired, M-x, and settings. Steps 28, 29 and 31
stand as they are; the rest is redone from step 35.

Ground rules, besides the plan's:

- No line budget: code that is easy to read and follow, and well
  commented, comes before its length (the owner's word, after step
  40). `make loc` counts it, as a measure.
- On Linux a program without C, a static executable; what it needs of
  the system is `Sys`'s (steps 34 and 41), so that over the C `Sys`
  it runs through the C library.
- Every session test, `test/ravite/X.keys`, does what emacs (`emacs -Q
  -nw`) does with the same keys, checked when it is written, except
  where ravite says it differs (`doc/ravite.md`).
- `make ravite` builds `build/ravite`; `make install` puts it on PATH;
  `make check` runs its tests; `make fmt` covers `ravite/`.

What it does, with emacs's keys and names:

- **Editing.** C-f C-b C-n C-p and the arrows, C-a C-e, M-f M-b, M-<
  M->, C-v M-v, C-l, M-g g, M-{ M-}; typing, RET with the line's
  indent, TAB to the next multiple of 4, DEL C-d, M-DEL M-d, C-k, C-o,
  C-t, M-u M-l M-c. The mark and the region, shown: C-SPC, C-x C-x,
  C-x h, C-w, M-w; the kill ring: C-y, M-y, kills in a row add up.
  C-/ C-_ C-x u undo; M-x undo-redo. C-u and M-digits for a count.
  C-g gets out of anything.
- **Search.** C-s and C-r search incrementally, for text; M-% replaces,
  asking y n ! q at each.
- **Buffers.** Any number. C-x C-f finds a file, C-x C-s saves, C-x
  C-w writes to another name, C-x s saves those that need it, C-x b
  switches, C-x k kills, C-x C-b lists them in a buffer of their own,
  C-x C-c quits, asking about unsaved buffers. `*scratch*` is there
  from the start, a buffer that is no file.
- **The minibuffer.** One line at the bottom, edited with the same keys
  as any buffer. ido completes in it, for buffers, files and M-x:
  the candidates that hold what is typed show after it, C-s and C-r
  turn them round, TAB completes, RET takes the first, C-j takes what
  is typed; for files, / goes into a directory and DEL out of one.
- **Dired.** C-x d, or finding a directory, lists it: RET or f opens
  what is on the line, ^ goes up, n and p move, g reads it again, +
  makes a directory, R renames, D deletes a file after a yes, q leaves.
- **M-x and settings.** Every command has a name and runs by M-x. Keys
  are bound to names in keymaps, with C-x and M-g as prefixes. At
  start ravite reads `~/.ravite`, lines of `bind KEYS COMMAND` and
  `set VARIABLE VALUE`, keys written as emacs writes them (`C-x C-s`,
  `M-%`). M-x global-set-key and set-variable do the same while it
  runs; C-h k and C-h b say what keys do. The variables: indent,
  tab-width, colour, ido.
- **The screen.** The buffer, a mode line (`-UU-:**-  name  L12  Top`)
  and the echo area, which the minibuffer shares. Long lines scroll
  sideways. A `.raz` buffer is coloured as before; `NO_COLOR` or `set
  colour off` turns it off.

What it leaves out: several windows, the mouse, the system clipboard,
undo in a tree (undo and redo are a line), patterns (search is for
text), major modes and their indenting, Lisp, the minibuffer's history,
and dired's marks. FreeBSD comes once `Sys` has what ravite needs.

The modules:

| Module | Lines | What |
|---|---|---|
| `Tty.linux-x86_64.raz` | 120 (155) | the terminal, directories and files, until `Sys` has them |
| `Keys.raz` | 220 (271) | a key from the bytes a terminal sends, Meta too; keys written as emacs writes them |
| `Text.raz` | 330 (337) | the text, a gap buffer, with undo and redo |
| `Colour.raz` | 110 (109) | the colour of each byte on the screen |
| `View.raz` | 170 (121) | the screen: the buffer, the mode line, the echo area |
| `Core.raz` | 300 (375) | buffers, the current one, the echo area, reading keys and running them, through procedures the main module sets |
| `Edit.raz` | 450 (558) | moving, typing, deleting, the mark, the kill ring, undo |
| `Mini.raz` | 350 (269) | the minibuffer, ido, yes or no |
| `Search.raz` | 200 (241) | incremental search, query-replace |
| `Dired.raz` | 250 (336) | directories, and the list of buffers |
| `Commands.raz` | 400 (799) | the commands' names, keymaps, M-x, settings, help, files and buffers |
| `Ravite.raz` | 250 (271) | the arguments, the screen, the keys from the terminal or a script, the loop |
| total | 3,150 (3,842) | |

In brackets, what each came to by step 40: 3,842 lines, past the
3,300 then planned. The owner set the budget aside for readability;
step 41 took `Tty`'s 155 lines out to `Sys`.

Testing. `ravite -script W H file...` reads keys as emacs writes them
from standard input, on a screen W by H, and at their end, or at C-x
C-c, prints the screen as plain text, then the current buffer. Each
`test/ravite/X.keys` has its `X.expect`, and may have an `X.txt` to
start from, or `X.args` for other arguments. Each module's `main` is
its test.

Steps 28 to 33 (vim's keys):

- [x] 28. `Tty` and `Keys`, with `Keys`'s test; raw mode, the size
      and the keys tried through a pseudo-terminal.
- [x] 29. `Text`: the gap buffer and undo, with its test.
- [x] 30. `View` and `Ravite` with vim's keys; `-script` and
      `test/ravite`; `make ravite`, `make loc` and `make fmt`.
- [x] 31. `Colour`.
- [x] 32. Visual mode, search, `%`, `f t`, and `file:line`.
- [x] 33. `doc/ravite.md`.

Steps 34 on (emacs's keys):

- [x] 34. The report: what `Sys` gains for ravite, for review before
      any code (report version `2026-10.2`).
- [x] 35. `Keys` with Meta and emacs's notation; `Core`, `View` with a
      mode line and the echo area, `Edit`, `Commands` with keymaps and
      C-u, `Mini` without ido, and `Ravite`: editing with emacs's keys,
      finding, saving and writing files, M-x by full name, quitting; the
      session tests, checked against emacs.
- [x] 36. ido in the minibuffer, for M-x, files and buffers; buffers,
      `*scratch*`, C-x b, C-x k, C-x C-b, C-x s, C-x C-c.
- [x] 37. `Search`: C-s, C-r, M-%.
- [x] 38. `Dired`.
- [x] 39. Settings: `~/.ravite`, M-x global-set-key and set-variable,
      C-h k, C-h b.
- [x] 40. `doc/ravite.md` again, `README.md`, `CLAUDE.md`; `test/emacs.py`,
      which checks a session against emacs.
- [x] 41. Once the owner approves step 34: `Sys` gains it, on Linux
      and over C, with tests; ravite's `Tty` goes. `make check` runs
      ravite's sessions over both.

Stage 6: the language of report 2026-10.3

The owner's choices after stage 5, written into the report first:
results passed on by `return`; `and`, `or` and `not` for `BOOL`s only,
binding below the relations, and `&`, `|`, `~` for bits, as in Go; `=`
on arrays and slices of plain elements, compiled where it stands
rather than called in `Rt`, so that no syntax runs hidden library
code; and generic instances made where they are first used, so that
their arguments may name types declared after the imports. Not
started: each step waits for the owner's word, and stage 4's open
steps come first unless the owner says otherwise.

- [x] 42. The report, version 2026-10.3: sections 2, 3, 6, 6.5, 7.3, 8
      and 11, and the list of versions. Approved before any code.
- [ ] 43. `return f(x);`: the call writes its results through the
      procedure's own hidden pointer, the one its caller gave it. The
      results must be the procedure's, type for type; `test/err` for
      a mismatch, `test/run` for one, two and three results, through
      two levels of calls.
- [ ] 44. `=` and `#` inline: the lengths compared, then, if equal,
      the bytes, `LEN * SIZE(T)` of them, with `repe cmpsb`; for
      strings and for arrays and slices of integers, `BOOL`s,
      enumerations, sets and pointers, any mix of `[n]T` and `[]T`.
      `Rt.eq` goes, and CLAUDE.md's note that the compiler finds it by
      name. Tests: equal, of different lengths, empty, a string
      literal against an array, and in `test/err` arrays of `F64`, of
      records, and of two element types.
- [ ] 45. Operators: `&` and `~` in the scanner, `|` an operator where
      an operand came before it; the parser's levels, `or` over `and`
      over the relations; `and`, `or`, `not` refused on integers and
      `&`, `|`, `xor`, `~` on `BOOL`s, each with a message that names
      the other. Every raz source moves to the new operators: `lib/`,
      `tools/` (Pretty spaces `&` and `|` as it spaces `+`, and
      leaves a match arm's `|` where it is), `examples/`, `test/`, the
      report's examples, and `test/genbench.py`; each `and` or `or`
      between relations is checked by hand, since its meaning may
      change without an error. `make bench` must still pass.
- [ ] 46. Generic instances on first use: the import keeps its
      arguments unresolved, and the instance is made, and its body
      queued to run before the importer's, the first time the import's
      name is used; an argument not declared by then is an error at
      the import. Tests: a type declared after the import, two imports
      sharing one instance, an import never used (no instance), and
      the error.
- [ ] 47. `doc/compiler.md` (its table and routine names),
      `README.md`, CLAUDE.md's readings, the report's first line and
      the compiler's to 2026-10.3; `make loc` within 6,000 and 10%,
      `make bench` at 400,000 lines a second. Then the editors, rmacs
      and ravite, move their pin to this raz, in their own
      repositories, with their sources moved to the new operators.

Stage 7: Sys for rlX11 and rat, report 2026-10.4

rlX11, an X11 client library written in raz, and rat, a terminal
emulator over it, are to need no C: they talk to the X server over a
socket, and rat runs its programs on a pseudo-terminal. Sys gains what
that takes. Approved; under way, each step on the owner's word.

- [x] 48. The report, version 2026-10.4: `connect`, `readyOf`,
      `openPty`, `setTermSize`, `spawn`, `wait`, `kill` (section 11),
      for review before any code.
- [x] 49a. The owner approves 2026-10.4. `connect` and `readyOf`, what
      rlX11 needs first: on Linux `socket` (close-on-exec) and
      `connect` for a Unix socket, `poll` over several fds; over C
      by POSIX's names, `struct sockaddr_un` named glibc's. Both
      files' tests: `connect` refused where nothing listens, and taken
      by a listener the test makes, which `readyOf` then finds ready;
      a byte across, and the end of the connection.
- [x] 49c. `send` (report 2026-10.7), at the owner's word: `write` to
      a socket with `MSG_NOSIGNAL`, -32 (EPIPE) where `write` would
      bring SIGPIPE. Both tests send to a connection closed.
- [ ] 49b. The rest, for rat: `/dev/ptmx` with `TIOCSPTLCK` and
      `TIOCGPTN` for the pseudo-terminal, `TIOCSWINSZ` for its size;
      `fork`, then in the child `setsid`, the terminal opened as its
      controlling one with `TIOCSCTTY`, `dup2` to 0, 1 and 2,
      `close_range` for the rest, and `execve` with the environment
      made from this one's; `wait4`, `kill`. Over C by POSIX's names
      (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname`, `fork`,
      `execve`, `waitpid`, `kill`), what is glibc's named in the
      file, as before. Both files' tests: a program spawned on a
      pseudo-terminal that prints its size and its arguments and ends
      with a status read back by `wait`; a program stopped by `kill`.

Stage 8: one module to a name, report 2026-10.5

A module found in two directories was taken from the first, silently,
by every module that imports it: a program's `C.raz` stood in for the
library's `C` inside `Rt`, and the compiler said only "Rt imports
itself". Not started: each step waits for the owner's word.

- [x] 50. The report, version 2026-10.5: one module to a name, the
      link that chooses a file, libraries' prefixes (section 3), for
      review before any code.
- [ ] 51. `ModuleFile` goes on through the later directories once it
      has found a module's file, and an error names the files of each
      other directory that has the module, unless the file found is a
      symbolic link to one of them (compared by device and inode). A
      test in `test/err` with a `C.raz` of its own; `test/libc`, and
      ravite's `ravite-c`, still build through their link to
      `lib/Sys.raz`. `Report` in `src/raz.pas` goes to 2026-10.5
      with it, or with step 49, whichever comes last.
