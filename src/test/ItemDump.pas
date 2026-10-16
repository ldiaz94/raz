{ Drives item with a fixed pseudo-random script of operands and
  operations, with mistakes among them, and prints what each step gave
  (the item, or that it failed, whose message goes to standard error),
  then the bytes, fixups, line notes and listing (raz -S) of the code
  it made: the seed's side of a test of src/Item.raz, whose
  ItemDump.raz does and prints the same. The argument, a number,
  changes the script. A run ends at the 20th error, as a compile does,
  so several scripts are run. }
program itemdump;
{$mode objfpc}{$H-}
uses diag, scan, seedcontinue, sym, chunk, x64, gen, item;

const
  FirstProc = 3;
  NumProcs = 30;
  FirstGlob = FirstProc + NumProcs;
  NumGlobs = 4;
  Steps = 14;
  YInt = 0; YI64 = 1; YI32 = 2; YU8 = 3; YU16 = 4; YU32 = 5; YU64 = 6; YBool = 7;
  YReal = 8; YF32 = 9; YI8 = 10; YEnum = 11; YSet = 12; YPtr = 13; YVptr = 14;
  YPtrArr = 15; YArr = 16; YArrU8 = 17; YSlice = 18; YBytes = 19; YRec = 20;
  YPacked = 21; YVariant = 22; YProc0 = 23; YProc1 = 24; YProc2 = 25;
  YPtrRec = 26; YErr = 27; YVrec = 28; YVarr = 29;
  NumT = 30;
  IntTypes: array[0..7] of longint = (YInt, YI64, YI32, YU8, YU16, YU32, YU64, YI8);
  Ops: array[0..19] of TSym = (sPlus, sMinus, sTimes, sDiv, sMod,
    sAmp, sBar, sXor, sShl, sShr,
    sEql, sNeq, sLss, sLeq, sGtr, sGeq,
    sSlash, sIn, sPlus, sMinus);
  Cmps: array[0..5] of TSym = (sEql, sNeq, sLss, sLeq, sGtr, sGeq);

var
  Letters: string[9];
  seed: int64;
  ty: array[0..NumT - 1] of PType;
  vars: array[0..NumT - 1] of PObj;
  procs: array[0..5] of PObj;
  strs: array[0..2] of PObj;
  arrConst, typeObj, builtinObj, caseObj: PObj;
  mod0, mod1: PModule;
  tuple2, record3, packedR, variantT: PType;
  results: array[0..8] of PType;
  curRes: longint;
  call: TCall;
  jb: jmp_buf;
  gK: longint;
  gX: TItem;
  gOk: boolean;

function Rnd(n: longint): longint;
begin
  seed := (seed * 1103515245 + 12345) and $7FFFFFFF;
  Rnd := (seed shr 8) mod n;
end;

function Flag: boolean;
begin
  Flag := Rnd(2) = 0;
end;

function Bit(f: boolean): longint;
begin
  if f then Bit := 1 else Bit := 0;
end;

function Pos: TPos;
var p: TPos;
begin
  p.f := 0; p.a := Rnd(400); p.b := p.a + 1 + Rnd(12);
  Pos := p;
end;

function ConstVal: int64;
var x: longint; r: int64;
begin
  x := Rnd(1 shl 30);
  case Rnd(7) of
    0: r := x mod 10;
    1: r := -(x mod 100);
    2: r := int64(1) shl (x mod 20);
    3: r := x;
    4: r := int64(x) * 4096 * 4096 * 9 - 7;
    5: r := -int64(x) * 8;
  else r := x mod 1000 - 500;
  end;
  ConstVal := r;
end;

function InternStr(const s: shortstring): longint;
begin
  InternStr := Intern(@s[1], length(s));
end;

{ A name v00, v01, ... , interned }
function NameOf(i: longint): longint;
var s: string[3];
begin
  s := 'v' + chr(48 + i div 10) + chr(48 + i mod 10);
  NameOf := Intern(@s[1], 3);
end;

function NewObjs(cls: TClass; t: PType; n: longint; step: int64; at: longint): PObj;
var first, o, last: PObj; i: longint;
begin
  first := nil; last := nil;
  for i := 0 to n - 1 do begin
    o := NewObj(cls, NameOf(at + i), t);
    o^.val := step * i;
    if last = nil then first := o else last^.next := o;
    last := o;
  end;
  NewObjs := first;
