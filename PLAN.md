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
- [ ] 21. Exact positions. An item and a statement remember where
      they start, so an error points at the whole offending
      expression, not the symbol after it; a missing `;`, `then` or
      `end` points just after the symbol before it. The scanner keeps
      the previous symbol's end. The machinery, *main*; moving each
      of the 200 `Mark` calls onto the right position, *agent*, one
      per file.
- [ ] 22. Going on after an error. A poison type that every check
      accepts without a word, so one mistake makes one message; a name
      not declared is declared as poison where it is first used; after
      a syntax error the parser skips to the next `proc` or the end of
      the module; code is still generated, then thrown away; at most
      20 errors. A module with errors stops the run after it. *main*.
      `tools/Mutate.raz`, which deletes, doubles and swaps symbols in
      the tests that compile; `make check` runs it with fixed seeds
      and fails on a crash or two messages at one place. Writing it
      and sorting what it finds, *agent*; the fixes in `gen.pas`,
      *main*.
- [ ] 23. Every message reworded to the rules above, each with a test
      in `test/err` that pins its position too. *agent*, one per file
      (`scan.pas`, `parse.pas` in two halves, `gen.pas`, the rest),
      against a list of messages and their tests the main model writes
      first; *main* reviews the wording as a whole.
- [ ] 24. Notes and help. Objects remember where they are declared:
      "declared here", "the first one is here", "the signature is
      here". Did you mean: the closest name by edit distance in the
      scopes in reach, in a module's exports, among the built-ins
      (`len` for `LEN`). Slips from other languages: `!=`, `==`, `=`
      for `:=`, `&&`, `||`, `!`, `elif`, a missing `then` or `do`, a
      missing import. The machinery, *main*; the catalogue of slips
      and their tests, *agent*.
- [ ] 25. Warnings: an unused import; an unused constant, type,
      variable or procedure that isn't exported; an unused parameter
      of a procedure written in raz; a variable assigned but never
      read. A name starting with `_` is never warned about. `-Werror`
      makes them errors, and `make check` builds `lib/`, `examples/`
      and `tools/` with it. The machinery, *main*; clearing the
      warnings it finds in `lib/`, `examples/` and `tools/`, *agent*.
- [ ] 26. Run-time messages. A failed check says which and with what
      values: `index 7 is out of range for a length of 5`, the slice,
      the enumeration position, at file, line and column. A table from
      code addresses to lines goes into the executable, and `Rt` sets
      handlers for SIGSEGV and SIGFPE that print where the program was
      and why (a `nil` pointer, a `nil` procedure, stack overflow, a
      bad address, a division fault) before it dies by that signal.
      Run tests gain an optional `X.stderr`. And the lowest `I64`
      divided by -1 wraps, as the report says, instead of trapping.
      The compiler and `Rt`,
      *main*; the tests, *agent*.
- [ ] 27. `doc/compiler.md` (its table and routine names), `README.md`
      and `CLAUDE.md` brought up to date; `make loc` within 6,000 and
      10%, `make bench` at 400,000 lines a second. *agent*, checked by
      *main*.
