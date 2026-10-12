# Reading the raz compiler

The compiler is nine files of Free Pascal, under 6,500 lines of code.
This guide walks through them in the order they are best read: from the
characters of a source file to the bytes of an executable. It assumes
you know the language from `doc/raz.md`, and enough x86-64 to read a
disassembly.

| File | Lines | Code | What |
|---|---|---|---|
| `src/diag.pas` | 274 | 198 | Messages: positions, source excerpts, colour, counts |
| `src/scan.pas` | 851 | 722 | Symbols, literals, comments, positions |
| `src/sym.pas` | 596 | 497 | Types, objects, scopes, layout |
| `src/x64.pas` | 695 | 559 | Code buffer, chunks, fixups, places, instruction encoder |
| `src/gen.pas` | 1,750 | 1,493 | Items: loading, storing, copying, frames, calls |
| `src/parse.pas` | 2,468 | 2,222 | Declarations, statements, expressions, built-ins, recovery, warnings |
| `src/link.pas` | 180 | 139 | Tree shaking, layout, patching, the places |
| `src/elf.pas` | 424 | 351 | Static and dynamic ELF, symbol table, line numbers |
| `src/raz.pas` | 234 | 185 | The command line, the entry points |

Every file opens with a comment that says what it is, what it depends
on and what it leaves out. Read those first; they are the map.

## The shape of it

There is one pass and no tree. The parser reads a construct and, in
the same breath, has the code generator emit its machine code. Nothing
is kept to be looked at again, except the declarations, which live in
the symbol table for as long as the compiler runs.

The code generator is a stack machine through `rax`. An expression's
value is computed into `rax`; when a second operand has to be computed,
the first is pushed, and popped into `rax` when both are ready, the
second going to `rcx`; if the second needed no code of its own (a
constant, or a plain variable), the push is taken back instead. No
register is ever allocated, so there is no register allocator, and
every access the program writes is one instruction, in the order
written. That is also why `VOLATILE` costs the compiler nothing: it
never does anything clever to begin with.

The output is a set of *chunks*: one for each procedure, each module
variable, each string. Code refers to other chunks through *fixups*,
which aren't resolved until the end. When everything is compiled, the
linker marks the chunks the entry point can reach, gives each an
address, patches the fixups, and the ELF writer puts them in a file.
Whatever nothing reaches never makes it into the executable.

All modules are compiled in one run, from source: there are no object
files, no symbol files, and nothing to keep up to date.

## Following one program

`raz Hello.raz` does this:

1. `raz.pas` reads the command line and calls `CompileMain`
   (`parse.pas`).
2. `CompileMain` imports `Rt` first, since every program needs it, and
   then compiles `Hello.raz` with `CompileFile`.
3. `CompileFile` opens the file in the scanner and parses the module.
   At `import Out;` it calls `ImportModule`, which finds `Out.raz` and
   compiles it there and then, saving and restoring the scanner and the
   scopes around it. So modules are finished in an order where each
   comes after those it imports; that is the order their bodies run.
4. Each procedure becomes a chunk of code; `Out.str("hello, world\n")`
   becomes a string chunk, a call, and a fixup to `Out.str`'s chunk.
5. Back in `raz.pas`, `Use` marks the modules the program uses; the
   entry point, `_start`, is written as one more chunk: save `argc` and
   `argv` and the address of the places (below), call every used
   module's body, call `main`, call `Rt.exit`.
6. `MarkLive` (`link.pas`) marks what `_start` reaches; then
   `WriteElf` (`elf.pas`) has `link.pas` place it and patch it, and
   writes headers, code, data, symbols and line numbers.

## A procedure, compiled

```
proc scale(a, b: I64): I64;
begin
    return a + b * 2;
end;
```

comes out as this (from `objdump -d -M intel`):

```
push   rbp                            ; EnterBody: the frame
mov    rbp,rsp
sub    rsp,0x10                       ; its size, patched in by EndProc
mov    QWORD PTR [rbp-0x8],rdi        ; the parameters, into their slots
mov    QWORD PTR [rbp-0x10],rsi
mov    rax,QWORD PTR [rbp-0x8]        ; a
push   rax                            ;   kept while b * 2 is computed
mov    rax,QWORD PTR [rbp-0x10]       ; b, its push taken back for the 2
shl    rax,0x1                        ; times 2 is a shift
mov    rcx,rax
pop    rax                            ; a again
add    rax,rcx
jmp    <leave>                        ; return
xor    eax,eax                        ; running off the end returns zero
movq   xmm0,rax
leave
ret
```

