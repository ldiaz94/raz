# raz: standards

How raz is written here: in `src/`, `lib/`, `tools/` and `examples/`,
and in the programs and libraries that use them (rpg, rsqlite, rmacs,
ravite, ...). The report says what a program may do; this says what we
do. New code keeps to it; old code comes to it when it is next changed,
or, for the library's interfaces, at a thaw (`PROPOSALS.md`).

## Parameters: a value, `var`, or a pointer

A procedure takes a variable it is given in one of three ways, by what
it does with it:

- **It reads it**: a value, when the type is a few words at most (a
  handle, a slice, a small record). A larger record or array that is
  only read is `var`, since a value parameter is a copy (8; a `const`
  parameter waits in `PROPOSALS.md`).
- **It changes it, and lets go of it when it returns**: `var`.
- **It keeps it**, in a record, a module variable or another thread,
  past the call: a pointer, `^T`.

So `ADR` at a call says the callee keeps what it is given. A reader
who sees `Pg.start(q, ADR(c), sql)` knows that `q` is changed and `c`
is kept, and that `c` must outlive `q`.

```
proc start*(var q: Query; c: ^Conn; sql: []U8);   (* q changed; c kept in q *)
proc run*(q: Query; var r: Result): ERROR;         (* q read; r changed *)
proc rows*(r: Result): INT;                        (* r read: one word *)
proc clear*(var r: Result);                        (* r changed *)
```

A pointer is right also where `var` can't serve:

- **An allocator**, `^Mem.Allocator`: `NEW` takes one, and an
  allocator such as `Arena` is reached through its first field,
  `^Arena(a)`, which a `var` of exactly one type can't do.
- **What may be absent**: a pointer may be `nil`; a `var` can't.
- **What the program already holds by pointer**: what `NEW` or the
  library hands out, such as `Thread.spawn`'s `^Thread`, is passed on
  as it is, not as `p^`.
- **C**, and memory that is bytes, not a variable: `extern`
  procedures, `Mem.pages`, `Sys.mmap`, a buffer's address.
- **A procedure value's argument** that holds what the procedure will
  need, as `Thread.spawn`'s `arg: ^U8`, which is kept.

Anything else that takes `^T` and neither keeps it nor needs one of the
above is a mistake, and its callers' `ADR`s are noise.

## The library until a thaw

The library's interfaces mostly take `^T` (`Buf`, `Vec`, `Map`,
`List`, `Lock`, `Opt`, ...), though none keeps what it is given. They
can't change while the freeze holds, since every caller would break;
`PROPOSALS.md` lists them for the next thaw. Until then a program
calls them with `ADR`, and its own procedures keep to this file.
