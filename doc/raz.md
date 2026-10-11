# The programming language raz

raz is a small systems language for x86-64 Linux. A raz program can lay
a record over a device's registers, read and write a device's memory
exactly as written, take part in lock-free algorithms, make system calls and call
C libraries. It has no garbage collector and no hidden run time: what
the program does is what its text says.

This report defines the language. It is short on purpose. Whatever it
doesn't allow, raz doesn't have.

This is version 2026-10.10 of the report; section 12 says what each
version changed.

The language is frozen, softly, from this version on: it changes only
to mend a defect, and its library grows only by what breaks no program
written for it. What anyone wishes it had waits on a list, for a later
thaw.

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
`Hello.raz`, it is compiled with `raz Hello.raz`, which writes the
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

`static`, in `link static;` (section 3), isn't one.

**Predeclared names** are the basic types (section 5.1), `ERROR`,
`true`, `false`, `nil` and the built-in procedures (section 6.8). They
belong to a scope around every module, so a module or a procedure may
declare the same name for something else, which hides them there.

**Numbers.** `123` is decimal. `0FFH` is hexadecimal: it starts with a
digit, its digits are `0` to `9` and `A` to `F`, and it ends in `H`,
all in capitals. `1.5` and `2.0E-3` are reals; a real always has a
digit on both sides of its point, and its exponent, if it has one, is
`E`, a sign if wanted, and digits. A decimal number above the largest
`I64`, or a hexadecimal one above the largest `U64`, is an error.

An integer is an untyped constant, which takes the type it is used as,
up to the largest `I64`. A hexadecimal number above that, such as
`0FFFFFFFFFFFFFFFFH`, has type `U64`: so `-1` never fits a `U64`, and
the big number goes nowhere else without a conversion. Arithmetic on
untyped constants doesn't wrap: a result beyond the `I64`s, such as
`9223372036854775807 + 1`, is an error.

A real is an untyped constant too, which takes `F32` or `F64`,
whichever it is used as, rounded to the nearest value of that type;
where nothing says which, it is an `F64`. A real never becomes an
integer, nor an integer a real, without a conversion: `x := 1;` is an
error for `x: F64`, and `x := 1.0;` is right.

**Characters.** `'a'` is the code point of one character, an integer:
`'a'` is 97 and `'é'` is 233.

**Strings.** `"héllo\n"` is a sequence of bytes, the UTF-8 of its text:
`"é"` is the two bytes 0C3H, 0A9H. Both characters and strings take the
escapes `\n` (line feed), `\t` (tab), `\r` (carriage return), `\0`
(zero), `\\`, `\'`, `\"`, `\u{H...}` (the code point with hexadecimal
value H..., in a string its UTF-8) and, in strings only, `\xHH` (the
byte with hexadecimal value HH, which needn't make valid UTF-8). In
an escape, the hexadecimal digits may be capitals or not. A character
or a string ends on the line it starts on.

Messages give the line and the column, counted in characters
(section 10).

**Comments** are `(*` ... `*)` and nest. By convention, the comment
just before an exported declaration is its documentation, and the one
before `module` is the module's.

**Operators and delimiters:**

```
+  -  *  /  &  |  ~  =  #  <  <=  >  >=  :=  :  ;  ,  .  ..  ...  (  )  [  ]  {  }  ^
```

`|` is also what starts an arm of `match` (section 7.4); an arm comes
where a statement could, never after an operand, so the two don't mix.

## 3. Modules

```
Module     = "module" ident [ "(" ModParams ")" ] ";"
             { Import } { Link } { Declaration }
             [ "begin" Statements ] "end" ident "." .
ModParams  = ident { "," ident } { ";" ident ":" "proc" Signature } .
Import     = "import" ImportItem { "," ImportItem } ";" .
ImportItem = ident [ ":=" ident [ "(" Type { "," Type } ")" ] ] .
Link       = "link" ( string | "static" ) ";" .
```

A module lives in a file of its own name: module `Out` is `Out.raz`.
The name after `end` repeats the module's name.

**Exports.** A name declared at the top of a module with `*` after it
is exported: other modules can use it as `Module.name`. Record fields
are exported the same way. Everything else is private to the module.
An exported variable can be read and assigned by the modules that
import it.

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

An instance is made where its module is first used, not at the
import: so the arguments may name types the importing module declares
after its imports, as long as they are declared before that first
use. The instance is made before the code of the procedure, or the
module body, that first uses it, and its arguments are read in the
scope there.

```
import Table := Map([]U8, Colour, Str.hash, Str.eq);

type Colour = (red, green, blue);

var names: Table.Map;   (* the instance is made here *)
```

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
first of `Name.OS-ARCH.raz`, `Name.OS.raz`, `Name.ARCH.raz` and
`Name.raz` that exists, where `OS-ARCH` is the target, for now only
`linux-x86_64`. So a module whose code depends on the machine or the
system comes in one file per target, and the modules that import it
don't change. Machine code (section 8) and system calls belong in such
files.

**One module to a name.** A program has one module of each name, so
the compiler reports an error, naming the files, if a module it looks
for has files in more than one of these directories, rather than take
the first: a `Buf.raz` beside a program would otherwise stand in for
the library's `Buf` in every module that imports it, the library's own
among them. A link is the exception: a file that is a symbolic link to
one of the module's files in a later directory chooses that file, so
that a directory holding a link to `lib/Sys.raz` builds a program over
the C library's `Sys` on Linux too.

**Names are flat.** The names of a program's modules are one space,
with no packages or paths. So the names of the library's modules
(section 11) are kept for it: a program or another library doesn't
name a module of its own `Arena`, `Buf`, `C`, `Files`, `Fmt`, `Heap`,
`List`, `Lock`, `Map`, `Math`, `Mem`, `Opt`, `Out`, `Rt`, `Sort`,
`Str`, `Sys` or `Thread`, nor any name the library takes later. The
modules of any other library share a prefix of their own, as an X11
library's `Xauth` and `Xkeys` do, and a program that wants a shorter
name imports one: `import Auth := Xauth;`.

The compiler holds every file of such a module to the same interface.
When it takes one of `Name.*.raz`, it also reads the declarations of
the others beside it, and of `Name.raz` if there is one, and reports an
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
for the `extern` declarations of section 9. **`link static;`** says the
module needs a program without C (section 10): it makes its own system
calls, or its own threads, which the C library wouldn't know about.

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
literals, other constants, operators, conversions, `SIZE` and the `LEN`
of arrays and strings. A constant is an integer, a real, a `BOOL`, a
name of an enumeration, a set, a string or an `ERROR`. A constant of an integer type wraps as the
program would: `U8(250) + 10` is 4. Dividing by zero in a constant is
an error. A string constant can be indexed and sliced as an array of
`U8` is, and its `LEN` is its length in bytes:

```
const Text = "the cat";
...
w := Text[4..7];    (* "cat" *)
```

**Variables** of a module live as long as the program; variables of a
procedure live as long as its call. Both start at zero: every byte of
them is zero. So a number starts as `0` (`0.0` for `F32` and `F64`),
a `BOOL` as `false`, a pointer, procedure or `ERROR` as `nil`, a slice
as the empty slice (`ptr` is `nil`, `len` is 0), a variant as its
first case with its fields zero, a set as the empty set, and an
enumeration as its first name. No variable is ever read before it has a value.

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
| `F32` | 4 | IEEE 754 single precision |
| `F64` | 8 | IEEE 754 double precision |

Each is aligned to its size. So are `ERROR` (section 5.8), pointers
and procedures, 8 bytes; a slice is aligned to 8.

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
has the same layout as that struct. A record may have no fields; its
size is then 0.

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
on), then the space for the fields. Each case's fields are laid out
in that space as a record's would be, after the tag, and the cases
share it, so the variant is as big as its largest case needs, padded
to its alignment, the largest of 8 and its fields'. `variant a(x:
U8); b(y: I64; z: U8); end` is 24 bytes. A variant that starts at zero
therefore holds its first case.

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
signature, 8 bytes, or `nil`. Two signatures are alike when their
parameters have the same types, each `var` or not alike, in order, and
their results are the same types; the parameters' names don't matter.

### 5.10 Same and assignable

Two named types are the same only if they are the same declaration.
Two anonymous types are the same if they are built alike: `^I64` is
`^I64` wherever it is written. A named and an anonymous type are the
same if the named one is built like the anonymous one, so that
`p := ADR(n)` works for `p: NodePtr` with `type NodePtr = ^Node`.
Sameness doesn't pass through the anonymous type: with `type P1 =
^Node; P2 = ^Node;`, each of `P1` and `P2` is the same as `^Node`, but
they are two declarations, so not the same as each other.

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
between integer types, between integers and reals, or between `F32`
and `F64`, without a written conversion (section 6.7).

## 6. Expressions

```
Expr       = Conjunct { "or" Conjunct } .
Conjunct   = Relation { "and" Relation } .
Relation   = SimpleExpr [ RelOp SimpleExpr ] .
RelOp      = "=" | "#" | "<" | "<=" | ">" | ">=" | "in" .
SimpleExpr = [ "-" ] Term { AddOp Term } .
AddOp      = "+" | "-" | "|" | "xor" .
Term       = Factor { MulOp Factor } .
MulOp      = "*" | "/" | "div" | "mod" | "&" | "shl" | "shr" .
Factor     = number | char | string | Designator | "(" Expr ")"
           | "not" Factor | "~" Factor
           | "[" [ Expr { "," Expr } ] "]"
           | "{" [ Element { "," Element } ] "}"
           | "^" [ "VOLATILE" ] Type "(" Expr ")" .
