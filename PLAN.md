# jed: the plan

jed (Polish *jeden*, one) is a small systems language in Wirth's
tradition: full control of memory, volatile access, atomics, calls into
C, generic modules. Its compiler is meant to be read in a long weekend:
about 4,300 lines of Free Pascal, one pass, no IR, no optimizer, writing
x86-64 machine code and the ELF file itself.

The language is defined by `doc/jed.md`. Where this plan and the report
disagree, the report wins and this plan is fixed.

## Ground rules

- The compiler is Free Pascal 3.2.2, `{$mode objfpc}{$H-}`: records,
  pointers, shortstrings. No classes, ansistrings, exceptions, dynamic
  arrays or SysUtils.
- Clarity over cleverness. Every unit opens with a header comment: what
  it is, what it depends on, what it leaves out. Comments say why, and
  what wherever a layout or encoding isn't obvious.
- One commit per step, as `Luis <42945842+ldiaz94@users.noreply.github.com>`, unsigned, with
  no attribution trailer.
- Work stops after every stage for review. A step starts only on an
  explicit go-ahead.
- Not in scope for now: man pages, QEMU or bare metal tests, aarch64,
  an optimizer.

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
   per distinct list of type arguments.
8. Tree shaking: the linker keeps only the procedures, variables and
   literals reachable from the entry point.
9. Variadic arguments exist only to call C. jed code gets the same
   effect from a slice of a variant (`Fmt.print`).
10. Strings are `[]U8`. The language compares them with `=`; the rest
    is a library.

## The compiler, in reading order

| File | Lines | What |
|---|---|---|
| `src/scan.pas` | ~360 | Symbols, literals, comments, error messages |
| `src/sym.pas` | ~390 | Types, objects, scopes, layout |
| `src/x64.pas` | ~400 | Code buffer, chunks, fixups, instruction encoder |
| `src/gen.pas` | ~660 | Items: loading, storing, copying, frames, calls |
| `src/parse.pas` | ~1,750 | Declarations, statements, expressions, built-ins |
| `src/link.pas` | ~200 | Tree shaking, layout, patching |
| `src/elf.pas` | ~450 | Static and dynamic ELF, symbol table |
| `src/jed.pas` | ~100 | The command line |

## Steps

Stage 1: the core

- [ ] 1. Language report, `doc/jed.md`. Reviewed and approved before
      any more code.
- [ ] 2. Scanner and symbol table, `scan.pas` and `sym.pas` (drafts
      exist), brought in line with the report; they compile.
- [ ] 3. Machine code, `x64.pas`.
- [ ] 4. Linking and output, `link.pas` and `elf.pas`: tree shaking,
      static ELF, symbol table. A hand built chunk runs.
- [ ] 5. Parser and code generator, `gen.pas` and `parse.pas`:
      everything in the report except multiple results, `NEW`, generic
      modules and `extern`.
- [ ] 6. `lib/Rt.jed`, `lib/Out.jed`; examples (hello, args, variants
      and slices, volatile); `make check` runs them against expected
      output.

Stage 2: allocation, results, generics

- [ ] 7. Multiple results.
- [ ] 8. `NEW`; `lib/Mem.jed`, `lib/Arena.jed`, `lib/Heap.jed`.
- [ ] 9. Generic modules; `lib/Str.jed`, `lib/Buf.jed`, `lib/Fmt.jed`;
      examples.

Stage 3: calling C

- [ ] 10. `extern`, `link`, dynamic ELF, start through
      `__libc_start_main`; examples with `printf` and an X11 window.

Wrap up

- [ ] 11. `README.md` and `doc/compiler.md`, a guide to reading the
      compiler file by file.