Every line of it can be traced to a routine in `gen.pas`; the pushes
and pops are `Op1` and `Op2`, the frame `EnterBody` and `EndProc`. It
is not fast code. It is code whose every instruction you can account
for, which is the point.

## diag.pas: messages

Every message the compiler prints is made here. A position, `TPos`, is
a file and a stretch of bytes in it; `Error`, `Warning` and `Note` show
it as `file:line:column`, then the line of source with the stretch
underlined, and `Help` adds a line of advice. Notes and help are shown
only with an error that was: not one at the place of the last, and
not one under `quiet`, which the parser sets when an error follows
from another (see parse.pas). The line and column are
worked out only when a message is printed (`Locate`, `Chars`), so
positions cost nothing while compiling. `AddFile` keeps every source
file the scanner opens, so a note can show a line of any of them.
`Finish` prints the count of errors and warnings and stops if there
were errors; `Fatal` is for errors with no place in the source.

## scan.pas: the scanner

The scanner turns bytes into symbols (`TSym`). The current symbol is in
`tok`, with its value in `ival` (integers and characters), `rval`
(reals), `id` (identifiers) or `sbuf` and `slen` (strings, already
decoded).

Read `Next` first: it skips white space and comments (`Comment`, which
counts nesting), then dispatches on the first character. `Number`
handles decimal, `0FFH`-style hexadecimal and reals; `LitChar` handles
one character of a literal, escapes included. `ReadReal` turns a real's
digits into the nearest `F64` exactly, as a fraction of two big
integers (`TBig`), since Free Pascal's `Val` can be one bit off.

Identifiers are *interned*: `Intern` puts each distinct name once in a
pool and hands back a small integer, so every later comparison of names
is a comparison of integers. The reserved words are interned first, in
the order of `TSym`, so a name's number tells at once whether it is a
reserved word.

Source is UTF-8, checked by `Utf8` wherever a byte above 127 appears:
in strings, characters and comments. Anywhere else it is an error.

`TokPos` is the position of the current symbol, `SpanFrom` the stretch
from a saved position to the end of the symbol before the current one,
and `MissingPos` the place to say a symbol is missing: just after the
symbol before, when the current one starts a new line. Errors go
through `Mark`, at the current symbol, `MarkAt`, at a position, or
`MarkHelp`, which adds a line of help; each reports the error
(`diag.Error`) and jumps to `recovery`, the parser's place to go on
from (see parse.pas), through `Fail`. An error with notes is reported
with `Error` and `Note`, then `Fail`. A message names what it found: `Found` describes
the current symbol and `SymText` spells an operator or reserved word,
so that the parser's `Expect` and `Expected` say `expected ";", found
"end"`. Errors in the text itself stop the
compiler (`MarkBytes`, `LexError`): past a string left open, the
symbols can't be trusted. A slip from another language, such as `!=`
for `#`, is reported by `Slip`, which reads on as if the right symbol
were written; not while the parser is `skipping` what it read once
before an error. `SaveScan` and `RestoreScan` keep
the scanner's state while an imported module is compiled.

## sym.pas: types, objects and scopes

Two records hold everything the compiler knows about a program.

`TType` is a type. Its `form` says what kind (`fInt`, `fPtr`, `fArray`,
`fRecord`, `fVariant`, `fProc`, and so on), and the other fields mean
what that form needs: `base` is what a pointer points at, an array or
slice holds, or a procedure returns; `fields` lists a record's fields,
a variant's cases, a procedure's parameters; `len` counts an array's
elements. `size` and `align` are worked out when the type is built, by
the C rules. `obj` is the declaration that named the type, if any.

`TObj` is anything a name can stand for: a constant, type, variable,
procedure, module, field, variant case or built-in (`cls`), and `pos`
is where its name is declared, for notes. Where it
lives is decided here too: a module variable's chunk, a local's frame
offset in `val`, a procedure's chunk.

Scopes are numbers. The universe is 0; each module, procedure, record
and match arm gets a new one from `NewScope`. All objects of all scopes
sit in one open-addressed hash table, keyed by scope and name: `Find`
looks in one scope, `Lookup` in each open scope from the innermost out.
A lookup costs the same however big a program grows, which matters at
a million lines a second. After an error, `Closest` looks through the
whole table for the name in reach spelled most like one not found
(`Distance`), for "did you mean".

`Same` and `Alike` decide whether two types are the same: one
declaration for named types, built alike otherwise. `Fingerprint`
hashes what a declaration exports, for the check that a module's files
for different targets agree. The universe, the basic types and built-in
procedures, is set up in the unit's `initialization`.

## x64.pas: machine code

