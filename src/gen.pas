{ gen.pas: the code generator.

  The parser describes each operand as an item (TItem), as in Wirth's
  compilers: a constant, a variable at an address the code can name, a
  value in rax, a value pushed on the stack, a procedure. The routines
  here turn items into code. They are a stack machine through rax: a
  value is computed into rax, and pushed while another is computed, so
  no register is ever allocated. Every access the program writes is one
  instruction, in the order written.

  Calls use the System V convention. Arguments are computed left to
  right into frame slots, then loaded into registers just before the
  call, so that computing one argument can't disturb another. A record,
  array, slice or variant passed by value goes as the address of a copy
  the caller makes; one returned goes through a hidden pointer, as C's
  structs do.

  A procedure's frame holds its parameters, its variables, and the
  temporaries of the statement running. All of it is zeroed on entry.

  Depends on: scan for errors, sym for types, x64 for instructions.
  Leaves out: the language's syntax; that is parse.pas. }

unit gen;

{$mode objfpc}{$H-}

interface

uses scan, diag, sym, x64;

type
  TMode = (mConst, mVar, mReg, mStack, mProc, mType, mStr, mBuiltin, mCase, mNone);
  TBase = (bFrame, bGlobal, bReg, bStack, bSlot);   { bSlot: address in a frame slot, chunk }

  TItem = record
    mode: TMode;
    typ: PType;
    val: int64;        { mConst: the value, an F64's bits; mStr: its length }
    base: TBase;       { mVar: what the address is relative to }
    reg: longint;      { mVar with bReg: the register }
    off: int64;        { mVar: added to the base }
    chunk: longint;    { mVar with bGlobal, mStr: the chunk }
    vol: boolean;      { mVar: reached through ^VOLATILE }
    isVar: boolean;    { mVar: a variable of the program, not a temporary }
    obj: PObj;         { mProc, mBuiltin, mCase }
    pos: TPos;         { where it is in the source, for messages }
  end;

  TCall = record
    sig: PType;
    param: PObj;       { the parameter the next argument is for }
    slots: array[0..63] of int64;
    n: longint;
    target: int64;     { the frame slot of a procedure value, if any }
    chunk: longint;    { else the procedure's chunk }
    obj: PObj;         { the procedure called, if it has a name }
    code: boolean;     { a code procedure: two results come in rax and rdx }
    ext: boolean;      { C's: called through the chunk holding its address }
    isF: array[0..63] of boolean;   { each argument: goes in an xmm register }
  end;

var
  rtFail, argcChunk, argvChunk: longint;
  depth: longint;      { values pushed and not yet popped }

procedure MakeConst(var x: TItem; t: PType; v: int64);
function What(const x: TItem): shortstring;
procedure MakeReal(var x: TItem; r: double);
procedure MakeStr(var x: TItem);
procedure MakeItem(var x: TItem; o: PObj);
function RealOf(const x: TItem): double;

procedure Value(var x: TItem);
procedure Address(var x: TItem; r: longint);
procedure Save(var x: TItem);
procedure Coerce(var x: TItem; t: PType);
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
procedure Op1(op: TSym; var x: TItem; var L: longint);
procedure Op2(op: TSym; var x, y: TItem; L: longint);
procedure Convert(var x: TItem; t: PType);

procedure BeginCall(var c: TCall; var x: TItem);
procedure PassArg(var c: TCall; var a: TItem);
procedure EndCall(var c: TCall; var x: TItem);

procedure ZeroTemp(var x: TItem; t: PType);
procedure Construct(var x: TItem; c: PObj);
procedure SetField(const x: TItem; f: PObj; var a: TItem);
function MatchBegin(var x: TItem): int64;
procedure MatchTag(p: int64; tag: int64; var L: longint; isEnum: boolean);
procedure CondJump(var x: TItem; var L: longint);

procedure SliceOf(var x: TItem; t: PType; len: int64);
procedure TempItem(var x: TItem; t: PType; off: int64);
function ScalarSize(t: PType): longint;
procedure Norm(t: PType);
procedure ForNext(o: PObj; bslot, step: int64; var exitL: longint; top: longint);
function AllocTemp(size, align: int64): int64;
function AllocPerm(size, align: int64): int64;
function TempMark: int64;
procedure ReleaseTemps(m: int64);
procedure KeepTemps;

procedure BeginProc(sig: PType; params: PObj);
procedure EnterBody(c, line: longint);
procedure ReturnValue(var x: TItem);
procedure ReturnField(f: PObj; var x: TItem);
procedure ReturnAll(var x: TItem);
procedure ReturnJump;
procedure ReturnNone;
procedure Pin(var x: TItem);
procedure IncDec(var v, k: TItem; dec: boolean);
procedure Msg(var x: TItem);
function ErrorChunk(var x: TItem; module, name: longint): longint;
procedure EndProc(c: longint);
procedure CmpI(r: longint; v: int64);
procedure PushRax;
procedure PopR(r: longint);

implementation

var
  frameTop, frameMax, permTop: int64;
  frameFix: longint;            { where the frame size is patched in }
  paramTop: int64;              { the parameters' slots end here }
  retSlot: int64;               { holds the hidden result pointer }
  pushEnd: longint;             { the code just after the last push of rax }
  result: PType;                { the procedure's result, or nil }
  exitL: longint;
  { parameters arriving in registers: where each is stored on entry }
  inReg: array[0..13] of longint;
  inSlot: array[0..13] of int64;
  inSize: array[0..13] of longint;
  numIn: longint;

const
  IntRegs: array[0..5] of longint = (RDI, RSI, RDX, RCX, R8, R9);

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
      end else begin
        x.mode := mConst; x.val := o^.val
      end;
    oVar: begin
      x.mode := mVar;
      x.isVar := true;
      if o^.ext then begin
        Load(RAX, MemRip(o^.chunk, 0), 8, false);
        x.base := bReg; x.reg := RAX;
      end else if o^.lev = 0 then begin
        x.base := bGlobal; x.chunk := o^.chunk
      end else if o^.ind then begin
        Load(RAX, Mem(RBP, o^.val), 8, false);
        x.base := bReg; x.reg := RAX; x.off := o^.off;
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

procedure PushRax;
begin
  Push(RAX);
  inc(depth);
  pushEnd := pc;
end;

procedure PopR(r: longint);
begin
  Pop(r);
  dec(depth);
end;

procedure CmpI(r: longint; v: int64);
begin
  if (v >= low(longint)) and (v <= high(longint)) then AluI(aluCmp, r, v)
  else begin MovRI(R11, v); Alu(aluCmp, r, R11) end;
end;

{ A constant into r: an error constant is the address of its chunk. }
procedure ConstTo(r: longint; const x: TItem);
var f: single;
begin
  if (x.typ^.form = fError) and (x.val > 0) then Lea(r, MemRip(x.val - 1, 0))
  else if IsF32(x.typ) then begin
    f := RealOf(x);
    MovRI(r, PLongword(@f)^);
  end else MovRI(r, x.val);
end;

function MemOf(var x: TItem; r: longint): TMem;
begin
  case x.base of
    bFrame: MemOf := Mem(RBP, x.off);
    bGlobal: MemOf := MemRip(x.chunk, x.off);
    bStack: begin
      PopR(r);
      x.base := bReg; x.reg := r;
      MemOf := Mem(r, x.off);
    end;
    bSlot: begin
      Load(r, Mem(RBP, x.chunk), 8, false);
      x.base := bReg; x.reg := r;
      MemOf := Mem(r, x.off);
    end;
  else MemOf := Mem(x.reg, x.off);
  end;
end;

function ScalarSize(t: PType): longint;
begin
  if t^.form in [fInt, fBool, fEnum, fSet, fReal] then ScalarSize := t^.size
  else ScalarSize := 8;
end;

{ Brings a value just computed in rax to its type's width. }
procedure Norm(t: PType);
begin
  if (t^.form = fInt) and (t^.size < 8) then Extend(RAX, t^.size, t^.signed);
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

procedure LoadVar(var x: TItem; r: longint);
begin
  if not IsScalar(x.typ) then MarkAt(x.pos, 'expected a single value, found ' + What(x));
  Load(r, MemOf(x, r), ScalarSize(x.typ), (x.typ^.form = fInt) and x.typ^.signed);
end;

{ Takes back the push of rax just emitted, if it is the last code, and
  neither a jump nor a line starts after it: the value is still in rax. }
function Unpush: boolean;
begin
  Unpush := (pc = pushEnd) and (labelAt <> pc)
    and ((numLines = 0) or (lines^[numLines - 1].at < pc));
  if Unpush then begin dec(pc); dec(depth); pushEnd := -1 end;
end;

procedure Value(var x: TItem);
begin
  case x.mode of
    mConst: ConstTo(RAX, x);
    mVar: LoadVar(x, RAX);
    mReg: ;
    mStack: PopR(RAX);
    mProc: begin
      if x.obj^.isCode and (x.obj^.typ^.base <> nil) and x.obj^.typ^.base^.tuple then
        MarkAt(x.pos, 'a code procedure with two results can only be called');
      if x.obj^.ext then Load(RAX, MemRip(x.obj^.chunk, 0), 8, false)
      else Lea(RAX, MemRip(x.obj^.chunk, 0));
    end;
  else NotValue(x);
  end;
  x.mode := mReg;
end;

procedure Address(var x: TItem; r: longint);
var m: TMem;
begin
  if x.mode = mStr then Lea(r, MemRip(x.chunk, 0))
  else if x.mode = mVar then begin
    m := MemOf(x, r);
    if (x.base <> bReg) or (x.reg <> r) or (x.off <> 0) then Lea(r, m);
    x.base := bReg; x.reg := r; x.off := 0;
  end else MarkAt(x.pos, 'expected a variable');
end;

procedure Save(var x: TItem);
begin
  if x.mode = mReg then begin
    PushRax; x.mode := mStack
  end else if (x.mode = mVar) and (x.base = bReg) then begin
    if x.reg <> RAX then MovRR(RAX, x.reg);
    PushRax; x.base := bStack;
  end;
end;

{ Frames }

function AllocTemp(size, align: int64): int64;
begin
  if align < 1 then align := 1;
  frameTop := AlignUp(frameTop + size, align);
  if frameTop > frameMax then frameMax := frameTop;
  AllocTemp := -frameTop;
end;

function AllocPerm(size, align: int64): int64;
begin
  AllocPerm := AllocTemp(size, align);
  permTop := frameTop;
end;

function TempMark: int64;
begin
  TempMark := frameTop;
end;

procedure ReleaseTemps(m: int64);
begin
  if m < permTop then m := permTop;
  frameTop := m;
end;

{ Every slot used so far stays reserved for the rest of the procedure:
  a deferred statement's temporaries live until it runs. }
procedure KeepTemps;
begin
  frameTop := frameMax;
  permTop := frameMax;
end;

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
  Store(Mem(RBP, s), RAX, 8);
  ToSlot := s;
end;

{ Copying }

procedure Copy(size: int64);
begin
  MovRI(RCX, size);
  RepMovsb;
end;

procedure CopyToTemp(var x: TItem);
var t: int64;
begin
  if x.vol then MarkAt(x.pos, 'can''t copy through a volatile pointer');
  t := AllocTemp(x.typ^.size, x.typ^.align);
  Address(x, RSI);
  Lea(RDI, Mem(RBP, t));
  Copy(x.typ^.size);
  TempItem(x, x.typ, t);
end;

{ A slice made from an address in rax and a length. }
procedure SliceOf(var x: TItem; t: PType; len: int64);
var s: int64;
begin
  s := AllocTemp(16, 8);
  Store(Mem(RBP, s), RAX, 8);
  MovRI(RAX, len);
  Store(Mem(RBP, s + 8), RAX, 8);
  TempItem(x, t, s);
end;

procedure Coerce(var x: TItem; t: PType);
var s: PType; tmp: int64;
begin
  s := x.typ;
  if x.mode = mStr then begin
    if (t^.form = fSlice) and (t^.base = tU8) then begin
      Address(x, RAX); SliceOf(x, t, x.val)
    end else if (t^.form = fPtr) and (t^.base = tU8) then begin
      Address(x, RAX); x.mode := mReg; x.typ := t
    end else if (t^.form = fArray) and (t^.base = tU8) and (t^.len >= x.val) then begin
      tmp := AllocTemp(t^.size, 1);
      Lea(RDI, Mem(RBP, tmp));
      Lea(RSI, MemRip(x.chunk, 0));
      Copy(x.val);
      MovRI(RCX, t^.len - x.val);
      MovRI(RAX, 0);
      RepStosb;
      TempItem(x, t, tmp);
    end else MarkAt(x.pos, 'can''t use a string as ' + TypeName(t));
    exit;
  end;
  if x.mode in [mType, mBuiltin, mNone, mCase] then NotValue(x);
  if Same(s, t) then exit;
  if (s = tRConst) and (t^.form = fReal) then RealTo(x, t)
  else if (s^.form = fConst) and (t^.form = fInt) then begin
    if (x.mode = mConst) and not Fits(x.val, t) then MarkAt(x.pos, IntStr(x.val) + ' doesn''t fit ' + TypeName(t));
    x.typ := t;
  end else if (s^.form = fNil) and (t^.form in [fPtr, fProc, fError]) then
    x.typ := t
  else if (s^.form = fPtr) and (t^.form = fPtr) and t^.vol and not s^.vol
    and Same(s^.base, t^.base) then
    x.typ := t
  else if (s^.form = fArray) and (t^.form = fSlice) and Same(s^.base, t^.base) then begin
    if x.vol then MarkAt(x.pos, 'can''t make a slice through a volatile pointer');
    Address(x, RAX);
    SliceOf(x, t, s^.len);
  end else
    MarkAt(x.pos, 'can''t use ' + TypeName(s) + ' as ' + TypeName(t));
end;

procedure Assign(var dst, src: TItem);
var m: TMem;
begin
  Coerce(src, dst.typ);
  if IsScalar(dst.typ) then begin
    Value(src);
    m := MemOf(dst, RCX);
    Store(m, RAX, ScalarSize(dst.typ));
  end else begin
    if dst.vol or src.vol then MarkAt(src.pos, 'can''t copy through a volatile pointer');
    Address(src, RSI);
    Address(dst, RDI);
    Copy(dst.typ^.size);
  end;
end;

{ Checks }

const
  NoBase = -2;   { a TMem that is no memory }

{ The program goes on if the condition cc holds, and otherwise stops
  in Rt.fail(what, a, b, len, at, name), which says what failed at p,
  found by at, the address of the call: an index a (what = 0), a slice
  a..b (1), each for a length len, or a position a of the enumeration
  called name (2). a is in register ra, b in RDX; len is in memory at
  m, or n if m.base is NoBase. The failing code has p for its place,
  and the code after it the place before it again. }
procedure Check(cc, what: longint; const p: TPos; ra: longint; const m: TMem; n: int64; name: longint);
var L, line, col: longint; before: TLine;
begin
  L := NoLabel;
  Jcc(cc, L);
  before := lines^[numLines - 1];
  LineCol(p.a, line, col);
  NoteLine(line, col);
  MovRR(RSI, ra);
  if m.base = NoBase then MovRI(RCX, n) else Load(RCX, m, 8, false);
  Lea(R8, Here);
  MovRI(RDI, what);
  if name >= 0 then Lea(R9, MemRip(name, 0));
  AluI(aluAnd, RSP, -16);
  CallChunk(rtFail);
  Ud2;
  FixLink(L);
  NoteLine(before.line, before.col);
end;

{ For Check: a length known here, not in memory }
function NoMem: TMem;
begin
  NoMem := Mem(NoBase, 0);
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
  x.mode := mVar; x.base := bReg; x.reg := RAX; x.off := 0;
  x.typ := t^.base; x.vol := t^.vol; x.isVar := true;
end;

procedure Field(var x: TItem; f: PObj);
begin
  x.off := x.off + f^.val;
  x.typ := f^.typ;
end;

procedure IndexPrep(var x: TItem);
begin
  if x.mode = mStr then Coerce(x, tBytes);
  if (x.typ^.form = fPtr) and (x.typ^.base^.form = fArray) then
    MarkAt(x.pos, 'a pointer to an array is indexed as p^[i]');
  if x.typ^.form = fPtr then begin
    Value(x); PushRax; x.mode := mStack
  end else if (x.mode = mVar) and (x.typ^.form in [fArray, fSlice]) then
    Save(x)
  else MarkAt(x.pos, 'expected an array, a slice or a pointer, found ' + What(x));
end;

procedure Index(var x, y: TItem);
var t: PType; s: int64; m, ml: TMem;
begin
  t := x.typ;
  s := t^.base^.size;
  if not IsInt(y.typ) then MarkAt(y.pos, 'an index is an integer, found ' + What(y));
  if t^.form = fPtr then begin
    Value(y);
    if s <> 1 then ImulI(RAX, s);
    PopR(RCX);
    Alu(aluAdd, RAX, RCX);
    x.mode := mVar; x.base := bReg; x.reg := RAX; x.off := 0;
    x.vol := t^.vol; x.isVar := true;
  end else if (t^.form = fArray) and (y.mode = mConst) then begin
    if (y.val < 0) or (y.val >= t^.len) then MarkAt(y.pos, 'index ' + IntStr(y.val) + ' is out of range for a length of ' + IntStr(t^.len));
    x.off := x.off + y.val * s;
    if x.base = bStack then begin
      PopR(RAX); x.base := bReg; x.reg := RAX
    end;
  end else if t^.form = fArray then begin
    Value(y);
    CmpI(RAX, t^.len);
    Check(ccB, 0, y.pos, RAX, NoMem, t^.len, -1);
    if s <> 1 then ImulI(RAX, s);
    if x.base = bStack then PopR(RCX) else Lea(RCX, MemOf(x, RCX));
    Alu(aluAdd, RAX, RCX);
    if x.base <> bStack then x.off := 0;
    x.base := bReg; x.reg := RAX;
  end else begin
    Value(y);
    m := MemOf(x, RCX);
    ml := m; ml.disp := ml.disp + 8;
    AluM(aluCmp, RAX, ml);
    Check(ccB, 0, y.pos, RAX, ml, 0, -1);
    if s <> 1 then ImulI(RAX, s);
    AluM(aluAdd, RAX, m);
    x.base := bReg; x.reg := RAX; x.off := 0; x.isVar := true; x.vol := false;
  end;
  x.typ := t^.base;
end;

procedure SliceLo(var lo: TItem);
begin
  if not IsInt(lo.typ) then MarkAt(lo.pos, 'an index is an integer, found ' + What(lo));
  Value(lo);
  PushRax;
end;

procedure Slice(var x, lo, hi: TItem);
var t, st: PType; s, tmp: int64; m, ml: TMem;
begin
  t := x.typ;
  s := t^.base^.size;
  if not IsInt(hi.typ) then MarkAt(hi.pos, 'an index is an integer, found ' + What(hi));
  if x.vol then MarkAt(x.pos, 'can''t make a slice through a volatile pointer');
  Value(hi);
  MovRR(RDX, RAX);
  PopR(RCX);
  if t^.form = fPtr then PopR(R8)
  else begin
    m := MemOf(x, R8);
    ml := m; ml.disp := ml.disp + 8;
    if t^.form = fArray then begin CmpI(RDX, t^.len); ml := NoMem end
    else AluM(aluCmp, RDX, ml);
    Check(ccBE, 1, lo.pos, RCX, ml, t^.len, -1);
    Alu(aluCmp, RCX, RDX);
    Check(ccBE, 1, lo.pos, RCX, ml, t^.len, -1);
  end;
  tmp := AllocTemp(16, 8);
  MovRR(RAX, RDX);
  Alu(aluSub, RAX, RCX);
  Store(Mem(RBP, tmp + 8), RAX, 8);
  if s <> 1 then ImulI(RCX, s);
  case t^.form of
    fPtr: MovRR(RAX, R8);
    fArray: Lea(RAX, m);
  else Load(RAX, m, 8, false);
  end;
  Alu(aluAdd, RAX, RCX);
  Store(Mem(RBP, tmp), RAX, 8);
  st := NewType(fSlice, 16, 8);
  st^.base := t^.base;
  TempItem(x, st, tmp);
end;

{ Operators }

procedure Neg(var x: TItem);
begin
  if x.typ^.form = fReal then begin
    if x.mode = mConst then x.val := x.val xor low(int64)
    else begin Value(x); if IsF32(x.typ) then Btc(RAX, 31) else Btc(RAX, 63) end;
  end else if IsInt(x.typ) then begin
    if x.mode = mConst then x.val := Cut(-x.val, x.typ)
    else begin Value(x); Unary(3, RAX); Norm(x.typ) end;
  end else MarkAt(x.pos, 'can''t negate ' + TypeName(x.typ));
end;

procedure NotOp(var x: TItem);
begin
  if x.typ^.form = fBool then begin
    if x.mode = mConst then x.val := 1 - x.val
    else begin Value(x); AluI(aluXor, RAX, 1) end;
  end else if IsInt(x.typ) then begin
    if x.mode = mConst then x.val := Cut(not x.val, x.typ)
    else begin Value(x); Unary(2, RAX); Norm(x.typ) end;
  end else MarkAt(x.pos, '"not" needs a BOOL or an integer, found ' + What(x));
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
    if x.mode = mStr then begin Address(x, RAX); SliceOf(x, t, x.val) end
    else begin
      if x.vol then MarkAt(x.pos, 'can''t compare through a volatile pointer');
      Address(x, RAX); SliceOf(x, t, x.typ^.len)
    end;
  end;
end;

procedure Op1(op: TSym; var x: TItem; var L: longint);
var tmp: TItem;
begin
  L := NoLabel;
  if (op in [sAnd, sOr]) and (x.typ^.form = fBool) then begin
    tmp := x;
    Value(tmp);
    if x.mode <> mConst then x := tmp;
    TestRR(RAX, RAX);
    if op = sAnd then Jcc(ccE, L) else Jcc(ccNE, L);
  end else if (op in [sEql, sNeq]) and IsSeq(x.typ) then
    SeqSlice(x)
  else if x.mode in [mType, mBuiltin, mNone, mCase, mStr] then
    NotValue(x)
  else if x.mode <> mConst then begin
    Value(x); PushRax; x.mode := mStack
  end;
end;

function Log2(v: int64): longint;
var n: longint;
begin
  n := 0;
  while (v > 1) and (v and 1 = 0) do begin v := v shr 1; inc(n) end;
  if v <> 1 then n := -1;
  Log2 := n;
end;

{ rax div or mod 2^k, 1 <= k <= 62, with shifts: div truncates towards
  zero, so a negative dividend first gets 2^k - 1 added (the bias). }
procedure DivPow2(op: TSym; k: longint; unsign: boolean);
begin
  if unsign then begin
    if op = sDiv then ShiftI(shShr, RAX, k)
    else begin ShiftI(shShl, RAX, 64 - k); ShiftI(shShr, RAX, 64 - k) end;
    exit;
  end;
  MovRR(RCX, RAX);
  ShiftI(shSar, RCX, 63);
  ShiftI(shShr, RCX, 64 - k);
  Alu(aluAdd, RCX, RAX);
  ShiftI(shSar, RCX, k);
  if op = sDiv then MovRR(RAX, RCX)
  else begin ShiftI(shShl, RCX, k); Alu(aluSub, RAX, RCX) end;
end;

function FoldInt(op: TSym; a, b: int64; t: PType; const p: TPos): int64;
var u: boolean;
begin
  u := (t^.form = fInt) and not t^.signed;
  case op of
    sPlus: FoldInt := a + b;
    sMinus: FoldInt := a - b;
    sTimes: FoldInt := a * b;
    sDiv, sMod: begin
      if b = 0 then MarkAt(p, 'division by zero');
      if u then begin
        if op = sDiv then FoldInt := int64(qword(a) div qword(b))
        else FoldInt := int64(qword(a) mod qword(b));
      end else if (b = -1) and (a = low(int64)) then MarkAt(p, 'division overflows')
      else if op = sDiv then FoldInt := a div b
      else FoldInt := a mod b;
    end;
    sAnd: FoldInt := a and b;
    sOr: FoldInt := a or b;
    sXor: FoldInt := a xor b;
    sShl: FoldInt := a shl (b and 63);
    sShr: if u then FoldInt := int64(qword(a) shr (b and 63))
          else FoldInt := SarInt64(a, b and 63);
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

procedure Op2(op: TSym; var x, y: TItem; L: longint);
const
  Rel = [sEql, sNeq, sLss, sLeq, sGtr, sGeq];
  CcSigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccL, ccLE, ccG, ccGE);
  CcUnsigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccB, ccBE, ccA, ccAE);
var
  xt, yt, t, e: PType; r: TItem; scale, sh, k, differ: longint; isPtr, unsign, f: boolean; a, b: int64;
begin
  xt := x.typ; yt := y.typ;
  if y.mode in [mType, mBuiltin, mNone, mCase] then NotValue(y);

  if (op in [sAnd, sOr]) and (xt^.form = fBool) then begin
    if yt^.form <> fBool then MarkAt(y.pos, SymText(op) + ' needs BOOLs, found ' + What(y));
    if (x.mode = mConst) and (y.mode = mConst) then begin
      FixLink(L);
      if op = sAnd then x.val := x.val and y.val else x.val := x.val or y.val;
      exit;
    end;
    Value(y);
    FixLink(L);
    x.mode := mReg; x.typ := tBool;
    exit;
  end;

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
    Address(y, RSI);
    Address(x, RDI);
    Load(RCX, Mem(RSI, 8), 8, false);
    AluM(aluCmp, RCX, Mem(RDI, 8));
    differ := NoLabel;
    Jcc(ccNE, differ);
    Load(RSI, Mem(RSI, 0), 8, false);
    Load(RDI, Mem(RDI, 0), 8, false);
    if e^.size > 1 then ShiftI(shShl, RCX, Log2(e^.size));
    Alu(aluCmp, RCX, RCX);   { equal, if there are no bytes }
    RepeCmpsb;
    FixLink(differ);
    if op = sEql then SetCC(ccE, RAX) else SetCC(ccNE, RAX);
    MakeConst(x, tBool, 0);
    x.mode := mReg;
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
  end else if (xt^.form = fReal) and (yt^.form = fReal) then begin
    if not (op in Rel + [sPlus, sMinus, sTimes, sSlash]) then MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(xt));
    if xt = tRConst then t := yt
    else if (yt = tRConst) or Same(xt, yt) then t := xt
    else Mismatch(x, y, xt, yt);
    if (x.mode = mConst) and (x.typ <> t) then RealTo(x, t);
    if (y.mode = mConst) and (y.typ <> t) then RealTo(y, t);
  end else if (xt^.form = fBool) and (yt^.form = fBool) then begin
    if not (op in [sXor, sEql, sNeq]) then MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(xt));
    t := tBool;
  end else if (xt^.form = fPtr) and IsInt(yt) and (op in [sPlus, sMinus]) then begin
    t := xt; scale := xt^.base^.size; isPtr := true;
    if y.mode = mConst then y.typ := tI64;
  end else if (xt^.form = fPtr) and (yt^.form = fPtr) and (op = sMinus) then begin
    if not Same(xt, yt) then Mismatch(x, y, xt, yt);
    t := tI64; scale := xt^.base^.size; isPtr := true;
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
  unsign := (t^.form = fInt) and not t^.signed;

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

  { a power of two on the right: shifts instead of imul and idiv }
  k := -1;
  if (y.mode = mConst) and (op in [sTimes, sDiv, sMod]) and (t^.form = fInt) then k := Log2(y.val);

  { x into rax, y into rcx; a left operand just pushed stays in rax when
  the right one needs no code of its own }
  if y.mode = mConst then begin
    if x.mode <> mStack then Value(x)
    else if not Unpush then PopR(RAX);
    if k < 1 then ConstTo(RCX, y);
  end else if (x.mode = mStack) and (y.mode = mVar) and (y.base in [bFrame, bGlobal])
    and Unpush then
    LoadVar(y, RCX)
  else begin
    Value(y);
    MovRR(RCX, RAX);
    if x.mode = mConst then ConstTo(RAX, x) else PopR(RAX);
  end;

  if t^.form = fReal then begin
    MovqXR(0, RAX);
    MovqXR(1, RCX);
    f := IsF32(t);
    case op of
      sPlus: Sse($58, 0, 1, f);
      sMinus: Sse($5C, 0, 1, f);
      sTimes: Sse($59, 0, 1, f);
      sSlash: Sse($5E, 0, 1, f);
      sEql: begin Ucomis(0, 1, f); SetCC(ccE, RAX); SetCC(ccNP, RCX); Alu(aluAnd, RAX, RCX) end;
      sNeq: begin Ucomis(0, 1, f); SetCC(ccNE, RAX); SetCC(ccP, RCX); Alu(aluOr, RAX, RCX) end;
      sLss: begin Ucomis(1, 0, f); SetCC(ccA, RAX) end;
      sLeq: begin Ucomis(1, 0, f); SetCC(ccAE, RAX) end;
      sGtr: begin Ucomis(0, 1, f); SetCC(ccA, RAX) end;
      sGeq: begin Ucomis(0, 1, f); SetCC(ccAE, RAX) end;
    end;
    if not (op in Rel) then MovqRX(RAX, 0);
  end else if t^.form = fSet then begin
    case op of
      sPlus: Alu(aluOr, RAX, RCX);
      sTimes: Alu(aluAnd, RAX, RCX);
      sMinus: begin Unary(2, RCX); Alu(aluAnd, RAX, RCX) end;
      sLeq, sGeq: begin
        if op = sLeq then Unary(2, RCX) else Unary(2, RAX);
        Alu(aluAnd, RAX, RCX);
        TestRR(RAX, RAX);
        SetCC(ccE, RAX);
      end;
      sIn: begin
        MovRR(RDX, RCX); MovRR(RCX, RAX); MovRR(RAX, RDX);
        Shift(shShr, RAX);
        AluI(aluAnd, RAX, 1);
      end;
    else Alu(aluCmp, RAX, RCX); SetCC(CcUnsigned[op], RAX);
    end;
  end else if op in Rel then begin
    Alu(aluCmp, RAX, RCX);
    if (t^.form = fInt) and t^.signed or (t^.form = fConst) then SetCC(CcSigned[op], RAX)
    else SetCC(CcUnsigned[op], RAX);
  end else begin
    case op of
      sPlus: begin if scale <> 1 then ImulI(RCX, scale); Alu(aluAdd, RAX, RCX) end;
      sMinus: begin
        if (scale <> 1) and (t <> tI64) then ImulI(RCX, scale);
        Alu(aluSub, RAX, RCX);
        if (t = tI64) and isPtr and (scale <> 1) then begin
          sh := Log2(scale);
          if sh >= 0 then ShiftI(shSar, RAX, sh)
          else begin MovRI(RCX, scale); Cqo; Unary(7, RCX) end;
        end;
      end;
      sTimes: if k >= 1 then ShiftI(shShl, RAX, k) else Imul(RAX, RCX);
      sDiv, sMod: if k >= 1 then DivPow2(op, k, unsign) else begin
        if unsign then begin MovRI(RDX, 0); Unary(6, RCX) end
        else begin Cqo; Unary(7, RCX) end;
        if op = sMod then MovRR(RAX, RDX);
      end;
      sAnd: Alu(aluAnd, RAX, RCX);
      sOr: Alu(aluOr, RAX, RCX);
      sXor: Alu(aluXor, RAX, RCX);
      sShl: Shift(shShl, RAX);
      sShr: if unsign then Shift(shShr, RAX) else Shift(shSar, RAX);
    else MarkAt(Join(x.pos, y.pos), SymText(op) + ' doesn''t apply to ' + TypeName(t));
    end;
    Norm(t);
  end;
  x.mode := mReg;
  if op in Rel + [sIn] then x.typ := tBool else x.typ := t;
end;

procedure Convert(var x: TItem; t: PType);
var s: PType; r: double; L1, L2: longint; f: boolean;
begin
  s := x.typ;
  if x.mode in [mType, mBuiltin, mNone, mCase, mStr] then begin
    if x.mode = mStr then MarkAt(x.pos, 'can''t convert a string');
    NotValue(x);
  end;
  if Same(s, t) then exit;
  if (IsInt(s) or (s^.form in [fEnum, fSet])) and (t^.form = fInt) then begin
    if x.mode = mConst then x.val := Cut(x.val, t)
    else begin Value(x); Norm(t) end;
  end else if IsInt(s) and (t^.form = fEnum) then begin
    if x.mode = mConst then begin
      if (x.val < 0) or (x.val >= t^.len) then MarkAt(x.pos, IntStr(x.val) + ' isn''t a position of ' + TypeName(t))
    end else begin Value(x); CmpI(RAX, t^.len); Check(ccB, 2, x.pos, RAX, NoMem, t^.len, NameChunk(t)) end;
  end else if IsInt(s) and (t^.form = fSet) then begin
    if x.mode = mConst then begin
      if t^.len < 64 then x.val := x.val and ((int64(1) shl t^.len) - 1)
    end else begin
      Value(x);
      if t^.len < 64 then begin MovRI(RCX, (int64(1) shl t^.len) - 1); Alu(aluAnd, RAX, RCX) end;
    end;
  end else if IsInt(s) and (t^.form = fReal) then begin
    f := IsF32(t);
    if x.mode = mConst then begin
      if (s^.form = fInt) and not s^.signed then r := qword(x.val) else r := x.val;
      MakeReal(x, r);
      RealTo(x, t);
    end else begin
      Value(x);
      if (s^.form = fInt) and not s^.signed and (s^.size = 8) then begin
        { above high(I64): halve, keeping the low bit, and double }
        L1 := NoLabel; L2 := NoLabel;
        TestRR(RAX, RAX);
        Jcc(ccS, L1);
        Cvtsi2s(0, RAX, f);
        Jmp(L2);
        FixLink(L1);
        MovRR(RCX, RAX);
        ShiftI(shShr, RCX, 1);
        AluI(aluAnd, RAX, 1);
        Alu(aluOr, RCX, RAX);
        Cvtsi2s(0, RCX, f);
        Sse($58, 0, 0, f);
        FixLink(L2);
      end else Cvtsi2s(0, RAX, f);
      MovqRX(RAX, 0);
    end;
  end else if (s^.form = fReal) and (t^.form = fReal) then begin
    { F32 to F64, F64 to F32, or a real constant to either }
    if x.mode = mConst then RealTo(x, t)
    else begin
      Value(x); MovqXR(0, RAX); Sse($5A, 0, 0, IsF32(s)); MovqRX(RAX, 0)
    end;
  end else if (s^.form = fReal) and (t^.form = fInt) then begin
    if x.mode = mConst then begin
      r := RealOf(x);
      if (r <> r) or (r >= 9.2233720368547758e18) or (r < -9.2233720368547758e18) then
        x.val := Cut(low(int64), t)
      else x.val := Cut(trunc(r), t);
    end else begin
      Value(x); MovqXR(0, RAX); Cvtts2si(RAX, 0, IsF32(s)); Norm(t)
    end;
  end else if (IsInt(s) or (s^.form in [fPtr, fProc, fNil])) and (t^.form in [fPtr, fProc]) then begin
    if x.mode <> mConst then Value(x);
  end else if (s^.form in [fPtr, fProc]) and (t^.form = fInt) then begin
    Value(x); Norm(t)
  end else
    MarkAt(x.pos, 'can''t convert ' + TypeName(s) + ' to ' + TypeName(t));
  x.typ := t;
end;

{ Calls }

procedure BeginCall(var c: TCall; var x: TItem);
begin
  if x.mode = mProc then begin
    c.sig := x.obj^.typ; c.chunk := x.obj^.chunk; c.target := 0;
    c.obj := x.obj; c.code := x.obj^.isCode; c.ext := x.obj^.ext;
  end else begin
    c.obj := nil; c.code := false; c.ext := false;
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

procedure PassArg(var c: TCall; var a: TItem);
var p: PObj; s: int64;
begin
  p := c.param;
  if c.n > High(c.slots) then MarkAt(a.pos, 'too many arguments');
  if p = nil then begin
    { past the parameters of a C procedure that ends in ...: a string
      goes as a C string, an integer constant as an I64, a real
      constant as an F64; C takes no F32 there }
    if not c.sig^.variadic then WrongCount(c, a.pos, 'too many arguments');
    if a.mode = mStr then Coerce(a, tPtrU8)
    else if a.typ^.form = fConst then Coerce(a, tI64)
    else if a.typ = tRConst then Coerce(a, tReal)
    else if IsF32(a.typ) then MarkAt(a.pos, 'an F32 goes to ... as F64(x)')
    else if not IsScalar(a.typ) then MarkAt(a.pos, 'only a single value goes to ...');
    c.isF[c.n] := a.typ^.form = fReal;
    c.slots[c.n] := ToSlot(a);
    inc(c.n);
    exit;
  end;
  c.isF[c.n] := (p^.typ^.form = fReal) and not p^.isVar;
  if p^.isVar then begin
    if (a.mode <> mVar) or not a.isVar then MarkAt(a.pos, 'a var parameter needs a variable');
    if not Same(a.typ, p^.typ) then MarkAt(a.pos, 'a var parameter needs exactly ' + TypeName(p^.typ) + ', found ' + What(a));
    if a.vol then MarkAt(a.pos, 'can''t pass through a volatile pointer to a var parameter');
    Address(a, RAX);
    s := AllocTemp(8, 8);
    Store(Mem(RBP, s), RAX, 8);
  end else if IsAggregate(p^.typ) then begin
    Coerce(a, p^.typ);
    if a.isVar or a.vol or (a.base <> bFrame) then CopyToTemp(a);
    Address(a, RAX);
    s := AllocTemp(8, 8);
    Store(Mem(RBP, s), RAX, 8);
  end else begin
    Coerce(a, p^.typ);
    s := ToSlot(a);
  end;
  c.slots[c.n] := s;
  inc(c.n);
  c.param := p^.next;
end;

procedure EndCall(var c: TCall; var x: TItem);
var
  res: PType; i, ni, nf, k, pad: longint; ret: int64;
  onStack: array[0..63] of boolean;
begin
  if c.param <> nil then WrongCount(c, TokPos, 'too few arguments');
  res := c.sig^.base;
  ret := 0;
  ni := 0; nf := 0;
  if (res <> nil) and IsAggregate(res) then begin
    ret := AllocTemp(res^.size, res^.align);
    if not c.code then ni := 1;
  end;
  { the System V classes: each argument in the next free register of
    its kind, or else on the stack }
  k := 0;
  for i := 0 to c.n - 1 do begin
    if c.isF[i] then begin onStack[i] := nf >= 8; if nf < 8 then inc(nf) end
    else begin onStack[i] := ni >= 6; if ni < 6 then inc(ni) end;
    if onStack[i] then inc(k);
  end;
  pad := ord(odd(depth + k));
  if pad <> 0 then AluI(aluSub, RSP, 8);
  for i := c.n - 1 downto 0 do
    if onStack[i] then begin
      Load(RAX, Mem(RBP, c.slots[i]), 8, false);
      Push(RAX);
    end;
  ni := 0; nf := 0;
  if (ret <> 0) and not c.code then begin Lea(RDI, Mem(RBP, ret)); ni := 1 end;
  for i := 0 to c.n - 1 do
    if not onStack[i] then
      if c.isF[i] then begin MovsdXM(nf, Mem(RBP, c.slots[i])); inc(nf) end
      else begin Load(IntRegs[ni], Mem(RBP, c.slots[i]), 8, false); inc(ni) end;
  { a procedure taking ... is told in al how many xmm registers it got }
  if c.sig^.variadic then MovRI(RAX, nf);
  if c.ext then CallM(MemRip(c.chunk, 0))
  else if c.chunk >= 0 then CallChunk(c.chunk)
  else begin
    Load(R11, Mem(RBP, c.target), 8, false);
    CallR(R11);
  end;
  if k + pad > 0 then AluI(aluAdd, RSP, 8 * (k + pad));
  if (ret <> 0) and c.code then begin
    Store(Mem(RBP, ret), RAX, 8);
    Store(Mem(RBP, ret + 8), RDX, 8);
  end;
  FillChar(x, SizeOf(x), 0);
  if res = nil then begin
    x.mode := mNone; x.typ := tNone; x.obj := c.obj
  end else if ret <> 0 then
    TempItem(x, res, ret)
  else begin
    x.mode := mReg; x.typ := res;
    if res^.form = fReal then MovqRX(RAX, 0)
    else if res^.form = fBool then Extend(RAX, 1, false)
    else Norm(res);
  end;
end;

{ Variants }

{ A temporary of type t, all zero: for variants and record literals. }
procedure ZeroTemp(var x: TItem; t: PType);
var tmp: int64;
begin
  tmp := AllocTemp(t^.size, t^.align);
  Lea(RDI, Mem(RBP, tmp));
  MovRI(RCX, t^.size);
  MovRI(RAX, 0);
  RepStosb;
  TempItem(x, t, tmp);
end;

procedure Construct(var x: TItem; c: PObj);
begin
  ZeroTemp(x, c^.typ);
  MovRI(RAX, c^.val);
  Store(Mem(RBP, x.off), RAX, 8);
end;

procedure SetField(const x: TItem; f: PObj; var a: TItem);
begin
  Coerce(a, f^.typ);
  if IsScalar(f^.typ) then begin
    Value(a);
    Store(Mem(RBP, x.off + f^.val), RAX, ScalarSize(f^.typ));
  end else begin
    if a.vol then MarkAt(a.pos, 'can''t copy through a volatile pointer');
    Address(a, RSI);
    Lea(RDI, Mem(RBP, x.off + f^.val));
    Copy(f^.typ^.size);
  end;
end;

{ The slot match tests: a variant's address, or an enumeration's value. }
function MatchBegin(var x: TItem): int64;
var p: int64;
begin
  if x.typ^.form = fEnum then exit(ToSlot(x));
  if (x.mode <> mVar) or (x.typ^.form <> fVariant) then MarkAt(x.pos, 'match needs a variant or an enumeration, found ' + What(x));
  Address(x, RAX);
  p := AllocTemp(8, 8);
  Store(Mem(RBP, p), RAX, 8);
  MatchBegin := p;
end;

procedure MatchTag(p: int64; tag: int64; var L: longint; isEnum: boolean);
begin
  Load(RAX, Mem(RBP, p), 8, false);
  if not isEnum then Load(RAX, Mem(RAX, 0), 8, false);
  CmpI(RAX, tag);
  Jcc(ccNE, L);
end;

{ The end of a round of a for loop: stop if the step would pass the
  limit, else step. Counting the distance left, rather than comparing
  after the step, can't be fooled by the variable wrapping around. }
procedure ForNext(o: PObj; bslot, step: int64; var exitL: longint; top: longint);
var v, w: TItem;
begin
  MakeItem(w, o);
  Value(w);
  Load(RCX, Mem(RBP, bslot), 8, false);
  if step > 0 then begin
    Alu(aluSub, RCX, RAX);
    CmpI(RCX, step);
  end else begin
    Alu(aluSub, RAX, RCX);
    CmpI(RAX, -step);
  end;
  Jcc(ccB, exitL);
  MakeItem(v, o);
  Save(v);
  MakeItem(w, o);
  Value(w);
  MovRI(RCX, step);
  Alu(aluAdd, RAX, RCX);
  Norm(o^.typ);
  Assign(v, w);
  JmpBack(top);
end;

procedure CondJump(var x: TItem; var L: longint);
begin
  if x.typ^.form <> fBool then MarkAt(x.pos, 'a condition is a BOOL, found ' + What(x));
  Value(x);
  TestRR(RAX, RAX);
  Jcc(ccE, L);
end;

{ Procedures }

procedure BeginProc(sig: PType; params: PObj);
var p: PObj; ni, nf: longint; stackOff: int64; f: boolean;
begin
  frameTop := 0; frameMax := 0; permTop := 0; depth := 0;
  exitL := NoLabel;
  numIn := 0;
  result := sig^.base;
  ni := 0; nf := 0; stackOff := 16;
  if (result <> nil) and IsAggregate(result) then begin
    retSlot := AllocPerm(8, 8);
    inReg[0] := RDI; inSlot[0] := retSlot; inSize[0] := 8;
    numIn := 1; ni := 1;
  end;
  p := params;
  while p <> nil do begin
    p^.ind := p^.isVar or IsAggregate(p^.typ);
    f := (p^.typ^.form = fReal) and not p^.isVar;
    if (f and (nf < 8)) or (not f and (ni < 6)) then begin
      p^.val := AllocPerm(8, 8);
      if f then begin inReg[numIn] := -1 - nf; inc(nf) end
      else begin inReg[numIn] := IntRegs[ni]; inc(ni) end;
      inSlot[numIn] := p^.val;
      if p^.ind then inSize[numIn] := 8 else inSize[numIn] := ScalarSize(p^.typ);
      inc(numIn);
    end else begin
      p^.val := stackOff;
      inc(stackOff, 8);
    end;
    p := p^.next;
  end;
  paramTop := frameTop;
end;

{ The prologue, which is for the procedure's first line. }
{ Only the locals are zeroed: the parameters are stored over their
  slots next, and every temporary is written before it is read. The
  locals are all declared by now, below the parameters' slots. }
procedure EnterBody(c, line: longint);
var i, top: longint; n: int64;
begin
  BeginChunk(c);
  NoteLine(line, 1);   { a declaration starts a line }
  Push(RBP);
  MovRR(RBP, RSP);
  Put1($48); Put1($81); Put1($EC);           { sub rsp, imm32 }
  frameFix := pc; Put4(0);
  n := (AlignUp(frameMax, 8) - paramTop) div 8;
  if n > 0 then MovRI(RAX, 0);
  if n <= 4 then
    for i := 1 to n do Store(Mem(RBP, -paramTop - 8 * i), RAX, 8)
  else begin
    { a quadword at a time: r10 counts up to zero }
    MovRI(R10, -n);
    top := pc;
    Store(MemIdx(RBP, R10, 8, -paramTop), RAX, 8);
    AluI(aluAdd, R10, 1);
    JccBack(ccNE, top);
  end;
  for i := 0 to numIn - 1 do
    if inReg[i] < 0 then MovsdMX(Mem(RBP, inSlot[i]), -1 - inReg[i])
    else Store(Mem(RBP, inSlot[i]), inReg[i], inSize[i]);
end;

procedure ReturnValue(var x: TItem);
begin
  if result = nil then MarkAt(x.pos, 'this procedure returns nothing');
  Coerce(x, result);
  if IsAggregate(result) then begin
    if x.vol then MarkAt(x.pos, 'can''t copy through a volatile pointer');
    Address(x, RSI);
    Load(RDI, Mem(RBP, retSlot), 8, false);
    Copy(result^.size);
    Load(RAX, Mem(RBP, retSlot), 8, false);
  end else Value(x);
end;

{ One of several results, into its place behind the hidden pointer. }
procedure ReturnField(f: PObj; var x: TItem);
begin
  Coerce(x, f^.typ);
  if IsScalar(f^.typ) then begin
    Value(x);
    Load(RCX, Mem(RBP, retSlot), 8, false);
    Store(Mem(RCX, f^.val), RAX, ScalarSize(f^.typ));
  end else begin
    if x.vol then MarkAt(x.pos, 'can''t copy through a volatile pointer');
    Address(x, RSI);
    Load(RDI, Mem(RBP, retSlot), 8, false);
    Lea(RDI, Mem(RDI, f^.val));
    Copy(f^.typ^.size);
  end;
end;

{ Several results at once, the call's that return f(x) passes on. }
procedure ReturnAll(var x: TItem);
begin
  Address(x, RSI);
  Load(RDI, Mem(RBP, retSlot), 8, false);
  Copy(result^.size);
end;

{ With the result in rax, as ReturnValue left it. }
procedure ReturnJump;
begin
  if IsAggregate(result) then Load(RAX, Mem(RBP, retSlot), 8, false)
  else if result^.form = fReal then MovqXR(0, RAX);
  Jmp(exitL);
end;

{ Keeps a variable's address in a frame slot, rather than in a register
  or on the stack, while other code runs. }
procedure Pin(var x: TItem);
var s: int64;
begin
  if (x.mode = mVar) and (x.base in [bReg, bStack]) then begin
    Address(x, RAX);
    s := AllocTemp(8, 8);
    Store(Mem(RBP, s), RAX, 8);
    x.base := bSlot;
    x.chunk := s;
  end;
end;

procedure IncDec(var v, k: TItem; dec: boolean);
var n: longint;
begin
  Coerce(k, v.typ);
  Value(k);
  MovRR(RCX, RAX);
  Address(v, RDX);
  n := ScalarSize(v.typ);
  Load(RAX, Mem(RDX, 0), n, v.typ^.signed);
  if dec then Alu(aluSub, RAX, RCX) else Alu(aluAdd, RAX, RCX);
  Store(Mem(RDX, 0), RAX, n);
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
var L: longint; s: int64;
begin
  Coerce(x, tError);
  Value(x);
  s := AllocTemp(16, 8);
  MovRI(RCX, 0);
  L := NoLabel;
  TestRR(RAX, RAX);
  Jcc(ccE, L);
  Load(RCX, Mem(RAX, 0), 8, false);
  Lea(RAX, Mem(RAX, 8));
  FixLink(L);
  Store(Mem(RBP, s), RAX, 8);
  Store(Mem(RBP, s + 8), RCX, 8);
  TempItem(x, tBytes, s);
end;

procedure ReturnNone;
begin
  if result <> nil then Mark('return needs a result of ' + TypeName(result));
  Jmp(exitL);
end;

procedure EndProc(c: longint);
var n: int64;
begin
  if depth <> 0 then Fatal('internal error: stack depth');
  { running off the end returns zeros }
  if result <> nil then
    if IsAggregate(result) then begin
      Load(RDI, Mem(RBP, retSlot), 8, false);
      MovRI(RCX, result^.size);
      MovRI(RAX, 0);
      RepStosb;
      Load(RAX, Mem(RBP, retSlot), 8, false);
    end else begin
      MovRI(RAX, 0);
      MovqXR(0, RAX);
    end;
  FixLink(exitL);
  Leave;
  Ret;
  n := AlignUp(frameMax, 16);
  if n < 16 then n := 16;
  if n > high(longint) then Mark('frame too big');
  Put4At(frameFix, n);
  EndChunk(c);
end;

end.