Element    = Expr | ident ":" Expr .
Designator = QualIdent { Selector } .
Selector   = "." ident | "^" | "[" Expr [ ".." Expr ] "]"
           | "(" [ Expr { "," Expr } ] ")" .
```

The operators bind in the order of the grammar: `not` and `~` most
tightly, then the multiplying operators, then the adding ones, then
the relations, then `and`, then `or`. So `a + b * c = d` is
`(a + (b * c)) = d`, `x & 0FH = 0` is `(x & 0FH) = 0`, and
`i < n and a[i] # 0 or done` is `((i < n) and (a[i] # 0)) or done`. A
unary minus applies to the first term: `-a * b` is `-(a * b)`.

`and`, `or` and `not` are for `BOOL`s only; `&`, `|`, `xor` and `~`
are for integers only.

A pointer to a record isn't the record: its fields are `p^.f`, never
`p.f`, and the elements of a pointer to an array are `p^[i]`. A
statement starts with a name, so `^T(x)^ := v` isn't one.

### 6.1 Integers

Both operands of `+ - * div mod & | xor` have the same integer
type, or one is an untyped constant that takes the other's type. The
result has that type and wraps around at its width: in `U8`,
`200 + 100` is `44`. A unary minus wraps too: for `x` of an unsigned
type, `-x` is `0 - x`.

`div` rounds toward zero and `mod` takes the sign of the dividend, as
in C: `-7 div 2` is `-3`, `-7 mod 2` is `-1`. Dividing by zero, and
dividing the smallest `I64` by `-1`, stop the program (`SIGFPE`).

`&` (and), `|` (or), `xor` and `~` (not) work on every bit. `x shl n`
and `x shr n` shift by `n & 63`; `shr` brings in copies of the sign bit
for signed types and zeros for unsigned ones. `n` may be of any integer
type. The result has `x`'s type, cut to its width: in `U8`, `0C0H shl
1` is `80H`.

Relations compare as signed or unsigned according to the type.

### 6.2 Booleans

`and` and `or` evaluate their right operand only when it decides the
result. `not` negates, and `=` and `#` compare; `#` is "different".

### 6.3 Reals

`+ - * /` and the relations work on `F32` and on `F64`. Both operands
have the same type, or one is a real constant, which takes the other's
type (section 2). The result has that type: `F32` arithmetic is done in
single precision, rounded at each step as C rounds `float`. A
constant expression of reals is evaluated in double precision, then
rounded once to the type it takes.

Relations are IEEE 754's: a NaN is equal to nothing, itself included,
so for a NaN `x`, `x # x` is true and every other relation with it is
false. Dividing by zero gives an infinity or a NaN; arithmetic on reals
never stops the program.

### 6.4 Pointers

- `p^` is the variable `p` points at.
- `p + i` and `p - i`, with `i` an integer, move `p` by `i` elements:
  by `i * SIZE(T)` bytes for `p: ^T`.
- `p - q`, with both of the same pointer type, is the number of
  elements between them, an `I64`.
- `p[i]` is `(p + i)^`. `p[lo..hi]` is the slice of the `hi - lo`
  elements from `p + lo`. Neither is checked against a length, which a
  pointer doesn't have, but a slice of a pointer that runs backwards,
  `hi < lo`, is a failed check (section 6.5). A pointer to an array
  isn't indexed this way, since a step would be a whole array: its
  elements are `p^[i]`.
- Pointers compare with `= # < <= > >=` as unsigned addresses.
  Procedure values compare with `=` and `#` only.

### 6.5 Arrays and slices

`a[i]` is an element of an array or slice, and `a[lo..hi]` is the slice
of the elements from `lo` up to but not including `hi`. Both are
checked: `i` must be below the length, and `0 <= lo <= hi <= length`.
A check that fails prints to standard error where it is, as file, line
and column, and what failed, with the values involved (`index 7 is out
of range for a length of 5`), and stops the program with status 2.

**Literals.** `[e1, e2, ...]` builds an array, and `{f: e, g: e, ...}`
a record, where the type it must have is known: assigned to a variable,
passed to a parameter, returned, compared with a value of that type, or
an element of a bigger literal. The elements must be assignable to the
element type, and an array literal for `[n]T` has exactly `n` of them.
A record literal names its fields, in any order, each at most once; the
fields it leaves out are zero, so `{}` is the record with every field
zero. An array literal used as a slice is a
hidden variable of the procedure, and lives as long as its call.

```
c := {ch: 'A', attr: 7};
Fmt.print("{} of {}\n", [Fmt.int(n), Fmt.int(m)]);
```

