# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

The manual (v0.7.1) is under way, by the owner's word, and better code
again (v0.8.0) after it. v0.7.0, better code, is tagged, and all before
it is approved by the owner.

## Next: the manual (v0.7.1)

For: someone who has never seen raz can learn it from `man`, and come
back to it as a reference, without the report open; the report stays
the definition, and the manual never disagrees with it. No change to
the language or the compiler. Modelled on concha's three pages, which
the owner knows: a reference, a tour, and the rest.

The rules for every page: mdoc, so man, mandoc and groff all set it
well; short sections, each with one idea; every example a whole
program or a piece of one that `make check` compiles and runs, as it
does the report's, so none can go stale; plain, short prose, as the
report's; `groff -mdoc -ww` and `mandoc -Tlint`, if there, say
nothing; and each page read whole at 80 columns, as a user would,
before it is done.

1. Done: **`raz-tutorial(7)`, a tour of the language.** Numbered sections,
   each one idea with a program to run: hello, world and modules;
   values, types and conversions; procedures and several results;
   arrays, slices and strings; records and pointers; memory and
   allocators; errors, `ERROR` and `MSG`; `defer`; checks and what a
   failure says; generic modules; talking to C; threads. Then "From
   Pascal and C to raz", a table of what each spells differently, as
   concha's tour has from sh. About 500 lines. The examples go in
   `test/man`, run by `make check`.
2. **`raz-lib(3)`, the library, made from its sources.** `tools/Doc`
   learns to write mdoc: each module's own comment, then its exported
   declarations with theirs, under a heading of its name. `make` builds
   the page from `lib/`, so it says what the library says, always.
   About 60 lines of `Doc`.
3. **`raz(7)`, the language at a glance.** What a programmer looks up:
   the grammar in brief, the types and their sizes, the operators and
   their order, the built-in procedures, the statements, what is
   checked, and the limits; each pointing to the report's section for
   the whole of it. About 400 lines.
4. **`raz(1)` again, and the pages together.** The command's page
   points into the others; `make install` installs all four, and
   `make uninstall` removes them; README and `doc/compiler.md` name
   them; the desktop guide gets an entry for raz as one of our own
   tools. The pages are read whole once more, together.

Each step is a commit and stops for review. Step 1 stands on its own
and is most of the worth; 2 to 4 can wait.

## Then: better code again (v0.8.0)

For: on the same program, raz within 1.3 times the time of FPC `-O2`
with `check off;` (today 1.3 on a heap sort, 1.7 on a sum over a slice,
1.8 on a search: these kernels go in
`test/bench` first, with their Pascal twins, so anyone can measure
them), and every default program smaller; the compiler as clear as
v0.7.0 left it, and under 10,000 lines. No change to the language.
Each step is measured as v0.7.0's were, on rat and on its kernel, and
one that buys less than 2% on both is reverted and noted here.

1. **Slices in registers.** A slice parameter or variable whose address
   isn't taken lives in two of the variables' registers, its pointer and
   its length, chosen by the read-ahead as a single value is, and
   counted as two. FPC's search keeps its slice in `rdi` and `rsi`;
   raz's reads both from the frame on every round.
2. **Parameters left where they arrive.** In a procedure that calls
   nothing, copies no block and divides by no variable, as the
   read-ahead can tell, a parameter stays in the register it came in,
   and no register is saved for it. Most of rat's hot procedures are
   such small ones (`unsplit`, `Width.cells`), and each call now saves
   and restores what it uses.
3. **Addresses and operands as the machine has them.** An element of a
   slice in registers is `[base + i*8]`, read where it is used; a
   compare or an addition takes its right operand from memory
   (`cmp r8, [rbp - 16]`), not through a register first.
4. **`while` tested at the bottom**, its test moved after the body and
   jumped to first, as `for` is now. ulam found nothing in it, and lost
   3% where the test was long: measured, and kept only if it pays.
5. **One table of lines, not two.** Rt finds a place in `.debug_line`,
   loaded with the program, which gdb reads already, in place of the
   places' own 16 bytes a line: about 7 KB off hello, more off a big
   program, for a decoder of DWARF's line program in Rt.

## Next, when the owner says

- The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
- A port to aarch64, to measure one: a new `gen.pas`, an encoder and
  assembler for it, and its ELF.

## Wishes, for a later thaw

What the language or the library might have, met while writing raz;
none is built while the freeze holds. None waits now.