end;

function ProcType(res: PType; params: PObj; n: longint): PType;
var t: PType;
begin
  t := NewType(fProc, 8, 8);
  t^.base := res;
  t^.fields := params;
  t^.len := n;
  ProcType := t;
end;

function Param(t: PType; isVar: boolean; at: longint): PObj;
var o: PObj;
begin
  o := NewObj(oVar, NameOf(at), t);
  o^.param := true;
  o^.isVar := isVar;
  Param := o;
end;

procedure MakeTypes;
var t: PType; p, q, r: PObj; i: longint;
begin
  ty[YInt] := tInt; ty[YI64] := tI64; ty[YI32] := tI32; ty[YU8] := tU8;
  ty[YU16] := tU16; ty[YU32] := tU32; ty[YU64] := tU64; ty[YBool] := tBool;
  ty[YReal] := tReal; ty[YF32] := tF32; ty[YI8] := tI8; ty[YErr] := tError;
  ty[YBytes] := tBytes;
  t := NewType(fEnum, 1, 1); t^.len := 5; ty[YEnum] := t;
  t := NewType(fSet, 8, 8); t^.len := 5; t^.base := ty[YEnum]; ty[YSet] := t;
  t := NewType(fPtr, 8, 8); t^.base := tI64; ty[YPtr] := t;
  t := NewType(fPtr, 8, 8); t^.base := tI64; t^.vol := true; ty[YVptr] := t;
  t := NewType(fArray, 48, 8); t^.base := tI64; t^.len := 6; ty[YArr] := t;
  t := NewType(fPtr, 8, 8); t^.base := ty[YArr]; ty[YPtrArr] := t;
  t := NewType(fPtr, 8, 8); t^.base := ty[YArr]; t^.vol := true; ty[YVarr] := t;
  t := NewType(fArray, 8, 1); t^.base := tU8; t^.len := 8; ty[YArrU8] := t;
  t := NewType(fSlice, 16, 8); t^.base := tI64; ty[YSlice] := t;
  record3 := NewType(fRecord, 24, 8);
  p := NewObj(oField, NameOf(40), tI64); p^.val := 0;
  q := NewObj(oField, NameOf(41), tReal); q^.val := 8; p^.next := q;
  r := NewObj(oField, NameOf(42), tI32); r^.val := 16; q^.next := r;
  record3^.fields := p;
  ty[YRec] := record3;
  t := NewType(fPtr, 8, 8); t^.base := record3; ty[YPtrRec] := t;
  t := NewType(fPtr, 8, 8); t^.base := record3; t^.vol := true; ty[YVrec] := t;
  packedR := NewType(fRecord, 53, 1);
  packedR^.packd := true;
  p := NewObj(oField, NameOf(43), tU8); p^.val := 0;
  q := NewObj(oField, NameOf(44), tI32); q^.val := 1; p^.next := q;
  r := NewObj(oField, NameOf(46), ty[YArr]); r^.val := 5; q^.next := r;
  packedR^.fields := p;
  ty[YPacked] := packedR;
  variantT := NewType(fVariant, 16, 8);
  ty[YVariant] := variantT;
  tuple2 := NewType(fRecord, 16, 8);
  tuple2^.tuple := true; tuple2^.len := 2; tuple2^.fields := NewObjs(oVar, tInt, 2, 8, 45);
  p := Param(tInt, false, 46); p^.next := Param(tReal, false, 47);
  ty[YProc0] := ProcType(tInt, p, 2);
  ty[YProc1] := ProcType(nil, nil, 0);
  p := Param(tI64, true, 48); p^.next := Param(ty[YSlice], false, 49);
  ty[YProc2] := ProcType(tuple2, p, 2);
  results[0] := nil; results[1] := tInt; results[2] := tReal; results[3] := ty[YSlice];
  results[4] := tuple2; results[5] := record3; results[6] := tF32; results[7] := tI16;
  results[8] := ty[YBytes];
  for i := 0 to NumT - 1 do
    if ty[i] = nil then Fatal('a type is missing');
end;

