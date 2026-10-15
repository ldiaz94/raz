# raz: proposals

What the language or the library might have, met while writing raz.
None is built while the freeze holds; each waits for a later thaw, by
the owner's word, and goes into the report before any code.

## A `const` parameter

`proc what(const x: Item): []U8;`: the callee may not change `x` (nor
take its address), so the caller may pass the address of a record or
array without a copy, and the program means the same.

Met in porting the compiler to raz, where the seed's `const x: TItem`
(about 130 bytes) became a value parameter, copied at every call.
Measured once the port built: not what stands out, the compiler's
profile is flat (`Scan.tokPos` is 9%).

## A minus sign after an operator

`x & -8` and `n * -1` are errors: a unary minus belongs to the start
of a `SimpleExpr` (6), not to a factor, so after an operator it needs
parentheses, `x & (-8)`, or another spelling, `x & ~7`. This is the
report's grammar, Oberon's, and the compiler is right to refuse it;
but nearly every other language takes it, and the error ("expected an
expression, found -") surprises.

The proposal: a factor that follows an operator may be `"-" Factor`.
The minus at the start of a `SimpleExpr` stays as it is, applying to
the first term, so no program changes meaning: `-a & b` is still
`-(a & b)`, which isn't `(-a) & b`, nor is `-a shr n` the same as
`(-a) shr n`. Only text that is an error today, `x & -8`, gets one.
The cost is that a minus means two things by where it stands, which
the report would say in a line.

Met in tery's `aligned`, `(a + 7) & -8`.

## Dividing 128 bits by 64

`Math.mul` gives the 128-bit product of two `U64`s; there is nothing
to divide such a number back down. Forth's `UM/MOD` and `M*/`, and
any arithmetic on numbers wider than a word (a bignum, a fixed-point
product scaled back), need "this 128-bit number, given as its high
and low words, divided by a 64-bit one: the quotient and the
remainder". x86-64 does it in one instruction, `div`; a raz program
does it by a loop of 64 shifts and subtractions, or a code procedure
per target.

The proposal, in the library:

```
proc div*(hi, lo, d: U64): (U64, U64);   (* hi, lo divided by d: the quotient and the remainder; hi < d *)
```

in `Math`, beside `mul`; `hi >= d`, whose quotient doesn't fit a word,
and `d = 0` stop the program as a division by zero does. It breaks no
program, so it could come with any release, not only a thaw.

Met in tery's `udivmod`, a loop of 64 rounds.

## Inlining a procedure that only returns

Not the language's but the compiler's: a call of a procedure whose
body is `return` and an expression, as `Grep.zeros` and
`Scan.tokPos` are, made in place of the call. One pass keeps no
tree to copy, but it can read source again, as `while` reads its
condition again (`saveScan`, `restoreScan`): the arguments go to
temporaries, each evaluated once and in order, a scope names the
parameters as them, and the expression is read again from where the
procedure's begins, in its own module's scope.

Measured by hand on the kernels: Grep with `zeros` and `lowest`
written in place is 20% faster, 0.88 times FPC `-O2`'s time where it
is 1.14 now. The compiler has 78 such procedures and the library 28;
the compiler's profile names the calls of small routines as what is
left (doc/compiler.md).

Kept narrow: scalars passed by value, no recursion, no code
procedure (a square root has its own way), a procedure taken as a
value still called. What it costs: an inlined procedure is not in
the trap report's list of procedures, nor in gdb's backtrace, though
a failed check in it is still told at its line; 60 to 100 lines of
the budget; and, across modules, the imported module's
text kept to be read again, which is to be checked.

More cases, from sauce (`~/r/sauce`, RAZ-NOTES.md). Its SHA-256, with
the rotation a procedure, `return (x shr n) | (x shl (32 - n))`, and
each word read by `Str.be`, ran at 52 MB/s; with both written out in
the loop, 115 MB/s, where FPC `-O2` does about 200 and `check off`
adds only 9%. Most of the gap is calls. `ror` is the narrow case
above; `Str.be` is not, a loop over its bytes, and would want a
`Str.be32` of four bytes that only returns, or the loop unrolled where
it is. A rotate of the language's own, an operator or a built-in
procedure, would serve SHA, the other hashes and checksums without
any inlining, but it is a language change, for a thaw. On 100 MB of
new files `sauce commit` takes 1.2 s against the Pascal sauce's 0.7,
and `verify` 0.95 s against 0.48: the hashing.

## Marking what a procedure does with what it is given: `ret` and `keep`

### The hole

A procedure's locals, its value parameters and the array literals it
passes as slices live in its frame, which is gone once it returns. A
slice that still points there afterwards reads whatever the next call
put in its place, and writes into it. Section 7.3 catches the plain
case, a slice of a local returned at once:

```
proc short(h: Hex): []U8;    (* Hex = [64]U8 *)
begin
    return h[0..8];          (* an error: h is the procedure's own copy *)
end;
```

It can't catch the same slice once it has passed through a call,
since the caller can't see what the callee returns a slice of:

```
proc head(var h: Hex): []U8;
begin
    return h[0..8];          (* fine: h is the caller's *)
end;

proc short: []U8;
var h: Hex;
begin
    return head(h);          (* a slice of short's frame; not caught *)
end;
```

Nor the other way, a slice given to a procedure that keeps it:

```
proc remember(name: []U8);
var buf: [16]U8;
begin
    ...
    _ := Names.put(ADR(table), buf[0..n], 1);   (* the map, on the heap, keeps a slice of buf *)
end;
```

Section 10 leaves both undefined. The marks close them: each parameter
says what the procedure may do with what it is given, the compiler
holds the procedure's body to its heading, and a caller trusts the
heading without seeing the body. Each check needs only the procedure
it is in, so a one-pass compiler can make it.

### Words

**Carrying a slice.** A type carries a slice if it is a slice, or an
array, record or variant with one in it: `[]U8`, `[4][]U8`,
`Sys.Program`, `Fmt.Arg`. `INT`, `[64]U8` and every pointer type don't.
What a pointer points at is not followed: a slice reached through a
pointer, `p^.s`, is the heap's or a module's, as far as the marks
know.

**Where a value points.** Every value that carries a slice has, for
the compiler, a set of places its slices may point into:

- **the frame**, this call's own: a slice of a local array, of a
  value parameter's array, or an array literal used as a slice;
- **a parameter `p`**: what `p` lends. For a value parameter, that is
  what its slices point at, which is the caller's business, not this
  frame. For a `var` parameter, it is also the caller's variable
  itself: `h[0..8]` of `var h: Hex` points into `h`.
- **nowhere that ends**: module variables, constants, string literals,
  and anything reached through a pointer.

A value made from others points wherever any of them does: a slice, a
field, an element or a view of `x` points where `x` does; a record, a
variant or an array literal built from parts, wherever the parts do; a
call's result, wherever its arguments for `ret` parameters do (below).
A local variable that carries a slice points wherever anything
assigned to it anywhere in the procedure does, wherever the assignment
stands, since a loop can run a `return` after an assignment written
below it. **Frame-bound** means pointing into the frame.

**Outliving the call.** A place outlives the call if it is a module
variable, anything reached through a pointer (`p^.f`, `p^[i]`), or a
`var` parameter of this procedure. A value stored there, or returned,
leaves the frame.

### No mark

A parameter without a mark is only used while the call runs. The
procedure may read it, copy its bytes (`COPY`, `Buf.str`), keep it in
locals and pass it to other calls' unmarked or `ret` parameters. It
may not return what it points at, nor store it anywhere that outlives
the call. This is what most procedures do: `Str.eq`, `Str.find`,
`Buf.str`, `Sys.write`, `Fmt.print`, `Map.get`'s key.

### `ret`

```
proc trim(ret s: []U8): []U8;
```

`ret s` says: the results may point where `s` points. In the body,
returning a slice of `s` is allowed; in the caller, the result points
wherever the argument given for `s` did.

```
proc greet: []U8;
var line: [80]U8; n: INT;
begin
    n := Sys.read(Sys.stdin, line);
    Out.str(Str.trim(line[0..n]));     (* fine: used here, in the frame *)
    return Str.trim(line[0..n]);       (* an error: frame-bound through trim's ret *)
end;

proc word(ret s: []U8): []U8;
begin
    return Str.trim(s);                (* fine: points where s does, and s is ret *)
end;

proc word2(s: []U8): []U8;
begin
    return Str.trim(s);                (* an error: s isn't ret here *)
end;
```

`ret` is allowed on a parameter that carries a slice, or on a `var`
parameter whose type holds an array (it lends the caller's variable),
of a procedure with a result that carries a slice. It is an error
elsewhere:

- `ret n: INT`, `ret a: [4]U8`: nothing to lend. A value array is the
  procedure's own copy, and a slice of it can never be returned.
- `ret` on a procedure whose results carry no slice: nothing to lend
  it to.

With several results, `ret` covers them all: in `cut(ret s: []U8;
sep: []U8): ([]U8, []U8, BOOL)` both slices may point into `s`. With
several `ret` parameters, a result may point where any of them does,
and the caller takes the result as pointing where all of their
arguments do.

### `keep`

```
proc put(m: ^Map; keep k: K; keep v: V): BOOL;
```

`keep k` says: what `k` points at may outlive the call; the procedure
may store it in a place that does. In the caller, an argument for a
`keep` parameter leaves the frame as a store would: it must not be
frame-bound, and if it points where one of the caller's own
parameters does, that parameter must be `keep` too.

```
(* import Names := Map([]U8, INT, Str.hash, Str.eq);
   table: Names.Map and heap: Heap's allocator, module variables *)
proc count(name: []U8);
var key: [32]U8;
begin
    _ := Names.put(ADR(table), name, 1);           (* an error: name isn't keep here *)
    _ := Names.put(ADR(table), key[0..4], 1);      (* an error: frame-bound to a keep *)
    _ := Names.put(ADR(table), "main", 1);         (* fine: a literal never ends *)
    _ := Names.put(ADR(table), Str.copy(ADR(heap), name), 1);  (* fine: copied to the heap *)
end;
```

`keep` is allowed on a parameter that carries a slice or is a `var`
parameter whose type holds an array; on another, `keep n: INT`, it
is an error, as `ret` is.

One exception keeps the common loop free of marks: a `var` parameter
may be given a value that points only where it already pointed, so
`s := s[1..LEN(s)]` with `var s: []U8` needs no `keep`. The caller's
variable is no worse off.

### Both, and the order

`ret keep v: T` is both. The marks come before `var`, and each
mark covers the group it starts, so `(ret s, t: []U8)` marks both;
`(ret s: []U8; sep: []U8)` marks only `s`. `ret` and `keep` are not
reserved words: they are marks only before a parameter's name, as
`static` is a mark only in `link static;`. `proc f(ret: INT)` is a
parameter named `ret`.

### What the compiler checks, all of it

In each procedure:

1. `return e`, each result: `e` must not be frame-bound, and every
   parameter it points at must be `ret`.
2. A store into a place that outlives the call, `M.x := e`,
   `p^.f := e`, or `v := e` for a `var` parameter `v`: `e` must not be
   frame-bound, and every parameter it points at must be `keep`, but
   for the exception above. `COPY` into such a place is no such store:
   it copies bytes, not where they point.
3. An argument for a call's `keep` parameter, as 2.
4. A heading's marks are allowed where it says so above.

Checks 1 to 3 on a local variable's value wait for the procedure's
`end`, when everything assigned to it is known.

### Procedure values, generic modules, and the rest

**Procedure types** carry the marks, `proc(ret s: []U8): []U8`. A
procedure may be given where its type has the same marks or more,
since a mark promises the caller less: a procedure without `ret` can
stand where `ret` was allowed, not the other way.

**Generic modules.** A mark is allowed on a parameter whose type is a
module parameter, `keep v: T`, whatever `T` will be. The body is
checked in each instance: `Map(INT, INT)`'s `put` would pass without
`keep`, `Map([]U8, INT)`'s wouldn't, so the library marks its generic
modules for the instance that needs it.

**`extern` procedures** take no marks: C is outside the promise of
section 10 already. **Code procedures** take them, and are trusted:
there is no body to check.

**`ADR`** gives a pointer, which the marks don't follow; a pointer to
a local that outlives it stays undefined, as section 10 says. So does
a slice reached through such a pointer, and a thread given a pointer
to its spawner's locals.

### False alarms

The rules are sure, not exact: they reject some programs that were
right.

- **A record that lives in the frame, filled through a pointer.**
  `examples/Sh.raz` does

  ```
  Opt.init(ADR(p), "Sh", [Opt.usage(...), Opt.option(...)]);
  ```

  `Opt.init` keeps its table in `p^`, so it needs `keep table`, and
  the array literal is frame-bound: an error, though `p` is a local
  and dies with the literal. `keep` can't say "as long as `p^`";
  saying that needs lifetimes on records, Rust's whole apparatus, which
  is not proposed. The way out: the table in a module variable.
- **A local variable used twice.** One slice variable that holds a
  slice of a local buffer early on and a result to return later is
  frame-bound throughout. Two variables cure it.
- **Several `ret` parameters.** A result is taken to point at all of
  them, though it may point at one.

### What it breaks

Every procedure, in the library or a program, that returns or keeps
what a parameter points at stops compiling until it is marked: a
thaw. In the library, by a search of the headings: `Str.trim`,
`trimLeft`, `trimRight`, `cut` and `field` (`ret`); `Map.put` and
`List.push` (`keep`); `Opt.init` (`keep`), and `Sh`'s call of it, as
above. Not marked: `Str.copy` (its result is the allocator's),
`Sys.env` and `readLink` (their own buffer), `Buf.str` and
`Fmt.write` (they copy), `Map.get`. In sauce, `Svec.push` and `add`
(`keep`), and what returns a slice of its argument.

### What it costs

Reports: 5.9 (procedure types), 7.3, 8 (parameters), 10 (the promise,
whose exceptions shrink to `ADR`, C, code procedures and `check
off`), appendix B. The compiler: a set of the places a value points
into, carried with each value as its type is, a 64-bit set (the frame
and up to 63 parameters); the same on each local; the checks above,
and a list per procedure of the checks that wait for its `end`.
Perhaps 250 to 400 lines; no cost at run time, and little at compile
time.

Precedent: D's `scope` and `return scope` (DIP1000) are `keep`'s
opposite and `ret`; Rust's lifetime elision reads a call's result as
`ret` does. D's experience is that the corners (fields, generics,
procedure values) take years; the narrow form here leaves record
lifetimes out, and so the first false alarm above, on purpose.

## What a shell needs of `Sys`

For concha, the shell written in raz. `examples/Sh.raz` shows how far
`Sys` goes today: pipelines, `<`, `>`, `>>` and `2>`, and job control
through `spawn`'s `group` and `foreground`. A shell people use every
day needs more. Each item below is library growth that breaks no
program, and each has a C call behind it, for `Sys.raz` over the C
library.

**Moving file descriptors.** `2>&1`, `3>log`, `exec >out` and `{ a;
b; } >f` move or copy the shell's own descriptors, around a builtin
or for good; `Program.fds` covers only a child's first three.

```
proc dup*(fd: INT): INT;                 (* a new fd for the same file, the lowest free *)
proc dupTo*(fd, to: INT): INT;           (* to made the same file as fd, closing what it was *)
proc keepOnExec*(fd: INT; yes: BOOL): INT;   (* fd passed to programs spawn starts, or not *)
```

`Program` gains `more*: []INT`, descriptors passed on to the program
at the same numbers, for `3<file cmd` and for `<(...)`, which hands a
program `/dev/fd/N`. `spawn` closes every other one, as it does now.
The C calls: `dup`, `dup2`, `fcntl` with `FD_CLOEXEC`.

**Replacing the shell.** `exec cmd` runs a program in the shell's
place, as does the last command of `sh -c`, saving a process.

```
proc exec*(p: Program): INT;   (* p run in this program's place; returns only if it can't, with minus an errno *)
```

`p.group`, `p.foreground` and `p.tty` are as in `spawn`. The C call
is `execve`.

**Finding programs.** A shell looks a name up along `PATH`, and `test
-x`, `-r` and `-w` ask whether this user may run, read or write a
file, which `Info.mode` alone can't say: it depends on the user, the
file's owner and group, and the file system (read-only, `noexec`).

```
proc access*(path: []U8; how: Accesses): INT;   (* 0 if this user may, by its real ids; reading, writing, and running *)
```

`Access` gains `running`, which `open` refuses. The C call is
`access`.

**The environment.** `env` reads one variable. A shell starts from
its whole environment, to list it (`env`, `export -p`) and pass it on
with what was exported:

```
proc envAt*(i: INT): ([]U8, BOOL);   (* the environment's ith NAME=value, from 0; false past the last *)
```

Nothing to set it: the shell keeps its own table and passes it whole
with `onlyEnv`.

**The umask.** `umask` shows and sets the bits taken from every file
the shell, and what it starts, makes.

```
proc umask*(mask: INT): INT;   (* the mask set to mask; the one it was *)
```

**A terminal's modes, kept for each job.** A job stopped by Ctrl-Z
in vi leaves the terminal raw; `fg` must give it back the modes it
had, and the shell its own between. `rawMode` and `restoreMode` keep
one saved state; a shell needs as many as it has jobs.

```
type Mode* = record ... end;              (* a terminal's modes; the target's *)
proc getMode*(fd: INT): (Mode, INT);
proc setMode*(fd: INT; m: Mode): INT;     (* once the output written is sent, as TCSADRAIN *)
```

The C calls: `tcgetattr` and `tcsetattr`.

**Time used.** `time pipeline` and `times` report CPU time used, the
shell's and its children's, which `clock` can't tell.

```
proc cpuTime*(children: BOOL): (I64, I64);   (* user and system time, in ns: this program's, or its waited-for children's *)
```

The C call is `getrusage`.

**Limits.** `ulimit -n`, `-s`, `-c`:

```
const limitFiles* = 7; limitStack* = 3; limitCore* = 4; ...   (* each target's numbers *)
proc limit*(which: INT): (I64, I64, INT);        (* soft and hard; -1 for none *)
proc setLimit*(which: INT; soft, hard: I64): INT;
```

The C calls: `getrlimit` and `setrlimit`.

**Who and where.** A prompt shows the user, the host, and `#` for
root; `~` is the home directory, and `~name` someone else's.

```
proc uid*: INT;                       (* the real user id *)
proc euid*: INT;                      (* the effective one: 0 is root *)
proc hostName*: ([]U8, INT);          (* good until the next call *)
```

`~name` is the sixth field of `name`'s line in `/etc/passwd`, which a
shell reads with `Files.read`; `HOME` is `~`. The C calls: `getuid`,
`geteuid`, `gethostname`.

**More signals.** `trap` and `kill -USR1` name them:

```
const sigUsr1* = 10; sigUsr2* = 12; sigAlrm* = 14;
```

**Not needed.** Globs are rwalk's `Glob` over `openDir` and
`entryKind`. `read -t` is `ready`. Here-documents are a `pipe`, or a
`memFile` when long. `wait` already says `stopped`; a job continued
by another program (`WCONTINUED`) would need a fifth `Status`, which
breaks a `match` on `Status` that names all four, so it is left out:
the shell knows when it continues a job itself.