**Arrays and strings compare.** Two operands that are each a `[]T` or
a `[n]T`, of the same element type `T`, are `=` when they have the
same length and the same elements, and `#` otherwise, where `T` is an
integer type, `BOOL`, an enumeration, a set or a pointer type. A string
literal compares as a `[]U8`. The comparison is code of its own where
it stands, a check of the lengths and then of the bytes, not a call.

Arrays of reals don't compare this way, since `-0.0 = 0.0` and a NaN
is equal to nothing, though their bytes say otherwise; nor do arrays
of records, variants or procedures, nor records and variants
themselves. Write a loop. Ordering strings is the library's
`Str.cmp`.

### 6.6 Enumerations and sets

Enumerations compare with all six relations, by position, and an
enumeration can be the variable of a `for` loop and the expression of a
`match` (section 7.4).

`{red, blue}` is a set, of the set type of its names' enumeration;
`{}` is the empty set, where the type it must have is known. On two sets
of the same type, `+` is union, `*` intersection and `-` difference;
`=` and `#` compare, and `<=` and `>=` are "is a subset of" and "is a
superset of". `x in s` is `true` if `x`, a value of the enumeration,
is in the set `s`.

### 6.7 Conversions

A type name applied like a procedure converts: `I32(x)`, `F64(n)`,
`^Cell(addr)`. A pointer type written out uses the `^` form of the
grammar: `^VOLATILE U32(0FEE00000H)`.

| From | To | Result |
|---|---|---|
| integer | integer | the value cut to the new width, or extended by its sign (signed) or zeros (unsigned) |
| integer | `F32`, `F64` | the nearest real |
| `F32`, `F64` | integer | rounded toward zero; a NaN, or a real out of the range of `I64`, gives the smallest `I64`, then cut |
| `F32` | `F64` | the same value |
| `F64` | `F32` | the nearest `F32`; too big a value gives an infinity |
| enumeration | integer | its position |
| integer | enumeration | the name at that position; a position out of range is a failed check (6.5) |
| set | integer | its bits |
| integer | set | the low bits, as many as the set has |
| integer | pointer, procedure | the address |
| pointer, procedure | integer | the address |
| pointer, procedure | pointer, procedure | the same address, seen as the new type |

There are no others: no conversion between `BOOL` and integers, and
none to or from records, arrays, slices, variants or `ERROR`. A
conversion of a constant is made by the compiler, by the same rules:
`U8(300)` is 44.

### 6.8 Built-in procedures

| Call | Result |
|---|---|
| `SIZE(T)` | the size of type `T` in bytes, a constant; `T` is a type, not a variable |
| `ADR(x)` | the address of variable `x`, a `^T` |
| `LEN(a)` | the number of elements of an array or a string constant (a constant) or of a slice, an `I64` |
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

`NEW(p, a)` calls `a^.alloc(a, SIZE(T), A)`, where `A` is the
alignment of `T`, and zeroes the bytes it gets if they aren't `nil`.
`Mem.Allocator` (section 11) is the one type of the library the
language names.

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

`for i := a to b by s do ... end;` sets `i` to `a`, `a + s`, ... while
`i <= b` (or `i >= b` if `s` is negative). `i` is a variable of an
integer or enumeration type, named by its name alone; `a` and then `b`
are evaluated once, before the first round; `s` is a constant other
than zero, and 1 if left out.

The loop never steps past `b`, so `i` can't wrap: afterwards `i`
holds the last value it took, or `a` if the body never ran. The body
may assign `i`. Precisely, for a positive `s`: at the end of a round,
if `i <= b` and `b - i < s`, the loop ends with `i` as it is;
otherwise `i` becomes `i + s`, wrapping, and the loop goes on while
`i <= b`. A negative `s` is the same, the other way round.

`break` ends the innermost `while`, `repeat` or `for` it stands in,
and the program goes on after it. There is no `goto`.

### 7.3 Return

`return e;` ends the procedure with the result `e`; `return a, b;` with
several results; `return f(x);` with the several results of `f`, if
they are the procedure's own (section 8); `return;` from a procedure
without results. A
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
itself, so assigning to one changes `s`; if `s` isn't a variable, they
stand for the fields of a copy. An arm may also leave the fields
unnamed. Every case must have an arm, and only one, unless there is an
`| else:` arm, which must come last.

`match` on an enumeration works the same way: each arm names one of the
enumeration's names.

### 7.5 Order of evaluation

Operands, arguments and the designators of an assignment are evaluated
from left to right, and the designators of an assignment before its
right side: `a[i()] := g()` calls `i` and then `g`.

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

**Ordinary variables.** Only volatile accesses, `CAS`, `XCHG`, `XADD`
and `FENCE` are exact. Any other access is ordinary: an implementation
may keep a variable in a register, leave out a write that nothing
reads, and change the order of ordinary accesses, as long as each
thread, on its own, does what this report says. A variable that one
thread writes while another reads or writes it, unless both use
volatile accesses or the atomic built-ins, or a `FENCE` orders them,
holds no particular value then: a read of it gives a value it had or
was given, or a mixture of their bytes. Nothing else of the program
becomes undefined by it.

### 7.7 Defer

`defer s;` runs the statement `s` when the program leaves the statement
list the `defer` stands in: at its end, or by a `return`, or by a
`break` out of it. Statements deferred in the same list run in the
opposite order to their `defer`s, and only those whose `defer` has been
reached run.

```
module Head;
import Sys, Out;

(* Prints the first line of the file at path. *)
proc head(path: []U8): BOOL;
var fd, n, i: I64; buf: [256]U8;
begin
    fd := Sys.openRead(path);
    if fd < 0 then return false; end;
    defer Sys.close(fd);
    n := Sys.read(fd, buf);
    if n < 0 then return false; end;
    for i := 0 to n - 1 do
        if buf[i] = 10 then n := i; break; end;
    end;
    Out.str(buf[0..n]);
    Out.ln;
    return true;
end;

proc main*;
begin
    if not head("/etc/hostname") then Out.str("no hostname\n"); end;
end;

end Head.
```

`return e;` evaluates `e` before the deferred statements run. A
deferred statement can't contain `return`, `break` or `defer` that
would leave it. A failed check, `Rt.exit` and `Sys.exit` end the
program without running the deferred statements still pending.

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
assignment, alone as a statement, or alone after `return` in a
procedure whose results are of the same types, in the same order,
which then returns them as they are: `return divmod(n, 2);`.

```
module Divide;
import Out;

proc divmod(a, b: I64): (I64, I64);
begin
    return a div b, a mod b;
end;

proc main*;
var q, r: I64;
begin
    q, r := divmod(17, 5);
    Out.int(q); Out.str(" rest "); Out.int(r); Out.ln;
end;

end Divide.
```

**forward.** `proc f(x: I64): I64; forward;` declares `f` so that it
can be called before its body appears; the body comes later with the
same signature, though its parameters may have other names.

A name after a procedure's `end`, if written, is the procedure's own.

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
`r9`, `F32` and `F64` ones in `xmm0` to `xmm7`, and the result goes in
`rax` (and `rdx` for a second) or `xmm0`. Its parameters and results
are therefore of the types C can take (section 9), at most six integer
and eight real parameters, and at most two results. The bytes are the whole
procedure, `ret` included; they must keep `rbx`, `rbp`, `rsp` and `r12`
to `r15` as they found them. The compiler doesn't look inside them.

