{ sym.pas: types, objects and scopes.

  Every name the program declares becomes an object (TObj): a constant,
  type, variable, procedure, module, record field, variant case or
  built-in. Every type is a TType. Objects are found through one hash
  table keyed by scope and name, so a lookup costs the same however
  big a module grows. A scope is just a number: the universe is 0,
  and each module, procedure, record and match arm gets a fresh one.

  Depends on: scan, for names and errors.
  Leaves out: code. Where a variable lives is decided here (frame
  offsets, chunk numbers), but nothing is emitted. }

unit sym;

{$mode objfpc}{$H-}

interface

uses scan;

type
  TForm = (fNone, fBool, fInt, fReal, fConst, fNil, fStr, fPtr, fArray,
    fSlice, fRecord, fVariant, fProc, fEnum, fSet, fError);
  { fConst is the type of an untyped integer constant; fStr of a string
    literal, whose length the literal carries }

  TClass = (oConst, oType, oVar, oProc, oModule, oField, oCase, oBuiltin);

  PType = ^TType;
  PObj = ^TObj;
  PModule = ^TModule;
  PImport = ^TImport;
  PLib = ^TLib;

  TType = record
    form: TForm;
    size, align: int64;
    signed: boolean;   { fInt }
    vol: boolean;      { fPtr: ^VOLATILE }
    packd: boolean;    { fRecord }
    variadic: boolean; { fProc: ends in ... }
    tuple: boolean;    { fRecord: the results of a procedure that has several }
    base: PType;       { fPtr, fArray, fSlice: what it holds; fProc: result }
    len: int64;        { fArray: elements; fProc: parameters; fVariant: cases }
    fields: PObj;      { fRecord: fields; fVariant: cases; fProc: parameters }
    scope: longint;    { fRecord: the scope of its fields }
    fwd: longint;      { fPtr whose base isn't declared yet: its name, else -1 }
    obj: PObj;         { the declaration that names it, or nil }
    module: PModule;   { the module that built it }
  end;

  TObj = record
    cls: TClass;
    name: longint;
    exported: boolean;
    typ: PType;
    next: PObj;        { the next in its list: scope, fields, parameters }
    scope: longint;    { where it is declared }
    val: int64;        { oConst: value; oBuiltin: which; oCase: tag;
                         oField: offset; oVar: frame offset }
    chunk: longint;    { global oVar, oProc, string oConst: its chunk }
    lev: integer;      { oVar: 0 for a module variable, 1 for a local }
    ind: boolean;      { oVar: the frame slot holds the variable's address }
    off: int64;        { oVar with ind: added to that address }
    isVar: boolean;    { a var parameter }
    fwd: boolean;      { oProc: declared forward, no body yet }
    isCode: boolean;   { oProc: a code procedure }
    ext: boolean;      { oProc, oVar: C's, reached through its chunk, which
                         holds its address }
    fields: PObj;      { oCase: its fields }
    module: PModule;   { oModule: the module; others: where declared }
    link: PObj;        { the next top-level declaration of its module }
  end;

  { The arguments of a generic module's instance: a type, or a
    procedure (o) and its type. }
  TArgs = record
    n: longint;
    t: array[0..7] of PType;
    o: array[0..7] of PObj;
  end;

  TImport = record
    module: PModule;
    next: PImport;
  end;

  { A library a module links, by its name, as interned }
  TLib = record
    name: longint;
    next: PLib;
  end;

  TModule = record
    name: longint;
    sname: longint;      { the name of its symbols: List(I64) for an instance }
    args: TArgs;
    scope: longint;
    path: shortstring;
    first, last: PObj;   { its top-level declarations, in order }
    imports: PImport;
    body: longint;       { the chunk of its body, or -1 }
    done: boolean;       { compiled to the end }
    checkOnly: boolean;  { read only to check another file's interface }
    used: boolean;       { imported, through others, by the main module }
    usesC: boolean;      { has an extern, or links a library }
    linkStatic: boolean; { says link static }
    libs: PLib;          { the libraries it links }
    next: PModule;       { modules in the order they were finished }
  end;

const
  { built-in procedures }
  bSize = 0; bAdr = 1; bLen = 2; bNew = 3; bMsg = 4; bSyscall = 5;
  bFence = 6; bCas = 7; bXchg = 8; bXadd = 9; bArgc = 10; bArgv = 11;
  bInc = 12; bDec = 13;

  MaxDepth = 64;   { scopes open at once }

var
  tI8, tI16, tI32, tI64, tU8, tU16, tU32, tU64: PType;
  tBool, tReal, tError, tConst, tNil, tStr, tNone, tPtrU8, tBytes: PType;
  curModule: PModule;

function NewType(form: TForm; size, align: int64): PType;
function NewObj(cls: TClass; name: longint; typ: PType): PObj;
function NewScope: longint;
procedure OpenScope(s: longint);
procedure CloseScope;
function TopScope: longint;
procedure SaveScopes(var d: longint; var saved: array of longint);
procedure RestoreScopes(d: longint; const saved: array of longint);
procedure Insert(obj: PObj; s: longint);
function Find(s, name: longint): PObj;
function Lookup(name: longint): PObj;

function AlignUp(x, a: int64): int64;
function Same(a, b: PType): boolean;
function IsInt(t: PType): boolean;
function IsScalar(t: PType): boolean;
function IsAggregate(t: PType): boolean;
function Fits(v: int64; t: PType): boolean;
function TypeName(t: PType): shortstring;
function Fingerprint(o: PObj): qword;

implementation

type
  PObjTab = ^TObjTab;
  TObjTab = array[0..MaxInt div 16] of PObj;

var
  scopes: array[0..MaxDepth - 1] of longint;
  depth: longint;
  nextScope: longint;
  hashTab: PObjTab;
  hashMask, hashCount: longint;

function NewType(form: TForm; size, align: int64): PType;
var t: PType;
begin
  New(t);
  FillChar(t^, SizeOf(TType), 0);
  t^.form := form;
  t^.size := size;
  t^.align := align;
  t^.fwd := -1;
  t^.module := curModule;
  NewType := t;
end;

function NewObj(cls: TClass; name: longint; typ: PType): PObj;
var o: PObj;
begin
  New(o);
  FillChar(o^, SizeOf(TObj), 0);
  o^.cls := cls;
  o^.name := name;
  o^.typ := typ;
  o^.chunk := -1;
  o^.module := curModule;
  NewObj := o;
end;

{ Scopes }

function NewScope: longint;
begin
  inc(nextScope);
  NewScope := nextScope;
end;

procedure OpenScope(s: longint);
begin
  if depth = MaxDepth then Mark('nested too deeply');
  scopes[depth] := s;
  inc(depth);
end;

procedure CloseScope;
begin
  dec(depth);
end;

{ An imported module is compiled in the middle of another, and must
  see only the universe and itself. }
procedure SaveScopes(var d: longint; var saved: array of longint);
var i: longint;
begin
  d := depth;
  for i := 0 to depth - 1 do saved[i] := scopes[i];
  depth := 1;
end;

procedure RestoreScopes(d: longint; const saved: array of longint);
var i: longint;
begin
  depth := d;
  for i := 0 to depth - 1 do scopes[i] := saved[i];
end;

function TopScope: longint;
begin
  TopScope := scopes[depth - 1];
end;

function Slot(s, name: longint): longint;
begin
  Slot := longint((longword(s) * 2654435761 xor longword(name) * 40503) and longword(hashMask));
end;

procedure Rehash;
var old: PObjTab; n, i, j: longint;
begin
  old := hashTab;
  n := hashMask + 1;
  hashMask := n * 2 - 1;
  hashTab := GetMem(n * 2 * SizeOf(PObj));
  FillChar(hashTab^, n * 2 * SizeOf(PObj), 0);
  for i := 0 to n - 1 do
    if old^[i] <> nil then begin
      j := Slot(old^[i]^.scope, old^[i]^.name);
      while hashTab^[j] <> nil do j := (j + 1) and hashMask;
      hashTab^[j] := old^[i];
    end;
  FreeMem(old);
end;

procedure Insert(obj: PObj; s: longint);
var i: longint; o: PObj;
begin
  i := Slot(s, obj^.name);
  o := hashTab^[i];
  while o <> nil do begin
    if (o^.scope = s) and (o^.name = obj^.name) then
      Mark(NameOf(obj^.name) + ' is declared twice');
    i := (i + 1) and hashMask;
    o := hashTab^[i];
  end;
  obj^.scope := s;
  hashTab^[i] := obj;
  inc(hashCount);
  if hashCount * 2 > hashMask then Rehash;
end;

function Find(s, name: longint): PObj;
var i: longint; o: PObj;
begin
  i := Slot(s, name);
  o := hashTab^[i];
  while o <> nil do begin
    if (o^.scope = s) and (o^.name = name) then exit(o);
    i := (i + 1) and hashMask;
    o := hashTab^[i];
  end;
  Find := nil;
end;

function Lookup(name: longint): PObj;
var i: longint; o: PObj;
begin
  for i := depth - 1 downto 0 do begin
    o := Find(scopes[i], name);
    if o <> nil then exit(o);
  end;
  Lookup := nil;
end;

{ Types }

function AlignUp(x, a: int64): int64;
begin
  AlignUp := (x + a - 1) div a * a;
end;

function IsInt(t: PType): boolean;
begin
  IsInt := t^.form in [fInt, fConst];
end;

function IsScalar(t: PType): boolean;
begin
  IsScalar := t^.form in [fBool, fInt, fReal, fConst, fNil, fPtr, fProc,
    fEnum, fSet, fError];
end;

function IsAggregate(t: PType): boolean;
begin
  IsAggregate := t^.form in [fArray, fSlice, fRecord, fVariant];
end;

function Fits(v: int64; t: PType): boolean;
begin
  if t^.form <> fInt then exit(t^.form = fConst);
  case t^.size of
    1: if t^.signed then Fits := (v >= -128) and (v <= 127)
       else Fits := (v >= 0) and (v <= 255);
    2: if t^.signed then Fits := (v >= -32768) and (v <= 32767)
       else Fits := (v >= 0) and (v <= 65535);
    4: if t^.signed then Fits := (v >= -2147483648) and (v <= 2147483647)
       else Fits := (v >= 0) and (v <= 4294967295);
  else Fits := t^.signed or (v >= 0);
  end;
end;

{ Structural sameness of two types. Named types are the same only if
  they are one declaration; a type with no name is the same as another
  built alike. }
function Alike(a, b: PType): boolean;
var p, q: PObj;
begin
  if a = b then exit(true);
  if a^.form <> b^.form then exit(false);
  case a^.form of
    fPtr: Alike := (a^.vol = b^.vol) and Same(a^.base, b^.base);
    fArray: Alike := (a^.len = b^.len) and Same(a^.base, b^.base);
    fSlice, fSet: Alike := Same(a^.base, b^.base);
    fProc, fRecord: begin
      { a record is the same only as itself, but for several results }
      if (a^.form = fRecord) and not (a^.tuple and b^.tuple) then exit(false);
      if (a^.len <> b^.len) or (a^.variadic <> b^.variadic) then exit(false);
      if (a^.base = nil) <> (b^.base = nil) then exit(false);
      if (a^.base <> nil) and not Same(a^.base, b^.base) then exit(false);
      p := a^.fields; q := b^.fields;
      while p <> nil do begin
        if (p^.isVar <> q^.isVar) or not Same(p^.typ, q^.typ) then exit(false);
        p := p^.next; q := q^.next;
      end;
      Alike := true;
    end;
  else Alike := false;
  end;
end;

function Same(a, b: PType): boolean;
begin
  if a = b then exit(true);
  if (a = nil) or (b = nil) then exit(false);
  if (a^.obj <> nil) and (b^.obj <> nil) then exit(false);
  Same := Alike(a, b);
end;

function TypeName(t: PType): shortstring;
var s: shortstring;
begin
  if t = nil then exit('nothing');
  if t^.obj <> nil then begin
    if (t^.obj^.module <> nil) and (t^.obj^.module <> curModule) then
      exit(NameOf(t^.obj^.module^.sname) + '.' + NameOf(t^.obj^.name));
    exit(NameOf(t^.obj^.name));
  end;
  case t^.form of
    fConst: TypeName := 'an integer constant';
    fNil: TypeName := 'nil';
    fStr: TypeName := 'a string';
    fPtr: if t^.vol then TypeName := '^VOLATILE ' + TypeName(t^.base)
          else TypeName := '^' + TypeName(t^.base);
    fArray: begin Str(t^.len, s); TypeName := '[' + s + ']' + TypeName(t^.base) end;
    fSlice: TypeName := '[]' + TypeName(t^.base);
    fRecord: TypeName := 'record';
    fVariant: TypeName := 'variant';
    fProc: TypeName := 'proc';
  else TypeName := '?';
  end;
end;

{ A fingerprint of what a declaration exports, for the interface
  check: two files of one module export the same thing when their
  fingerprints agree. A named type counts by its name, so that a type
  declared in each file stands for the other's. }
procedure Mix(var h: qword; v: int64);
begin
  h := (h xor qword(v)) * 1099511628211;
end;

procedure Shape(var h: qword; t: PType; top: boolean);
var f, g: PObj;
begin
  if t = nil then begin Mix(h, -1); exit end;
  if (t^.obj <> nil) and not top then begin
    Mix(h, t^.obj^.name);
    if t^.obj^.module <> nil then Mix(h, t^.obj^.module^.sname);
    exit;
  end;
  Mix(h, ord(t^.form));
  Mix(h, ord(t^.vol) + 2 * ord(t^.variadic));
  Mix(h, t^.len);
  if t^.form in [fPtr, fArray, fSlice, fProc, fSet] then Shape(h, t^.base, false);
  f := t^.fields;
  while f <> nil do begin
    if (t^.form <> fRecord) or f^.exported then begin
      Mix(h, f^.name);
      Mix(h, ord(f^.isVar));
      Shape(h, f^.typ, false);
      g := f^.fields;
      while g <> nil do begin Shape(h, g^.typ, false); g := g^.next end;
    end;
    f := f^.next;
  end;
end;

function Fingerprint(o: PObj): qword;
var h: qword; f: PObj;
begin
  h := 14695981039346656037;
  Mix(h, ord(o^.cls));
  if o^.cls = oCase then begin
    Mix(h, o^.val);
    f := o^.fields;
    while f <> nil do begin Shape(h, f^.typ, false); f := f^.next end;
  end else Shape(h, o^.typ, o^.cls = oType);
  Fingerprint := h;
end;

{ The universe }

function Basic(const name: shortstring; form: TForm; size: int64; signed: boolean): PType;
var t: PType; o: PObj;
begin
  t := NewType(form, size, size);
  t^.signed := signed;
  o := NewObj(oType, Intern(@name[1], length(name)), t);
  o^.exported := true;
  t^.obj := o;
  Insert(o, 0);
  Basic := t;
end;

procedure Enter(const name: shortstring; cls: TClass; t: PType; v: int64);
var o: PObj;
begin
  o := NewObj(cls, Intern(@name[1], length(name)), t);
  o^.val := v;
  o^.exported := true;
  Insert(o, 0);
end;

initialization
  hashMask := (1 shl 14) - 1;
  hashTab := GetMem((hashMask + 1) * SizeOf(PObj));
  FillChar(hashTab^, (hashMask + 1) * SizeOf(PObj), 0);
  depth := 1;
  scopes[0] := 0;
  nextScope := 0;
  curModule := nil;
  tI8 := Basic('I8', fInt, 1, true);
  tI16 := Basic('I16', fInt, 2, true);
  tI32 := Basic('I32', fInt, 4, true);
  tI64 := Basic('I64', fInt, 8, true);
  tU8 := Basic('U8', fInt, 1, false);
  tU16 := Basic('U16', fInt, 2, false);
  tU32 := Basic('U32', fInt, 4, false);
  tU64 := Basic('U64', fInt, 8, false);
  tBool := Basic('BOOL', fBool, 1, false);
  tReal := Basic('F64', fReal, 8, false);
  tError := Basic('ERROR', fError, 8, false);
  tConst := NewType(fConst, 8, 8);
  tConst^.signed := true;
  tNil := NewType(fNil, 8, 8);
  tStr := NewType(fStr, 0, 1);
  tNone := NewType(fNone, 0, 1);
  tPtrU8 := NewType(fPtr, 8, 8);
  tPtrU8^.base := tU8;
  tBytes := NewType(fSlice, 16, 8);
  tBytes^.base := tU8;
  Enter('true', oConst, tBool, 1);
  Enter('false', oConst, tBool, 0);
  Enter('nil', oConst, tNil, 0);
  Enter('SIZE', oBuiltin, nil, bSize);
  Enter('ADR', oBuiltin, nil, bAdr);
  Enter('LEN', oBuiltin, nil, bLen);
  Enter('NEW', oBuiltin, nil, bNew);
  Enter('MSG', oBuiltin, nil, bMsg);
  Enter('SYSCALL', oBuiltin, nil, bSyscall);
  Enter('FENCE', oBuiltin, nil, bFence);
  Enter('CAS', oBuiltin, nil, bCas);
  Enter('XCHG', oBuiltin, nil, bXchg);
  Enter('XADD', oBuiltin, nil, bXadd);
  Enter('ARGC', oBuiltin, nil, bArgc);
  Enter('ARGV', oBuiltin, nil, bArgv);
  Enter('INC', oBuiltin, nil, bInc);
  Enter('DEC', oBuiltin, nil, bDec);
end.
