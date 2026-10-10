# The programming language jed

jed is a small systems language for x86-64 Linux. A jed program can lay
a record over a device's registers, read and write memory exactly as
written, take part in lock-free algorithms, make system calls and call
C libraries. It has no garbage collector and no hidden run time: what
the program does is what its text says.

This report defines the language. It is short on purpose. Whatever it
doesn't allow, jed doesn't have.

## 1. A first look

```
module Hello;
import Out;

proc main*;
begin
    Out.str("hello, world\n");
end;

end Hello.
```

A program is a set of modules. One of them, the main module, has a
procedure `main`; the program starts there. Saved as `Hello.jed`, it is
compiled with `jed Hello.jed`, which writes the executable `Hello`.

## 2. Words and symbols

A program is written in ASCII. Spaces, tabs and line breaks separate
symbols and are otherwise ignored.

**Identifiers** are a letter or `_` followed by letters, digits and `_`,
up to 63 characters. Case matters: `count` and `Count` are different
names.

**Reserved words** are lowercase, except `VOLATILE`:

```
and begin by const div do else elsif end extern for forward if import
link match mod module not of or proc record repeat return shl shr then
to type until var variant VOLATILE while xor
```

**Numbers.** `123` is decimal. `0FFH` is hexadecimal: it starts with a
digit and ends in `H`. `1.5` and `2.0E-3` are reals; a real always has
a digit on both sides of its point.

**Characters.** `'a'` is the code of one character, an integer.

**Strings.** `"hello\n"` is a sequence of bytes. Both characters and
strings take the escapes `\n` (line feed), `\t` (tab), `\r` (carriage
return), `\0` (zero), `\\`, `\'`, `\"` and `\xHH` (the byte with
hexadecimal value HH).

**Comments** are `(*` ... `*)` and nest.

**Operators and delimiters:**

```
+  -  *  /  =  #  <  <=  >  >=  :=  :  ;  ,  .  ..  ...  (  )  [  ]  ^  |
```

## 3. Modules

```
Module     = "module" ident [ "(" ident { "," ident } ")" ] ";"
             { Import } { Link } { Declaration } "end" ident "." .
Import     = "import" ImportItem { "," ImportItem } ";" .
ImportItem = ident [ ":=" ident [ "(" Type { "," Type } ")" ] ] .
Link       = "link" string ";" .
```

A module lives in a file of its own name: module `Out` is `Out.jed`.
The name after `end` repeats the module's name.

**Exports.** A name declared at the top of a module with `*` after it
is exported: other modules can use it as `Module.name`. Record fields
are exported the same way. Everything else is private to the module.

**Imports.** `import Out;` makes `Out`'s exports available as `Out.x`.
`import O := Out;` uses the name `O` instead. A module can't import
itself, directly or through others.

**Generic modules** take types as parameters:

```
module List(T);
type
    Node* = record next*: ^Node; val*: T; end;
...
end List.
```

An import gives the arguments: `import Ints := List(I64);`. Each
distinct list of arguments makes one *instance*: the module compiled
with `T` standing for `I64`. Two imports of `List(I64)`, in any modules,
share one instance. Since every instance is checked on its own, an
operation the argument type doesn't support (adding two records, say)
is reported as an error in that instance.

**Finding modules.** The compiler looks for `Name.jed` in the main
module's directory, then in each directory given with `-I`, then in the
`lib` directory beside the compiler.

**No module bodies.** Module variables start at zero, and there is no
code that runs when a module starts. A module that needs setting up
does it on first use.

**`link "libX11.so.6";`** names a shared library to load at run time,
for the `extern` procedures of section 9.

## 4. Declarations

```
Declaration = "const" { IdentDef "=" Expr ";" }
            | "type" { IdentDef "=" Type ";" }
            | "var" { IdentList ":" Type ";" }
            | ProcDeclaration ";"
            | ExternDeclaration ";" .
IdentDef    = ident [ "*" ] .
IdentList   = IdentDef { "," IdentDef } .
```