## 9. Calling C

```
ExternDeclaration = "extern" ( "proc" IdentDef Signature
                             | "var" IdentDef ":" Type ) .
```

```
link "libX11.so.6";
extern proc XOpenDisplay(name: ^U8): ^U8;
extern proc printf(format: ^U8; ...): I32;
extern var environ: ^^U8;
```

An `extern` procedure or variable is found by its name in the C
libraries the program links: the C library always, and each library
named by `link`.

An `extern` procedure's parameters and result are integers, `BOOL`,
`F32`, `F64`, pointers or procedures; a record goes to C by pointer,
never by value. `...` accepts any number of further arguments of those
types, and is allowed only in an `extern`. C takes no `float` there,
so an `F32` given to `...` is an error: the program writes `F64(x)`.
Past the parameters, a real constant goes as an `F64`, an integer
constant as an `I64`, and a string literal as a pointer to its bytes
followed by a zero byte.

An `extern` variable is C's variable itself: reading it reads C's,
assigning it writes C's. It can be of any type, declared as C declares
it, a record laid out as C lays it out (section 5.5); the compiler
can't check that it is. A C variable that is local to each thread,
such as `errno`, can't be reached this way; the C library has a
procedure for it (`__errno_location`).

A C union has no raz type. A program reads one as an array of words,
and the member it wants through a pointer conversion:

```
var ev: [24]I64;                       (* XEvent: 192 bytes *)
...
XNextEvent(dpy, ADR(ev));
if I32(ev[0]) = KeyPress then
    key := ^XKeyEvent(ADR(ev));
    ...
end;
```

Every raz procedure uses the System V calling convention, so a raz
procedure whose parameters and result are of those types can be given
to C as a callback.

## 10. Programs

Any module may export a procedure `main`, declared `proc main*;` or
`proc main*: I64;`. The program runs the bodies of all its modules
(section 3), then the main module's `main`, if it has one, and ends
with status 0, or with the status `main` returns, by calling
`Rt.exit`. The `main` of an imported module is an ordinary procedure,
which runs only if something calls it; so a library module can carry a
`main` that tests it.
A program uses C if any of its modules has an `extern` declaration or
a `link` of a library; a module's other files, read only to check its
interface (section 3), don't count. A program that doesn't is a static executable
with no run time besides the code it uses. One that does is linked
dynamically and starts through the C library, so that C's own set-up
and clean-up run. A program with a module that says `link static;`
must not use C, and the compiler reports an error if it does.

**Ending.** `Rt.exit(status)` ends the program. First it runs the
procedures registered with `Rt.atExit`, the last registered first,
each at most once; then it ends the program with `status`, through
C's `exit` in a program that uses C, so that C flushes its own
buffers. A failed check (section 6.5) runs them too, after its
message, so that `Out`'s buffer is written out. `Sys.exit` ends the
program at once, and a program stopped by a signal runs none of them.

```
proc atExit*(p: proc): ERROR;   (* Rt.Full if 32 are registered *)
proc exit*(status: I64);
```

Only what can be reached from `main` and the module bodies goes into
the executable: unused procedures, variables and strings are left out.
The executable names its procedures and carries line numbers, so that
gdb can stop at a line of the source and show where it is.

**Defined behaviour.** Every variable starts at zero, integers wrap,
and indexing arrays and slices is checked, so a program's behaviour is
defined by this report, with one exception: memory reached through a
pointer. Dereferencing a stale or made-up pointer, indexing through a
pointer, a code procedure that breaks its rules, and C code can read or
write any memory, and what follows isn't defined. Dereferencing `nil`, dividing
by zero, calling a `nil` procedure and running out of stack stop the
program with a signal. Before it stops, the program prints to standard
error where it was, as file, line and column, and why, as far as it can
tell: a `nil` pointer, a `nil` procedure, a stack overflow, a bad
address or a division fault.

**Messages.** The compiler reports an error with its file, line and
column, the line of source with the offending part underlined, and,
where they help, notes pointing at other places, such as where a name
is declared, and a suggestion, such as a name in reach spelled almost
alike. It goes on after an error to find the others, up to 20, and
writes no executable. After an error it skips the statement or
declaration the error is in and carries on with the next; a name that
isn't declared is reported once, and nothing that follows from it is
reported. An error in the text itself, such as a string left open,
stops the compile, and so does a module with errors, after it.

The compiler also warns of what is declared and never used: an import;
a constant, type, variable or procedure that isn't exported; a
parameter of a procedure written in raz. It warns of a variable that is
assigned but never read, too. A name that starts with `_` is never
warned about. Warnings don't stop the compile; `raz -Werror` makes them
errors.

## 11. The library

Modules written in raz, in the compiler's `lib` directory:

| Module | What |
|---|---|
| `Rt` | ending the program, `exit` and `atExit`; `stop`, which ends it with a message; what the compiler's checks call when they fail |
| `Sys` | system calls: `open`, `openRead`, `create`, `read`, `write`, `seek`, `close`, `mmap`, `munmap`, `isTerminal`, `yield`, `exit`; files and directories, `rename`, `remove`, `removeDir`, `makeDir`, `chmod`, `symlink`, `readLink`, `info`, `openDir`, `nextEntry`, `closeDir`; the terminal, `rawMode`, `restoreMode`, `termSize`, `ready`; the environment, `env`, `workDir`, `setWorkDir`; programs, pipes and signals; time, `clock`, `now`, `sleep`; `random`; and sockets. One file per target, and `Sys.raz` over the C library for the others |
| `Out` | writing text and numbers to standard output, buffered; safe to call from several threads |
| `C` | the parts of the C library the others use, and `printf`, `fflush`, `stdout`, `pthread_create`; a program that imports it uses C |
| `Lock` | a lock for short sections, for C's threads and `Thread`'s alike |
| `Thread` | threads for a program without C: `spawn`, `join`, and `Mutex`; it says `link static` |
| `Mem` | `Allocator`, the interface of every allocator, and pages from the system |
| `Heap` | a general allocator, `Heap.heap`, safe to call from several threads; freeing a block twice, or one it never gave out, stops the program |
| `Arena` | an allocator that frees everything at once; `ADR(arena.base)` is its allocator |
| `Str` | operations on `[]U8` strings: comparing, hashing, finding, UTF-8, reading a number |
| `Buf` | a growable byte buffer |
| `Fmt` | formatted output: `Fmt.print("{} of {}\n", [Fmt.int(n), Fmt.real(x, 2)])`, or into a `Buf` with `Fmt.write` |
| `List` | a generic singly linked list, `List(T)` |
| `Map` | a generic hash map, `Map(K, V; hash, eq)` |
| `Sort` | sorting a slice in place, `Sort(T; less)` |
| `Math` | `sqrt`, `floor`, `sin`, `cos`, `atan2`, `exp`, `ln` and `pi`, for `F64` |
| `Files` | an argument as a string, and a whole file read or written |
| `Opt` | a command line read through one table, by `getopt`'s rules with long options; its help and its mistakes |

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

