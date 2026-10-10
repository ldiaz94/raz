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

A program is a set of modules. The one named on the command line is
the main module, and it exports a procedure `main`; the program starts
there, once every module's body has run (section 3). Saved as
`Hello.jed`, it is compiled with `jed Hello.jed`, which writes the
executable `Hello`.

## 2. Words and symbols

A program is written in UTF-8. The compiler rejects a file that isn't
valid UTF-8: a malformed or overlong sequence, a surrogate, or a code
point beyond 10FFFFH. Everything outside strings, characters and
comments is ASCII. Spaces, tabs and line breaks separate symbols and
are otherwise ignored.

**Identifiers** are an ASCII letter or `_` followed by letters, digits
and `_`, up to 63 characters. Case matters: `count` and `Count` are different
names.

**Reserved words** are lowercase, except `VOLATILE`:

```
and begin break by code const defer div do else elsif end extern for
forward if import in link match mod module not of or packed proc record
repeat return set shl shr then to type until var variant VOLATILE while
xor
```

**Numbers.** `123` is decimal. `0FFH` is hexadecimal: it starts with a
digit and ends in `H`. `1.5` and `2.0E-3` are reals; a real always has
a digit on both sides of its point.

An integer is an untyped constant, which takes the type it is used as,
up to the largest `I64`. A hexadecimal number above that, such as
`0FFFFFFFFFFFFFFFFH`, has type `U64`: so `-1` never fits a `U64`, and
the big number goes nowhere else without a conversion.

**Characters.** `'a'` is the code point of one character, an integer:
`'a'` is 97 and `'é'` is 233.