A name must be declared before it is used, with two exceptions: the
base type of a pointer may name a type declared later in the same
`type` section (so that two records can point at each other), and a
procedure may be declared `forward` and defined later (section 8).

**Constants** are evaluated by the compiler. Their expressions use only
literals, other constants, operators, `SIZE` and the `LEN` of arrays.

**Variables** of a module live as long as the program; variables of a
procedure live as long as its call. Both start at zero.

## 5. Types

```
Type      = QualIdent
          | "[" Expr "]" Type                 (* array *)
          | "[" "]" Type                      (* slice *)
          | "^" [ "VOLATILE" ] Type           (* pointer *)
          | "record" { IdentList ":" Type ";" } "end"
          | "variant" { Case ";" } "end"
          | "proc" Signature .
Case      = ident [ "(" FieldList { ";" FieldList } ")" ] .
FieldList = ident { "," ident } ":" Type .
QualIdent = [ ident "." ] ident .
```

### 5.1 Basic types

| Type | Size | Values |
|---|---|---|
| `I8` `I16` `I32` `I64` | 1, 2, 4, 8 | signed integers, two's complement |
| `U8` `U16` `U32` `U64` | 1, 2, 4, 8 | unsigned integers |
| `BOOL` | 1 | `false` (0), `true` (1) |
| `F64` | 8 | IEEE 754 double precision |

### 5.2 Arrays

`[n]T` is `n` elements of type `T`, one after another. `n` is a
constant greater than zero. Arrays are values: assigning one copies it.

### 5.3 Slices

`[]T` is a view of elements that live elsewhere: a pointer to the first
and a count, 16 bytes in all.

```
Slice = record ptr: ^T; len: I64; end;    (* its layout *)
```

A slice is made from an array (`a[2..5]`, or an array used where a
slice is wanted), from another slice, or from a pointer (`p[0..n]`). It
doesn't own what it points at.

### 5.4 Pointers

`^T` is the address of a `T`, 8 bytes. `nil` is the pointer to nothing.

`^VOLATILE T` is the address of a `T` that something besides the
program may read or change: a device register, memory shared with
another process. Section 7.6 says what that promises.

### 5.5 Records

```
type Cell = record ch: U8; attr: U8; end;
```

Fields are laid out in order as C lays them out: each at the next
multiple of its own alignment, and the whole record padded to a
multiple of its largest alignment. A record declared like a C struct
has the same layout as that struct.

### 5.6 Variants

A variant holds one of several cases, each with its own fields:

```
type
    Shape* = variant
        circle(r: F64);
        rect(w, h: F64);
        dot;
    end;
```

The case names are declared in the scope around the type, so `circle`
can be used directly, and as `Shapes.circle` from another module if
`Shape` is exported. A case with fields is built by calling it like a
procedure, `circle(2.0)`; a case without fields is just `dot`. The only
way to read the fields is `match` (section 7.4).

Layout: an `I64` tag (0 for the first case, 1 for the second, and so
on) followed by the fields of the largest case, laid out as a record.

### 5.7 Procedure types

```
type Compare = proc(a, b: I64): BOOL;
```

A value of a procedure type is the address of a procedure with that
signature, 8 bytes, or `nil`.

### 5.8 Same and assignable

Two named types are the same only if they are the same declaration.
Two anonymous types are the same if they are built alike: `^I64` is
`^I64` wherever it is written.

A value of type `A` can be assigned to a variable of type `B` (and
passed to a parameter of type `B`, and returned as a `B`) if they are
the same type, or if:

- `A` is an integer constant whose value fits in the integer type `B`;
- `A` is `nil` and `B` is a pointer or procedure type;
- `A` is `^T` and `B` is `^VOLATILE T`;
- `A` is `[n]T` and `B` is `[]T`;
- `A` is a string literal and `B` is `[]U8`, `^U8` (a pointer to the
  bytes followed by a zero byte, as C wants), or `[n]U8` with `n` at
  least the string's length (the rest is zero);
- `A` is a procedure and `B` a procedure type with the same signature.

Nothing else converts silently. In particular, there is no conversion
between integer types, or between integers and `F64`, without a written
conversion (section 6.6).

