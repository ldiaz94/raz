# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

Better code again (v0.8.0) is under way, by the owner's word. v0.7.1,
the manual, is tagged, and all before v0.7.1 is approved by the owner.

## Now: better code again (v0.8.0)

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