**Sys** gives every target the same procedures, so that a program
that needs only these runs wherever raz does: through system calls on
Linux, through the C library elsewhere. A result that can fail is a
number, minus an errno, as on Linux; 0 is success.

```
const
    stdin* = 0; stdout* = 1; stderr* = 2;
    (* signals, by their numbers on Linux; each target has its own *)
    sigHup* = 1; sigInt* = 2; sigQuit* = 3; sigKill* = 9; sigPipe* = 13;
    sigTerm* = 15; sigChld* = 17; sigCont* = 18; sigStop* = 19;
    sigTstp* = 20; sigTtin* = 21; sigTtou* = 22; sigWinch* = 28;

type
    Access* = (reading, writing, creating, exclusive, truncating, appending);
    Accesses* = set of Access;
    Info* = record
        size*: I64;      (* in bytes *)
        mtime*: I64;     (* when its contents last changed, in nanoseconds since 1970 *)
        mode*: I64;      (* its permission bits, as chmod takes them: 1EDH is rwxr-xr-x *)
        dir*: BOOL;      (* a directory *)
        file*: BOOL;     (* a regular file: not a directory, device, pipe or socket *)
        symlink*: BOOL;  (* the path itself is a symbolic link *)
    end;
    Dir* = record ... end;   (* an open directory; its fields are the target's *)
    Program* = record
        path*: []U8;
        args*: [][]U8;      (* the first is its name *)
        env*: [][]U8;       (* NAME=value, each added to this program's environment *)
        onlyEnv*: BOOL;     (* env is its whole environment *)
        dir*: []U8;         (* its working directory; "" for this program's *)
        fds*: [3]I64;       (* its standard input, output and error; 0 for this program's own *)
        group*: I64;        (* the process group it joins: 0 for this program's, -1 a new one it leads *)
        foreground*: BOOL;  (* its group takes the terminal on standard input *)
        tty*: I64;          (* a pseudo-terminal's fd, to start a session on; 0 for none *)
    end;
    Status* = (running, exited, killed, stopped);

proc open*(path: []U8; how: Accesses): I64;   (* its fd *)
proc openRead*(path: []U8): I64;         (* open(path, {reading}) *)
proc create*(path: []U8): I64;           (* open(path, {writing, creating, truncating}) *)
proc seek*(fd, pos: I64; fromEnd: BOOL): I64;  (* the new position *)

proc rename*(old, new: []U8): I64;       (* replaces what new names *)
proc remove*(path: []U8): I64;           (* a file, not a directory *)
proc removeDir*(path: []U8): I64;        (* an empty directory *)
proc makeDir*(path: []U8): I64;          (* readable by all, writable by its owner *)
proc chmod*(path: []U8; mode: I64): I64;
proc symlink*(target, path: []U8): I64;  (* path made a link to target *)
proc readLink*(path: []U8): ([]U8, I64); (* what the link names, good until the next call *)
proc info*(path: []U8): (Info, I64);     (* following a symbolic link *)

proc openDir*(d: ^Dir; path: []U8): I64;
proc nextEntry*(d: ^Dir): ([]U8, BOOL);  (* a name, good until the next call; false at the end *)
proc closeDir*(d: ^Dir);

proc rawMode*(fd: I64): BOOL;      (* the terminal on fd: no echo, no lines, no signals *)
proc restoreMode*(fd: I64);        (* as rawMode found it *)
proc termSize*(fd: I64): (I64, I64);   (* columns and rows; 80 and 24 if unknown *)
proc ready*(fd: I64; ms: I64): BOOL;   (* something to read within ms, or ever if ms < 0 *)
proc readyOf*(fds: []I64; ms: I64): I64;   (* the first of fds with something to read within ms, or -1 *)

proc env*(name: []U8): []U8;       (* the environment variable's value; "" if unset *)
proc workDir*: ([]U8, I64);        (* the working directory, good until the next call *)
proc setWorkDir*(path: []U8): I64;

proc pipe*: (I64, I64);            (* the fd to read and the fd to write; or minus an errno and -1 *)
proc openPty*: I64;                (* a pseudo-terminal: the fd of its controlling side *)
proc setTermSize*(fd, cols, rows: I64): I64;   (* the size its programs are told of *)
proc spawn*(p: Program): I64;      (* a program started: its process id *)
proc wait*(pid: I64; block: BOOL): (I64, Status, I64);   (* which program, how, and its code *)
proc kill*(pid, signal: I64): I64;
proc pid*: I64;                    (* this program's process id *)
proc setGroup*(pid, group: I64): I64;    (* pid 0 is this program; group 0 a new one pid leads *)
proc foreground*(fd, group: I64): I64;   (* the terminal on fd gives its keys to group *)
proc foregroundOf*(fd: I64): I64;  (* the group the terminal on fd gives its keys to *)

proc catch*(sigs: []I64): I64;     (* sigs caught: an fd to wait on *)
proc caught*(fd: I64): I64;        (* the next signal caught, or 0 if none is waiting *)
proc ignore*(sig: I64; yes: BOOL): I64;  (* sig ignored; or, if not yes, back to what it does at first *)

proc clock*: I64;                  (* nanoseconds, on a clock that only goes forward *)
proc now*: I64;                    (* nanoseconds since 1970-01-01, UTC *)
proc sleep*(ms: I64);
proc random*(b: []U8);             (* b filled with random bytes *)

proc connect*(path: []U8): I64;    (* a stream socket, connected to the Unix socket at path: its fd *)
proc connectTcp*(addr: []U8; port: I64): I64;   (* addr an IPv4 or IPv6 address, as numbers *)
proc connectUdp*(addr: []U8; port: I64): I64;
proc listen*(path: []U8): I64;     (* a Unix socket made at path, taking connections *)
proc listenTcp*(addr: []U8; port: I64): I64;
proc accept*(fd: I64): I64;        (* the next connection, waiting for one *)
proc send*(fd: I64; s: []U8): I64; (* write, to a socket: -32 (EPIPE), not a signal, if it is closed *)
```

`info` follows a symbolic link: `size`, `dir` and `file` are those of
what it names, and `symlink` says the path was a link, so that a program walking
a tree can choose not to follow one back up it. A link to nothing is
`-ENOENT`, as a missing file is. `file` lets a walk open only what
holds data: opening a pipe would wait for a program to write to it.

`nextEntry` gives every name in the directory except `.` and `..`, in
no particular order. `rawMode` turns off what the terminal does with
keys before the program reads them: echo, waiting for a whole line,
Ctrl-C and Ctrl-Z as signals, Ctrl-S and Ctrl-Q as flow control, and
CR to NL; and with output, NL to CR NL. A program that turns it on
restores it before it ends: `Rt.atExit` is the place.

`connect` is for talking to a server on the same machine, an X server
at `/tmp/.X11-unix/X0` say; what it receives comes by `read`, what it
sends goes by `send`, and `close` ends it. `send` is `write` for a
socket, except when the other end has closed it: `write` would stop
the program with the signal SIGPIPE, where `send` returns -32
(EPIPE), so that a program learns its server has gone and can end as
it wants. `readyOf` waits on several file
descriptors at once, as a program does that listens to a server and a
terminal both; a descriptor at its end, or failed, counts as ready,
since a read of it won't wait. It looks at the first 64 of `fds`, and
`connect` takes a path of at most 107 bytes, as `struct sockaddr_un`
holds; a longer one is -36 (ENAMETOOLONG).

