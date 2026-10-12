# Reading the raz compiler

The compiler is eleven files of Free Pascal, under 7,900 lines of code.
This guide walks through them in the order they are best read: from the
characters of a source file to the bytes of an executable. It assumes
you know the language from `doc/raz.md`, and enough x86-64 to read a
disassembly.

| File | Lines | Code | What |
|---|---|---|---|
| `src/diag.pas` | 310 | 229 | Messages: positions, source excerpts, colour, counts |
| `src/scan.pas` | 886 | 747 | Symbols, literals, comments, positions |
| `src/sym.pas` | 615 | 510 | Types, objects, scopes, layout |
| `src/chunk.pas` | 276 | 217 | The compiled program: chunks, fixups, line notes |
| `src/x64.pas` | 1,039 | 870 | The instruction encoder, jumps within a procedure, the assembler |
| `src/gen.pas` | 1,332 | 1,039 | The stack machine, for x86-64: values, operations, checks, calls, frames |
| `src/item.pas` | 1,342 | 1,118 | Items: types, constants, variables, operators, conversions, calls |
| `src/parse.pas` | 2,712 | 2,407 | Declarations, statements, expressions, built-ins, recovery, warnings |
| `src/link.pas` | 234 | 180 | Tree shaking, layout, patching, the places |
| `src/elf.pas` | 435 | 352 | Static and dynamic ELF, symbol table, line numbers |
| `src/raz.pas` | 197 | 147 | The command line |

Every file opens with a comment that says what it is, what it depends
on and what it leaves out. Read those first; they are the map.

## The shape of it

There is one pass and no tree. The parser reads a construct and, in
the same breath, has the code generator emit its machine code. Nothing
is kept to be looked at again, except the declarations, which live in
the symbol table for as long as the compiler runs.

Three layers do it. `parse.pas` knows the language's syntax. `item.pas`
knows what the program means: each operand is an *item*, as in Wirth's
compilers, and the routines there check the items' types, fold
constants and work out where variables are. Neither knows the machine:
they drive a stack machine, `gen.pas`, by its calls (push a value,
add the two on top, store the top in a variable, jump if it is false),
each with the kind of the value (a word, a 64-bit integer, an `F32`,
an `F64`). `gen.pas` is the only one that knows x86-64; a port to
another machine is a new `gen.pas`, with an encoder of its own in place
of `x64.pas`.

On x86-64 the stack lives in registers, as in Wirth's compilers: the
value at depth `d` is in register `d`, of `r8` to `r11`, and a constant
is only noted, until something needs it in a register, so that it can
be an instruction's operand. Which register a value goes in is settled
by its depth, so there is no register allocator, and every access the
program writes is one instruction, in the order written. That is also
why `VOLATILE` costs the compiler nothing: it never does anything
clever to begin with.

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
   entry point, `_start`, is written by `gen.pas`'s `EntryPoint` as one
   more chunk: save `argc` and `argv` and the address of the places
   (below), call every used module's body, call `main`, call `Rt.exit`.
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

comes out as this (from `objdump -d -M intel`; `raz -S` shows the same
under each line of source, named by the compiler as it made them):

```
push   rbp                            ; EnterBody: the frame
mov    rbp,rsp
sub    rsp,0x10                       ; its size, patched in by EndProc
mov    QWORD PTR [rbp-0x8],rdi        ; the parameters, into their slots
mov    QWORD PTR [rbp-0x10],rsi
mov    r8,QWORD PTR [rbp-0x8]         ; a, at depth 0
mov    r9,QWORD PTR [rbp-0x10]        ; b, at depth 1; the 2 is only noted
shl    r9,0x1                         ; times 2 is a shift
add    r8,r9
mov    rax,r8                         ; the result
jmp    <leave>                        ; return
xor    eax,eax                        ; running off the end returns zero
movq   xmm0,rax
leave
ret
```

Every line of it can be traced to a routine in `gen.pas`: the loads
are `PushVar`'s, the shift and the add `Op`'s, the result
`ReturnJump`'s, and the frame is `EnterBody`'s and `EndProc`'s. It is
not fast code. It is code whose every instruction you can account
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