procedure MakeObjs;
var i, c: longint; o: PObj;
begin
  New(mod0); mod0^.name := InternStr('Zero');
  New(mod1); mod1^.name := InternStr('Other');
  curModule := mod0;
  for i := 0 to 5 do begin
    o := NewObj(oProc, NameOf(50 + i), ty[YProc0 + i mod 3]);
    o^.chunk := FirstProc + Rnd(NumProcs);
    o^.ext := i >= 4;
    o^.isCode := i = 3;
    procs[i] := o;
  end;
  for i := 0 to 2 do begin
    o := NewObj(oConst, NameOf(60 + i), tStr);
    o^.val := 2 + 3 * i;
    c := NewChunk(secRodata, -1, -1);
    SetData(c, @Letters[1], o^.val + 1, 1);
    o^.chunk := c;
    strs[i] := o;
  end;
  arrConst := NewObj(oConst, NameOf(63), ty[YArr]);
  arrConst^.chunk := NewChunk(secRodata, -1, -1);
  SetData(arrConst^.chunk, @Letters[1], 8, 8);
  typeObj := NewObj(oType, NameOf(64), ty[YRec]);
  builtinObj := NewObj(oBuiltin, NameOf(65), tNone);
  caseObj := NewObj(oCase, NameOf(66), variantT);
  caseObj^.val := 3;
  caseObj^.fields := NewObjs(oField, tInt, 2, 8, 67);
  caseObj^.fields^.val := 8;
end;

procedure MakeVars;
var i, k: longint; o: PObj; t: PType;
begin
  for i := 0 to NumT - 1 do begin
    t := ty[i];
    o := NewObj(oVar, NameOf(i), t);
    o^.lev := 1;
    k := Rnd(9);
    if k = 2 then begin
      o^.lev := 0; o^.chunk := FirstGlob + Rnd(NumGlobs);
    end else if k = 3 then begin
      o^.ind := true; o^.val := AllocPerm(8, 8); o^.off := 8 * Rnd(3);
    end else if k = 4 then begin
      if (t^.form in [fInt, fPtr]) and (t^.size = 8) then
        o^.reg := VarRegs[Rnd(5)]
      else if t^.form = fReal then
        o^.reg := XVarRegs[Rnd(4)]
      else if t^.form = fSlice then begin
        o^.reg := VarRegs[Rnd(3)]; o^.reg2 := VarRegs[3 + Rnd(2)];
      end;
      if o^.reg = 0 then o^.val := AllocPerm(t^.size, 8);
    end else if k = 5 then begin
      o^.lev := 0; o^.chunk := FirstGlob + Rnd(NumGlobs); o^.module := mod1;
    end else if k = 6 then begin
      o^.lev := 0; o^.chunk := FirstGlob + Rnd(NumGlobs); o^.ext := true;
    end else
      o^.val := AllocPerm(t^.size + 8, 8);
    vars[i] := o;
  end;
end;

{ Operands }

function IntType: PType;
begin
  IntType := ty[IntTypes[Rnd(8)]];
end;

procedure VarItem(var x: TItem; t: PType);
var i, k: longint;
begin
  k := Rnd(NumT);
  for i := 0 to NumT - 1 do
    if ty[i] = t then k := i;
  FillChar(x, SizeOf(x), 0);
  x.pos := Pos;
  MakeItem(x, vars[k]);
end;