**Files.** `open` gives a file for what `how` asks: `reading`,
`writing` or both; `creating` it if it is missing, readable by all and
writable by its owner; with `exclusive`, failing with -17 (EEXIST) if
it is there, as a program does that makes a lock or a file of its
own; `truncating` it to nothing; `appending`, each write going to its
end, however other programs write it too. `seek` moves to `pos` from
the start of the file, or from its end if `fromEnd`, where a negative
`pos` reads back from the end. `Info.mtime` is what a program checks
to see whether a file changed under it; `Info.mode` holds the nine
bits of `rwxrwxrwx`, and `chmod` sets them, 1EDH (755) for a program,
1A4H (644) for data.

**Programs.** `openPty` makes a pseudo-terminal, a terminal that a
program, a terminal emulator, plays the screen and the keyboard of:
what it writes to the fd is typed, and what the programs on the
terminal write it reads.

`spawn` starts the program at `p.path`, with `p.args` as its
arguments, the first being its name. Its environment is this
program's with each `NAME=value` of `p.env` added or put in place of
the old value, or, if `p.onlyEnv`, `p.env` alone. It starts in
`p.dir`. Its standard input, output and error are `p.fds`; a 0 gives
it this program's own, so `{path: "/bin/ls", args: ["ls"]}` runs
`ls` as a shell runs it, with every other field zero. It gets no
other open file, every signal does what it does at first, and none
is blocked. If `p.tty` is a pseudo-terminal's fd, the program starts a
session on that terminal: it is its controlling terminal, and its
standard input, output and error, and `p.fds` and `p.group` are not
used.

`p.group` puts the program in a process group, the programs that a
shell's job is made of: -1 makes it the first of a new group, whose
number is its process id, and the other programs of the job join that
number. The terminal gives its keys, and the signals of Ctrl-C and
Ctrl-Z, to one group, the one in its foreground: `p.foreground` puts
the program's group there before it starts, and `foreground` puts any
group there, as a shell does to take the terminal back. `setGroup`
moves a program to a group, as the shell does for each program it
starts, for whichever of the two runs first; a shell runs in a group
of its own, `setGroup(0, 0)`.

`wait` waits for the program `pid` to change, or for any of this
program's if `pid` is -1, and says which one, and how: `exited`, with
its exit status; `killed`, with the number of the signal that ended
it; or `stopped`, by Ctrl-Z or a signal, with the signal's number.
Without `block` it doesn't wait, and is 0 and `running` if no program
changed. A program that has nothing to wait for is -10 (ECHILD).
`kill` sends a program a signal, `sigTerm` to end it; to a group, if
`pid` is minus its number.

**Signals.** `catch` takes the signals `sigs` away from what they
would do, ending the program most of them, and gives an fd that is
ready to read when one comes, so that a program waits for signals with
`ready` and `readyOf` as it waits for keys or a server. `caught` gives
each signal that came, in turn. A later `catch` adds to the signals
caught and gives the same fd. Catching `sigKill` or `sigStop`, or the
signals `Rt` reports, SIGSEGV and SIGFPE, is -22 (EINVAL). `ignore`
makes a signal do nothing, as a shell ignores `sigTtou` so that it can
take its terminal back, and `ignore(sig, false)` gives it back what it
does at first. A program that `spawn` starts begins with neither.

**Time.** `clock` is for measuring how long something takes: it never
goes back, and says nothing of the date. `now` is the date and time,
which a person or the network may set back. `sleep` waits `ms`
milliseconds.

**Sockets.** `connect` is for talking to a server on the same machine,
an X server at `/tmp/.X11-unix/X0` say; `connectTcp` for one across
the network, given its address as numbers, `"127.0.0.1"` or `"::1"`:
turning a name into an address is a library's work over these.
`connectUdp` gives a socket of datagrams, each `send` one message to
that address and each `read` one message from it, as a program asks a
name server. What a socket receives comes by `read`, what it sends goes
by `send`, and `close` ends it. `send` is `write` for a socket, except
when the other end has closed it: `write` would stop the program with
the signal SIGPIPE, where `send` returns -32 (EPIPE), so that a
program learns its server has gone and can end as it wants.
`listen` and `listenTcp` are the other side: a server's socket, on
`path`, which must not be there yet, or on `port` at `addr`,
`"0.0.0.0"` or `"::"` for every address the machine has; `accept`
gives each connection that comes, as a socket of its own.

`readyOf` waits on several file descriptors at once, as a program does
that listens to a server and a terminal both; a descriptor at its end,
or failed, counts as ready, since a read of it won't wait. It looks at
the first 64 of `fds`, and `connect` and `listen` take a path of at
most 107 bytes, as `struct sockaddr_un` holds; a longer one is -36
(ENAMETOOLONG).

**Str, Map, Sort, Math and Fmt** gain these:

```
module Str;
proc encode*(c: I64): ([4]U8, I64);   (* c in UTF-8: its bytes, and how many *)
proc decode*(s: []U8): (I64, I64);    (* the character s starts with, and its length in bytes *)
proc toInt*(s: []U8): (I64, BOOL);    (* s, in decimal; false if it isn't a number an I64 holds *)

module Map(K, V; hash: proc(k: K): U64; eq: proc(a, b: K): BOOL);
proc remove*(m: ^Map; k: K): BOOL;            (* false if k wasn't there *)
proc next*(m: ^Map; i: I64): (I64, K, V);     (* the entry after i *)

module Sort(T; less: proc(a, b: T): BOOL);
proc sort*(s: []T);

module Math;
const pi* = 3.141592653589793;
proc sqrt*(x: F64): F64;
proc floor*(x: F64): F64;
proc sin*(x: F64): F64;
proc cos*(x: F64): F64;
proc atan2*(y, x: F64): F64;
proc exp*(x: F64): F64;
proc ln*(x: F64): F64;

module Fmt;
type Arg* = variant ... real(r: F64; places: I64); end;
```

`Str` reads and writes UTF-8. `encode` writes a character, of at most
10FFFFH, in one to four bytes; a number that isn't one becomes FFFDH,
the character that stands for a wrong one. `decode` reads the first
character of `s`, and gives FFFDH and 1 for a byte that doesn't start
one rightly, and 0 and 0 for an empty `s`. `toInt` reads a decimal
number, with a `-` or `+` before it if any, and nothing else.

`Map.next` walks a map: from 0, it gives the next entry and the number
to pass for the one after it, and -1 when there are no more. A walk
sees each entry once if the map doesn't change during it:

```
i, k, v := Names.next(ADR(names), 0);
while i >= 0 do
    Fmt.print("{} is {}\n", [Fmt.str(k), Fmt.int(v)]);
    i, k, v := Names.next(ADR(names), i);
end;
```

`Sort.sort` puts `s` in the order `less` gives, in place, without
memory of its own, in time `n log n` at most; two elements equal by
`less` may change places. `Math`'s procedures are as C's `math.h`
has them, to within the last bit or so. `Fmt.real(x, places)` writes
`x` with `places` digits after the point, at most 9, rounded to the
nearest; from 1e15 on, with an exponent, as `1.50e17`; and `nan`,
`inf` and `-inf` as themselves.