## chunk.pas: the compiled program

Code is written into one growing buffer, `code`, with `pc` its length;
strings and other constants go to `rodata`. A chunk (`TChunk`) records
its section, where its bytes start, how many, and the fixups it makes.
`BeginChunk` and `EndChunk` bracket a procedure; `SetData` and `SetBss`
make data chunks.

A *fixup* (`TFixup`) is a 32-bit field in the code that will hold the
distance to another chunk: a call's target, or a rip-relative address.
`AddFixup` records one; `link.pas` fills them in. `NoteLine` records
which line and column of the source the code from `pc` on belongs to,
for gdb and for the places. `ExternChunk` makes, once per C symbol,
the quadword the dynamic loader will fill with that symbol's address.
None of this depends on the machine.

## x64.pas: machine code

The encoder is `OpM` and `OpR`: a prefix, the REX byte, the opcode, the
ModRM and SIB bytes and the displacement, for a register and a memory
operand (`TMem`) or two registers. Everything else (`MovRR`, `Load`,
`Store`, `Alu`, `Sse`, ...) is a line or two that calls them with the
right opcode. Only the instructions the code generator uses are here.
`test/enctest.pas` emits one of each for `objdump` to check. `Here` is
the address of the code being written, as an operand.

The assembler, `Assemble`, reads a code procedure's instructions with
the scanner, Intel's syntax as NASM writes it, and encodes them with
`OpM` and `OpR`: `Operand` reads a register, a memory operand or a
constant (by the parser's `ConstExpr`, handed in), and a few tables
give the operations of a kind their opcodes (`Alus`, `Unaries`,
`Shifts`, `SseOps`, `Plain`). Labels are chains of jumps, as below.
`db` gives bytes it doesn't know. `RegNames` and `CondNames` are the
names of the registers and conditions.

The listing, `raz -S`: with `listing` set, each routine of the encoder
says, with `Say`, the instruction it is about to write, as the
assembler would read it; `List` prints the main module's live
procedures with each line of source (`LineText` in `diag.pas`) and the
instructions under it. Nothing is disassembled: the listing is what
the encoder meant.

Jumps within a procedure don't wait for the linker. A label not yet
placed is a chain of the jumps to it, each jump's 32-bit field holding
the position of the one before (`Jmp`, `Jcc`); `FixLink` walks the
chain and patches each once the label's position is known. This is the
trick from Wirth's compilers, and it means a label is one integer.

## gen.pas: the stack machine

This is the only unit that knows the machine. The calls it answers:

- values: `PushConst`, `PushAdr` (the address of a variable),
  `PushVar` (its value), `PushProc`, and `PopVar`, which stores the
  value on top; `Drop` and `Swap`;
- operations on the values on top: `Op`, `Compare`, `Neg`,
  `Complement`, `NotBool`, `Narrow` (to a narrow integer's width),
  the conversions between integers and reals, `CompareSeq` (of two
  slices), and copying: `CopyBlock`, `CopyTo`, `ZeroVar`;
- jumps: `Jump`, `JumpIf` (on a `BOOL`), `JumpCmp` (on two integers),
  `JumpKeep` and `FixKeep` for `and` and `or`, `Fix` where the label
  is;
- checks: `CheckIndex`, `CheckEnum`, and `IndexSlice`, `Slice` and
  `SlicePtr`, which check as they make their address or slice;
- calls (`Call`), frames (`BeginProc`, `EnterBody`, `ReturnJump`,
  `EndProc`, the temporaries of `AllocTemp`), deferred statements
  (`DeferBegin`, `DeferEnd`, `RunDefer`), the built-ins that are
  instructions (`Atomic`, `SysCall`, `Fence`), and the program's entry
  point (`EntryPoint`).

A variable's place is a `TAdr`: relative to the frame (`bFrame`), to a
chunk (`bGlobal`), to an address on the stack (`bStack`), or to one
held in a frame slot (`bSlot`, as a `var` parameter's is); plus `off`.
`Place` turns it into an x64 memory operand, popping or loading the
address first, so that a variable is read or written with one
instruction.

The stack: `stack` notes where each value is, a constant (`lConst`),
in its register (`lReg`) or in a frame slot (`lFrame`); `owner` which
value each register holds. The value at depth `d` belongs in
`Regs[d mod 4]`, `r8` to `r11`: `rax`, `rdx` and `rcx`, which division
and shifts need, and `rsi` and `rdi`, which copying needs, aren't among
them. `Claim` gives a value its register, and `Spill`s a deeper one
that holds it, when an expression is deeper than the registers;
`Loaded` brings a value into its register, from its constant or its
slot; `Top` is `Loaded` for the value on top, and `Target` the
register a new one is computed in. Before a call every value in a
register is spilled (`SpillBelow`), since the call may change them, and
so are the values under `and`'s and `or`'s left operand, which both
ways to its label must find in the same place. `pushed` counts what
is on the machine's stack, which a call must align: the return
address, in a deferred statement. `Op` takes a
constant on the right as it is, and a power of two on the right of
`*`, `div` or `mod` becomes shifts (`DivPow2`), since `idiv` is slow.
Narrow integers are brought back to their width after each operation,
which is how `U8` arithmetic wraps; since they are computed in 64 bits,
a shift's count is cut to their width first, and `DivTrap` makes the
smallest value of one divided by -1 fault as an `I64`'s does.

Checks: `Check` jumps over a call to `Rt.fail` when the check holds.
The call passes what failed, the values involved and its own address,
by which `Rt` finds the place; that code has the place of the
offending expression (`LineCol` in `scan.pas`), and the code after it
the statement's again.

What the machine catches, the code doesn't test for (report section
10, appendix A): on x86-64 Linux a division by zero raises SIGFPE, a
stack overflow meets the guard page under the stack, a call to `nil`
jumps to an address never mapped, and so does a load or store within
`NilPage` bytes of address 0. `Rt`'s handlers say where and why. What
is left is a field of a `nil` pointer past that page: an item reached
through `^` is `deref` until `NilTest` (`item.pas`) has it used, and
gen's `CheckNil` tests the pointer only if the use reaches past
`NilPage`. A port whose machine catches less tests for more, in its
own `gen.pas`: `Rt.fail` stops for a nil pointer, a division by zero
and a stack overflow as the signals would.

Calls: the arguments are in frame slots by the time `Call` runs, one
each, computed left to right; only then are they loaded into the
registers System V wants, and the stack aligned for the call. A record
passed by value goes as the address of a copy; one returned comes back
through a hidden pointer in `rdi`, as C's structs do, and so do several
results (`ResultTo`, `CopyResult`).

Frames: `BeginProc` gives the parameters their slots; `EnterBody`
writes the prologue, which zeroes the locals (with a few stores, or a
loop for more; there are none to zero in `scale`) but not the
temporaries, since each is written before it is read; `EndProc` writes
the epilogue and patches the frame's size in. Within a statement,
scratch space comes from `AllocTemp` and is given back by
`ReleaseTemps`; `AllocPerm` reserves space for the whole procedure.

## item.pas: items

An operand is an *item* (`TItem`), as in Wirth's compilers. Its `mode`
says what it is now:

- `mConst`: a value known to the compiler, in `val`;
- `mVar`: a variable, at `base`, `chunk` and `off`, which `AdrOf`
  makes a `TAdr` for gen;
- `mStack`: a value on gen's stack;
- `mProc`, `mType`, `mStr`, and a few more the parser needs.

An item also carries `pos`, the stretch of source it came from, which
the parser sets as it reads an expression; an error about an item is
reported there (`MarkAt(x.pos, ...)`), and one about two operands
across both (`Join(x.pos, y.pos)`). `What` names an item for a
message: a constant without a type of its own as it is written
(`found 1.5`), anything else by its type.

Two routines move items towards the machine: `Value` pushes an item's
value, and `Address` a variable's address. Both leave the item saying
it is on the stack. An item nothing more is done with is given back to
`Discard`.

Expressions: `Op1` is called when the parser has seen an operator and
its left operand, `Op2` when it has the right one. `Op1` pushes the
left operand, unless it is a constant (or, for `and` and `or`, has gen
jump past the right one). `Op2` checks the types, folds constants
(`FoldInt`, `FoldReal`), and otherwise pushes the right operand and has
gen do the operation; a constant on the left goes on after the right,
and the two `Swap`. A set's operations are operations on its bits
(`SetOp`). `=` and `#` on arrays, slices and strings make a slice of
each side (`SeqSlice`) and have gen compare them right where the
comparison stands: no call. `+` on two string constants is `JoinStr`,
which makes one string of them, in a chunk of its own.

Variables: `Deref`, `Field`, `Index` and `Slice` turn an item for a
variable into an item for part of it, mostly by adding to `off`. An
item for another module's exported variable, or part of it, is `ro`:
it isn't a variable (`isVar`), and `NotReadOnly` says why where one is
wanted; what it points at is. An array constant is a variable too, in
read-only data: `ArrayConst` (`parse.pas`) reads its literal into the
bytes of a chunk, as a string constant's are, and `MakeItem` makes it
an `mVar` there that isn't `isVar`, so it is read, indexed, sliced and
passed, never changed. `Index` and `Slice` have gen make the bounds
checks, unless the module says `check off;` (`checks`, which
`CompileFile` sets for each module), and `Convert` the check of an
enumeration's position.

Assignment and conversion: `Coerce` makes a value fit the type it's
going to, or reports that it can't; it's where a string literal becomes
a slice, an array a slice, an untyped constant a typed one, and an
`INT` an `I64` (`Widens`). `CoerceExact` is for where the types must
be the same, as in a `for` loop, `INC` and several results. `Assign`
stores, or copies records and arrays. `Convert` is the written
conversion, `T(x)`.

Calls: `BeginCall`, then `PassArg` for each argument, then `EndCall`,
which has gen's `Call` make the call. Each argument is computed into a
frame slot of its own. `return f(x);` passing on f's several results
copies them, with `ReturnAll`, from the call's temporary to the place
its own hidden pointer names.

## parse.pas: the parser

A recursive descent parser, one routine for each rule of the grammar in
the report, calling `item.pas`, and for jumps `gen.pas`, as it goes.

Start with expressions, bottom up: `Factor`, `Term`, `SimpleExpr`,
`Relation`, `Conjunct` (the `and`s), `Expression` (the `or`s). Then `Designator`, which reads a name and what follows
it: `.field`, `^`, `[i]`, `[lo..hi]`, a call, a conversion. Each step
calls the matching routine in `item.pas` on the item it has. The
`want` parameter carries the type an expression must have, where it is
known, so that `[1, 2, 3]`, `{x: 1}` and `{red}` know what to build.

Then statements: `Statement` makes each one a recovery point (below)
and `OneStatement` dispatches; `IfStatement`,
`WhileStatement`, `ForStatement` and `MatchStatement` emit their jumps
with gen's labels. The blank is a symbol of its own, `sBlank`, so
no declaration or expression takes it: `_ := e` loads a single value
and drops it, and `MultiAssign` skips the results it stands for. A
`match` on an integer reads each arm's
labels in `IntArm`, which refuses a value in two of them, and tests them
one after another with `MatchRange`: compares and branches, no jump
table. `Defer` is worth reading: a deferred statement
is compiled where it stands, as a little subroutine of the procedure
that the code jumps over (gen's `DeferBegin` and `DeferEnd`), and
`RunDefers` emits a call to it at every way out of its statement list:
the end, `return` and `break`. A `return`'s result waits in the frame
meanwhile, so that gen's stack is empty when they run.

Then declarations: `Declarations` reads `const`, `type`, `var`, `proc`
and `extern`, each one through `Declaration`, a recovery point, which
calls `ConstDecl`, `TypeDecl`, `VarDecl`, `ProcDecl` or `ExternDecl`. `ProcDecl` handles forward declarations, code procedures
(`CodeBody`, which checks the signature and has gen's `CodeProc` run
the target's assembler) and bodies (`Body`).
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

**Hints.** Some messages guess at the mistake from the layout. A
block statement passes `CloseEnd` its start and how far its line is
indented; an `end` further left was most likely meant for a block
around it, so the first such statement is kept, and `EndMissing`
notes it when a procedure's own `end` turns out to be missing. A type
error in an argument goes through `Mismatch`, which notes the
parameter it goes to (`passing`, set by `PassArg`).

**Warnings.** `Declare` keeps each module's declarations in order in
two lists, through `link`: its own and its procedures', parameters
and a match's names for fields among them. `Named` marks an object
`used` and `read` wherever a name finds it, except a procedure naming
itself; `LeftSide` puts `read` back as it was for a variable named
whole before `:=`, which is written, not read. At the end of a module
with no errors, `Warnings` merges the two lists by position and `Warn`
reports what isn't exported, doesn't start with `_`, and was never
used, or, for a variable, only assigned, and a procedure with results
that may reach its end (`openEnd`, from `ends`, which each statement
sets). The calls that drop results are a third list, `drops`, in
order: `CompileFile` notes where the module's own begin, since the
instances it makes along the way add theirs and take them back. A
generic module's instances
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
line, column and file; and for the trap report, each live procedure's
address range and name, and its variables, which `Body` (`parse.pas`)
notes with `NoteVar`: each one's name, its place in the frame and how
`Rt` shows it (`VarKind`). `Rt` reads them, through `Rt.places`, which
the entry point sets, to say where a failed check or a signal was: the
place with the highest address up to the one it has. Its signal
handlers, set in its body, run on a stack of their own, so that they
can tell a stack overflow, and leave by returning to the faulting
instruction with the handler reset, so that the signal ends the
program.

Then `Rt` follows the chain of frames, each `rbp` pointing at its
caller's, and says each call under way and its variables (`calls`);
`Rt.trace` does the same on demand. A thread's first frame has `rbp`
zero, which ends the chain. With `RAZ_PROFILE` set, `Rt`'s body has the
kernel send SIGPROF every millisecond of the program's time
(`setitimer`); `onProf` notes the address it interrupted, and `exit`
has `profile` say which procedures and places those fell in, by the
same tables.

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
that both uses C and has a module saying `link static`. Then it has
gen's `EntryPoint` write the entry point, and `MarkLive` mark what it
reaches. On a target
without reals (`HasReals`, beside `Target` in `parse.pas`; x86-64 has
them), a live chunk that computes with one is an error at the first
place it does: `UsesReals` in `item.pas` notes it, from `Value` and a
real literal, on the chunk of the procedure being compiled. A real
moved whole, as a record's bytes are, isn't noted. A static program starts at `_start` itself. A dynamic
one starts at a `_start` that calls `__libc_start_main` the way C's own
start-up does, which sets C up and calls back a `main` that runs the
module bodies and the program's `main`.

`raz -S` lists the code (`List`, in `x64.pas`) instead of writing
it. `raz run` writes the executable to a memfd, a file only in memory, and
executes it through `/proc/self/fd` in raz's own place, handing it the
rest of raz's `argv`. Nothing is left on disk, and the program's
status is the command's.

## This compiler's choices

What the report's appendix A leaves to an implementation, and what
this one does.

- **The target.** x86-64 Linux, `linux-x86_64`: `INT` is 64 bits, and
  there are reals. Every module of a program is compiled together, in
  one run, into a static ELF executable, or a dynamic one if the
  program uses C; no object files.
- **Finding modules.** `raz Main.raz` looks for `X`, imported, in
  `Main.raz`'s directory, then in each `-I dir` in the order given
  (16 at most), then in `lib` beside the `raz` executable, following
  a link to it (`make install` puts `raz` and `lib/` together in
  `PREFIX/lib/raz`). In each directory it tries `X.linux-x86_64.raz`,
  `X.linux.raz`, `X.x86_64.raz` and `X.raz`, in that order, and takes
  the first found (`ModuleFile`, `parse.pas`).
- **Errors.** Every error in a run is reported, up to 20 (`MaxErrors`,
  `diag.pas`); then the compiler stops. Two errors at the same place
  are told as one. Any error is status 1.
- **Warnings.** Of a declaration never used, or a variable only
  assigned (`Warn`, `parse.pas`): not of what is exported, a name that
  starts with `_`, an enumeration's names or a generic module's
  parameters. A procedure naming itself doesn't use it; a type named by
  a pointer in its own declaration does. Assigning a variable whole
  (`x :=`, `a, b :=`) doesn't read it; anything else does. Warnings
  come only for a module with no errors, and a generic module's only
  for its first instance. A procedure with results is warned of if
  it may reach its end without `return` (`ends`, `parse.pas`): each
  way through its statements must end in a `return`, an `if` with an
  `else`, a `match`, a `while true` or a `repeat ... until false`
  with no `break`. So is a call standing on its own that drops a
  result (`drops`, kept by `OneStatement` and told by `Dropped`);
  `_ := f(x)` drops one on purpose. `-Werror` makes each an error.
- **Several results** come back through a hidden pointer to the
  caller's slots; a code procedure returns two in rax and rdx.
- **Reals.** A real constant is held as an F64. An `F32` in a register
  is its low 32 bits; the upper ones are left as they fall.
- **How a failure is caught.** A division by zero, a stack overflow
  (the guard page under the stack), a call to `nil` and a load or
  store within 4 KB of address 0 are caught by the machine, as
  signals; a field of a `nil` pointer further on is tested for in the
  code. The smallest value of a signed type divided by -1 faults as the
  machine does for 64 bits; for a narrower type the code makes it
  fault.
- **Run-time failures.** A failed check says on standard error what
  failed and with what values, at the place of the offending
  expression, then the calls under way and their variables, and ends
  the program by `Rt.exit` with status 2; `Rt.stop` says its message
  and ends it the same way. A signal
  is told at the place of the statement it stopped in, or of the
  procedure for a stack overflow in its prologue, and then ends the
  program, so its status is the signal's. The handlers run on a stack
  of their own: `Rt`'s for the main thread, one in each `Thread`
  thread's mapping. C's threads have none, so a stack overflow in one
  ends the program by the signal with no message.
- **Locks.** `Heap` and `Out` lock with `Lock`, a spinlock that yields,
  since they serve C's threads and `Thread`'s alike; `Thread.Mutex` is
  a futex.
- **C.** A program uses C if a module it uses has an `extern` or a
  `link` of a library. C's symbols are reached through quadwords the
  loader fills in (GLOB_DAT), with no PLT; the executable exports
  nothing. Its entry point stores C's `exit` in `Rt.cExit` before any
  module body runs.
- **Frames.** A deferred statement's slots stay reserved for the rest
  of its procedure. A generic instance first used in a procedure, or in
  a module's body, is made before that code begins (`InstancesFor`).
- **The executable** carries DWARF line numbers and the names of
  procedures for gdb, and `Rt`'s own table of places (`Rt.places`).

## Where to start changing it

- **A built-in procedure:** an entry in `sym.pas`'s universe, a case in
  `Builtin` in `parse.pas`, and the code, in `gen.pas` if it is an
  instruction, or of calls to gen right there.
- **An instruction:** a routine in `x64.pas` built on `OpM` or `OpR`,
  and a line in `test/enctest.pas` to check its encoding.
- **A machine:** a new `gen.pas`, answering the same calls, and an
  encoder and assembler for it in place of `x64.pas`.
- **A statement:** a reserved word in `scan.pas` (in `TSym` and `Words`,
  in the same order), a case in `OneStatement`, and a routine beside the
  others.
- **A check that fails:** `Check` in `gen.pas`, and the message in
  `lib/Rt.raz`'s `fail`; a reason a signal gives, `onSignal` there.

After any change: `make check`, `make bench`, `make loc`.