procedure Operand(var x: TItem; t: PType);
var k: longint; r: double; v: int64;
begin
  FillChar(x, SizeOf(x), 0);
  x.pos := Pos;
  if t = nil then begin
    case Rnd(14) of
      0: MakeConst(x, tConst, ConstVal);
      1: MakeConst(x, tConst, ConstVal mod 200);
      2: begin t := IntType; v := ConstVal mod 100; MakeConst(x, t, v) end;
      3: begin r := (ConstVal mod 1000) / 8.0; MakeReal(x, r) end;
      4: MakeConst(x, tBool, Rnd(2));
      5: MakeItem(x, strs[Rnd(3)]);
      6: MakeConst(x, tNil, 0);
      7: MakeItem(x, procs[Rnd(6)]);
      8: begin
        if Rnd(4) = 0 then begin
          case Rnd(3) of
            0: MakeItem(x, typeObj);
            1: MakeItem(x, builtinObj);
          else MakeItem(x, caseObj);
          end;
        end else
          MakeItem(x, arrConst);
      end;
      13: begin MakeItem(x, vars[Rnd(NumT)]); Value(x) end;
    else VarItem(x, ty[Rnd(NumT)]);
    end;
    exit;
  end;
  k := Rnd(10);
  if IsInt(t) then begin
    if k < 3 then begin MakeConst(x, tConst, ConstVal mod 100); exit end;
    if k = 3 then begin MakeConst(x, t, ConstVal mod 100); exit end;
  end else if t^.form = fReal then begin
    if k < 3 then begin r := (ConstVal mod 1000) / 8.0; MakeReal(x, r); exit end;
  end else if t^.form = fBool then begin
    if k < 3 then begin MakeConst(x, tBool, Rnd(2)); exit end;
  end else if t^.form = fPtr then begin
    if k < 2 then begin MakeConst(x, tNil, 0); exit end;
  end else if (t^.form = fSlice) and (t^.base = tU8) then begin
    if k < 3 then begin MakeItem(x, strs[Rnd(3)]); exit end;
  end;
  VarItem(x, t);
end;

procedure CondItem(var x: TItem);
var y: TItem; L: longint; op: TSym; t: PType;
begin
  t := IntType;
  op := Cmps[Rnd(6)];
  Operand(x, t);
  Op1(op, x, L);
  Operand(y, t);
  Op2(op, x, y, L);
end;

procedure Place(var x: TItem);
var i, k: longint; f: PObj; y, lo, hi: TItem;
begin
  VarItem(x, ty[Rnd(NumT)]);
  for i := 1 to 3 do begin
    if Rnd(3) <> 0 then begin
      k := Rnd(6);
      if (k = 0) or (x.typ^.form = fPtr) then
        Deref(x)
      else if x.typ^.form = fRecord then begin
        f := x.typ^.fields;
        k := Rnd(3);
        while (k > 0) and (f^.next <> nil) do begin f := f^.next; dec(k) end;
        Field(x, f);
      end else if x.typ^.form in [fArray, fSlice, fStr] then begin
        IndexPrep(x);
        if k < 4 then begin
          Operand(y, IntType);
          Index(x, y);
        end else begin
          Operand(lo, IntType);
          SliceLo(lo);
          Operand(hi, IntType);
          Slice(x, lo, hi);
        end;
      end;
    end;
  end;
end;

procedure Dump(var x: TItem);
var name: shortstring; flags: longint;
begin
  name := '-';
  if x.typ <> nil then name := TypeName(x.typ);
  flags := Bit(x.vol) + 2 * Bit(x.isVar) + 4 * Bit(x.odd) + 8 * Bit(x.ro) + 16 * Bit(x.deref);
  write('I ', ord(x.mode), ' ', name, ' ', ord(x.rel), ' ', Bit(x.relSigned), ' ', x.fj, ' ', x.tj, ' ', x.val);
  writeln(' ', ord(x.base), ' ', x.chunk, ' ', x.off, ' ', flags, ' depth ', depth, ' pushed ', pushed);
end;

procedure DoCall(var x: TItem);
var f, a: TItem; p: PObj; n: longint;
begin
  FillChar(f, SizeOf(f), 0);
  f.pos := Pos;
  if Rnd(5) = 0 then MakeItem(f, vars[YProc0 + Rnd(3)])
  else MakeItem(f, procs[Rnd(6)]);
  BeginCall(call, f);
  p := call.param;
  n := Rnd(4) - 1;
  while (p <> nil) or (n > 0) do begin
    if p <> nil then begin
      if p^.isVar and (Rnd(2) = 0) then begin
        VarItem(a, ty[YVptr]);
        Deref(a);
      end else if Rnd(6) = 0 then Operand(a, nil)
      else Operand(a, p^.typ);
      p := p^.next;
    end else begin
      Operand(a, nil);
      n := n - 1;
    end;
    PassArg(call, a);
    if (p = nil) and (n < 0) then n := 0;
    if (p <> nil) and (n < 0) and (Rnd(4) = 0) then begin p := nil; n := 0 end;
  end;
  EndCall(call, x);
end;

