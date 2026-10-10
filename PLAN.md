# jed: the plan

jed (Polish *jeden*, one) is a small systems language in Wirth's
tradition: full control of memory, volatile access, atomics, calls into
C, generic modules. Its compiler is meant to be read in a long weekend:
under 5,000 lines of Free Pascal, one pass, no IR, no optimizer, writing
x86-64 machine code and the ELF file itself.

The language is defined by `doc/jed.md`. Where this plan and the report
disagree, the report wins and this plan is fixed.

## Ground rules

- The compiler is Free Pascal 3.2.2, `{$mode objfpc}{$H-}`: records,
  pointers, shortstrings. No classes, ansistrings, exceptions, dynamic
  arrays or SysUtils.
- The compiler stays near 5,000 lines of code (not counting blank and
  comment lines), within 10%, and compiles at least 400,000 lines of
  jed a second, from reading the sources to writing the executable.
  `make loc` and `make bench` measure them, and a step that breaks
  either limit isn't done.
- Clarity over cleverness. Every unit opens with a header comment: what
  it is, what it depends on, what it leaves out. Comments say why, and
  what wherever a layout or encoding isn't obvious.
- One commit per step, as `Luis <42945842+ldiaz94@users.noreply.github.com>`, unsigned, with
  no attribution trailer.
- Work stops after every stage for review. A stage starts only on an
  explicit go-ahead; within it, each step is committed and pushed as it
  is done.
- Not in scope for now: man pages, QEMU or bare metal tests, aarch64,
  macOS and Windows (Mach-O, PE), an optimizer.

## Decisions

1. Source files end in `.jed`, one module per file, named after it.
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
9. Variadic arguments exist only to call C. jed code gets the same
   effect from a slice of a variant (`Fmt.print`).
10. Strings are `[]U8`. The language compares them with `=`; the rest
    is a library.

## The compiler, in reading order

Lines after stage 2, all of them and those of code (neither blank nor
only comment), as `make loc` counts them:

| File | Lines | Code | What |
|---|---|---|---|
| `src/scan.pas` | 548 | 471 | Symbols, literals, comments, error messages |
| `src/sym.pas` | 492 | 410 | Types, objects, scopes, layout |
| `src/x64.pas` | 620 | 497 | Code buffer, chunks, fixups, instruction encoder |
| `src/gen.pas` | 1,354 | 1,193 | Items: loading, storing, copying, frames, calls |
| `src/parse.pas` | 1,754 | 1,626 | Declarations, statements, expressions, built-ins |
| `src/link.pas` | 123 | 92 | Tree shaking, layout, patching |
| `src/elf.pas` | 185 | 147 | Static ELF, symbol table |
| `src/jed.pas` | 111 | 83 | The command line, the entry point |
| total | 5,187 | 4,519 | |

## Steps

Stage 1: the core

- [x] 1. Language report, `doc/jed.md`. Reviewed and approved before
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
- [x] 6. `lib/Rt.jed`, `lib/Sys.linux-x86_64.jed`, `lib/Out.jed`;
      examples (hello, args, variants and slices, volatile, a code
      procedure); `make check` runs them against expected output;
      `make bench` times the compiler on generated jed.

Stage 2: the rest of the language

- [x] 7. Multiple results and errors; `INC` and `DEC`.
- [x] 8. Enumerations and sets, record literals, `defer`; examples.
- [x] 9. `NEW`; `lib/Mem.jed`, `lib/Arena.jed`, `lib/Heap.jed`.
- [x] 10. Generic modules, with type and procedure arguments;
      `lib/Str.jed`, `lib/Buf.jed`, `lib/Fmt.jed`; examples.

Stage 3: calling C, and what comes with it

- [x] 11. `extern proc`, `extern var` and `link`; dynamic ELF, start
      through `__libc_start_main`. A plain `lib/Sys.jed` over the C
      library, the default for targets with no file of their own.
      Examples with `printf` to `stdout`, and an X11 window, reading
      `XEvent` as an array of words through pointer conversions.
      Ending a program: the entry point calls `Rt.exit(status)`, which
      runs the procedures registered with `Rt.atExit`, then ends it;
      `Rt.fail` runs them too. A buffered `lib/Out.jed`: 4 KB, flushed
      at each newline when standard output is a terminal, when full,
      by `Out.flush`, and at exit. The report says how to mix `Out`
      with C's `stdio`: flush one before using the other.
- [ ] 12. `F32`: arithmetic, conversions, calls; real literals become
      untyped constants that take `F32` or `F64`.
- [ ] 13. A thread-safe `lib/Heap.jed`: its bad sizes refused, and a
      marker in each block's header so that freeing a block twice, or
      one it never gave out, stops the program; `Out` locks its buffer.
      An example with threads from `pthread_create`.
      Native threads for programs without C, in
      `lib/Thread.linux-x86_64.jed`: `spawn` on an `mmap`ed stack with
      a guard page, through `clone` and a small code procedure; `join`
      and a `Mutex` through `futex`. `link static;` marks a module that
      needs a program without C; the compiler refuses a program that
      uses both.
- [ ] 14. Line numbers for gdb: `.debug_line`, with the least of
      `.debug_info` and `.debug_abbrev` that gdb needs.

Tools

- [ ] 15. `tools/Doc.jed`, a jed program: prints a module's own
      comment, the one before `module`, then its exported
      declarations, each with the comment just before it; and pulls
      out the examples of `doc/jed.md` that are whole modules.
      `make check` also compiles those examples, running the ones with
      a `main`, and runs each library module's `main` as its test.
      The test runner stays in the Makefile: it must work when the
      compiler doesn't.

Wrap up

- [ ] 16. `README.md` and `doc/compiler.md`, a guide to reading the
      compiler file by file.
