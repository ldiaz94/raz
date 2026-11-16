# Working on raz

This file is for whoever prepares a defect fix or a documentation fix
for raz, a person or the AI tool helping them. `CONTRIBUTING.md` says
how one is offered: through a GitHub issue, never a pull request, with
a `Signed-off-by:` line, and with you answering for every line a tool
wrote.

## Read first

- `doc/raz.md`, the report, volume 1: it defines the language.
- `doc/raz-lib.md`, volume 2: the library.
- `doc/compiler.md`, the guide to the compiler, file by file, and,
  under "This compiler's choices", what the report leaves to an
  implementation.
- `STANDARDS.md`: how raz is written here.
- `doc/report-history.md`, what each version of the report changed;
  `PLAN.md`, what is left before 1.0.

## Build and check

    make raz           # the compiler, ./raz, built from src/ by the release BOOT names; its library is lib/
    make check         # every example and test against its expected output
    make fmt           # lib/, examples/, tools/, site/, src/ and src/test/ are formatted
    make bench         # must report at least 400,000 lines a second
    make prev-bench    # the compiler's speed against BOOT's: more than a tenth slower fails
    make fixpoint      # BOOT's release builds src, that builds src, that again: the last two agree
    make loc           # lines of the compiler, by rloc; the last, code, is the budget
    make kernels       # test/bench's kernels against FPC -O2's twins (needs fp-compiler)
    make gdb           # gdb stops at a line of a test and names it
    make stress        # 40,000 native threads; make check runs a small version
    make alpine        # test/libc in an Alpine container, over musl (docker)
    make pdf           # the report as PDF
    make install       # raz on PATH (PREFIX=..., ~/.local by default); make uninstall

On a Mac (docker needed):

    make docker-check  # make check in a linux/amd64 container; under Rosetta it skips 9 tests, each saying why
    make mac-check     # on Apple Silicon: test/mac and conform/run cross-compiled in the container, run natively, and lldb
    make lldb          # gdb's test, for lldb, on a program made for darwin-arm64

`make check` also runs `tools/Doc.raz` and `tools/Pretty.raz`, the
report's whole examples, the tutorial's (`doc/raz-tutorial.7`, each
against the output the page shows after it, its status in `test/man`),
each library module's own `main` (its test), and the vim and emacs
support headless where they are installed (`vim`, `emacs-nox`): each
example must indent back exactly as written.

`test/libc` runs its programs over `lib/Sys.raz`, the C one, through a
link in its `mods`; `make check` runs them again with `-libc musl`
where musl's loader is installed (`musl`, `musl-tools`), and compares
`tools/cabi.c`'s output, with `cc` and `musl-gcc`, with
`lib/CAbi.linux-x86_64.raz`, which is never edited by hand.

`fpc` is needed only for `make kernels`; `rloc` only for `make loc`.

## Tests

The conformance suite, `conform/`, holds what any implementation must
do; `test/` holds what is this compiler's alone: its messages, its
limits, its target. A test goes in `conform/` when the report alone
fixes its output and status, and keeps to the language and the library
a target can't leave out. `conform/check.sh` and `test/check.sh` say
how each is laid out.

- `test/run/X.raz` with `X.expect` (standard output), and optional
  `X.status`, `X.stderr` and `X.args`; modules they import in
  `test/run/mods`.
- `test/err/X.raz` must fail to compile with the text in `X.err` (all
  of standard error), given the compiler options in `X.args` if there
  is one.
- `test/msg` holds this compiler's `X.stderr` and `X.err` for the
  programs in `conform/`.
- `test/pretty/X.raz` must format to `X.expect`.
- `examples/` works the same way. Examples, `test/libc`, the tools and
  the library's tests are compiled with `-Werror`: no warnings.
- A test or example without `.expect` is only compiled
  (`examples/Window.raz` needs a display).

## What a patch must keep

- **BOOT.** `src/`, the compiler, is raz, built by the release the file
  `BOOT` names, by its tag and its tarball's SHA-256. `src/boot.sh`
  fetches that tarball into `build/boot/`, checks the sum and puts its
  `raz` there with today's `lib/` beside it. So `src/`, and the modules
  of `lib/` it imports, use nothing that release doesn't know.
  `lib/Sys.raz` and `CAbi` are read for an interface check when BOOT's
  release builds `src/`, so they keep to its language too.
- **Checks.** `make check` and `make fmt` pass; the fixpoint holds.
- **Budget.** At most 18,000 lines of code in `src/` (blank and comment
  lines not counted, as `make loc` counts them; the compiler is about
  16,700 now).