## 6. Expressions

```
Expr       = SimpleExpr [ Relation SimpleExpr ] .
Relation   = "=" | "#" | "<" | "<=" | ">" | ">=" .
SimpleExpr = [ "-" ] Term { AddOp Term } .
AddOp      = "+" | "-" | "or" | "xor" .
Term       = Factor { MulOp Factor } .
MulOp      = "*" | "/" | "div" | "mod" | "and" | "shl" | "shr" .
Factor     = number | char | string | Designator | "(" Expr ")"
           | "not" Factor
           | "[" [ Expr { "," Expr } ] "]"
           | "^" [ "VOLATILE" ] Type "(" Expr ")" .
Designator = QualIdent { Selector } .
Selector   = "." ident | "^" | "[" Expr [ ".." Expr ] "]"
           | "(" [ Expr { "," Expr } ] ")" .
```

The operators bind in the order of the grammar: `not` most tightly,
then the multiplying operators, then the adding ones, then the
relations. So `a + b * c = d` is `(a + (b * c)) = d`. A unary minus
applies to the first term: `-a * b` is `-(a * b)`.

### 6.1 Integers

Both operands of `+ - * div mod and or xor` have the same integer
type, or one is an untyped constant that takes the other's type. The
result has that type and wraps around at its width: in `U8`,
`200 + 100` is `44`.

`div` rounds toward zero and `mod` takes the sign of the dividend, as
in C: `-7 div 2` is `-3`, `-7 mod 2` is `-1`. Dividing by zero stops
the program (`SIGFPE`).

`and`, `or`, `xor` and `not` work on every bit. `x shl n` and
`x shr n` shift by `n mod 64`; `shr` brings in copies of the sign bit
for signed types and zeros for unsigned ones.

Relations compare as signed or unsigned according to the type.

### 6.2 Booleans

`and` and `or` on `BOOL` evaluate their right operand only when it
decides the result. `not` negates, `xor` is "different", and `=` and
`#` compare.

### 6.3 Reals

`+ - * /` and the relations work on `F64`, both operands `F64`. A real
literal has type `F64`.

### 6.4 Pointers

- `p^` is the variable `p` points at.
- `p + i` and `p - i`, with `i` an integer, move `p` by `i` elements:
  by `i * SIZE(T)` bytes for `p: ^T`.
- `p - q`, with both of the same pointer type, is the number of
  elements between them, an `I64`.
- `p[i]` is `(p + i)^`. `p[lo..hi]` is the slice of the `hi - lo`
  elements from `p + lo`. Neither is checked.
- Pointers compare with `= # < <= > >=` as unsigned addresses.
  Procedure values compare with `=` and `#` only.

### 6.5 Arrays and slices

`a[i]` is an element of an array or slice, and `a[lo..hi]` is the slice
of the elements from `lo` up to but not including `hi`. Both are
checked: `i` must be below the length, and `0 <= lo <= hi <= length`.
A check that fails prints the file and line to standard error and stops
the program with status 2.

`[e1, e2, ...]` builds an array where the type it must have is known:
assigned to an array or slice variable, passed to such a parameter, or
returned as one. Its elements must be assignable to the element type.

Arrays, slices, records and variants can't be compared; write a loop,
or use the library's `Str.eq` for strings.

### 6.6 Conversions

A type name applied like a procedure converts: `I32(x)`, `F64(n)`,
`^Cell(addr)`. A pointer type written out uses the `^` form of the
grammar: `^VOLATILE U32(0FEE00000H)`.

| From | To | Result |
|---|---|---|
| integer | integer | the value cut to the new width, or extended by its sign (signed) or zeros (unsigned) |
| integer | `F64` | the nearest real |
| `F64` | integer | rounded toward zero |
| integer | pointer, procedure | the address |
| pointer, procedure | integer | the address |
| pointer, procedure | pointer, procedure | the same address, seen as the new type |

### 6.7 Built-in procedures