**Files and Opt** are what most programs need of their command line.

```
module Files;
proc arg*(i: I64): []U8;                     (* argument i; 0 is the program's name *)
proc read*(path: []U8; b: ^Buf.Buf): BOOL;   (* the whole file added to b *)
proc write*(path, data: []U8): BOOL;         (* the file made to hold data *)

module Opt;
type
    Row* = variant
        usage(scope, line: []U8);           (* a synopsis line, without "usage: " *)
        sub(scope, name, help: []U8);       (* a subcommand *)
        option(scope: []U8; letter: U8; long, value, help: []U8);
    end;
    Parser* = record
        letter*: U8;    (* the option just read *)
        value*: []U8;   (* its value; "" for a flag *)
        long*: BOOL;    (* it was written by its long name *)
        ...
    end;
proc init*(p: ^Parser; name: []U8; table: []Row);  (* the arguments from 1 on, by table *)
proc next*(p: ^Parser): BOOL;                     (* the next option; false when they end *)
proc operand*(p: ^Parser): ([]U8, BOOL);          (* the next operand; false when there are no more *)
proc scope*(p: ^Parser; name: []U8);              (* subcommand name's options, from the word after it *)
proc number*(p: ^Parser; lo, hi: I64): I64;       (* the value just read, a number from lo to hi *)
proc fail*(p: ^Parser; text: []U8);               (* the program's own mistake *)
```

`Opt` reads a command line by the rules of the C library's `getopt`,
with GNU's long options, so that a program's options behave as every
other Unix program's. The program describes itself once, in a table of
`Row`s: its synopsis lines, its subcommands and its options. The help
and the messages for mistakes are made from the table, so they can't
drift from it; the program's test of `p.letter` is the only other
place an option appears. The parser is a record the program owns, and
the table a slice it keeps as long as the parser: a literal written in
the call to `init` lives as long as the procedure that makes it.

A row's `scope` is `""` for the program itself, or a subcommand's
name: `"start"`, or `"remote.add"` for a subcommand of `remote`. An
option has a `letter`, a `long` name, or both. One with a long name
only has a key of its own below `'!'` for a letter, so that the
program can tell it from the others. With a `value`, the name the
help and the messages give it, the option takes a value; with `""` it
is a flag.

```
const wait = 1;     (* the key of --wait, which has no letter *)
...
Opt.init(ADR(p), "keep", [
    Opt.usage("", "keep [-v] [--wait secs] start ..."),
    Opt.sub("", "start", "start a job"),
    Opt.option("", 'v', "verbose", "", "say more"),
    Opt.option("", wait, "wait", "secs", "give the job secs to start"),
    Opt.usage("start", "keep start [-b label] name command [argument ...]"),
    Opt.option("start", 'b', "bar", "label", "show the job in the bar as label")]);
while Opt.next(ADR(p)) do
    if p.letter = 'v' then verbose := true;
    elsif p.letter = wait then secs := Opt.number(ADR(p), 1, 600);
    end;
end;
w, ok := Opt.operand(ADR(p));
if not ok or (w # "start") then Opt.fail(ADR(p), "no command; see keep -h"); end;
Opt.scope(ADR(p), "start");
while Opt.next(ADR(p)) do
    if p.letter = 'b' then bar := p.value; end;
end;
job, ok := Opt.operand(ADR(p));
```

The rules are `getopt`'s:

- Flags may share a dash: `-lw` is `-l -w`. A letter's value is the
  rest of its word, `-bdev`, or the whole next word, `-b dev`, even one
  that starts with a dash or is empty; in a group, the first letter
  that takes a value takes the rest, `-qn12`.
- A long option is written in full, with its value after a `=` or in
  the next word: `--bar=dev`, `--bar dev`. An abbreviation is unknown,
  not guessed, so that adding an option never breaks a script. A value
  given to a flag, `--follow=x`, is a mistake.
- `--` ends the options, and isn't an operand; `-` alone is one. The
  options end at the first operand, so in `keep start site python -m
  http.server` the `-m` is python's.
- Each scope has its own options. An option given twice is read twice.

`number` reads the value as `Str.toInt` does. `operand` reads what
options are left first, and the program doesn't see them.

`-h` or `--help` among a scope's options prints its help on standard
output and ends the program with status 0. `init` and `scope` answer
it, looking through the scope's options before `next` gives one, so
that the program has done nothing yet: `keep -v -h -x` prints the
help, and the program never sees `-v`, nor the mistake. The help is
the scope's synopsis lines, a blank line, and its subcommands, its
options and the help itself, each with its line of help:

```
usage: keep start [-b label] name command [argument ...]

  -b, --bar label   show the job in the bar as label
  -h, --help        print this and exit
```

A scope with several synopsis lines has the others indented under the
first; one with none, `usage:` and its words, as `usage: keep start`.

A mistake on the command line is a sentence on standard error, the
program's name first, then the scope's synopsis lines, as the help
begins, and status 2:

```
keep: unknown option -x
usage: keep start [-b label] name command [argument ...]
```

The sentences are `unknown option -x` (or `--name`, up to its `=`),
`-b needs a label`, `--follow takes no value` and `--wait wants a
number from 1 to 600, not '0'`. `fail` writes the program's own
mistakes the same way, but alone, so that the sentence can say where
the help is: `keep: no command; see keep -h`.

A mistake in the table is the program's, not its user's. `init` checks
the table before it reads a word, and ends the program with status 1:
`keep: option table, row 3: the option is in the scope already`. The
others are an option with neither a letter nor a long name, a long
name with `=` in it, a letter `-`, and `-h` or `--help` in the table,
since they are `Opt`'s.

**Out and C's stdio.** `Out` keeps a buffer of 4 KB. It writes it out
when it is full, at each line feed when standard output is a terminal,
at `Out.flush`, and when the program ends by `Rt.exit`. C's `stdio`
keeps a buffer of its own for the same standard output. A program that
writes with both flushes one before writing with the other, or the
text comes out of order:

```
module Both;
import Out, C;      (* C: printf, fflush and C's FILE *stdout *)

proc main*;
begin
    Out.str("from raz\n");
    Out.flush;
    C.printf("from C\n");
    C.fflush(C.stdout);
    Out.str("from raz again\n");
end;

end Both.
```

## 12. Versions

A version of this report is named by the month it was made in and a
count: `2026-10.0`, then `2026-10.1` for the next change that month.
`raz --version` says which version the compiler follows.

- **2026-10.0.** The first numbered version: the language of compiler
  0.3.0.
- **2026-10.1.** Messages: every error in a run, warnings of what is
  never used and `-Werror` (section 10); failed checks say what failed,
  and signals say where (sections 6.5 and 10).
- **2026-10.2.** `Sys` gains files and directories, the terminal, and
  the environment (section 11).