Code is written into one growing buffer, `code`, with `pc` its length;
strings go to `rodata`. A chunk (`TChunk`) records its section, where
its bytes start, how many, and the fixups it makes. `BeginChunk` and
`EndChunk` bracket a procedure; `SetData` and `SetBss` make data
chunks.

A *fixup* (`TFixup`) is a 32-bit field in the code that will hold the
distance to another chunk: a call's target, or a rip-relative address.
`AddFixup` records one; `link.pas` fills them in.

Jumps within a procedure don't wait for the linker. A label not yet
placed is a chain of the jumps to it, each jump's 32-bit field holding
the position of the one before (`Jmp`, `Jcc`); `FixLink` walks the
chain and patches each once the label's position is known. This is the
trick from Wirth's compilers, and it means a label is one integer.

The encoder is `OpM` and `OpR`: a prefix, the REX byte, the opcode, the
ModRM and SIB bytes and the displacement, for a register and a memory
operand (`TMem`) or two registers. Everything else (`MovRR`, `Load`,
`Store`, `Alu`, `Sse`, ...) is a line or two that calls them with the
right opcode. Only the instructions the code generator uses are here.
`test/enctest.pas` emits one of each for `objdump` to check.

Two more things live here because they are tied to code positions:
`NoteLine` records which line and column of the source the code from
`pc` on belongs to, for gdb and for the places; `Here` is the address
of the code being written, as an operand. `ExternChunk` makes, once per C symbol, the quadword the
dynamic loader will fill with that symbol's address.

## gen.pas: the code generator

This is the heart, and the file to read slowly.

An operand is an *item* (`TItem`), as in Wirth's compilers. Its `mode`
says what it is now:

- `mConst`: a value known to the compiler, in `val`;
- `mVar`: a variable at an address the code can name: relative to
  `rbp` (`bFrame`), to a chunk (`bGlobal`), to a register (`bReg`), to
  an address pushed on the stack (`bStack`), or kept in a frame slot
  (`bSlot`); plus `off`;
- `mReg`: a value in `rax`; `mStack`: a value pushed on the stack;
- `mProc`, `mType`, `mStr`, and a few more the parser needs.

An item also carries `pos`, the stretch of source it came from, which
the parser sets as it reads an expression; an error about an item is
reported there (`MarkAt(x.pos, ...)`), and one about two operands
across both (`Join(x.pos, y.pos)`). `What` names an item for a
message: a constant without a type of its own as it is written
(`found 1.5`), anything else by its type.

Three routines move items towards the machine. `Value` brings a value
into `rax`, loading it with the one instruction its size needs.
`Address` brings a variable's address into a register. `Save` pushes
whatever an item has in a register, so that another expression can be
computed; the item remembers that it's on the stack. Read these three,
then `MemOf`, which turns an `mVar` into an x64 memory operand, popping
its address first if it was pushed.

Expressions: `Op1` is called when the parser has seen an operator and
its left operand, `Op2` when it has the right one. `Op1` saves the left
operand (or, for `and` and `or`, emits the test that skips the right
one). `Op2` checks the types, folds constants (`FoldInt`, `FoldReal`),
and otherwise puts the left operand in `rax`, the right in `rcx`, and
emits the operation. When the left was the last thing pushed and the
right needs no code (a constant, or a variable on the frame or in a
chunk), `Unpush` takes the push back, and the right goes straight to
`rcx`; not if a jump or a line starts after the push. A power of two
on the right of `*`, `div` or `mod` becomes shifts (`DivPow2`), since
`idiv` is slow. Narrow integers are brought back to their width
after each operation (`Norm`), which is how `U8` arithmetic wraps.
Since they are computed in 64 bits, a shift's count is cut to their
width first, and `DivTrap` makes the smallest value of one divided by
-1 fault as an `I64`'s does.
`=` and `#` on arrays, slices and strings make a slice of each side
(`SeqSlice`), compare the lengths, and then the bytes with `repe
cmpsb`, right where the comparison stands: no call. `+` on two string
constants is `JoinStr`, which makes one string of them, in a chunk of
its own.

Variables: `Deref`, `Field`, `Index` and `Slice` turn an item for a
variable into an item for part of it, mostly by adding to `off`. An
item for another module's exported variable, or part of it, is `ro`:
it isn't a variable (`isVar`), and `NotReadOnly` says why where one is
wanted; what it points at is.
`Index` and `Slice` emit the bounds checks, unless the module says
`check off;` (`checks`, which `CompileFile` sets for each module), and
`Convert` the check of an enumeration's position; `Check` jumps over a call to `Rt.fail` when
the check holds. The call passes what failed, the values involved and
its own address, by which `Rt` finds the place; that code has the
place of the offending expression (`LineCol` in `scan.pas`), and the
code after it the statement's again.