| Call | Result |
|---|---|
| `SIZE(T)` | the size of type `T` in bytes, a constant |
| `ADR(x)` | the address of variable `x`, a `^T` |
| `LEN(a)` | the number of elements of an array (a constant) or a slice, an `I64` |
| `NEW(p)` | sets `p: ^T` to a fresh, zeroed `T` from `Heap`; the module must import `Heap` |
| `NEW(p, a)` | the same, from the allocator `a: ^Mem.Allocator` |
| `SYSCALL(n, x1, ..., x6)` | Linux system call `n` with up to six integer or pointer arguments; the raw result, an `I64` (a negative number is `-errno`) |
| `CODE(b1, b2, ...)` | puts the constant bytes in the code, see 7.7 |
| `FENCE` | a full memory barrier |
| `CAS(p, old, new)` | if `p^ = old`, sets `p^ := new` and returns `true`; atomically |
| `XCHG(p, x)` | sets `p^ := x` and returns the value before, atomically |
| `XADD(p, x)` | adds `x` to `p^` and returns the value before, atomically |
| `ARGC()` | the number of command line arguments, an `I64` |
| `ARGV()` | the arguments, a `^^U8` (C strings) |

For `CAS`, `XCHG` and `XADD`, `p` is a `^T` or `^VOLATILE T` where `T`
is an 8-byte integer or pointer type (an integer type for `XADD`). They
are sequentially consistent.

## 7. Statements

```
Statements = { Statement ";" } .
Statement  = Designator [ ":=" Expr ]
           | Designator "," Designator { "," Designator } ":=" Expr
           | "if" Expr "then" Statements
             { "elsif" Expr "then" Statements } [ "else" Statements ] "end"
           | "while" Expr "do" Statements "end"
           | "repeat" Statements "until" Expr
           | "for" ident ":=" Expr "to" Expr [ "by" Expr ] "do" Statements "end"
           | "match" Expr "of" { "|" Arm } "end"
           | "return" [ Expr { "," Expr } ] .
Arm        = ( ident [ "(" ident { "," ident } ")" ] | "else" ) ":" Statements .
```

Every statement ends in `;`, including the ones that end in `end` or
`until`.

### 7.1 Assignment and calls

`x := e` evaluates `e` and stores it in `x`; arrays, records, slices and
variants are copied. A designator on its own is a call, and any result
it returns is dropped: `Out.ln;`, `write(fd, buf);`.

`a, b := f(x);` assigns the results of a procedure that returns several
(section 8), in order.

### 7.2 Conditions and loops

`if`, `while` and `repeat` take `BOOL` expressions. `repeat` runs its
body at least once and stops when the condition is true.

`for i := a to b by s do ... end;` sets the integer variable `i` to `a`,
`a + s`, ... while `i <= b` (or `i >= b` if the constant `s` is
negative). `s` is 1 if left out. `b` is evaluated once, before the
first round.

There is no `break` or `goto`. A loop that must stop early tests a
condition, or its body is a procedure that returns.

### 7.3 Return

`return e;` ends the procedure with the result `e`; `return a, b;` with
several results; `return;` from a procedure without results. A
procedure with results that runs off its end returns an undefined value.

### 7.4 Match

```
match s of
| circle(r):  area := 3.14159 * r * r;
| rect(w, h): area := w * h;
| dot:        area := 0.0;
end;
```

`match` runs the arm of the case `s` holds. An arm may name the case's
fields, in order, all of them; the names stand for those fields of `s`
itself, so assigning to one changes `s`. An arm may also leave the
fields unnamed. Every case must have an arm, unless there is an
`| else:` arm, which must come last.

### 7.5 Order of evaluation

Operands, arguments and the designators of an assignment are evaluated
from left to right.

### 7.6 Volatile

A variable reached through a `^VOLATILE T` is volatile, and so is any
field or element of it. Each read or write of a volatile variable of a
basic or pointer type is exactly one memory access, of exactly its
size, and volatile accesses happen in the order the program writes
them. Copying a whole record or array through a volatile pointer is
not allowed, since it can't be one access.

A `^VOLATILE T` doesn't convert to `^T` without a written conversion.