procedure Binary(var x: TItem);
var y: TItem; L, M: longint; op: TSym; t: PType;
begin
  L := NoLabel;
  M := NoLabel;
  op := Ops[Rnd(20)];
  case Rnd(8) of
    0, 1: t := IntType;
    2: t := ty[YReal + Rnd(2)];
    3: t := ty[YBool];
    4: t := ty[YEnum + Rnd(2)];
  else t := ty[Rnd(NumT)];
  end;
  if Rnd(6) = 0 then begin
    if Flag then op := sAnd else op := sOr;
    CondItem(x);
    Op1(op, x, L);
    CondItem(y);
  end else if op = sIn then begin
    Operand(x, ty[YEnum]);
    Op1(op, x, L);
    Operand(y, ty[YSet]);
  end else begin
    Operand(x, t);
    Op1(op, x, L);
    if Rnd(5) = 0 then Operand(y, nil) else Operand(y, t);
  end;
  Op2(op, x, y, L);
  if (x.mode = mCond) and (Rnd(3) <> 0) then begin
    if Flag then CondJump(x, M) else CondJumpTrue(x, M);
    Fix(M);
    x.mode := mNone;
  end;
end;

procedure Unary(var x: TItem);
begin
  Operand(x, nil);
  case Rnd(3) of
    0: Neg(x);
    1: NotOp(x);
  else Complement(x);
  end;
end;

procedure DoMatch(var x: TItem);
var p, lo, hi: int64; L: longint;
begin
  L := NoLabel;
  case Rnd(3) of
    0: VarItem(x, ty[YVariant]);
    1: VarItem(x, ty[YEnum]);
  else Operand(x, nil);
  end;
  p := MatchBegin(x);
  MatchTag(p, ConstVal mod 10, L);
  lo := ConstVal mod 10;
  hi := ConstVal mod 10 + 10;
  MatchRange(p, lo, hi, L);
  MatchRange(p, 3, 3, L);
  Fix(L);
end;

procedure DoFor(var x: TItem);
var o: PObj; lim: TItem; step: int64; exitL: longint;
begin
  o := vars[IntTypes[Rnd(8)]];
  step := ConstVal mod 5;
  if step = 0 then step := 1;
  if Rnd(2) = 0 then step := -step;
  FillChar(lim, SizeOf(lim), 0);
  lim.pos := Pos;
  MakeConst(lim, o^.typ, ConstVal mod 50);
  exitL := NoLabel;
  ForStep(o, step);
  ForNext(o, lim, step, exitL, pc, pc);
  Fix(exitL);
  x := lim;
end;

procedure DoMisc(var x: TItem);
var y: TItem;
begin
  case Rnd(5) of
    0: begin
      Place(x);
      Address(x);
      Operand(y, x.typ);
      IncDec(x, y, Flag);
    end;
    1: begin
      Place(x);
      Pin(x);
    end;
    2: begin
      Place(x);
      CopyDest(x);
      Place(y);
      CopyFrom(x, y);
    end;
    3: begin
      Operand(x, nil);
      MakeStr(y);
      Coerce(y, ty[YBytes]);
    end;
  else begin
    Operand(x, nil);
    NilTest(x);
    UsesReals(x.pos);
    Discard(x);
  end;
  end;
end;

procedure DoTemp(var x: TItem);
var a: TItem; c, h, n: longint; f: PObj;
begin
  FillChar(x, SizeOf(x), 0);
  x.pos := Pos;
  case Rnd(5) of
    0: ZeroTemp(x, ty[YVariant]);
    1: begin
      Construct(x, caseObj);
      f := caseObj^.fields;
      Operand(a, f^.typ);
      SetField(x, f, a);
    end;
    2: begin
      ZeroTemp(x, ty[YRec]);
      f := ty[YRec]^.fields;
      if Flag then f := f^.next;
      Operand(a, f^.typ);
      SetField(x, f, a);
    end;
    3: begin
      Operand(a, nil);
      h := Rnd(3) - 1;
      n := Rnd(3) - 1;
      c := ErrorChunk(a, h, n);
      MakeConst(x, tError, int64(c) + 1);
    end;
  else begin
    Operand(x, ty[YErr]);
    Msg(x);
  end;
  end;
end;

