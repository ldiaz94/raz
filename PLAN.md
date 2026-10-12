# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

v0.7.0, better code, is under way. v0.6.0 is tagged; its steps 5 to 10 await
the owner's review.

## Under way: better code (v0.7.0)

For: rat within 1.25 times the time of pt built by FPC `-O2 -Cr`
(today 634 ms against 428, 1.48 times), with the compiler still a
model of clarity. No change to the language. Measured on rat's 26 MB
workload, best of 9 interleaved runs, and on `make bench`.

Where rat's time goes (ulam-prof): `Utf8.next` 22%, `Str.decode` 15%,
`Screen.put` 11%, `Parser.feed` 11%, `Screen.unsplit` 9%. Their
listings show the steps below. ulam's `doc/codegen.md` measured the
same rewrites in a compiler of the same kind; its gains are quoted.

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

## Next, when the owner says

- The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
- A port to aarch64, to measure one: a new `gen.pas`, an encoder and
  assembler for it, and its ELF.

## Wishes, for a later thaw

What the language or the library might have, met while writing raz;
none is built while the freeze holds. None waits now.
