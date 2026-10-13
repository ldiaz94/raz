# Stage: the book "Compiling Raz"

This is the owner's go-ahead for a new stage: a book, "Compiling Raz",
explaining how the raz compiler works. Follow CLAUDE.md's way of working:
one commit per step, push it, then stop for review. Don't change the
language or the compiler for the book's sake. If the book exposes a bug
or a clumsy spot, report it rather than fixing it.

## Read first
- CLAUDE.md, doc/raz.md (the report), doc/compiler.md, README.md.
- seed/*.pas, the whole compiler (about 5,000 lines), and enough of lib/
  (Rt, Heap, Mem, Thread, Sys) to explain the runtime.
- The tiza skill, for drawings.

## The reader
A working programmer: not good at Pascal, little knowledge of compilers.
- Assume they roughly know registers, the stack and memory. Explain only
  what raz does with them (frames, calling convention, layout).
- Introduce compiler ideas (tokens, grammar, generating code while
  parsing, symbol tables) briefly and in friendly terms where they first
  appear.
- Teach just enough Pascal to read the compiler: one early chapter, then
  more as features come up. Teach enough raz the same way.
- Keep the two languages visibly apart: ```raz and ```pascal code blocks,
  and say which one is on screen.
- Don't explain formats that can be looked up. ELF gets a page on what
  raz writes and why, plus a pointer to the spec.
- Target 40-50k words.

## Tone
Like Learn You a Haskell and Starting FORTH: tiny steps, talking straight
to the reader, every idea shown at once on a real example, drawings that
carry meaning. Warm, with an occasional dry aside. Never a joke per
paragraph; humor is seasoning. Plain, short sentences.

## Mascot: Razmataz
A small, very serious creature with a flashy name, which suits a frugal
compiler (razzmatazz minus one z).
- Its motto, "once is enough", plays on "raz" meaning "one" or "once" in
  Polish and Russian. Check that the compiler really works in one pass
  before leaning on this; if it doesn't, find the honest version of the
  joke.
- Razmataz appears in tiza drawings: eating characters in the scanner,
  stacking boxes in frames, throwing unused code overboard in linking.

## Structure
Build up gradually, not unit by unit:
1. Introduction and a whirlwind tour: compile `exit 42` (or the smallest
   real program) through every stage, shallowly.
2. Enough Pascal (and raz) to follow along.
3. One chapter per language feature, followed through scanner, parser,
   symbols, code generator and machine code: variables and expressions,
   control flow, procedures and frames, records and arrays, pointers and
   the heap, strings, modules, defer, C interop, threads.
4. Closing chapters: x64 encoding, link (tree shaking, layout), elf,
   speed (how it reaches 400k lines a second), and where to go next.

Refine this order in the outline (step 1).

## Format and tooling
- Markdown in doc/book/: NN-slug.md per chapter, plus metadata.yaml
  (title, author Luis, cover). It must read well as plain text.
- `make book` builds build/compiling-raz.epub with pandoc. If pandoc gets
  installed locally, update the desktop guide (see the global
  CLAUDE.md).
- Drawings: .tiza source and a rendered PNG, both committed (CI has no
  tiza). Every image has a caption that stands on its own in plain text.
  Use ASCII art in code blocks for diagrams that are really structure
  (frames, memory layout); those read the same in both formats.
- Disassembly is cleaned up: instructions only, the raz source line
  beside them as a comment, and bytes only where the bytes are the point.
  Show raw objdump output once, early, next to the cleaned version, and
  say how to get it.
- A checker, written in raz alongside tools/Doc.raz (reuse what exists),
  run by `make check`. It must:
  - compile and run every raz example marked as runnable and compare the
    expected output written in the book;
  - confirm every quoted Pascal excerpt still matches seed/, quoted by
    unit and routine name, never by line number;
  - regenerate or verify the cleaned disassembly.
  The goal: when the compiler changes, `make check` fails rather than
  the book going quietly wrong.
- CI (.github/workflows/): on a push to main that touches doc/book/**,
  seed/** or lib/**, build the epub and replace the file on a standing
  prerelease tagged `book` (gh release upload --clobber), so the owner
  has a fixed URL to open on an iPad. Tagged releases also attach that
  version's epub.

## Steps (each one is a commit, then stop for review)
1. The outline: doc/book/OUTLINE.md, chapter by chapter, with what each
   one teaches, its running example, and the drawings planned.
2. The tooling: doc/book/ skeleton, `make book`, the checker in
   `make check`, the CI job. One placeholder chapter proves the pipeline
   end to end.
3. Razmataz's design sheet (tiza) and one sample chapter, the procedures
   and frames one, to set tone and depth.
4. Then one chapter per step, in order.

doc/compiler.md stays as it is: the short guide for people changing the
compiler. The book can point to it but never replaces it.

## Left to the tooling step
- How the checker marks runnable examples and quoted excerpts inside
  Markdown.
- Whether the cleaned disassembly comes from the compiler's own line
  information (`make gdb` suggests it has some) or from objdump.
