# raz: the plan

Work goes by milestones, each a release. A milestone says what it is
for, what is in it and when it is done; its steps are commits, each
stopping for the owner's review. A finished milestone is cut from this
file: git keeps the history, and the report's section 12 the language's.

No milestone is under way. v0.6.0 is tagged; its steps 5 to 10 await
the owner's review.

## Next, when the owner says

- The book, "Compiling Raz": its brief is `doc/book/PLAN.md`.
- A port to aarch64, to measure one: a new `gen.pas`, an encoder and
  assembler for it, and its ELF.

## Wishes, for a later thaw

What the language or the library might have, met while writing raz;
none is built while the freeze holds.

- A warning for a call whose result is dropped. Code drops results on
  purpose (`SYSCALL`, `Sys.write`; about 40 places in `lib/`), so it
  needs a way to say so first, such as `_ := f(x)`.
