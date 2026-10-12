# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

v0.7.0, better code, has all its steps done and awaits the owner's
review before its tag. v0.6.0 is tagged; its steps 5 to 10 await
the owner's review.

## Done, for review: better code (v0.7.0)

For: rat within 1.25 times the time of pt built by FPC `-O2 -Cr`
(today 634 ms against 428, 1.48 times), with the compiler still a
model of clarity. No change to the language. Measured on rat's 26 MB
workload, best of 9 interleaved runs, and on `make bench`.

Where rat's time goes (ulam-prof): `Utf8.next` 22%, `Str.decode` 15%,
`Screen.put` 11%, `Parser.feed` 11%, `Screen.unsplit` 9%. Their
listings show the steps below. ulam's `doc/codegen.md` measured the
same rewrites in a compiler of the same kind; its gains are quoted.

**Where it stands.** All seven steps are done and pushed. rat takes
513 ms against 622 for the same workload built by the milestone's
first compiler (-18%), on a machine that drifts by 3%; pt built with
`-O2 -Cr` takes 426 ms the same hour, so rat is at 1.20 times, inside
the goal. Text is 1.5% smaller; the compiler is 8,559 lines of code
and compiles 980,000 lines a second. Each step:

| Step | rat | Its kernel |
|---|---|---|
| 1. Prologue | -12% | |
| 2. Two words in rax, rdx | noise | calls returning two results, -9% |
| 3. Two results on the stack | -8% | |
| 4. Conditions as jumps | noise | a search leaving by break, -28% |
| 5. Shifts, constants right | noise | heap sort and list walk, -11% |
| 6. for loops | noise | matrix product -14%, sum -21% |
| 7. Read by a beginner | | |

Steps that left rat's time alone stayed for their kernels, which the
2% rule allows. Moves between registers bought size, not time: this
machine renames them away, as ulam found.

1. **A prologue that does only what it must.** A register variable
   keeps a frame slot that is zeroed for nothing, and so do the slots
   the registers are saved in: `Str.decode`, whose four variables are
   all in registers, zeroes seven quadwords in a loop on every call.
2. **Two results in rax and rdx** for every procedure whose two
   results are each one word, as a code procedure's are now; not
   through a hidden pointer to the caller's slots. Changes a reading
   of the report already taken: the owner's to approve.
3. **Values left where they are.** Gen's value stack keeps a value in
   the place it is until it must move: a slice made from a slice
   (`s[i..LEN(s)]`) isn't written to the frame and read back to be
   passed; `v := v + x` adds into `v`'s register; a value is not moved
   through `r8` on its way from one register to another; a value that
   fits its type already isn't extended again (ulam's P1).
4. **Conditions as jumps.** `test` for a compare with zero; a `BOOL`
   result tested where it is; a jump over a jump made one jump (ulam's
   P7: with step 5, `heap` 11% faster); no dead jump after a `return`
   or `break`; no check of what a slice's own length makes certain
   (`s[i..LEN(s)]`'s upper bound).
5. **Addresses as the machine makes them.** An index scaled in the
   address (`[rdi + rax*8]`), not by `imul` and `add`; a product by a
   power of two as a shift; a constant on the right of `+ * & |`,
   where it becomes an immediate (ulam's P5: `tree` 5 to 10% faster).
6. **`for` loops as FPC writes them**: stepped at the top, one compare
   and one jump back at the bottom, the limit in a register when one is
   free (ulam's P2: `matmul` 16% faster).
7. **Read by a beginner.** A reader with no part in this milestone
   (a fresh agent) reads `gen.pas` and `doc/compiler.md` and lists
   every place it can't follow; each is mended. `doc/compiler.md`
   gains a section, "How the code is made good", walking one of rat's
   procedures through the steps, before and after.

Each step stops if it buys less than its lines: one that gains under
2% on rat and on no kernel is reverted and noted here. Short branches
(code 5 to 8% smaller in ulam's estimate) are left for after, measured
on their own.

## Proposed: the manual

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

1. **`raz-tutorial(7)`, a tour of the language.** Numbered sections,
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

## Next, when the owner says

- The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
- A port to aarch64, to measure one: a new `gen.pas`, an encoder and
  assembler for it, and its ELF.

## Wishes, for a later thaw

What the language or the library might have, met while writing raz;
none is built while the freeze holds. None waits now.