Assignment and conversion: `Coerce` makes a value fit the type it's
going to, or reports that it can't; it's where a string literal becomes
a slice, an array a slice, an untyped constant a typed one, and an
`INT` an `I64` (`Widens`). `CoerceExact` is for where the types must
be the same, as in a `for` loop, `INC` and several results. `Assign`
stores, copying records and arrays with `rep movsb`. `Convert` is the
written conversion, `T(x)`.

Calls: `BeginCall`, then `PassArg` for each argument, then `EndCall`.
Each argument is computed into a frame slot of its own, left to right;
only in `EndCall` are they loaded into the registers System V wants,
and the stack aligned for the call. A record passed by value goes as
the address of a copy; one returned comes back through a hidden pointer
in `rdi`, as C's structs do, and so do several results. `return
f(x);` passing on f's several results copies them, with `ReturnAll`,
from the call's temporary to the place its own hidden pointer names.

Frames: `BeginProc` gives the parameters their slots; `EnterBody`
writes the prologue, which zeroes the locals (with a few stores, or a
loop for more; there are none to zero in `scale`) but not the
temporaries, since each is written before it is read;
`EndProc` writes the epilogue and patches the frame's size in. Within
a statement, scratch space comes from `AllocTemp` and is given back by
`ReleaseTemps`; `AllocPerm` reserves space for the whole procedure.

## parse.pas: the parser

A recursive descent parser, one routine for each rule of the grammar in
the report, calling `gen.pas` as it goes.

Start with expressions, bottom up: `Factor`, `Term`, `SimpleExpr`,
`Relation`, `Conjunct` (the `and`s), `Expression` (the `or`s). Then `Designator`, which reads a name and what follows
it: `.field`, `^`, `[i]`, `[lo..hi]`, a call, a conversion. Each step
calls the matching routine in `gen.pas` on the item it has. The
`want` parameter carries the type an expression must have, where it is
known, so that `[1, 2, 3]`, `{x: 1}` and `{red}` know what to build.

Then statements: `Statement` makes each one a recovery point (below)
and `OneStatement` dispatches; `IfStatement`,
`WhileStatement`, `ForStatement` and `MatchStatement` emit their jumps
with `x64.pas`'s labels. `Defer` is worth reading: a deferred statement
is compiled where it stands, as a little subroutine of the procedure
that the code jumps over, and `RunDefers` emits a call to it at every
way out of its statement list: the end, `return` and `break`.

Then declarations: `Declarations` reads `const`, `type`, `var`, `proc`
and `extern`, each one through `Declaration`, a recovery point, which
calls `ConstDecl`, `TypeDecl`, `VarDecl`, `ProcDecl` or `ExternDecl`. `ProcDecl` handles forward declarations, code procedures
(`CodeBody`, which just copies the bytes) and bodies (`Body`).
`ParseType` and its helpers (`RecordType`, `VariantType`, `Signature`,
`EnumType`) build `TType`s.

Last, modules, at the end of the file. `CompileFile` reads one module.
`ImportModule` finds a module's file, trying the target's names first,
and compiles it if it isn't yet. `CheckOneModule` first makes sure no
later directory has the module too, unless the file is a link to one
of its files there; `CheckSiblings` then reads the files for other
targets beside it, declarations only, and `CompareIface` holds them
to the same exports by their fingerprints. A generic module is
compiled once per distinct list of arguments, where it is first used.
The import only notes where its arguments are (`SkipArgs`, `deferred`);
`FirstUse`, from `QualIdent`, has `MakeInstance` go back there, where
`ParseArgs` reads them, then compile the instance. `Params` binds them
to the module's parameters, and `IsModule` decides whether an instance
already exists. An instance can't be compiled in the middle of another
procedure's code, since the code buffer is one run of bytes, so
`InstancesFor` reads ahead through a procedure, or the module's body,
before its code begins, and makes the instances it names.

**Recovery.** After an error the parser carries on, so that one run
reports them all. `Guard` notes, at the start of a statement or
declaration, the scanner's state and the parser's; `setjmp` marks the
place, and `MarkAt` jumps back to it after reporting. `Restore` puts
the state back, the construct's first symbol current again, and
`SkipConstruct` reads past it, counting the words that open and close
blocks. A symbol at the start of a line ends the skip: by the usual
layout it starts the next declaration, so the statement gives up its
procedure (`GiveUp`), and `SkipProc` reads to the procedure's
`end Name;`. A name not declared is reported by `NotDeclared`, with
what it may have meant: a module to import (`ModuleFile`) or a name
spelled alike. It is then declared where it is used, with the type
`tPoison` (`Poison`), as are the names of a declaration that had an
error; a construct that uses poison sets `quiet`, and its errors
aren't reported, since they follow from one that was. Nothing breaks
for the half-made code: once there is an error, no executable is
written.

**Warnings.** `Declare` keeps each module's declarations in order in
two lists, through `link`: its own and its procedures', parameters
and a match's names for fields among them. `Named` marks an object
`used` and `read` wherever a name finds it, except a procedure naming
itself; `LeftSide` puts `read` back as it was for a variable named
whole before `:=`, which is written, not read. At the end of a module
with no errors, `Warnings` merges the two lists by position and `Warn`
reports what isn't exported, doesn't start with `_`, and was never
used, or, for a variable, only assigned. A generic module's instances
share its text, so only the first is warned of.

The built-in procedures are in `Builtin` (and `New_`, `Atomic`): each
parses its own arguments, since `SIZE` takes a type and `INC` a
variable.

## link.pas: tree shaking and layout

`MarkLive` starts from the entry chunk and follows fixups, marking each
chunk it reaches; nothing else goes into the executable. `LinkAll`
places the live chunks section by section (`Place`), each at its
alignment, then copies their bytes into the images of text and rodata,
patching every fixup with the distance from the end of its field to its
target.

Between placing text and placing rodata, `MakePlaces` writes the
places, a rodata chunk: for each line note in live code, its address,
line, column and file. `Rt` reads them, through `Rt.places`, which the
entry point sets, to say where a failed check or a signal was: the
place with the highest address up to the one it has. Its signal
handlers, set in its body, run on a stack of their own, so that they
can tell a stack overflow, and leave by returning to the faulting
instruction with the handler reset, so that the signal ends the
program.

The layout is chosen so the file can be mapped as it lies: text just
after the headers, rodata on the next page, then a writable page that
begins with the dynamic loader's table (in a program that uses C) and
goes on as bss.

## elf.pas: the executable

`WriteElf` writes the ELF header, the program headers, the text and
rodata images, and then what isn't loaded: section headers, a symbol
table with every live procedure and variable by `Module.name`, and the
line table.

A program that uses C is linked dynamically, in the least way the
loader accepts: an interpreter header naming the loader; a dynamic
section naming the libraries; and, for each C symbol the program uses,
a symbol and a `GLOB_DAT` relocation that has the loader write the
symbol's address into the quadword `ExternChunk` made. Code calls C
through that quadword. There is no PLT and no lazy binding.
`SizeTables` and `PutTables` lay these out in the room `link.pas` left
at the end of rodata.

Line numbers are DWARF 4: `PutDebug` writes a line table with one
sequence per procedure, from the notes `NoteLine` made, and the single
compile unit gdb needs to find it. There are no types or variables in
it; gdb can stop at a line and show where it is, not print a variable.

## raz.pas: the command line

`raz.pas` parses the arguments, calls `CompileMain`, and works out what
the program uses: `Use` marks the modules imported from the main module
and `Rt`; `UsesC` decides whether the program is dynamic, refusing one
that both uses C and has a module saying `link static`. Then it writes
the entry point, and has `MarkLive` mark what it reaches. On a target
without reals (`HasReals`, beside `Target` in `parse.pas`; x86-64 has
them), a live chunk that computes with one is an error at the first
place it does: `UsesReals` in `gen.pas` notes it, from `Value` and a
real literal, on the chunk of the procedure being compiled. A real
moved whole, as a record's bytes are, isn't noted. A static program starts at `_start` itself. A dynamic
one starts at a `_start` that calls `__libc_start_main` the way C's own
start-up does, which sets C up and calls back a `main` that runs the
module bodies and the program's `main`.

`raz run` writes the executable to a memfd, a file only in memory, and
executes it through `/proc/self/fd` in raz's own place, handing it the
rest of raz's `argv`. Nothing is left on disk, and the program's
status is the command's.

## Where to start changing it

- **A built-in procedure:** an entry in `sym.pas`'s universe, a case in
  `Builtin` in `parse.pas`, and the code, in `gen.pas` or right there.
- **An instruction:** a routine in `x64.pas` built on `OpM` or `OpR`,
  and a line in `test/enctest.pas` to check its encoding.
- **A statement:** a reserved word in `scan.pas` (in `TSym` and `Words`,
  in the same order), a case in `Statement`, and a routine beside the
  others.
- **A check that fails:** `Check` in `gen.pas`, and the message in
  `lib/Rt.raz`'s `fail`; a reason a signal gives, `onSignal` there.

After any change: `make check`, `make bench`, `make loc`.
