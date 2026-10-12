{ item.pas: operands, their types, and what they mean.

  The parser describes each operand as an item (TItem), as in Wirth's
  compilers: a constant, a variable at an address it can name, a value
  on gen's stack, a procedure, a string. The routines here check the
  items' types, fold constants, and have gen.pas make the code, as calls
  of its stack machine; nothing here knows the machine.

  Depends on: scan for errors, sym for types, chunk for data, gen for
  code.
  Leaves out: the language's syntax, which is parse.pas; the machine,
  which is gen.pas. }

unit item;

{$mode objfpc}{$H-}

interface

uses scan, diag, sym, chunk, gen;

type
  TMode = (mConst, mVar, mStack, mProc, mType, mStr, mBuiltin, mCase, mNone, mCond,
           mWords);   { two results of a call, on the stack, the first under the second }

  TItem = record
    mode: TMode;
    typ: PType;
    rel: TSym;          { mCond: the comparison of the two integers on
                          the stack, not yet made, as Wirth's compilers
                          keep a condition }
    relSigned: boolean;
    fj, tj: longint;    { mCond: the jumps taken where it is false, and
                          where it is true, to land past it }
    val: int64;        { mConst: the value, an F64's bits; mStr: its length }
    base: TBase;       { mVar: what the address is relative to }
    chunk: longint;    { mVar with bGlobal, mStr: the chunk; bSlot: the slot }
    off: int64;        { mVar: added to the base }
    vol: boolean;      { mVar: reached through ^VOLATILE }
    isVar: boolean;    { mVar: a variable of the program, not a temporary }
    odd: boolean;      { mVar: in a packed record, so maybe misaligned }
    ro: boolean;       { mVar: another module's exported variable, or part
                         of one, which only that module changes }
    deref: boolean;    { mVar: at an address from a pointer, which may be
                         nil and isn't tested yet (NilTest) }
    obj: PObj;         { mProc, mBuiltin, mCase; mVar: the variable named }
    pos: TPos;         { where it is in the source, for messages }
  end;

var
  demoted: boolean;    { Address wanted a register variable's address }
  checks: boolean;     { the module's index and slice checks are made: it
                         doesn't say check off }

procedure MakeConst(var x: TItem; t: PType; v: int64);
function What(const x: TItem): shortstring;
procedure MakeReal(var x: TItem; r: double);
procedure MakeStr(var x: TItem);
procedure MakeItem(var x: TItem; o: PObj);
function RealOf(const x: TItem): double;
function FrameAdr(off: int64): TAdr;
function GlobalAdr(c: longint): TAdr;
function AdrOf(const x: TItem): TAdr;

procedure UsesReals(const p: TPos);
procedure Value(var x: TItem);
procedure Address(var x: TItem);
procedure Discard(const x: TItem);
procedure NilTest(var x: TItem);
procedure Coerce(var x: TItem; t: PType);
procedure CoerceExact(var x: TItem; t: PType; const help: shortstring);
procedure NotReadOnly(const x: TItem);
procedure Assign(var dst, src: TItem);
procedure CopyToTemp(var x: TItem);
function ToSlot(var x: TItem): int64;

procedure Deref(var x: TItem);
procedure Field(var x: TItem; f: PObj);
procedure IndexPrep(var x: TItem);
procedure Index(var x, y: TItem);
procedure SliceLo(var lo: TItem);
procedure Slice(var x, lo, hi: TItem);

procedure Neg(var x: TItem);
procedure NotOp(var x: TItem);
procedure Complement(var x: TItem);
procedure Op1(op: TSym; var x: TItem; var L: longint);
procedure Op2(op: TSym; var x, y: TItem; L: longint);
function IsWord(t: PType): boolean;
procedure Convert(var x: TItem; t: PType);

procedure BeginCall(var c: TCall; var x: TItem);
procedure PassArg(var c: TCall; var a: TItem);
procedure EndCall(var c: TCall; var x: TItem);

procedure ZeroTemp(var x: TItem; t: PType);
procedure Construct(var x: TItem; c: PObj);
procedure SetField(const x: TItem; f: PObj; var a: TItem);
function MatchBegin(var x: TItem): int64;
procedure MatchTag(p: int64; tag: int64; var L: longint; isEnum: boolean);
procedure MatchRange(p, lo, hi: int64; var body: longint);
procedure CondJump(var x: TItem; var L: longint);
procedure CondJumpTrue(var x: TItem; var L: longint);

procedure SliceOf(var x: TItem; t: PType; len: int64);
procedure TempItem(var x: TItem; t: PType; off: int64);
function ScalarSize(t: PType): longint;
procedure ForStep(o: PObj; step: int64);
procedure ForCmp(o: PObj; const lim: TItem; op: TSym; var L: longint);
procedure ForNext(o: PObj; const lim: TItem; step: int64; var exitL: longint; top, body: longint);

procedure BeginProc(sig: PType; params: PObj);
procedure ReturnValue(var x: TItem);
procedure ReturnField(f: PObj; var x: TItem);
procedure ReturnAll(var x: TItem);
procedure ReturnNone;
procedure Pin(var x: TItem);
procedure IncDec(var v, k: TItem; dec: boolean);
procedure CopyDest(var d: TItem);
procedure CopyFrom(var d, s: TItem);
procedure Msg(var x: TItem);
function ErrorChunk(var x: TItem; module, name: longint): longint;

implementation

const
  { the comparison that holds when op doesn't, for integers }
  Negated: array[sEql..sGeq] of TSym = (sNeq, sEql, sGeq, sGtr, sLeq, sLss);

var
  result: PType;   { the result of the procedure being compiled, or nil }

{ Items }

procedure MakeConst(var x: TItem; t: PType; v: int64);
var p: TPos;
begin
  p := x.pos;
  FillChar(x, SizeOf(x), 0);
  x.pos := p;
  x.mode := mConst;
  x.typ := t;
  x.val := v;
end;

{ A real constant: untyped, unless typed later. Its value is an F64,
  which for an F32 is one an F32 can hold. }
procedure MakeReal(var x: TItem; r: double);
begin
  MakeConst(x, tRConst, 0);
  Move(r, x.val, 8);
end;

function IsF32(t: PType): boolean;
begin
  IsF32 := (t^.form = fReal) and (t^.size = 4);
end;

{ Gives a real constant the real type t, rounded to it. }
procedure RealTo(var x: TItem; t: PType);
var r: double;
begin
  r := RealOf(x);
  if IsF32(t) then MakeReal(x, single(r)) else MakeReal(x, r);
  x.typ := t;
end;

function RealOf(const x: TItem): double;
var r: double;
begin
  Move(x.val, r, 8);
  RealOf := r;
end;

{ The current string literal, as an item of its own chunk. }
procedure MakeStr(var x: TItem);
begin
  FillChar(x, SizeOf(x), 0);
  x.mode := mStr;
  x.typ := tStr;
  x.val := slen;
  x.chunk := NewChunk(secRodata, -1, -1);
  SetData(x.chunk, @sbuf, slen + 1, 1);
end;

function FrameAdr(off: int64): TAdr;
begin
  FrameAdr.base := bFrame;
  FrameAdr.chunk := -1;
  FrameAdr.off := off;
end;

function GlobalAdr(c: longint): TAdr;
begin
  GlobalAdr.base := bGlobal;
  GlobalAdr.chunk := c;
  GlobalAdr.off := 0;
end;

{ Where the variable x is, for gen }
function AdrOf(const x: TItem): TAdr;
begin
  AdrOf.base := x.base;
  AdrOf.chunk := x.chunk;
  AdrOf.off := x.off;
end;

{ An item for "found ...": a constant without a type of its own as it
  is written, so that "found 1.5" says what is wrong; else its type. }
function What(const x: TItem): shortstring;
begin
  if (x.mode = mConst) and ((x.typ = tConst) or (x.typ = tRConst)) then What := Source(x.pos)
  else What := TypeName(x.typ);
end;

{ Two operands of different types. Numbers convert, so say how. }
procedure Mismatch(const x, y: TItem; xt, yt: PType);
var msg: shortstring;
begin
  msg := TypeName(xt) + ' and ' + TypeName(yt) + ' are different types';
  if (IsInt(xt) or (xt^.form = fReal)) and (IsInt(yt) or (yt^.form = fReal))
    and (xt <> tConst) and (xt <> tRConst) then
    MarkHelp(Join(x.pos, y.pos), msg, 'convert one to the other''s type, as in ' + TypeName(xt) + '(' + Source(y.pos) + ')')
  else MarkAt(Join(x.pos, y.pos), msg);
end;

{ An item that is not a value, by what it is. }
procedure NotValue(const x: TItem);
begin
  case x.mode of
    mType: MarkAt(x.pos, TypeName(x.typ) + ' is a type, not a value');
    mBuiltin: MarkAt(x.pos, NameOf(x.obj^.name) + ' is a built-in procedure, not a value');
    mCase: MarkAt(x.pos, NameOf(x.obj^.name) + ' is a case, not a value');
    mNone:
      if x.obj <> nil then MarkAt(x.pos, NameOf(x.obj^.name) + ' returns nothing')
      else MarkAt(x.pos, 'the procedure returns nothing');
  else MarkAt(x.pos, 'a string can''t be an operand');
  end;
end;

procedure MakeItem(var x: TItem; o: PObj);
begin
  FillChar(x, SizeOf(x), 0);
  x.typ := o^.typ;
  x.obj := o;
  case o^.cls of
    oConst:
      if o^.typ = tStr then begin
        x.mode := mStr; x.val := o^.val; x.chunk := o^.chunk
      end else if o^.typ^.form in [fArray, fRecord] then begin
        { an array or record constant: a variable in read-only data, not one of
          the program's, so nothing can change it }
        x.mode := mVar; x.base := bGlobal; x.chunk := o^.chunk
      end else begin
        x.mode := mConst; x.val := o^.val
      end;
    oVar: begin
      x.mode := mVar;
      x.ro := (o^.lev = 0) and (o^.module <> curModule);
      x.isVar := not x.ro;
      if o^.ext then begin
        PushVar(GlobalAdr(o^.chunk), 8, false, kWord);
        x.base := bStack;
      end else if o^.lev = 0 then begin
        x.base := bGlobal; x.chunk := o^.chunk
      end else if o^.ind then begin
        x.base := bSlot; x.chunk := o^.val; x.off := o^.off;
      end else if o^.reg <> 0 then begin
        x.base := bReg; x.chunk := o^.reg
      end else begin
        x.base := bFrame; x.off := o^.val
      end;
    end;
    oProc: x.mode := mProc;
    oType: x.mode := mType;
    oBuiltin: x.mode := mBuiltin;
    oCase: x.mode := mCase;
  else Mark(NameOf(o^.name) + ' is not a value');
  end;
end;

function ScalarSize(t: PType): longint;
begin
  if t^.form in [fInt, fBool, fEnum, fSet, fReal] then ScalarSize := t^.size
  else ScalarSize := 8;
end;

{ The width an operation on t is brought back to, and whether signed }
function IntSize(t: PType): longint;
begin
  if t^.form = fInt then IntSize := t^.size else IntSize := 8;
end;

function Signed(t: PType): boolean;
begin
  Signed := ((t^.form = fInt) and t^.signed) or (t^.form = fConst);
end;

function Cut(v: int64; t: PType): int64;
begin
  Cut := v;
  if t^.form <> fInt then exit;
  case t^.size of
    1: if t^.signed then Cut := shortint(v) else Cut := byte(v);
    2: if t^.signed then Cut := smallint(v) else Cut := word(v);
    4: if t^.signed then Cut := longint(v) else Cut := longword(v);
  end;
end;

{ Code computing with a real is noted on its chunk, at the first place,
  for a target without reals (report 5.1) to refuse if the chunk turns
  out to be used. A real moved whole, as a record's bytes are copied,
  needs nothing the target lacks, and isn't noted. }
procedure UsesReals(const p: TPos);
begin
  if (codeChunk >= 0) and not chunks^[codeChunk].reals then begin
    chunks^[codeChunk].reals := true;
    chunks^[codeChunk].realsAt := p;
  end;
end;

{ x, at an address from a pointer, is about to be used: gen tests the
  address for nil where the machine wouldn't stop at it (report section
  10), from its offset to its end. }
procedure NilTest(var x: TItem);
begin
  if (x.mode = mVar) and x.deref then CheckNil(x.off + x.typ^.size, x.pos);
  x.deref := false;
end;

{ x's value, on top of the stack }
procedure Value(var x: TItem);
var f: single;
begin
  if x.mode = mCond then begin
    if (x.fj = NoLabel) and (x.tj = NoLabel) then Compare(x.rel, kWord, x.relSigned)
    else CondValue(Negated[x.rel], x.relSigned, x.fj, x.tj);
    x.mode := mStack;
    exit;
  end;
  if x.typ^.form = fReal then UsesReals(x.pos);
  NilTest(x);
  case x.mode of
    mConst:
      if (x.typ^.form = fError) and (x.val > 0) then PushAdr(GlobalAdr(x.val - 1))
      else if IsF32(x.typ) then begin
        f := RealOf(x);
        PushConst(kF32, PLongword(@f)^);
      end else PushConst(KindOf(x.typ), x.val);
    mVar: begin
      if not IsScalar(x.typ) then MarkAt(x.pos, 'expected a single value, found ' + What(x));
      PushVar(AdrOf(x), ScalarSize(x.typ), (x.typ^.form = fInt) and x.typ^.signed, KindOf(x.typ));
    end;
    mStack: ;
    mProc: begin
      if x.obj^.isCode and (x.obj^.typ^.base <> nil) and x.obj^.typ^.base^.tuple then
        MarkAt(x.pos, 'a code procedure with two results can only be called');
      PushProc(x.obj^.chunk, x.obj^.ext);
    end;
  else NotValue(x);
  end;
  x.mode := mStack;
end;

{ The address of the variable or string x, on top of the stack }
procedure Address(var x: TItem);
begin
  NilTest(x);
  if (x.mode = mVar) and (x.base = bReg) then begin
    { its address is wanted after all: the procedure is compiled again
      with the variable in memory; till then, this code is thrown away }
    x.obj^.reg := 0;
    demoted := true;
    x.base := bFrame;
    x.off := x.obj^.val;
  end;
  if x.mode = mStr then PushAdr(GlobalAdr(x.chunk))
  else if x.mode = mVar then begin
    PushAdr(AdrOf(x));
    x.base := bStack; x.off := 0;
  end else MarkAt(x.pos, 'expected a variable');
end;

{ x isn't wanted: what it has on the stack is dropped }
procedure Discard(const x: TItem);
var y: TItem;
begin
  if x.mode = mCond then begin y := x; Value(y); Drop; exit end;
  if (x.mode = mStack) or ((x.mode = mVar) and (x.base = bStack)) then Drop;
  if x.mode = mWords then begin Drop; Drop end;
end;

{ Frames }

procedure TempItem(var x: TItem; t: PType; off: int64);
var p: TPos;
begin
  p := x.pos;
  FillChar(x, SizeOf(x), 0);
  x.pos := p;
  x.mode := mVar; x.typ := t; x.base := bFrame; x.off := off;
end;

function ToSlot(var x: TItem): int64;
var s: int64;
begin
  Value(x);
  s := AllocTemp(8, 8);
  PopVar(FrameAdr(s), 8);
  ToSlot := s;
end;

{ Copying }

procedure CopyToTemp(var x: TItem);
var t: int64; f, g: PObj;
begin
  if x.vol then MarkAt(x.pos, 'can''t copy through a volatile pointer');
  t := AllocTemp(x.typ^.size, x.typ^.align);
  if x.mode = mWords then begin
    f := x.typ^.fields; g := f^.next;
    PopVar(FrameAdr(t + g^.val), ScalarSize(g^.typ));
    PopVar(FrameAdr(t + f^.val), ScalarSize(f^.typ));
    TempItem(x, x.typ, t);
    exit;
  end;
  Address(x);
  CopyTo(FrameAdr(t), x.typ^.size);
  TempItem(x, x.typ, t);
end;

{ A slice made from an address on the stack and a length. }
procedure SliceOf(var x: TItem; t: PType; len: int64);
var s: int64;
begin
  s := AllocTemp(16, 8);
  PopVar(FrameAdr(s), 8);
  PushConst(kWord, len);
  PopVar(FrameAdr(s + 8), 8);
  TempItem(x, t, s);
end;

{ An INT goes silently into an I64, and a UINT into a U64, losing
  nothing on any target (report section 5.10). }
function Widens(s, t: PType): boolean;
begin
  Widens := ((s = tInt) and Same(t, tI64)) or ((s = tUInt) and Same(t, tU64));
end;

{ Another module's exported variable can be read, not changed, nor
  handed to anything that could change it (report section 3). }
procedure NotReadOnly(const x: TItem);
begin
  if x.ro then MarkAt(x.pos, Source(x.pos) + ' is ' + NameOf(x.obj^.module^.name) + '''s, and can''t be changed outside it');
end;

var
  passing: PObj;     { the parameter the argument at passingAt goes to }
  passingAt: TPos;

{ An error in x's type; if x is an argument, a note at the parameter
  it goes to. }
procedure Mismatch(const x: TItem; const msg: shortstring);
begin
  Error(x.pos, msg);
  if (passing <> nil) and (x.pos.f = passingAt.f) and (x.pos.a = passingAt.a) and (x.pos.b = passingAt.b) then
    Note(passing^.pos, 'it goes to ' + NameOf(passing^.name) + ', declared here');
  Fail;
end;

procedure Coerce(var x: TItem; t: PType);
var s: PType; tmp: int64;
begin
  if x.mode = mCond then Value(x);
  s := x.typ;
  if x.mode = mStr then begin
    if (t^.form = fSlice) and (t^.base = tU8) then begin
      Address(x); SliceOf(x, t, x.val)
    end else if (t^.form = fPtr) and (t^.base = tU8) then begin
      Address(x); x.mode := mStack; x.typ := t
    end else if (t^.form = fArray) and (t^.base = tU8) and (t^.len >= x.val) then begin
      tmp := AllocTemp(t^.size, 1);
      Address(x);
      CopyTo(FrameAdr(tmp), x.val);
      if t^.len > x.val then ZeroVar(FrameAdr(tmp + x.val), t^.len - x.val);
      TempItem(x, t, tmp);
    end else Mismatch(x, 'can''t use a string as ' + TypeName(t));
    exit;
  end;
  if x.mode in [mType, mBuiltin, mNone, mCase] then NotValue(x);
  if Same(s, t) then exit;
  if Widens(s, t) then x.typ := t   { the same bits, on a 64-bit target }
  else if (s = tRConst) and (t^.form = fReal) then RealTo(x, t)
  else if (s^.form = fConst) and (t^.form = fInt) then begin
    if (x.mode = mConst) and not Fits(x.val, t) then MarkAt(x.pos, IntStr(x.val) + ' doesn''t fit ' + TypeName(t));
    x.typ := t;
  end else if (s^.form = fNil) and (t^.form in [fPtr, fProc, fError]) then
    x.typ := t
  else if (s^.form = fPtr) and (t^.form = fPtr) and t^.vol and not s^.vol
    and Same(s^.base, t^.base) then
    x.typ := t
  else if (s^.form = fArray) and (t^.form = fSlice) and Same(s^.base, t^.base) then begin
    NotReadOnly(x);
    if x.vol then MarkAt(x.pos, 'can''t make a slice through a volatile pointer');
    if x.odd then MarkAt(x.pos, 'can''t make a slice of a field of a packed record');
    Address(x);
    SliceOf(x, t, s^.len);
  end else if (x.mode = mProc) and (t^.form <> fProc) and (s^.base = nil) then
    MarkAt(x.pos, Source(x.pos) + ' is a procedure, and returns nothing')
  else if (x.mode = mProc) and (t^.form <> fProc) then
    MarkHelp(x.pos, 'can''t use ' + TypeName(s) + ' as ' + TypeName(t), 'to call it, write ' + Source(x.pos) + '()')
  else
    Mismatch(x, 'can''t use ' + TypeName(s) + ' as ' + TypeName(t));
end;

{ Coerce where the types must be the same, as in a for loop, INC and
  several results, which don't widen an INT to an I64 (report sections
  5.10, 6.1 and 7.2); help, if not empty, says why. }
procedure CoerceExact(var x: TItem; t: PType; const help: shortstring);
var h: shortstring;
begin
  if Widens(x.typ, t) then begin
    h := help;
    if h = '' then h := 'they don''t mix here: write ' + TypeName(t) + '(' + Source(x.pos) + ')';
    MarkHelp(x.pos, 'expected ' + TypeName(t) + ', found ' + What(x), h);
  end;
  Coerce(x, t);
end;

{ dst := src. The address of dst, if it has to be computed, is on the
  stack already, under src's. }
procedure Assign(var dst, src: TItem);
begin
  Coerce(src, dst.typ);
  if IsScalar(dst.typ) then begin
    Value(src);
    PopVar(AdrOf(dst), ScalarSize(dst.typ));
  end else begin
    if dst.vol or src.vol then MarkAt(src.pos, 'can''t copy through a volatile pointer');
    Address(src);
    if dst.base = bStack then CopyBlock(dst.typ^.size, dst.off)
    else CopyTo(AdrOf(dst), dst.typ^.size);
  end;
end;

{ t's name, ending in a zero byte, for Rt.fail }
function NameChunk(t: PType): longint;
var s: shortstring; c: longint;
begin
  s := TypeName(t) + #0;
  c := NewChunk(secRodata, -1, -1);
  SetData(c, @s[1], length(s), 1);
  NameChunk := c;
end;

{ Selectors }

procedure Deref(var x: TItem);
var t: PType;
begin
  t := x.typ;
  if t^.form <> fPtr then MarkAt(x.pos, 'expected a pointer, found ' + TypeName(t));
  if t^.base = nil then MarkAt(x.pos, TypeName(t) + ' points to a type never declared');
  Value(x);
  x.mode := mVar; x.base := bStack; x.off := 0; x.deref := true;
  x.typ := t^.base; x.vol := t^.vol; x.isVar := true; x.odd := false; x.ro := false;
end;

{ A field of a packed record, of more than one byte's alignment, may
  sit anywhere; it is read and written, but has no address and no
  volatile access, which a machine that can't reach a misaligned word
  couldn't make one access (report section 5.5). }
procedure Field(var x: TItem; f: PObj);
begin
  if x.typ^.packd and (f^.typ^.align > 1) then begin
    if x.vol then MarkAt(x.pos, 'a field of a packed record can''t be volatile');
    x.odd := true;
  end;
  x.off := x.off + f^.val;
  x.typ := f^.typ;
end;

procedure IndexPrep(var x: TItem);
begin
  NilTest(x);
  if x.mode = mStr then Coerce(x, tBytes);
  if (x.typ^.form = fPtr) and (x.typ^.base^.form = fArray) then
    MarkAt(x.pos, 'a pointer to an array is indexed as p^[i]');
  if x.typ^.form = fPtr then Value(x)
  else if not ((x.mode = mVar) and (x.typ^.form in [fArray, fSlice])) then
    MarkAt(x.pos, 'expected an array, a slice or a pointer, found ' + What(x));
end;

{ The index on top, times the size of an element }
procedure ScaleBy(s: int64);
begin
  if s <> 1 then begin
    PushConst(kWord, s);
    gen.Op(sTimes, kWord, 8, true);
  end;
end;

procedure Index(var x, y: TItem);
var t: PType; s: int64;
begin
  t := x.typ;
  s := t^.base^.size;
  if not IsInt(y.typ) then MarkAt(y.pos, 'an index is an integer, found ' + What(y));
  if t^.form = fPtr then begin
    Value(y);
    ScaleBy(s);
    gen.Op(sPlus, kWord, 8, false);
    x.mode := mVar; x.base := bStack; x.off := 0;
    x.vol := t^.vol; x.isVar := true; x.odd := false; x.ro := false;
  end else if (t^.form = fArray) and (y.mode = mConst) then begin
    if (y.val < 0) or (y.val >= t^.len) then MarkAt(y.pos, 'index ' + IntStr(y.val) + ' is out of range for a length of ' + IntStr(t^.len));
    x.off := x.off + y.val * s;
  end else if t^.form = fArray then begin
    Value(y);
    if checks then CheckIndex(t^.len, y.pos);
    ScaleBy(s);
    if x.base <> bStack then begin PushAdr(AdrOf(x)); x.off := 0 end;
    gen.Op(sPlus, kWord, 8, false);
    x.base := bStack;
  end else begin
    Value(y);
    IndexSlice(AdrOf(x), s, checks, y.pos);
    x.base := bStack; x.off := 0; x.isVar := true; x.vol := false; x.ro := false;
  end;
  x.typ := t^.base;
end;

procedure SliceLo(var lo: TItem);
begin
  if not IsInt(lo.typ) then MarkAt(lo.pos, 'an index is an integer, found ' + What(lo));
  Value(lo);
end;

procedure Slice(var x, lo, hi: TItem);
var t, st: PType; tmp: int64;
begin
  t := x.typ;
  if not IsInt(hi.typ) then MarkAt(hi.pos, 'an index is an integer, found ' + What(hi));
  if x.vol then MarkAt(x.pos, 'can''t make a slice through a volatile pointer');
  if x.odd then MarkAt(x.pos, 'can''t make a slice of a field of a packed record');
  if t^.form = fArray then NotReadOnly(x);
  Value(hi);
  tmp := AllocTemp(16, 8);
  if t^.form = fPtr then SlicePtr(t^.base^.size, tmp, checks, lo.pos)
  else gen.Slice(AdrOf(x), t^.form = fArray, t^.len, t^.base^.size, tmp, checks, lo.pos);
  st := NewType(fSlice, 16, 8);
  st^.base := t^.base;
  TempItem(x, st, tmp);
end;

{ Operators }

procedure Neg(var x: TItem);
begin
  if x.typ^.form = fReal then begin
    if x.mode = mConst then x.val := x.val xor low(int64)
    else begin Value(x); gen.Neg(KindOf(x.typ), 8, false) end;
  end else if IsInt(x.typ) then begin
    if (x.mode = mConst) and (x.typ^.form = fConst) and (x.val = low(int64)) then
      MarkAt(x.pos, 'the constant is too big for I64')
    else if x.mode = mConst then x.val := Cut(-x.val, x.typ)
    else begin Value(x); gen.Neg(kWord, IntSize(x.typ), Signed(x.typ)) end;
  end else MarkAt(x.pos, 'can''t negate ' + TypeName(x.typ));
end;

procedure NotOp(var x: TItem);
var L: longint;
begin
  if IsInt(x.typ) then MarkHelp(x.pos, '"not" needs a BOOL, found ' + What(x), 'the bits of an integer flip with ~');
  if x.typ^.form <> fBool then MarkAt(x.pos, '"not" needs a BOOL, found ' + What(x));
  if x.mode = mConst then x.val := 1 - x.val
  else if x.mode = mCond then begin
    x.rel := Negated[x.rel];
    L := x.fj; x.fj := x.tj; x.tj := L;
  end
  else begin Value(x); NotBool end;
end;

procedure Complement(var x: TItem);
begin
  if x.typ^.form = fBool then MarkHelp(x.pos, '"~" needs an integer, found ' + What(x), 'a BOOL is negated with not');
  if not IsInt(x.typ) then MarkAt(x.pos, '"~" needs an integer, found ' + What(x));
  if x.mode = mConst then x.val := Cut(not x.val, x.typ)
  else begin Value(x); gen.Complement(IntSize(x.typ), Signed(x.typ)) end;
end;

{ Arrays, slices and strings, which = and # compare element by element }
function IsSeq(t: PType): boolean;
begin
  IsSeq := t^.form in [fStr, fArray, fSlice];
end;

function ElemOf(t: PType): PType;
begin
  if t^.form = fStr then ElemOf := tU8 else ElemOf := t^.base;
end;

{ An array, slice or string as a slice in a temporary, for comparing. }
procedure SeqSlice(var x: TItem);
var t: PType;
begin
  t := NewType(fSlice, 16, 8);
  t^.base := ElemOf(x.typ);
  if x.typ^.form = fSlice then begin
    x.typ := t; CopyToTemp(x)
  end else begin
    if x.mode = mStr then begin Address(x); SliceOf(x, t, x.val) end
    else begin
      if x.vol then MarkAt(x.pos, 'can''t compare through a volatile pointer');
      Address(x); SliceOf(x, t, x.typ^.len)
    end;
  end;
end;

{ x, a BOOL, as a condition: a value compared with 0 if it isn't one }
procedure MakeCond(var x: TItem);
begin
  if x.mode = mCond then exit;
  Value(x);
  PushConst(kWord, 0);
  x.mode := mCond;
  x.rel := sNeq;
  x.relSigned := false;
  x.fj := NoLabel;
  x.tj := NoLabel;
end;

procedure Op1(op: TSym; var x: TItem; var L: longint);
begin
  L := NoLabel;
  if (op in [sAnd, sOr]) and (x.typ^.form = fBool) then begin
    if x.mode = mConst then exit;    { folded by Op2 }
    MakeCond(x);
    if op = sAnd then begin
      JumpOut(Negated[x.rel], x.relSigned, x.fj);
      Fix(x.tj);
      x.tj := NoLabel;
    end else begin
      JumpOut(x.rel, x.relSigned, x.tj);
      Fix(x.fj);
      x.fj := NoLabel;
    end;
  end else if (op in [sEql, sNeq]) and IsSeq(x.typ) then
    SeqSlice(x)
  else if (op = sPlus) and (x.mode = mStr) then
    { two string constants to be joined: nothing to compute }
  else if (op = sPlus) and IsSeq(x.typ) then
    MarkHelp(x.pos, '+ doesn''t join ' + What(x), 'strings are joined in a Buf: Buf.str(b, s)')
  else if x.mode in [mType, mBuiltin, mNone, mCase, mStr] then
    NotValue(x)
  else if x.mode <> mConst then
    Value(x);
end;

function Log2(v: int64): longint;
var n: longint;
begin
  n := 0;
  while (v > 1) and (v and 1 = 0) do begin v := v shr 1; inc(n) end;
  if v <> 1 then n := -1;
  Log2 := n;
end;

{ Whether a op b, for + - *, overflows an I64: an untyped constant
  doesn't wrap, it is an error (report section 4). }
function Overflows(op: TSym; a, b: int64): boolean;
begin
  case op of
    sPlus: Overflows := ((b > 0) and (a > high(int64) - b)) or ((b < 0) and (a < low(int64) - b));
    sMinus: Overflows := ((b < 0) and (a > high(int64) + b)) or ((b > 0) and (a < low(int64) + b));
    sTimes:
      if (a = 0) or (b = 0) then Overflows := false
      else if a = -1 then Overflows := b = low(int64)
      else if b = -1 then Overflows := a = low(int64)
      else Overflows := (a * b) div b <> a;
  else Overflows := false;
  end;
end;

{ A type's width in bits; an untyped constant's is an I64's }
function Bits(t: PType): longint;
begin
  Bits := t^.size * 8;
end;

function FoldInt(op: TSym; a, b: int64; t: PType; const p: TPos): int64;
var u: boolean;
begin
  u := (t^.form = fInt) and not t^.signed;
  if (t^.form = fConst) and Overflows(op, a, b) then MarkAt(p, 'the constant is too big for I64');
  case op of
    sPlus: FoldInt := a + b;
    sMinus: FoldInt := a - b;
    sTimes: FoldInt := a * b;
    sDiv, sMod: begin
      if b = 0 then MarkAt(p, 'division by zero');
      if u then begin
        if op = sDiv then FoldInt := int64(qword(a) div qword(b))
        else FoldInt := int64(qword(a) mod qword(b));
      end else if (b = -1) and (a = int64(-1) shl (Bits(t) - 1)) then MarkAt(p, 'division overflows')
      else if op = sDiv then FoldInt := a div b
      else FoldInt := a mod b;
    end;
    sAmp: FoldInt := a and b;
    sBar: FoldInt := a or b;
    sXor: FoldInt := a xor b;
    sShl: FoldInt := a shl (b and (Bits(t) - 1));
    sShr: if u then FoldInt := int64(qword(a) shr (b and (Bits(t) - 1)))
          else FoldInt := SarInt64(a, b and (Bits(t) - 1));
    sEql: FoldInt := ord(a = b);
    sNeq: FoldInt := ord(a <> b);
    sLss: if u then FoldInt := ord(qword(a) < qword(b)) else FoldInt := ord(a < b);
    sLeq: if u then FoldInt := ord(qword(a) <= qword(b)) else FoldInt := ord(a <= b);
    sGtr: if u then FoldInt := ord(qword(a) > qword(b)) else FoldInt := ord(a > b);
    sGeq: if u then FoldInt := ord(qword(a) >= qword(b)) else FoldInt := ord(a >= b);
  else MarkAt(p, 'bad operator'); FoldInt := 0;
  end;
end;

{ Folds x op y, of the real type t: an F32 rounded at each step, as
  the machine would. }
function FoldReal(op: TSym; const x, y: TItem; t: PType; var r: TItem): boolean;
var a, b: double;
begin
  a := RealOf(x); b := RealOf(y);
  FoldReal := true;
  case op of
    sPlus: MakeReal(r, a + b);
    sMinus: MakeReal(r, a - b);
    sTimes: MakeReal(r, a * b);
    sSlash: MakeReal(r, a / b);
    sEql: MakeConst(r, tBool, ord(a = b));
    sNeq: MakeConst(r, tBool, ord(a <> b));
    sLss: MakeConst(r, tBool, ord(a < b));
    sLeq: MakeConst(r, tBool, ord(a <= b));
    sGtr: MakeConst(r, tBool, ord(a > b));
    sGeq: MakeConst(r, tBool, ord(a >= b));
  else FoldReal := false;
  end;
  if r.typ^.form = fReal then RealTo(r, t);
end;

{ and, or and not are for BOOLs; &, |, xor and ~ for the bits of
  integers: x is the wrong kind for op, and the message names the
  operator it may have meant }
procedure WrongLogic(op: TSym; var x: TItem);
const Bits = 'the bits of integers take ';
begin
  case op of
    sAnd: if IsInt(x.typ) then MarkHelp(x.pos, '"and" needs BOOLs, found ' + What(x), Bits + '&');
    sOr: if IsInt(x.typ) then MarkHelp(x.pos, '"or" needs BOOLs, found ' + What(x), Bits + '|');
    sAmp: MarkHelp(x.pos, '"&" needs integers, found ' + What(x), 'BOOLs take and');
    sBar: MarkHelp(x.pos, '"|" needs integers, found ' + What(x), 'BOOLs take or');
    sXor: MarkHelp(x.pos, '"xor" needs integers, found ' + What(x), 'BOOLs that differ are #');
  end;
  MarkAt(x.pos, SymText(op) + ' needs BOOLs, found ' + What(x));
end;

{ x + y, of two string constants: one string, in a chunk of its own
  (report section 4) }
procedure JoinStr(var x, y: TItem);
var p: PBytes; c: longint;
begin
  if y.mode <> mStr then MarkAt(y.pos, '"+" joins two strings, found ' + What(y));
  p := GetMem(x.val + y.val + 1);
  Move(rodata^[chunks^[x.chunk].start], p^[0], x.val);
  Move(rodata^[chunks^[y.chunk].start], p^[x.val], y.val + 1);
  c := NewChunk(secRodata, -1, -1);
  SetData(c, p, x.val + y.val + 1, 1);
  FreeMem(p);
  x.chunk := c;
  x.val := x.val + y.val;
end;

{ A set's operations, as operations on its bits: the two values on top }
procedure SetOp(op: TSym);
begin
  case op of
    sPlus: gen.Op(sBar, kWord, 8, false);
    sTimes: gen.Op(sAmp, kWord, 8, false);
    sMinus: begin gen.Complement(8, false); gen.Op(sAmp, kWord, 8, false) end;
    sLeq, sGeq: begin
      { x <= y has no bit of x outside y }
      if op = sGeq then Swap;
      gen.Complement(8, false);
      gen.Op(sAmp, kWord, 8, false);
      PushConst(kWord, 0);
      Compare(sEql, kWord, false);
    end;
    sIn: begin
      Swap;
      gen.Op(sShr, kWord, 8, false);
      PushConst(kWord, 1);
      gen.Op(sAmp, kWord, 8, false);
    end;
  else Compare(op, kWord, false);
  end;
end;

procedure Op2(op: TSym; var x, y: TItem; L: longint);
const
  Rel = [sEql, sNeq, sLss, sLeq, sGtr, sGeq];
var
  xt, yt, t, e: PType; r: TItem; scale: longint; isPtr: boolean; a, b: int64;
begin
  xt := x.typ; yt := y.typ;
  if y.mode in [mType, mBuiltin, mNone, mCase] then NotValue(y);
  if (op = sPlus) and (x.mode = mStr) then begin JoinStr(x, y); exit end;

  if op in [sAnd, sOr] then begin
    if xt^.form <> fBool then WrongLogic(op, x);
    if yt^.form <> fBool then WrongLogic(op, y);
    if (x.mode = mConst) and (y.mode = mConst) then begin
      if op = sAnd then x.val := x.val and y.val else x.val := x.val or y.val;
    end else if x.mode = mConst then begin
      { true and y, false or y: y; else x, y computed and dropped }
      if (x.val = 1) = (op = sAnd) then x := y
      else Discard(y);
    end else begin
      MakeCond(y);
      if op = sAnd then begin x.fj := JoinJumps(x.fj, y.fj); x.tj := y.tj end
      else begin x.tj := JoinJumps(x.tj, y.tj); x.fj := y.fj end;
      x.rel := y.rel;
      x.relSigned := y.relSigned;
    end;
    exit;
  end;

  if (op in [sAmp, sBar, sXor]) and (xt^.form = fBool) then WrongLogic(op, x);
  if (op in [sAmp, sBar, sXor]) and (yt^.form = fBool) then WrongLogic(op, y);

  { the lengths, then the bytes, LEN * SIZE(T) of them: the elements
    are of types whose bytes say all there is to their values }
  if (op in [sEql, sNeq]) and IsSeq(xt) then begin
    e := ElemOf(xt);
    if not IsSeq(yt) then
      MarkAt(Join(x.pos, y.pos), 'can''t compare an array with ' + TypeName(yt))
    else if not Same(e, ElemOf(yt)) then
      MarkAt(Join(x.pos, y.pos), 'can''t compare an array of ' + TypeName(e) + ' with one of ' + TypeName(ElemOf(yt)));
    if e^.form = fReal then
      MarkHelp(Join(x.pos, y.pos), 'can''t compare arrays of reals with ' + SymText(op),
        '-0.0 = 0.0 and a NaN equals nothing, though their bytes say otherwise: write a loop')
    else if not (e^.form in [fInt, fBool, fEnum, fSet, fPtr]) then
      MarkHelp(Join(x.pos, y.pos), 'can''t compare arrays of ' + TypeName(e) + ' with ' + SymText(op), 'write a loop');
    SeqSlice(y);
    CompareSeq(x.off, y.off, Log2(e^.size), op = sEql);
    MakeConst(x, tBool, 0);
    x.mode := mStack;
    exit;
  end;

  { the type of the result, and the checks }
  t := nil; scale := 1; isPtr := false;
  if IsInt(xt) and IsInt(yt) then begin
    if op = sSlash then MarkHelp(Join(x.pos, y.pos), '"/" divides reals, not integers', 'to divide integers, write ' + Source(x.pos) + ' div ' + Source(y.pos));
    if op in [sShl, sShr] then begin
      if xt^.form = fConst then t := tConst else t := xt
    end else if (xt^.form = fConst) and (yt^.form = fConst) then t := tConst
    else if xt^.form = fConst then begin
      if (x.mode = mConst) and not Fits(x.val, yt) then MarkAt(x.pos, IntStr(x.val) + ' doesn''t fit ' + TypeName(yt));
      t := yt
    end else if yt^.form = fConst then begin
      if (y.mode = mConst) and not Fits(y.val, xt) then MarkAt(y.pos, IntStr(y.val) + ' doesn''t fit ' + TypeName(xt));
      t := xt
    end else if Same(xt, yt) then t := xt
    else Mismatch(x, y, xt, yt);
    if not (op in Rel + [sPlus, sMinus, sTimes, sDiv, sMod, sAmp, sBar, sXor, sShl, sShr]) then
      MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(t));
  end else if (xt^.form = fReal) and (yt^.form = fReal) then begin
    if not (op in Rel + [sPlus, sMinus, sTimes, sSlash]) then MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(xt));
    if xt = tRConst then t := yt
    else if (yt = tRConst) or Same(xt, yt) then t := xt
    else Mismatch(x, y, xt, yt);
    if (x.mode = mConst) and (x.typ <> t) then RealTo(x, t);
    if (y.mode = mConst) and (y.typ <> t) then RealTo(y, t);
  end else if (xt^.form = fBool) and (yt^.form = fBool) then begin
    if not (op in [sEql, sNeq]) then MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(xt));
    t := tBool;
  end else if (xt^.form = fPtr) and IsInt(yt) and (op in [sPlus, sMinus]) then begin
    t := xt; scale := xt^.base^.size; isPtr := true;
    if y.mode = mConst then y.typ := tInt;
  end else if (xt^.form = fPtr) and (yt^.form = fPtr) and (op = sMinus) then begin
    if not Same(xt, yt) then Mismatch(x, y, xt, yt);
    t := tInt; scale := xt^.base^.size; isPtr := true;
  end else if (xt^.form in [fPtr, fProc, fNil, fError]) and (yt^.form in [fPtr, fProc, fNil, fError]) then begin
    if not (op in Rel) then MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(xt));
    if (xt^.form in [fProc, fError]) or (yt^.form in [fProc, fError]) then
      if not (op in [sEql, sNeq]) then MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(xt));
    if (xt^.form <> fNil) and (yt^.form <> fNil) and not Same(xt, yt) then
      if not ((xt^.form = fPtr) and (yt^.form = fPtr) and Same(xt^.base, yt^.base)) then
        Mismatch(x, y, xt, yt);
    t := tU64;
  end else if (xt^.form = fEnum) and Same(xt, yt) then begin
    if not (op in Rel) then MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(xt));
    t := xt;
  end else if (xt^.form = fSet) and Same(xt, yt) then begin
    if not (op in [sPlus, sTimes, sMinus, sEql, sNeq, sLeq, sGeq]) then MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(xt));
    t := xt;
  end else if (op = sIn) and (yt^.form = fSet) and Same(xt, yt^.base) then
    t := yt
  else
    Mismatch(x, y, xt, yt);

  { constants }
  if (x.mode = mConst) and (y.mode = mConst) and not isPtr then begin
    if t^.form = fReal then begin
      if not FoldReal(op, x, y, t, r) then MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(xt));
      x := r;
    end else if t^.form = fSet then begin
      a := x.val; b := y.val;
      case op of
        sPlus: MakeConst(x, t, a or b);
        sTimes: MakeConst(x, t, a and b);
        sMinus: MakeConst(x, t, a and not b);
        sIn: MakeConst(x, tBool, (b shr a) and 1);
        sLeq: MakeConst(x, tBool, ord(a and not b = 0));
        sGeq: MakeConst(x, tBool, ord(b and not a = 0));
      else MakeConst(x, tBool, ord((a = b) = (op = sEql)));
      end;
    end else if op in Rel then
      MakeConst(x, tBool, FoldInt(op, x.val, y.val, t, Join(x.pos, y.pos)))
    else
      MakeConst(x, t, Cut(FoldInt(op, x.val, y.val, t, Join(x.pos, y.pos)), t));
    exit;
  end;

  { x and y on the stack, x under y; a constant x goes on after y }
  Value(y);
  if x.mode = mConst then begin Value(x); Swap end;

  if t^.form = fReal then begin
    if op in Rel then Compare(op, KindOf(t), false) else gen.Op(op, KindOf(t), 8, false)
  end else if t^.form = fSet then
    SetOp(op)
  else if op in Rel then begin
    x.mode := mCond;
    x.rel := op;
    x.relSigned := Signed(t);
    x.fj := NoLabel;
    x.tj := NoLabel;
    x.typ := tBool;
    exit;
  end
  else if isPtr then begin
    if t <> tInt then ScaleBy(scale);
    gen.Op(op, kWord, 8, false);
    if (t = tInt) and (scale <> 1) then begin
      PushConst(kWord, scale);
      gen.Op(sDiv, kWord, 8, true);
    end;
  end else
    gen.Op(op, KindOf(t), IntSize(t), Signed(t));
  x.mode := mStack;
  if op in Rel + [sIn] then x.typ := tBool else x.typ := t;
end;

{ INT and UINT, the integers as big as an address, through which
  integers and pointers convert (report section 6.7) }
function IsWord(t: PType): boolean;
begin
  IsWord := Same(t, tInt) or Same(t, tUInt);
end;

procedure Convert(var x: TItem; t: PType);
var s: PType; r: double;
begin
  s := x.typ;
  if x.mode in [mType, mBuiltin, mNone, mCase, mStr] then begin
    if x.mode = mStr then MarkAt(x.pos, 'can''t convert a string');
    NotValue(x);
  end;
  if Same(s, t) then exit;
  if (IsInt(s) or (s^.form in [fEnum, fSet])) and (t^.form = fInt) then begin
    if x.mode = mConst then x.val := Cut(x.val, t)
    else begin Value(x); Narrow(t^.size, t^.signed) end;
  end else if IsInt(s) and (t^.form = fEnum) then begin
    if x.mode = mConst then begin
      if (x.val < 0) or (x.val >= t^.len) then MarkAt(x.pos, IntStr(x.val) + ' isn''t a position of ' + TypeName(t))
    end else begin Value(x); CheckEnum(t^.len, NameChunk(t), x.pos) end;
  end else if IsInt(s) and (t^.form = fSet) then begin
    if x.mode = mConst then begin
      if t^.len < 64 then x.val := x.val and ((int64(1) shl t^.len) - 1)
    end else begin
      Value(x);
      if t^.len < 64 then begin
        PushConst(kWord, (int64(1) shl t^.len) - 1);
        gen.Op(sAmp, kWord, 8, false);
      end;
    end;
  end else if IsInt(s) and (t^.form = fReal) then begin
    if x.mode = mConst then begin
      if (s^.form = fInt) and not s^.signed then r := qword(x.val) else r := x.val;
      MakeReal(x, r);
      RealTo(x, t);
    end else begin
      Value(x);
      IntToReal(KindOf(t), (s^.form = fInt) and not s^.signed and (s^.size = 8));
    end;
  end else if (s^.form = fReal) and (t^.form = fReal) then begin
    { F32 to F64, F64 to F32, or a real constant to either }
    if x.mode = mConst then RealTo(x, t)
    else begin Value(x); RealToReal(KindOf(s)) end;
  end else if (s^.form = fReal) and (t^.form = fInt) then begin
    if x.mode = mConst then begin
      r := RealOf(x);
      { NaN or out of range folds to low(int64), the "integer
        indefinite" cvttsd2si gives at run time }
      if (r <> r) or (r >= 9.2233720368547758e18) or (r < -9.2233720368547758e18) then
        x.val := Cut(low(int64), t)
      else x.val := Cut(trunc(r), t);
    end else begin
      Value(x); RealToInt(KindOf(s)); Narrow(t^.size, t^.signed)
    end;
  end else if (IsWord(s) or (s^.form in [fConst, fPtr, fProc, fNil])) and (t^.form in [fPtr, fProc]) then begin
    if x.mode <> mConst then Value(x);
  end else if (s^.form in [fPtr, fProc]) and IsWord(t) then
    Value(x)
  else
    MarkAt(x.pos, 'can''t convert ' + TypeName(s) + ' to ' + TypeName(t));
  x.typ := t;
end;

{ Calls }

procedure BeginCall(var c: TCall; var x: TItem);
begin
  if x.mode = mProc then begin
    c.sig := x.obj^.typ; c.chunk := x.obj^.chunk; c.target := 0;
    c.obj := x.obj; c.ext := x.obj^.ext;
  end else begin
    c.obj := nil; c.ext := false;
    if x.typ^.form <> fProc then MarkAt(x.pos, 'expected a procedure, found ' + What(x));
    c.sig := x.typ; c.chunk := -1;
    c.target := ToSlot(x);
  end;
  c.param := c.sig^.fields;
  c.n := 0;
end;

{ Too many arguments or too few, at p }
procedure WrongCount(var c: TCall; const p: TPos; const what: shortstring);
begin
  if c.obj = nil then MarkAt(p, what);
  Error(p, what + ': ' + NameOf(c.obj^.name) + ' takes ' + IntStr(c.sig^.len));
  if c.obj^.module <> nil then Note(c.obj^.pos, 'the signature is here');
  Fail;
end;

{ Pushes the two words of x, a slice or two results (InTwoRegs), read
  from memory now, so that what comes after can't change them. }
procedure PushWords(var x: TItem);
var adr: TAdr; f: PObj;
begin
  if x.mode = mWords then exit;   { there already }
  if (x.mode <> mVar) or x.vol or not (x.base in [bFrame, bGlobal, bSlot]) then CopyToTemp(x);
  adr := AdrOf(x);
  if x.typ^.form = fSlice then begin
    PushVar(adr, 8, false, kWord);
    inc(adr.off, 8);
    PushVar(adr, 8, false, kWord);
  end else begin
    f := x.typ^.fields;
    while f <> nil do begin
      adr.off := AdrOf(x).off + f^.val;
      PushVar(adr, ScalarSize(f^.typ), Signed(f^.typ), KindOf(f^.typ));
      f := f^.next;
    end;
  end;
end;

procedure PassArg(var c: TCall; var a: TItem);
var p: PObj;
begin
  p := c.param;
  if c.n >= High(c.isF) then MarkAt(a.pos, 'too many arguments');
  if p = nil then begin
    { past the parameters of a C procedure that ends in ...: a string
      goes as a C string, an integer constant as an INT, a real
      constant as an F64; C takes no F32 there }
    if not c.sig^.variadic then WrongCount(c, a.pos, 'too many arguments');
    if a.mode = mStr then Coerce(a, tPtrU8)
    else if a.typ^.form = fConst then Coerce(a, tInt)
    else if a.typ = tRConst then Coerce(a, tReal)
    else if IsF32(a.typ) then MarkAt(a.pos, 'an F32 goes to ... as F64(x)')
    else if not IsScalar(a.typ) then MarkAt(a.pos, 'only a single value goes to ...');
    c.isF[c.n] := a.typ^.form = fReal;
    c.pair[c.n] := false;
    Value(a);
    inc(c.n);
    exit;
  end;
  c.isF[c.n] := (p^.typ^.form = fReal) and not p^.isVar;
  passing := p;
  passingAt := a.pos;
  if p^.isVar then begin
    NotReadOnly(a);
    if (a.mode <> mVar) or not a.isVar then MarkAt(a.pos, 'a var parameter needs a variable');
    if a.odd then MarkAt(a.pos, 'a field of a packed record can''t be a var parameter');
    if not Same(a.typ, p^.typ) then Mismatch(a, 'a var parameter needs exactly ' + TypeName(p^.typ) + ', found ' + What(a));
    if a.vol then MarkAt(a.pos, 'can''t pass through a volatile pointer to a var parameter');
    Address(a);
  end else if p^.typ^.form = fSlice then begin
    Coerce(a, p^.typ);
    PushWords(a);
    c.pair[c.n] := true;
    inc(c.n);
    c.isF[c.n] := false;
  end else if IsAggregate(p^.typ) then begin
    Coerce(a, p^.typ);
    if a.isVar or a.vol or (a.base <> bFrame) then CopyToTemp(a);
    Address(a);
  end else begin
    Coerce(a, p^.typ);
    Value(a);
  end;
  c.pair[c.n] := false;
  inc(c.n);
  c.param := p^.next;
end;

procedure EndCall(var c: TCall; var x: TItem);
var res: PType;
begin
  if c.param <> nil then WrongCount(c, TokPos, 'too few arguments');
  Call(c);
  res := c.sig^.base;
  FillChar(x, SizeOf(x), 0);
  if res = nil then begin
    x.mode := mNone; x.typ := tNone; x.obj := c.obj
  end else if c.ret <> 0 then
    TempItem(x, res, c.ret)
  else begin
    x.mode := mStack; x.typ := res;
    if res^.tuple then x.mode := mWords;
  end;
end;

{ Variants }

{ A temporary of type t, all zero: for variants and record literals. }
procedure ZeroTemp(var x: TItem; t: PType);
var tmp: int64;
begin
  tmp := AllocTemp(t^.size, t^.align);
  ZeroVar(FrameAdr(tmp), t^.size);
  TempItem(x, t, tmp);
end;

procedure Construct(var x: TItem; c: PObj);
begin
  ZeroTemp(x, c^.typ);
  PushConst(kWord, c^.val);
  PopVar(FrameAdr(x.off), 8);
end;

procedure SetField(const x: TItem; f: PObj; var a: TItem);
begin
  Coerce(a, f^.typ);
  if IsScalar(f^.typ) then begin
    Value(a);
    PopVar(FrameAdr(x.off + f^.val), ScalarSize(f^.typ));
  end else begin
    if a.vol then MarkAt(a.pos, 'can''t copy through a volatile pointer');
    Address(a);
    CopyTo(FrameAdr(x.off + f^.val), f^.typ^.size);
  end;
end;

{ The slot match tests: a variant's address, or an enumeration's or an
  integer's value. }
function MatchBegin(var x: TItem): int64;
var p: int64;
begin
  if x.typ^.form in [fEnum, fInt] then exit(ToSlot(x));
  if (x.mode <> mVar) or (x.typ^.form <> fVariant) then MarkAt(x.pos, 'match needs a variant, an enumeration or an integer, found ' + What(x));
  if x.ro then CopyToTemp(x);   { its arms' names stand for a copy's fields }
  Address(x);
  p := AllocTemp(8, 8);
  PopVar(FrameAdr(p), 8);
  MatchBegin := p;
end;

{ To L unless the tag of the variant whose address is in slot p, or the
  enumeration in it, is tag }
procedure MatchTag(p: int64; tag: int64; var L: longint; isEnum: boolean);
var a: TAdr;
begin
  PushVar(FrameAdr(p), 8, false, kWord);
  if not isEnum then begin
    a.base := bStack; a.chunk := -1; a.off := 0;
    PushVar(a, 8, false, kWord);
  end;
  PushConst(kWord, tag);
  JumpCmp(sNeq, false, L);
end;

{ To body if the integer in slot p is from lo to hi: less its lo, it is
  then at most hi - lo, compared unsigned, which holds for a signed type
  or not, with no second jump. }
procedure MatchRange(p, lo, hi: int64; var body: longint);
begin
  PushVar(FrameAdr(p), 8, false, kWord);
  if lo = hi then begin
    PushConst(kWord, lo);
    JumpCmp(sEql, false, body);
    exit;
  end;
  if lo <> 0 then begin
    PushConst(kWord, lo);
    gen.Op(sMinus, kWord, 8, false);
  end;
  PushConst(kWord, hi - lo);
  JumpCmp(sLeq, false, body);
end;

{ A for loop's variable o, stepped by step, wrapping as its type does }
procedure ForStep(o: PObj; step: int64);
var v, w: TItem;
begin
  MakeItem(v, o);
  MakeItem(w, o);
  Value(w);
  PushConst(kWord, step);
  gen.Op(sPlus, kWord, IntSize(o^.typ), Signed(o^.typ));
  Assign(v, w);
end;

{ For a for loop: pushes the variable o and the limit lim, a constant or
  the slot it was put in, and jumps to L if the one is op the other, as
  the type of o compares }
procedure ForCmp(o: PObj; const lim: TItem; op: TSym; var L: longint);
var v, b: TItem;
begin
  MakeItem(v, o);
  Value(v);
  b := lim;
  Value(b);
  JumpCmp(op, o^.typ^.signed, L);
end;

{ The end of a round of a for loop, as the report has it for a positive
  step s: if v <= b and b - v < s, the loop ends; otherwise v becomes
  v + s and the loop goes on while v <= b. Counting the distance left,
  rather than comparing after the step, can't be fooled by v wrapping
  around. So the loop goes on, to top, where v is stepped, if v < b for
  a step of 1, or if v <= b and b - v >= s for another: then v + s <= b
  needs no test. It ends if v = b, or b - v < s. Only where the body has
  put v past b is it stepped here and tested, past. A negative step is
  the same the other way round. }
procedure ForNext(o: PObj; const lim: TItem; step: int64; var exitL: longint; top, body: longint);
const
  Before: array[boolean] of TSym = (sGtr, sLss);   { by a negative step, by a positive }
  Past: array[boolean] of TSym = (sLss, sGtr);
  Within: array[boolean] of TSym = (sGeq, sLeq);
var v, b: TItem; L, pastL: longint; up: boolean;
begin
  up := step > 0;
  L := NoLabel;
  pastL := NoLabel;
  if abs(step) = 1 then begin
    ForCmp(o, lim, Before[up], L);
    FixTo(L, top);
    ForCmp(o, lim, sEql, exitL);
  end else begin
    ForCmp(o, lim, Past[up], pastL);
    MakeItem(v, o);
    b := lim;
    if up then begin Value(b); Value(v) end
    else begin Value(v); Value(b) end;
    gen.Op(sMinus, kWord, 8, false);
    PushConst(kWord, abs(step));
    JumpCmp(sGeq, false, L);
    FixTo(L, top);
    Jump(exitL);
  end;
  Fix(pastL);
  ForStep(o, step);
  L := NoLabel;
  ForCmp(o, lim, Within[up], L);
  FixTo(L, body);
end;

procedure CondJump(var x: TItem; var L: longint);
begin
  if x.typ^.form <> fBool then MarkAt(x.pos, 'a condition is a BOOL, found ' + What(x));
  if x.mode = mCond then begin
    JumpCmp(Negated[x.rel], x.relSigned, L);
    L := JoinJumps(L, x.fj);
    Fix(x.tj);
    exit;
  end;
  Value(x);
  JumpIf(L, false);
end;

{ As CondJump, but the jump is taken where the condition holds }
procedure CondJumpTrue(var x: TItem; var L: longint);
begin
  if x.typ^.form <> fBool then MarkAt(x.pos, 'a condition is a BOOL, found ' + What(x));
  if x.mode = mCond then begin
    JumpCmp(x.rel, x.relSigned, L);
    L := JoinJumps(L, x.tj);
    Fix(x.fj);
    exit;
  end;
  Value(x);
  JumpIf(L, true);
end;

{ Procedures }

procedure BeginProc(sig: PType; params: PObj);
begin
  result := sig^.base;
  gen.BeginProc(sig, params);
end;

{ The result of return x: a value on top, a slice's two words on top,
  or one copied behind the hidden pointer }
procedure ReturnValue(var x: TItem);
begin
  if result = nil then MarkAt(x.pos, 'this procedure returns nothing');
  Coerce(x, result);
  if InTwoRegs(result) then PushWords(x)
  else if IsAggregate(result) then begin
    if x.vol then MarkAt(x.pos, 'can''t copy through a volatile pointer');
    Address(x);
    CopyResult(0, result^.size);
  end else Value(x);
end;

{ One of several results: of two words, a value left on top for
  ReturnJump to put in rax or rdx; else into its place behind the
  hidden pointer. }
procedure ReturnField(f: PObj; var x: TItem);
begin
  Coerce(x, f^.typ);
  if InTwoRegs(result) then Value(x)
  else if IsScalar(f^.typ) then begin
    Value(x);
    ResultTo(f^.val, ScalarSize(f^.typ));
  end else begin
    if x.vol then MarkAt(x.pos, 'can''t copy through a volatile pointer');
    Address(x);
    CopyResult(f^.val, f^.typ^.size);
  end;
end;

{ Several results at once, the call's that return f(x) passes on. }
procedure ReturnAll(var x: TItem);
begin
  if InTwoRegs(result) then PushWords(x)
  else begin
    Address(x);
    CopyResult(0, result^.size);
  end;
end;

procedure ReturnNone;
begin
  if result <> nil then Mark('return needs a result of ' + TypeName(result));
  ReturnJump;
end;

{ Keeps a variable's address in a frame slot, rather than on the stack,
  while other code runs. }
procedure Pin(var x: TItem);
var s: int64;
begin
  if (x.mode = mVar) and (x.base = bStack) then begin
    Address(x);
    s := AllocTemp(8, 8);
    PopVar(FrameAdr(s), 8);
    x.base := bSlot;
    x.chunk := s;
  end;
end;

{ INC(v, k) or DEC: v's address is on the stack, from Address. }
procedure IncDec(var v, k: TItem; dec: boolean);
begin
  CoerceExact(k, v.typ, '');
  Value(k);
  if v.base = bReg then IncDecReg(v.chunk, ScalarSize(v.typ), v.typ^.signed, dec)
  else gen.IncDec(ScalarSize(v.typ), v.typ^.signed, dec);
end;

{ COPY(d, s): d, an array variable or a slice, as a slice in the frame,
  before s is read }
procedure CopyDest(var d: TItem);
begin
  if not IsSeq(d.typ) or (d.mode = mStr) or (d.typ^.form = fArray) and ((d.mode <> mVar) or not d.isVar) then
    MarkAt(d.pos, 'COPY copies into an array variable or a slice, found ' + What(d));
  if d.typ^.form = fArray then NotReadOnly(d);
  SeqSlice(d);
end;

{ ... and the elements of s copied to its start }
procedure CopyFrom(var d, s: TItem);
begin
  if not IsSeq(s.typ) or not Same(ElemOf(s.typ), d.typ^.base) then
    MarkAt(s.pos, 'COPY copies elements of ' + TypeName(d.typ^.base) + ', found ' + What(s));
  SeqSlice(s);
  CopySlice(d.off, s.off, d.typ^.base^.size, checks, s.pos);
end;

{ An error is the address of its length, followed by its message. }
function ErrorChunk(var x: TItem; module, name: longint): longint;
var c: longint; p: PBytes;
begin
  if x.mode <> mStr then MarkAt(x.pos, 'an error is made from a string');
  p := GetMem(x.val + 8);
  PInt64(p)^ := x.val;
  Move(rodata^[chunks^[x.chunk].start], p^[8], x.val);
  c := NewChunk(secRodata, module, name);
  SetData(c, p, x.val + 8, 8);
  FreeMem(p);
  ErrorChunk := c;
end;

procedure Msg(var x: TItem);
var s: int64;
begin
  Coerce(x, tError);
  Value(x);
  s := AllocTemp(16, 8);
  ErrorText(s);
  TempItem(x, tBytes, s);
end;

end.