procedure DoReturn(var x: TItem);
var f: PObj;
begin
  if (curRes = 4) and Flag then begin
    f := tuple2^.fields;
    if Flag then f := f^.next;
    if Flag then begin
      Operand(x, f^.typ);
      ReturnField(f, x);
      exit;
    end;
    DoCall(x);
    ReturnAll(x);
    exit;
  end;
  if Rnd(4) = 0 then begin ReturnNone; exit end;
  Operand(x, results[curRes]);
  ReturnValue(x);
end;

procedure Step(k: longint; var x: TItem);
var y: TItem;
begin
  FillChar(x, SizeOf(x), 0);
  case k of
    0: begin Operand(x, nil); Value(x) end;
    1: begin Operand(x, nil); Address(x) end;
    2: begin Operand(x, nil); Coerce(x, ty[Rnd(NumT)]) end;
    3: begin Operand(x, nil); CoerceExact(x, IntType, '') end;
    4: begin
      Place(x);
      Operand(y, x.typ);
      Assign(x, y);
    end;
    5: Unary(x);
    6: Binary(x);
    7: begin Operand(x, nil); Convert(x, ty[Rnd(NumT)]) end;
    8: Place(x);
    9: DoCall(x);
    10: DoMatch(x);
    11: DoFor(x);
    12: DoMisc(x);
    13: DoTemp(x);
    14: DoReturn(x);
  else Binary(x);
  end;
end;

{ A step, and what it leaves, each a recovery point as the parser's
  statements are }
procedure RunStep;
begin
  gOk := false;
  recovery := @jb;
  if setjmp(jb) = 0 then begin
    Step(gK, gX);
    gOk := true;
  end;
  recovery := nil;
end;

procedure RunDiscard;
begin
  recovery := @jb;
  if setjmp(jb) = 0 then Discard(gX);
  recovery := nil;
end;

procedure GenProc(c: longint);
var sig: PType; i, line: longint;
begin
  curRes := Rnd(9);
  sig := ProcType(results[curRes], nil, 0);
  BeginProc(sig, nil);
  for i := 0 to 5 do AllocPerm(8, 8);
  MakeVars;
  checks := Flag;
  line := 1 + Rnd(40);
  EnterBody(c, line);
  for i := 1 to Steps do begin
    if errors >= 19 then break;
    gK := Rnd(17);
    demoted := false;
    RunStep;
    if not gOk then
      writeln('S ', c, ' ', gK, ' failed')
    else begin
      writeln('S ', c, ' ', gK, ' ok');
      Dump(gX);
      if (gK < 4) or ((gK >= 5) and (gK <= 9)) then RunDiscard;
    end;
    writeln('demoted ', Bit(demoted));
    ResetStack(0, 0);
  end;
  EndProc(c, sig^.base <> nil);
end;

function ChunkNameOf(i: longint): longint;
var s: string;
begin
  s := 'p' + chr(48 + i div 10) + chr(48 + i mod 10);
  ChunkNameOf := Intern(@s[1], 3);
end;

var
  i, c: longint; path: string;
begin
  seed := 5;
  for i := 1 to length(ParamStr(1)) do seed := seed * 10 + ord(ParamStr(1)[i]) - 48;
  Letters := 'abcdefgh' + #0;
  path := 'src/test/ItemDump.txt';
  if Open(path) <> '' then Fatal('no file');
  Next;
  listing := true;
  curFile := Intern(@path[1], length(path));
  for i := 0 to NumProcs - 1 do begin c := NewChunk(secText, -1, ChunkNameOf(i)); chunks^[c].live := true end;
  for i := 0 to NumGlobs - 1 do begin
    c := NewChunk(secBss, -1, ChunkNameOf(NumProcs + i));
    SetBss(c, 64, 8);
  end;
  MakeTypes;
  MakeObjs;
  for i := 0 to NumProcs - 1 do GenProc(FirstProc + i);
  writeln('pc ', pc, ' fixups ', numFixups, ' lines ', numLines, ' said ', SaidCount);
  for i := 0 to pc - 1 do write(HexStr(code^[i], 2));
  writeln;
  for i := 0 to numFixups - 1 do writeln('F ', fixups^[i].at, ' ', fixups^[i].chunk, ' ', fixups^[i].addend);
  for i := 0 to numLines - 1 do writeln('L ', lines^[i].at, ' ', lines^[i].chunk, ' ', lines^[i].line, ' ', lines^[i].col);
  List(-1);
end.