`FENCE` also orders the program's ordinary accesses against those of
other processors and devices.

### 7.7 CODE

`CODE` puts machine code where it stands. Between two statements the
compiler keeps nothing in registers but `rsp` and `rbp`, so code there
may use any other register. It must leave `rsp` and `rbp` as it found
them.

```
proc halt;
begin
    CODE(0FAH, 0F4H);    (* cli; hlt *)
end;
```

## 8. Procedures

```
ProcDeclaration   = "proc" IdentDef Signature ";"
                    ( "forward" | { LocalDeclaration } "begin" Statements "end" [ ident ] ) .
LocalDeclaration  = "const" { ident "=" Expr ";" }
                  | "type" { ident "=" Type ";" }
                  | "var" { ident { "," ident } ":" Type ";" } .
Signature         = "(" [ Params { ";" Params } [ ";" "..." ] ] ")" [ ":" Results ]
                  | [ ":" Results ] .
Params            = [ "var" ] ident { "," ident } ":" Type .
Results           = Type | "(" Type { "," Type } ")" .
```

A procedure without parameters may leave out the parentheses, both
where it is declared (`proc main*;`) and where it is called (`Out.ln`).
Used without parentheses in an expression, a procedure is a procedure
value, not a call.

**Parameters.** A value parameter is a copy: the procedure may change
it, and the caller's variable stays as it was. A `var` parameter is the
caller's variable itself; its argument must be a variable of exactly
the parameter's type.

**Results.** A procedure returns nothing, one value, or several. A call
that returns several values can only stand on the right of a multiple
assignment, or alone as a statement.

```
proc divmod(a, b: I64): (I64, I64);
begin
    return a div b, a mod b;
end;

q, r := divmod(17, 5);
```

**forward.** `proc f(x: I64): I64; forward;` declares `f` so that it
can be called before its body appears; the body comes later with the
same signature.

Procedures don't nest.

## 9. Calling C

```
ExternDeclaration = "extern" "proc" IdentDef Signature .
```

```
link "libX11.so.6";
extern proc XOpenDisplay(name: ^U8): ^U8;
extern proc printf(format: ^U8; ...): I32;
```

An `extern` procedure is found by its name in the C libraries the
program links: the C library always, and each library named by `link`.
Its parameters and result are integers, `BOOL`, `F64`, pointers or
procedures; a record goes to C by pointer, never by value. `...`
accepts any number of further arguments of those types, and is allowed
only in an `extern`.

Every jed procedure uses the System V calling convention, so a jed
procedure whose parameters and result are of those types can be given
to C as a callback.

## 10. Programs

The main module declares `proc main;` or `proc main: I64;`. The program
runs `main`, and ends with status 0, or with the status `main` returns.
A program that calls no C is a static executable with no run time
besides the code it uses. One that does is linked dynamically and
starts through the C library, so that C's own set-up and clean-up run.

Only what can be reached from `main` goes into the executable: unused
procedures, variables and strings are left out.

**Not checked.** Dereferencing `nil` or a stale pointer, indexing
through a pointer, integer overflow (it wraps), and a missing `return`
in a procedure with results. Dividing by zero and dereferencing `nil`
stop the program with a signal.

## 11. The library

Modules written in jed, in the compiler's `lib` directory:

| Module | What |
|---|---|
| `Rt` | what the compiler's checks call when they fail |
| `Out` | writing text and numbers to standard output |
| `Mem` | `mmap`, and `Allocator`, the interface of every allocator |
| `Heap` | a general allocator; what `NEW(p)` uses |
| `Arena` | an allocator that frees everything at once |
| `Str` | operations on `[]U8` strings |
| `Buf` | a growable byte buffer |
| `Fmt` | formatted output: `Fmt.print("{} of {}\n", [Fmt.int(n), Fmt.int(m)])` |
| `List` | a generic singly linked list, `List(T)` |

```
module Mem;
type
    Allocator* = record
        alloc*: proc(a: ^Allocator; size, align: I64): ^U8;
        free*:  proc(a: ^Allocator; p: ^U8);
    end;
...
end Mem.
```