- **Speed.** At least 400,000 lines of raz a second (`make bench`), and
  no more than a tenth slower than BOOT's release (`make prev-bench`).
- **The report** stays under 40 pages as `make pdf` renders it.
- **Clarity first**, before speed and size: the compiler must be plain
  code that a beginner can follow. Each unit opens with what it is,
  what it depends on and what it leaves out; comments say why, most of
  all where the code is obscure or needs a compiler writer's knowledge.
  Every rewrite of the code the compiler makes is explained where it is
  done, with the code before and after, and in `doc/compiler.md`.
- **Parameters** (`STANDARDS.md`): a value, `var`, `const`, or, only
  when it is kept, a pointer; no `ADR` where `var` serves.
- **The guide stays true.** The parser reaches the machine only through
  `Gen` (`src/Gen.x86_64.raz`; `src/Gen.arm64.raz` for darwin-arm64),
  and the executable's format only through `Exe` (`src/Exe.linux.raz`,
  `src/Exe.darwin.raz`). When the compiler changes, keep
  `doc/compiler.md`'s table of lines and its routine names true. The
  arm64 back end is built only into a compiler for darwin-arm64
  (`src/cross.sh`); a change must leave x86-64's output as it was
  unless it means to change it.
- **Documentation** matches the report's plain, short prose.

`src/` has one module to a unit of the Pascal compiler it was ported
from, with the same names. That compiler, the seed, built `src/` up to
v0.19.0 and is in git at that tag (`seed/`); a comment in `src/` that
names "the seed" means it. Each release since was built by the one
before it.

`sbcl/` is an example, not part of the build: a second compiler, in
Common Lisp, written from the report alone and kept as a reference
(`sbcl/README.md`).

## The freeze

The language is frozen. It changes only to mend a defect: the compiler
or the library doing other than the report says. The library's core
(appendix A) changes only to mend a defect or plug a very big gap; the
rest of the library grows only conservatively, by what breaks no
program. Proposals and new features aren't taken, and a wish isn't
recorded.

That a word is reserved, however common (`code`, `to`, `packed`,
`forward`, `set`, ...), and that module names share one space with the
library's (report 3, "Names are flat"), so that a program's module may
clash with one of the library's, are settled. Don't raise them, as a
defect, a proposal or an awkwardness, in raz or in a program written
in it: a name that is taken is renamed.

## Readings of the report already taken

These are how the compiler behaves, and a fix keeps them. Where one
names registers or instructions, it describes the x86-64 back end.

- A named and an anonymous type built alike are the same; `type A = B`
  is an alias. A hex literal above high(I64) is a `U64`.
- `p^.f` and `p^[i]` are explicit; `p[i]` on a pointer to an array is
  an error. A statement starts with a name, so `^T(x)^ := v` isn't one.
- A `BOOL` converts to every integer type, 0 or 1, in `convert`'s
  integer branch with no code of its own, as a `BOOL`'s value is
  already 0 or 1; of a constant it folds. No integer to `BOOL`: the
  error's help says `x # 0`.
- `for`: the step is a constant; the loop never steps past the limit,
  so it can't wrap; afterwards the variable holds the last value it
  took; the body may assign it.
- Two results that are each a single value of a word at most, not a
  real, come back in rax and rdx, and so does a slice, as from a code
  procedure; other several results, and records, through a hidden
  pointer.
- `NEW(p, a)` requires `a: ^Mem.Allocator` and calls its `alloc`
  field: the one library type the compiler knows by name. `Rt.fail` is
  found by name too.
- A set literal takes its type from its first name when nothing else
  gives it; `{}` needs a known type. String constants can be indexed
  and sliced.
- A deferred statement's frame slots stay reserved for the rest of its
  procedure.
- A generic instance first used in a procedure, or in the module's
  body, is made before that code begins: `instancesFor` reads ahead
  for the import's name, since code can't be compiled inside other
  code. Its arguments are read then, in the scope there.
- A program uses C if a module it uses (not one read only for an
  interface check) has an `extern` or a `link` of a library. `static`
  in `link static;` is not a reserved word. It is linked against
  glibc, or musl (`/lib/ld-musl-x86_64.so.1`, needing `libc.so`) by
  `-libc musl` or on a machine with musl's loader and not glibc's.
- `Sys` gives minus Linux's errnos on every target; `Sys.raz` maps the
  C library's through `CAbi.errnos`.