- **2026-10.3.** `return f(x);` passes on the several results of `f`
  (sections 7.3 and 8). `and`, `or` and `not` are for `BOOL`s, and
  bind below the relations; `&`, `|` and `~` are the operators on bits,
  and `xor` is for integers only (sections 2 and 6). Arrays and slices
  of integers, `BOOL`s, enumerations, sets and pointers compare with
  `=`, by code where the comparison stands, not by a call into `Rt`
  (section 6.5). A generic module's instance is made where it is first
  used, so its arguments may name types declared after the imports
  (section 3).
- **2026-10.4.** `Sys` gains a connection to a Unix socket, waiting on
  several files at once, pseudo-terminals, and starting, waiting for
  and stopping programs (section 11).
- **2026-10.5.** A module with files in more than one of the
  directories searched is an error, unless the first is a link to one
  of the others (section 3).
- **2026-10.6.** `Sys.Info` says whether the path is a regular file,
  and whether it is a symbolic link (section 11).
- **2026-10.7.** `Sys.send` writes to a socket without SIGPIPE
  (section 11).
- **2026-10.8.** `Sys.workDir` returns the directory, with no `var`
  parameter (section 11).
- **2026-10.9.** The language is frozen (the start of the report).
  `Sys` gains opening a file for any use, seeking,
  links, permissions and times; pipes, process groups and the
  terminal's foreground; signals caught on a file descriptor; clocks,
  sleeping and random bytes; and network sockets. `Sys.spawn` takes a
  `Program`, and `Sys.wait` says which program changed and how. `Str`
  gains UTF-8 and reading a number, `Map` removing and walking, `Fmt`
  reals; `Sort`, `Math`, `Files` and `Opt` are new (section 11).
- **2026-10.10.** Said at last: what the compiler did and the report
  didn't say, all through; what an implementation chooses, and the
  core every target has (appendix A); the whole grammar (appendix B);
  the library's module names are kept for it (section 3). Mended:
  arithmetic on untyped constants that overflows is an error (section
  2); a slice of a pointer can't run backwards (section 6.4). Ordinary
  accesses are no longer promised to be made exactly as written, only
  volatile and atomic ones (section 7.6).

## Appendix A. What an implementation chooses

Everything in this report binds every implementation of raz, except
what follows, which each chooses for itself and documents. This
compiler's choices are in `doc/compiler.md`.

- **The target.** Which machines and systems it compiles for, and the
  names of their files (`linux-x86_64`, section 3).
- **The calling convention.** On x86-64 Linux it is System V
  (sections 8 and 9); elsewhere it is the C library's own, so that
  `extern` procedures and callbacks work. How a procedure returns
  several results, and how its frame is laid out, are the
  implementation's.
- **What is the target's.** Code procedures (section 8) hold the
  target's machine code, and exist only where the implementation says
  so; `SYSCALL` exists only on Linux targets (section 6.8). A record's
  layout is the target's C layout (section 5.5).
- **The executable.** Its format, and the names and line numbers it
  carries for a debugger (section 10).
- **Messages and warnings.** The text of the compiler's messages, how
  many errors it reports before it stops, and which warnings it gives
  (section 10). A program that is an error in this report is one in
  every implementation; the words that say so are free.
- **The command line.** How the compiler is run, its options, and
  where its library lives (sections 1 and 3).

**The core.** A target may leave out what the system under it can't
give: `Sys` past writing, ending the program and getting memory,
`Thread`, `link` and `extern`. What it must have, besides the whole
language, is the core of the library: `Rt`, `Out`, `Mem`, `Arena`,
`Lock`, `Str`, `Buf` and `Fmt`, and of `Sys` what they need. A
program that keeps to the core runs on every target.

## Appendix B. The grammar

The whole syntax of raz, gathered from the sections above, with the
symbols of section 2. `{ x }` is any number of `x`, `[ x ]` is `x` or
nothing, and `( x | y )` is one of them.

```
ident      = letter { letter | digit } .
letter     = "A" .. "Z" | "a" .. "z" | "_" .
digit      = "0" .. "9" .
hexDigit   = digit | "A" .. "F" .
number     = digit { digit }
           | digit { hexDigit } "H"
           | digit { digit } "." digit { digit } [ "E" [ "+" | "-" ] digit { digit } ] .
char       = "'" ( character | escape ) "'" .
string     = '"' { character | escape | "\x" anyHex anyHex } '"' .
escape     = "\n" | "\t" | "\r" | "\0" | "\\" | "\'" | '\"'
           | "\u{" anyHex { anyHex } "}" .
anyHex     = hexDigit | "a" .. "f" .

Module     = "module" ident [ "(" ModParams ")" ] ";"
             { Import } { Link } { Declaration }
             [ "begin" Statements ] "end" ident "." .
ModParams  = ident { "," ident } { ";" ident ":" "proc" Signature } .
Import     = "import" ImportItem { "," ImportItem } ";" .
ImportItem = ident [ ":=" ident [ "(" Type { "," Type } ")" ] ] .
Link       = "link" ( string | "static" ) ";" .

Declaration = "const" { IdentDef [ ":" "ERROR" ] "=" Expr ";" }
            | "type" { IdentDef "=" Type ";" }
            | "var" { IdentList ":" Type ";" }
            | ProcDeclaration ";"
            | ExternDeclaration ";" .
IdentDef    = ident [ "*" ] .
IdentList   = IdentDef { "," IdentDef } .

Type      = QualIdent
          | "[" Expr "]" Type
          | "[" "]" Type
          | "^" [ "VOLATILE" ] Type
          | [ "packed" ] "record" { IdentList ":" Type ";" } "end"
          | "variant" { Case ";" } "end"
          | "(" ident { "," ident } ")"
          | "set" "of" QualIdent
          | "proc" Signature .
Case      = ident [ "(" FieldList { ";" FieldList } ")" ] .
FieldList = ident { "," ident } ":" Type .
QualIdent = [ ident "." ] ident .

Expr       = Conjunct { "or" Conjunct } .
Conjunct   = Relation { "and" Relation } .
Relation   = SimpleExpr [ RelOp SimpleExpr ] .
RelOp      = "=" | "#" | "<" | "<=" | ">" | ">=" | "in" .
SimpleExpr = [ "-" ] Term { AddOp Term } .
AddOp      = "+" | "-" | "|" | "xor" .
Term       = Factor { MulOp Factor } .
MulOp      = "*" | "/" | "div" | "mod" | "&" | "shl" | "shr" .
Factor     = number | char | string | Designator | "(" Expr ")"
           | "not" Factor | "~" Factor
           | "[" [ Expr { "," Expr } ] "]"
           | "{" [ Element { "," Element } ] "}"
           | "^" [ "VOLATILE" ] Type "(" Expr ")" .
Element    = Expr | ident ":" Expr .
Designator = QualIdent { Selector } .
Selector   = "." ident | "^" | "[" Expr [ ".." Expr ] "]"
           | "(" [ Expr { "," Expr } ] ")" .

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
ExternDeclaration = "extern" ( "proc" IdentDef Signature
                             | "var" IdentDef ":" Type ) .
```

`character` is any character but a line break, and in a string any
but `"` and `\`, in a character any but `'` and `\`. A procedure
argument of a generic module (section 3) is written as a `QualIdent`,
which is a `Type` here. `...` comes last in a `Signature`, and only in
an `extern`.