**Strings.** `"héllo\n"` is a sequence of bytes, the UTF-8 of its text:
`"é"` is the two bytes 0C3H, 0A9H. Both characters and strings take the
escapes `\n` (line feed), `\t` (tab), `\r` (carriage return), `\0`
(zero), `\\`, `\'`, `\"`, `\u{H...}` (the code point with hexadecimal
value H..., in a string its UTF-8) and, in strings only, `\xHH` (the
byte with hexadecimal value HH, which needn't make valid UTF-8).

Error messages give the line and the column, counted in characters.

**Comments** are `(*` ... `*)` and nest.

**Operators and delimiters:**

```
+  -  *  /  =  #  <  <=  >  >=  :=  :  ;  ,  .  ..  ...  (  )  [  ]  {  }  ^  |
```

## 3. Modules

```
Module     = "module" ident [ "(" ModParams ")" ] ";"
             { Import } { Link } { Declaration }
             [ "begin" Statements ] "end" ident "." .
ModParams  = ident { "," ident } { ";" ident ":" "proc" Signature } .
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

What a generic module needs to do with its types, beyond moving them
about, it is given as procedures, after the types:

```
module Map(K, V; hash: proc(k: K): U64; eq: proc(a, b: K): BOOL);
```

```
import Names := Map([]U8, I64, Str.hash, Str.eq);
```

A procedure argument names a procedure, not a variable or an
expression, and its signature, with the type arguments put in, must be
the parameter's. Inside the module, `hash(k)` calls it directly. Two
imports make the same instance only if their types and their procedures
are the same.

**Finding modules.** The compiler looks for module `Name` in the main
module's directory, then in each directory given with `-I`, then in the
`lib` directory beside the compiler. In each directory it takes the
first of `Name.OS-ARCH.jed`, `Name.OS.jed`, `Name.ARCH.jed` and
`Name.jed` that exists, where `OS-ARCH` is the target, for now only
`linux-x86_64`. So a module whose code depends on the machine or the
system comes in one file per target, and the modules that import it
don't change. Machine code (section 8) and system calls belong in such
files.

The compiler holds every file of such a module to the same interface.
When it takes one of `Name.*.jed`, it also reads the declarations of
the others beside it, and of `Name.jed` if there is one, and reports an
error unless they all export the same names, each the same kind of
thing:

- a constant of the same type (its value may differ: a system call
  number, say);
- a type of the same kind, and for a record or variant the same
  exported fields and cases, with the same types (unexported fields,
  and so the size and layout, may differ);
- a variable of the same type;
- a procedure of the same signature.

Two types here are the same if they are built alike, a name in one file
standing for the same name in another.

**Module bodies.** A module may end with `begin` and statements, its
body. Every module's body runs once, before the main module's `main`:
a module's body runs after the bodies of the modules it imports, in the
order of its `import`s, and once however many modules import it. Each
instance of a generic module has its body run once. Module variables
are zero before any body runs. `return;` ends a body early.

**`link "libX11.so.6";`** names a shared library to load at run time,
for the `extern` procedures of section 9.

## 4. Declarations

```
Declaration = "const" { IdentDef [ ":" "ERROR" ] "=" Expr ";" }
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
procedure live as long as its call. Both start at zero: every byte of
them is zero. So a number starts as `0` (`0.0` for `F64`), a `BOOL` as
`false`, a pointer, procedure or `ERROR` as `nil`, a slice as the empty
slice (`ptr` is `nil`, `len` is 0), a variant as its first case with
its fields zero, a set as the empty set, and an enumeration as its
first name. No variable is ever read before it has a value.

## 5. Types

```
Type      = QualIdent
          | "[" Expr "]" Type                 (* array *)
          | "[" "]" Type                      (* slice *)
          | "^" [ "VOLATILE" ] Type           (* pointer *)
          | [ "packed" ] "record" { IdentList ":" Type ";" } "end"
          | "variant" { Case ";" } "end"
          | "(" ident { "," ident } ")"       (* enumeration *)
          | "set" "of" QualIdent
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

A `packed record` has no padding: each field starts at the byte after
the field before it, and the record's alignment is 1. A field of a
packed record may be misaligned. x86-64 reads and writes it anyway, but
an atomic operation on it is slow, and a volatile access to it is one
instruction that needn't be atomic.

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
A variant that starts at zero therefore holds its first case.

### 5.7 Enumerations and sets

```
type
    Color* = (red, green, blue);
    Colors* = set of Color;
```

An enumeration is a list of names, in order. Like the cases of a
variant, the names are declared in the scope around the type. An
enumeration has at most 256 names and takes 1 byte; the first name is
0, the next 1, and so on.

`set of E`, for an enumeration `E` of at most 64 names, holds any
choice of `E`'s names: bit `i` stands for the name at position `i`. It
takes the smallest of 1, 2, 4 and 8 bytes that has a bit for each name,
so a set can stand for a C flags word.

### 5.8 Errors

```
const NotFound*: ERROR = "not found";
```

`ERROR` is a basic type of 8 bytes. A value of it is made only by a
constant declared as above, and each such declaration makes an error
different from every other, whatever its message: two modules that
both declare `"not found"` have two different errors. A generic module
makes its errors once per instance. `nil` is no error.

Errors compare with `=` and `#` only, by which declaration made them,
never by their message. `MSG(e)` is the message, a `[]U8`; `MSG(nil)`
is `""`.

```
proc find*(key: I64): (^Node, ERROR);
...
n, err := Table.find(7);
if err = Table.NotFound then ... end;
```

### 5.9 Procedure types

```
type Compare = proc(a, b: I64): BOOL;
```

A value of a procedure type is the address of a procedure with that
signature, 8 bytes, or `nil`.

### 5.10 Same and assignable

Two named types are the same only if they are the same declaration.
Two anonymous types are the same if they are built alike: `^I64` is
`^I64` wherever it is written. A named and an anonymous type are the
same if the named one is built like the anonymous one, so that
`p := ADR(n)` works for `p: NodePtr` with `type NodePtr = ^Node`.

A type declared with only a name on the right, `type Count = I64;`, is
another name for that type, not a new one.

A value of type `A` can be assigned to a variable of type `B` (and
passed to a parameter of type `B`, and returned as a `B`) if they are
the same type, or if:

- `A` is an integer constant whose value fits in the integer type `B`;
- `A` is `nil` and `B` is a pointer, procedure or `ERROR` type;
- `A` is `^T` and `B` is `^VOLATILE T`;
- `A` is `[n]T` and `B` is `[]T`;
- `A` is a string literal and `B` is `[]U8`, `^U8` (a pointer to the
  bytes followed by a zero byte, as C wants), or `[n]U8` with `n` at
  least the string's length (the rest is zero);
- `A` is a procedure and `B` a procedure type with the same signature.

Nothing else converts silently. In particular, there is no conversion
between integer types, or between integers and `F64`, without a written
conversion (section 6.7).

## 6. Expressions

```
Expr       = SimpleExpr [ Relation SimpleExpr ] .
Relation   = "=" | "#" | "<" | "<=" | ">" | ">=" | "in" .
SimpleExpr = [ "-" ] Term { AddOp Term } .
AddOp      = "+" | "-" | "or" | "xor" .
Term       = Factor { MulOp Factor } .
MulOp      = "*" | "/" | "div" | "mod" | "and" | "shl" | "shr" .
Factor     = number | char | string | Designator | "(" Expr ")"
           | "not" Factor
           | "[" [ Expr { "," Expr } ] "]"
           | "{" [ Element { "," Element } ] "}"
           | "^" [ "VOLATILE" ] Type "(" Expr ")" .
Element    = Expr | ident ":" Expr .
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
in C: `-7 div 2` is `-3`, `-7 mod 2` is `-1`. Dividing by zero, and
dividing the smallest `I64` by `-1`, stop the program (`SIGFPE`).

`and`, `or`, `xor` and `not` work on every bit. `x shl n` and
`x shr n` shift by `n and 63`; `shr` brings in copies of the sign bit
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
  elements from `p + lo`. Neither is checked. A pointer to an array
  isn't indexed this way, since a step would be a whole array: its
  elements are `p^[i]`.
- Pointers compare with `= # < <= > >=` as unsigned addresses.
  Procedure values compare with `=` and `#` only.

### 6.5 Arrays and slices

`a[i]` is an element of an array or slice, and `a[lo..hi]` is the slice
of the elements from `lo` up to but not including `hi`. Both are
checked: `i` must be below the length, and `0 <= lo <= hi <= length`.
A check that fails prints the file and line to standard error and stops
the program with status 2.

**Literals.** `[e1, e2, ...]` builds an array, and `{f: e, g: e, ...}`
a record, where the type it must have is known: assigned to a variable,
passed to a parameter, returned, compared with a value of that type, or
an element of a bigger literal. The elements must be assignable to the
element type, and an array literal for `[n]T` has exactly `n` of them.
A record literal names its fields, in any order, each at most once; the
fields it leaves out are zero. An array literal used as a slice is a
hidden variable of the procedure, and lives as long as its call.

```
c := {ch: 'A', attr: 7};
Fmt.print("{} of {}\n", [Fmt.int(n), Fmt.int(m)]);
```

**Strings compare.** Two operands that are each a `[]U8`, a `[n]U8` or
a string literal are `=` when they have the same length and the same
bytes, and `#` otherwise. Other arrays and slices, records and variants
can't be compared; write a loop. Ordering strings is the library's
`Str.cmp`.

### 6.6 Enumerations and sets

Enumerations compare with all six relations, by position, and an
enumeration can be the variable of a `for` loop and the expression of a
`match` (section 7.4).

`{red, blue}` is a set, of the set type of its names' enumeration;
`{}` is the empty set, where the type it must have is known. On two sets
of the same type, `+` is union, `*` intersection and `-` difference;
`=` and `#` compare, and `<=` and `>=` are "is a subset of" and "is a
superset of". `x in s` is `true` if the name `x` is in the set `s`.

### 6.7 Conversions

A type name applied like a procedure converts: `I32(x)`, `F64(n)`,
`^Cell(addr)`. A pointer type written out uses the `^` form of the
grammar: `^VOLATILE U32(0FEE00000H)`.

| From | To | Result |
|---|---|---|
| integer | integer | the value cut to the new width, or extended by its sign (signed) or zeros (unsigned) |
| integer | `F64` | the nearest real |
| `F64` | integer | rounded toward zero; a NaN, or a real out of the range of `I64`, gives the smallest `I64`, then cut |
| enumeration | integer | its position |
| integer | enumeration | the name at that position; a position out of range is a failed check (6.5) |
| set | integer | its bits |
| integer | set | the low bits, as many as the set has |
| integer | pointer, procedure | the address |
| pointer, procedure | integer | the address |
| pointer, procedure | pointer, procedure | the same address, seen as the new type |

### 6.8 Built-in procedures

| Call | Result |
|---|---|
| `SIZE(T)` | the size of type `T` in bytes, a constant |
| `ADR(x)` | the address of variable `x`, a `^T` |
| `LEN(a)` | the number of elements of an array (a constant) or a slice, an `I64` |
| `NEW(p, a)` | sets `p: ^T` to a fresh, zeroed `T` from the allocator `a: ^Mem.Allocator`, or to `nil` if `a` has no room |
| `MSG(e)` | the message of the error `e`, a `[]U8` |
| `SYSCALL(n, x1, ..., x6)` | Linux system call `n` with up to six integer or pointer arguments; the raw result, an `I64` (a negative number is `-errno`) |
| `INC(v)`, `INC(v, k)` | adds 1, or `k`, to the integer variable `v`; it wraps, like `+` |
| `DEC(v)`, `DEC(v, k)` | subtracts 1, or `k`, from `v` |
| `FENCE` | a full memory barrier |
| `CAS(p, old, new)` | if `p^ = old`, sets `p^ := new` and returns `true`; atomically |
| `XCHG(p, x)` | sets `p^ := x` and returns the value before, atomically |
| `XADD(p, x)` | adds `x` to `p^` and returns the value before, atomically |
| `ARGC()` | the number of command line arguments, an `I64` |
| `ARGV()` | the arguments, a `^^U8` (C strings) |

`SYSCALL` exists only on Linux targets. Other systems have no stable
system call interface, and their modules call the C library instead
(section 9).

`INC` and `DEC` evaluate `v` once, so `INC(a[f(i)])` calls `f` once. They
read `v` and then write it: two accesses, even through a `^VOLATILE`
pointer, and not atomic; `XADD` is the atomic one.

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
           | "return" [ Expr { "," Expr } ]
           | "break"
           | "defer" Statement .
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

`break` ends the innermost `while`, `repeat` or `for` it stands in,
and the program goes on after it. There is no `goto`.

### 7.3 Return

`return e;` ends the procedure with the result `e`; `return a, b;` with
several results; `return;` from a procedure without results. A
procedure with results that runs off its end returns zeros, each result
as a variable of its type starts (section 4).

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

`match` on an enumeration works the same way: each arm names one of the
enumeration's names.

### 7.5 Order of evaluation

Operands, arguments and the designators of an assignment are evaluated
from left to right.

### 7.6 Volatile

A variable reached through a `^VOLATILE T` is volatile, and so is any
field or element of it. Each read or write of a volatile variable of a
basic, enumeration, set or pointer type is exactly one memory access,
of exactly its size, and volatile accesses happen in the order the
program writes them. Copying a whole record or array through a
volatile pointer is not allowed, since it can't be one access.

A `^VOLATILE T` doesn't convert to `^T` without a written conversion.

`FENCE` also orders the program's ordinary accesses against those of
other processors and devices.

### 7.7 Defer

`defer s;` runs the statement `s` when the program leaves the statement
list the `defer` stands in: at its end, or by a `return`, or by a
`break` out of it. Statements deferred in the same list run in the
opposite order to their `defer`s, and only those whose `defer` has been
reached run.

```
fd := Sys.open(name, Sys.rdonly);
if fd < 0 then return Sys.Failed; end;
defer Sys.close(fd);
...
```

`return e;` evaluates `e` before the deferred statements run. A
deferred statement can't contain `return`, `break` or `defer` that
would leave it.

## 8. Procedures

```
ProcDeclaration   = "proc" IdentDef Signature ";"
                    ( "forward" | { LocalDeclaration } "begin" Statements "end" [ ident ]
                    | "code" Expr { "," Expr } ) .
LocalDeclaration  = "const" { ident [ ":" "ERROR" ] "=" Expr ";" }
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

**Code procedures.** A procedure whose body is `code` and a list of
constant bytes is machine code, written by hand:

```
proc rdtsc*: U64;
code 0FH, 31H,              (* rdtsc *)
     48H, 0C1H, 0E2H, 20H,  (* shl rdx, 32 *)
     48H, 09H, 0D0H,        (* or rax, rdx *)
     0C3H;                  (* ret *)
```

It is called like any procedure, with the System V convention: integer
and pointer arguments arrive in `rdi`, `rsi`, `rdx`, `rcx`, `r8` and
`r9`, `F64` ones in `xmm0` to `xmm7`, and the result goes in `rax` (and
`rdx` for a second) or `xmm0`. Its parameters and results are therefore
of the types C can take (section 9), at most six integer and eight
`F64` parameters, and at most two results. The bytes are the whole
procedure, `ret` included; they must keep `rbx`, `rbp`, `rsp` and `r12`
to `r15` as they found them. The compiler doesn't look inside them.

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

Any module may export a procedure `main`, declared `proc main*;` or
`proc main*: I64;`. The program runs the bodies of all its modules
(section 3), then the main module's `main`, if it has one, and ends
with status 0, or with the status `main` returns. The `main` of an
imported module is an ordinary procedure, which runs only if something
calls it; so a library module can carry a `main` that tests it.
A program that calls no C is a static executable with no run time
besides the code it uses. One that does is linked dynamically and
starts through the C library, so that C's own set-up and clean-up run.

Only what can be reached from `main` and the module bodies goes into
the executable: unused procedures, variables and strings are left out.

**Defined behaviour.** Every variable starts at zero, integers wrap,
and indexing arrays and slices is checked, so a program's behaviour is
defined by this report, with one exception: memory reached through a
pointer. Dereferencing a stale or made-up pointer, indexing through a
pointer, a code procedure that breaks its rules, and C code can read or
write any memory, and what follows isn't defined. Dereferencing `nil`, dividing
by zero and calling a `nil` procedure stop the program with a signal.

## 11. The library

Modules written in jed, in the compiler's `lib` directory:

| Module | What |
|---|---|
| `Rt` | what the compiler's checks call when they fail, and string comparison |
| `Sys` | system calls: `write`, `exit`; one file per target |
| `Out` | writing text and numbers to standard output |
| `Mem` | `mmap`, and `Allocator`, the interface of every allocator |
| `Heap` | a general allocator |
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