- C symbols are reached through quadwords the loader fills in
  (GLOB_DAT), with no PLT; the executable exports nothing. In a C
  program the entry point stores C's `exit` in `Rt.cExit`, found by
  name like `Rt.exit`, before any module body runs; and, if the
  program has `Thread`, `pthread_create` and `pthread_join` in
  `Thread.cCreate` and `Thread.cJoin`, so that `Thread` makes C's
  threads there and serves programs with C and without.
- Past an extern's parameters, a string goes as a C string and an
  integer constant as an `INT`.
- A real constant is held as an F64; one typed `F32` holds a value an
  F32 can hold (report 2). An `F32` in a register is its low 32 bits;
  the upper ones are left as they fall.
- `Heap` and `Out` lock with `Lock`, a spinlock that yields, since
  they serve C's threads and `Thread`'s alike; `Thread.Mutex` is a
  futex.
- A failed check says what failed and with what values, at the place
  of the offending expression. A signal is told at the place of the
  statement it stopped in, or of the procedure for a stack overflow in
  its prologue, and the program ends by `Rt.exit(2)`, after its
  `atExit` procedures, as a failed check does (a fault inside `Out`'s
  or `Heap`'s lock would hang there). The handlers run on a stack of
  their own: `Rt`'s for the main thread, and one in each `Thread`
  thread's mapping, made by clone or by C. Threads a program makes
  with `pthread_create` itself have none, so a stack overflow in one
  still ends the program by the signal with no message.
- The smallest value of a signed type divided by -1 stops the program
  (SIGFPE), as 6.1 says, `mod` as `div`; for a type narrower than 64
  bits the code makes the division fault, as the machine wouldn't. In
  a constant it is an error, as dividing by zero is.
- `INT` widens to `I64` (and `UINT` to `U64`) wherever its value goes
  to one: assigned, passed, returned, in `a, b := f(x)` and
  `return f(x)`, a `for`'s bounds, `INC`/`DEC`'s step, and where it
  meets an `I64` in an operator (5.10 and 6.1). Never to a `U64`, nor
  an `I64` back to an `INT`.
- `U8`, `I8` and `I16` widen to `INT`, `U8` and `U16` to `UINT`, one
  step only (a `U8` into an `I64` is written), and not in
  `return f(x)`. An operator's result on them (`made`) doesn't widen;
  a conversion's does, `U8(a + b)` too.
- A view, `v.(T)`, is `v`'s item with `T` for its type: nothing is
  copied. A variable kept in a register goes to memory for it, as for
  `ADR`. Another module's variable may be viewed, and not written. A
  view that runs past its end fails as kind 7 of `Rt.fail`.
- A returned slice of the frame (7.3) is caught by `Item.frame`, which
  sees only the expression: a slice held first in a local slice
  variable or a record, stored, or come back from a call, isn't, and
  is left undefined (10).
- An empty slice constant, `const E: []T = [];`, is 16 zero bytes in
  read-only data, read as an array constant is; `LEN` of it is no
  constant. A constant's slice part takes `[]`, names a constant
  whole, of any module, by its type, not its text, and takes an array
  literal, an array constant of its own in a chunk with no name,
  nested to any depth. An `ERROR` constant given another takes its
  chunk: the same error.
- An array a call returns, or a record or variant holding one, and a
  `const` parameter's temporary holding one, is a slot of the
  procedure (8: `Sym.holdsArray`, `allocPerm`): a slice of it may be
  kept to the end of the procedure, and returning it is caught only as
  7.3 catches a slice of the frame.
- `Buf.add`, `str` and `spare`, and `Vec`'s growing, stop the program
  when the allocator has no room; `room` asks first.
- `Sys.handle`'s handler only notes the signal, with `XCHG`; it is
  installed without `SA_RESTART`, so a call it breaks into is -4,
  which `Out` and `Files` try again. Over C, `ready` and `readyFor` try
  `poll` again after EINTR only when no signal `handle` took broke in.
- An enumeration's name shared in its scope with another
  enumeration's is written with its type; shared with anything else,
  the name alone is that other declaration. A `match` arm on an
  enumeration or a variant (7.4) takes a case alone, found among the
  matched type's own whatever the scope holds, or qualified as
  anywhere else (`Kind.done`, `Xml.done`, `Xml.Kind.done`), read by
  `qualIdent`; a qualified case of another type is an error naming
  both.
- `Width` follows glibc's `wcwidth` but gives a control 0, and 0 to
  the format characters glibc counts as 1 (Egyptian hieroglyph
  controls, interlinear annotation), but for the prepended
  concatenation marks.
- A pointer's base, and a procedure type's parameter or result (4 and
  5.9), may name a type declared later in its `type` section, if the
  name is a bare one that nothing in scope declares yet (`[]Later` or
  `[2]Later` doesn't wait): a placeholder of form `fNone` stands for
  it until the section's end (`laterType`, `resolveLaters`), which
  lays several results out again. A procedure type outside a `type`
  section, a variable's, waits for nothing.
- An `extern` module variable is read-only for an importer, as the
  report says of every exported variable (3).
- Warnings come only for a module with no errors. A procedure naming
  itself doesn't use it; a type named by a pointer, or by a procedure
  type's parameter or result, in its own declaration does. An
  enumeration's names are never warned of, nor a generic module's
  parameters; a generic module is warned of in its first instance
  only. Assigning a variable whole (`x :=`, `a, b :=`) doesn't read
  it; anything else does.
- A `const` parameter is a `var` one never changed: passed by address
  always, its `Obj` `isVar` and `isConst`, an item of it `ro`. A slice
  of its array may be made, to read; through it the caller's array may
  be written, which the report says (8). An argument that isn't a
  variable, or is a packed field, a view or volatile, goes in a
  temporary of the statement. `match` on a `const` parameter or a
  constant gives names that are only read. Procedure types compare
  `const` as `var`. It is unused if never read, as a value parameter.
- A variant in a constant must be typed; `const D = dot;` is an error
  that says to write its type. Its case is read by name (`constCase`).
- The library takes a `var` for what it changes and `const` for a
  record or array it only reads. `src/` takes an `Item` as `const`
  only where profiling shows a gain, on the paths every compile goes
  through; the routines that word an error take a value. (A `Map`
  passed as a value, four words, made a loop of `get` half again as
  slow as `const`.) A trace shows no `var` or `const` parameter.
  `Fmt`'s `format` and `put` keep `^Buf.Buf`, since `nil` is standard
  output there.
- `PTR(s)` is a slice's first word, read with no check; of an array or
  a string constant, its address, refused wherever a slice of all of
  it is (a packed record's misaligned field, a view, through
  `^VOLATILE`, another module's array). `PTR("")` is the string's
  place in read-only data, not `nil`; an empty slice cut from another
  keeps its place. `PTR([])` is an error, since `[]` has no type
  there, and its help says it would be `nil`. A slice where its
  element's pointer is wanted, and a pointer where a slice is, are
  errors whose help names `PTR(s)` and `LEN(s)`, or `p[0..n]`.
- `CAS(v, old, new)`, `XCHG(v, x)` and `XADD(v, x)` take a variable,
  whose address is pushed as `ADR`'s is (`atomic`); a local named in
  one is kept out of a register, as for `ADR` (`chooseRegs`). A
  pointer that isn't a variable, `ADR(x)`, is refused with help, and
  so is a pointer variable, `XADD(p, 1)`, whose help says `p^`.
- `import SYSTEM` binds to `Sym.system`, no file, whose scope holds
  `ADR`, `PTR`, `SYSCALL` and `ARGV`; it is never warned of as unused,
  and an alias is refused. What it fences (`Item.needSystem`,
  `doc/compiler.md`) is refused elsewhere: `extern`, `link`, code
  procedures and `check off;` are said and read on, so one missing
  import is one error.
- `[]const T` is a slice type with `rdonly` set: not the same as
  `[]T`, which goes into it with no code (`coerce`), never back (help
  says why). An element read through one has the item's `elemRo`,
  which `notReadOnly` refuses, so every write route (`:=`, `INC`, a
  `var` argument, `ADR`, a view) is caught in one place; `COPY` and
  `FILL` refuse one as their destination (`destSlice`); a slice of
  one, or of an array read through one or of another module's array,
  is one (`slice`); `BYTES` of one is a `[]const U8`; `match` on an
  element gives names only read. A string literal (`tConstBytes` where
  indexed), a constant's slice (`ofConst`), `MSG` and a slice of a
  `const` parameter's array are `[]const`; a constant's slice part
  must be declared `[]const`.
- A procedure or a global in a code procedure (8) is found by
  `Parse.asmName`, beside `asmConst`, after the procedure's labels,
  which `X64.findLabels` enters first: a label wins wherever it is
  written. `call p` and `jmp p` are E8 and E9 with a fixup, `[v]`
  rip-relative, as ordinary code's; `[v]` stands alone (`[g + 8]` is
  an error), a label is only for a jump, and C's names are refused,
  their chunk holding C's address. A variable another module exports
  may be written through `lea`: its type isn't checked. A code
  procedure's body has a scope of its own, so a name not yet declared
  is poison there only.
- The limits (10): one count, `Parse.nest`, of statements, expressions
  and types nested, to 256; 1024 values waiting in one expression
  (`Gen.MaxStack`), past which the compile ends; the other limits are
  `Parse`'s constants, listed in `doc/compiler.md` under "This
  compiler's choices".
- `ROL(x, n)` and `ROR(x, n)` are done at `x`'s own width,
  `rol al, cl` for a `U8`, with no mask of the count: x86 takes it
  modulo 32 or 64, and a byte's or a word's rotation goes round modulo
  8 or 16 itself. A negative count is taken modulo the width as a
  shift's is, `n & (w - 1)`: `ROL(x, -1)` is `ROR(x, 1)`. The result
  is a built-in's, not an operator's, and widens (`made` is false). Of
  two constants they fold, in a constant too.
- `ABS(x)` is of `x`'s type and widens (`made` is false). A signed
  integer's is `mov rax, r; neg r; cmovs r, rax`, then cut to a narrow
  width as `neg` is, so the smallest value gives itself with no check,
  as `-x` does; an unsigned one's is no code; a real's is `btr` of its
  sign bit in rax, as `neg`'s `btc`. Of a constant it folds, a real's
  top bit cleared; of the smallest untyped constant it is `neg`'s
  error, "too big for I64". A string is refused as no number.
- `MIN(T)` and `MAX(T)` are untyped constants, but `MAX(U64)` and
  `MAX(UINT)`, above `high(I64)`, keep their type, as a hex literal
  above it is a `U64`. A `T` not an integer type is an error; `MAX(x)`
  of a variable is "x isn't a type".
- `CLZ(x)`, `CTZ(x)` and `POPCOUNT(x)` give an `INT`, a constant of
  one when `x` is. They use only baseline x86-64, no `lzcnt`, `tzcnt`
  or `popcnt`: `bsr` or `bsf` on all 64 bits (a narrow value's upper
  ones are zero), with `jnz` past setting the count of 0 to the width;
  `POPCOUNT` by `Bytes.count`'s sums of two, four and eight bits and a
  multiply by `0101...H`, in rax and rdx. A set's `POPCOUNT` counts its
  bits the same way.
- `SIZE(T.f)` and `OFFSET(T, f)`: the type is read by `parseType`,
  where a name before a `.` must be a module's, so `M.T` is read whole
  and a `.` past the type is a field's, `SIZE(M.T.f)` too. `T` must be
  a record type (a variant is refused, with help); a path `a.b` is
  refused, its help naming `a`'s type.
- `BYTES(x)`: of a slice, its `PTR` and `LEN * SIZE(T)`, with no check
  of what holds the slice (a `const` one, another module's, a field of
  a packed record), as for `PTR`; of anything else, a variable's
  address and size, refused, as `ADR` refuses, for what is only read,
  and, beyond `ADR`, for a volatile variable; a constant of any kind
  is no variable. `T` is refused by the view's `notPlain`. The result
  keeps `x`'s `frame`, so the bytes of a local are caught by
  `notOfFrame` as far as a slice of it is.
- `FILL(d, x)` takes `d` as `COPY` does (`destSlice`), then `x` as
  `:=` would, with `:=`'s messages, read once before any element is
  written. A scalar element of 1, 2, 4 or 8 bytes is stored from
  `rax`, a real's bits as an integer's: by a store each into an array
  of 16 elements or fewer, else by a loop for fewer than 16 at run
  time and `rep stos` of its width from 16 up. A constant zero into an
  array is `zeroBytes`, as `NEW`'s zeroing is; into a slice it is
  stored as any scalar, which is as fast. Another element is copied
  into `d[0]` and forward from there by `rep movsb`. A record literal
  of zeros isn't seen as a zero. A const parameter's or another
  module's array, as `d`, says why it can't be changed, for `COPY`
  too. `seqSlice` copies no slice that is a temporary already (a slice
  just cut): nothing `s` or `x` does can change it.
- A call of a procedure whose body is only `return e`, with no locals,
  a single value its result and no `try` in `e`, is made in place
  (`Parse.inlined`): the arguments read and converted as for a call,
  each once and in order, into temporaries the parameters are named as
  (a `var` or `const` one, a record or an array, by the address the
  call would pass), then `e` read again in its own module's scope,
  with that module's checks. Another module's procedure and a generic
  instance's too; not one already being made in place, nor a call
  through a procedure value. The procedure has no frame: it is in
  neither the trap report's calls nor gdb's backtrace; a failed check
  in `e` is told at `e`'s line, a signal at the caller's statement. A
  test that wants its frame calls it through a procedure value.
