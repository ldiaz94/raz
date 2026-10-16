{ Compiles procedures made by a fixed pseudo-random script of calls to
  Gen, valid by construction, then prints the bytes, the fixups and the
  listing (raz -S) of what it made: the seed's side of a test of
  src/Gen.raz, whose GenDump.raz makes and prints the same. With an
  argument, the entry point is the dynamic one. }
program gendump;
{$mode objfpc}{$H-}
uses diag, scan, seedcontinue, sym, chunk, x64, gen;

const
  FirstProc = 3;
  NumProcs = 80;
  FirstGlob = FirstProc + NumProcs;
  NumGlobs = 4;
  Arith: array[0..9] of TSym = (sPlus, sMinus, sTimes, sDiv, sMod, sAmp, sBar, sXor, sShl, sShr);
  Cmps: array[0..5] of TSym = (sEql, sNeq, sLss, sLeq, sGtr, sGeq);
  RealOps: array[0..3] of TSym = (sPlus, sMinus, sTimes, sSlash);

var
  seed: int64;
  slots: array[0..5] of int64;
  regs: array[0..4] of longint;
  numRegs: longint;
  xregs: array[0..3] of longint;
  numX: longint;
  tuple2, tuple3, record3, sliceT: PType;
  results: array[0..8] of PType;
  curRes: longint;

function Rnd(n: longint): longint;
begin
  seed := (seed * 1103515245 + 12345) and $7FFFFFFF;
  Rnd := (seed shr 8) mod n;
end;

function Pos: TPos;
var p: TPos;
begin
  p.f := 0; p.a := Rnd(400); p.b := p.a + 1;
  Pos := p;
end;

function Size: longint;
begin
  Size := 1 shl Rnd(4);
end;

function Slot: int64;
begin
  Slot := slots[Rnd(6)];
end;

function Bit(f: boolean): longint;
begin
  if f then Bit := 1 else Bit := 0;
end;

function Flag: boolean;
begin
  Flag := Rnd(2) = 0;
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

function NewObjs(t: PType; n: longint): PObj;
var first, o, last: PObj; i: longint;
begin
  first := nil; last := nil;
  for i := 0 to n - 1 do begin
    o := NewObj(oVar, 0, t);
    o^.val := 8 * i;
    if last = nil then first := o else last^.next := o;
    last := o;
  end;
  NewObjs := first;
end;

procedure MakeTypes;
begin
  tuple2 := NewType(fRecord, 16, 8);
  tuple2^.tuple := true; tuple2^.len := 2; tuple2^.fields := NewObjs(tInt, 2);
  tuple3 := NewType(fRecord, 24, 8);
  tuple3^.tuple := true; tuple3^.len := 3; tuple3^.fields := NewObjs(tInt, 3);
  record3 := NewType(fRecord, 24, 8);
  record3^.fields := NewObjs(tReal, 3);
  sliceT := NewType(fSlice, 16, 8);
  sliceT^.base := tU8;
  results[0] := nil;
  results[1] := tInt;
  results[2] := tReal;
  results[3] := sliceT;
  results[4] := tuple2;
  results[5] := tuple3;
  results[6] := tF32;
  results[7] := tI16;
  results[8] := record3;
end;

function MemAdr: TAdr;
var a: TAdr; c: longint;
begin
  c := Rnd(3);
  if c = 0 then begin
    a.base := bFrame; a.chunk := 0; a.hi := 0; a.off := Slot; if Flag then a.off := a.off + 8;
  end else if c = 1 then begin
    a.base := bGlobal; a.chunk := FirstGlob + Rnd(NumGlobs); a.hi := 0; a.off := 8 * Rnd(3);
  end else begin
    a.base := bSlot; a.chunk := Slot; a.hi := 0; a.off := 8 * Rnd(3);
  end;
  MemAdr := a;
end;

function PushableAdr: TAdr;
var a: TAdr;
begin
  a.chunk := 0; a.hi := 0;
  if Flag then begin
    a.base := bFrame; a.off := Slot; if Flag then a.off := a.off + 8;
  end else begin
    a.base := bGlobal; a.chunk := FirstGlob + Rnd(NumGlobs); a.off := 8 * Rnd(3);
  end;
  PushableAdr := a;
end;

function RegAdr(r: longint): TAdr;
var a: TAdr;
begin
  a.base := bReg; a.chunk := r; a.hi := 0; a.off := 0;
  RegAdr := a;
end;

function StackAdr: TAdr;
var a: TAdr;
begin
  a.base := bStack; a.chunk := 0; a.hi := 0; a.off := 8 * Rnd(3);
  StackAdr := a;
end;

procedure PushIntVar;
var a: TAdr; sz, c: longint;
begin
  sz := Size;
  c := Rnd(5);
  if (c = 0) and (numRegs > 0) then begin
    if Flag then inPlace := regs[Rnd(numRegs)];
    PushVar(RegAdr(regs[Rnd(numRegs)]), 8, false, kWord);
  end else if c = 1 then begin
    PushAdr(PushableAdr);
    a := StackAdr;
    PushVar(a, sz, Flag, kWord);
  end else begin
    a := MemAdr;
    PushVar(a, sz, Flag, kWord);
  end;
end;

procedure IntExpr(b: longint); forward;
procedure RealExpr(k: TKind; b: longint); forward;
procedure CallExpr(want, b: longint); forward;

function RealKind: TKind;
begin
  if Flag then RealKind := kF64 else RealKind := kF32;
end;

procedure IntExpr(b: longint);
var c, sz, n: longint; sg, f: boolean; k: TKind; sy: TSym; a: TAdr;
begin
  if b > 0 then c := Rnd(14) else c := Rnd(3);
  case c of
    0: PushConst(kWord, ConstVal);
    1: PushIntVar;
    2: PushIntVar;
    3, 4, 5: begin
      IntExpr(b - 1); IntExpr(b - 1);
      sy := Arith[Rnd(10)]; sz := Size; sg := Flag;
      Op(sy, kWord, sz, sg);
    end;
    6:
      if Flag then begin
        IntExpr(b - 1); IntExpr(b - 1);
        sy := Cmps[Rnd(6)]; sg := Flag;
        Compare(sy, kWord, sg);
      end else begin
        k := RealKind;
        RealExpr(k, b - 1); RealExpr(k, b - 1);
        sy := Cmps[Rnd(6)];
        Compare(sy, k, false);
      end;
    7: begin
      IntExpr(b - 1);
      n := Rnd(4); sz := Size; sg := Flag;
      if n = 0 then Neg(kWord, sz, sg)
      else if n = 1 then Complement(sz, sg)
      else if n = 2 then NotBool
      else Narrow(sz, sg);
    end;
    8: begin
      IntExpr(b - 1);
      a := PushableAdr;
      sz := Size; sg := Flag;
      n := 10 + Rnd(100);
      CheckIndex(n, Pos);
      IndexArray(a, sz);
      a := StackAdr; a.off := 0;
      PushVar(a, sz, sg, kWord);
    end;
    9: begin
      n := Rnd(3);
      sz := Size; sg := Flag;
      if n = 0 then begin
        a := MemAdr;
        if a.base = bGlobal then a.base := bFrame;
        IntExpr(b - 1);
        f := Flag;
        IndexSlice(a, sz, f, Pos);
      end else if n = 1 then begin
        PushAdr(PushableAdr);
        IntExpr(b - 1);
        a := StackAdr; a.off := 0;
        f := Flag;
        IndexSlice(a, sz, f, Pos);
      end else begin
        a.base := bReg; a.chunk := R13; a.hi := R14; a.off := 0;
        IntExpr(b - 1);
        f := Flag;
        IndexSlice(a, sz, f, Pos);
      end;
      a := StackAdr; a.off := 0;
      PushVar(a, sz, sg, kWord);
    end;
    10: begin
      k := RealKind;
      RealExpr(k, b - 1);
      RealToInt(k);
    end;
    11: CallExpr(1, b - 1);
    12: begin
      IntExpr(b - 1);
      PushConst(kWord, Rnd(100) - 50);
      Op(sPlus, kWord, 8, false);
    end;
  else begin
    IntExpr(b - 1);
    PushConst(kWord, ConstVal);
    sy := Arith[Rnd(10)]; sz := Size; sg := Flag;
    Op(sy, kWord, sz, sg);
  end;
  end;
end;

procedure RealExpr(k: TKind; b: longint);
var c, n: longint; sy: TSym; a: TAdr; k2: TKind; v: int64;
begin
  if b > 0 then c := Rnd(9) else c := Rnd(3);
  case c of
    0: begin
      n := Rnd(4);
      if n = 0 then v := $3FF0000000000000
      else if n = 1 then v := $4000000000000000
      else if n = 2 then v := 0
      else v := $3FE0000000000000;
      PushConst(k, v);
    end;
    1: begin
      a := MemAdr;
      if k = kF32 then PushVar(a, 4, false, k) else PushVar(a, 8, false, k);
    end;
    2:
      if numX > 0 then begin
        if Flag then inPlace := xregs[Rnd(numX)];
        PushVar(RegAdr(xregs[Rnd(numX)]), 8, false, k);
      end else begin
        PushAdr(PushableAdr);
        a := StackAdr;
        PushVar(a, 8, false, k);
      end;
    3, 4: begin
      RealExpr(k, b - 1); RealExpr(k, b - 1);
      sy := RealOps[Rnd(4)];
      Op(sy, k, 8, false);
    end;
    5: begin
      IntExpr(b - 1);
      IntToReal(k, Flag);
    end;
    6: begin
      RealExpr(k, b - 1);
      Neg(k, 8, false);
    end;
    7: begin
      if k = kF32 then k2 := kF64 else k2 := kF32;
      RealExpr(k2, b - 1);
      RealToReal(k2);
    end;
  else CallExpr(2, b - 1);
  end;
end;

procedure CallExpr(want, b: longint);
var
  c: TCall; sig: PType; i, n, kind, r, ni: longint; k: TKind;
begin
  sig := NewType(fProc, 8, 8);
  sig^.variadic := Rnd(5) = 0;
  if want = 1 then begin
    r := Rnd(5);
    if r = 0 then sig^.base := tBool
    else if r = 1 then sig^.base := tI8
    else if r = 2 then sig^.base := tU32
    else if r = 3 then sig^.base := tuple2
    else sig^.base := tInt;
  end else if want = 2 then begin
    if Flag then sig^.base := tReal else sig^.base := tF32;
  end else
    sig^.base := results[Rnd(9)];
  c.sig := sig; c.param := nil; c.obj := nil; c.ext := Rnd(4) = 0;
  c.n := 0; c.target := 0;
  c.chunk := FirstProc + Rnd(NumProcs);
  if Rnd(5) = 0 then begin c.chunk := -1; c.ext := false; c.target := Slot end;
  n := Rnd(8);
  for i := 0 to n - 1 do begin
    kind := Rnd(4);
    if kind = 0 then begin
      k := RealKind;
      RealExpr(k, b);
      c.isF[c.n] := true; c.pair[c.n] := false;
      inc(c.n);
    end else if kind = 1 then begin
      IntExpr(b); IntExpr(b);
      c.isF[c.n] := false; c.pair[c.n] := true;
      c.isF[c.n + 1] := false; c.pair[c.n + 1] := false;
      inc(c.n, 2);
    end else begin
      IntExpr(b);
      c.isF[c.n] := false; c.pair[c.n] := false;
      inc(c.n);
    end;
  end;
  Call(c);
  ni := 0;
  if sig^.base <> nil then begin
    if sig^.base^.form = fSlice then ni := 0
    else if sig^.base = tuple2 then ni := 2
    else if BehindPointer(sig^.base) then ni := 0
    else ni := 1;
  end;
  if want = 0 then begin
    for i := 1 to ni do Drop;
  end else if ni = 2 then
    Drop;
end;

procedure BoolExpr(b: longint);
var sy: TSym; sg: boolean;
begin
  if Flag then begin
    IntExpr(b); IntExpr(b);
    sy := Cmps[Rnd(6)]; sg := Flag;
    Compare(sy, kWord, sg);
  end else
    IntExpr(b);
end;

procedure Stmt(b: longint); forward;

procedure Assign(b: longint);
var a: TAdr; c, sz: longint; k: TKind;
begin
  c := Rnd(6);
  sz := Size;
  if c = 0 then begin
    a := MemAdr;
    IntExpr(b);
    PopVar(a, sz);
  end else if c = 1 then begin
    PushAdr(PushableAdr);
    a := StackAdr;
    IntExpr(b);
    PopVar(a, sz);
  end else if (c = 2) and (numRegs > 0) then begin
    a := RegAdr(regs[Rnd(numRegs)]);
    inPlace := a.chunk;
    PushVar(a, 8, false, kWord);
    IntExpr(b);
    Op(Arith[Rnd(3)], kWord, 8, false);
    PopVar(a, 8);
  end else if (c = 3) and (numX > 0) then begin
    k := RealKind;
    a := RegAdr(xregs[Rnd(numX)]);
    RealExpr(k, b);
    PopVar(a, 8);
  end else if c = 4 then begin
    k := RealKind;
    a := MemAdr;
    RealExpr(k, b);
    if k = kF32 then PopVar(a, 4) else PopVar(a, 8);
  end else begin
    a := MemAdr;
    PushConst(kWord, ConstVal);
    PopVar(a, sz);
  end;
end;

procedure RetStmt(b: longint);
var i: longint;
begin
  if curRes = 1 then IntExpr(b)
  else if curRes = 7 then IntExpr(b)
  else if curRes = 2 then RealExpr(kF64, b)
  else if curRes = 6 then RealExpr(kF32, b)
  else if (curRes = 3) or (curRes = 4) then begin IntExpr(b); IntExpr(b) end
  else if curRes = 5 then begin
    for i := 0 to 2 do begin IntExpr(b); ResultTo(8 * i, 8) end;
  end else if curRes = 8 then begin
    PushAdr(PushableAdr);
    CopyResult(0, 24);
  end;
  ReturnJump;
end;

procedure Stmt(b: longint);
var
  c, n, lo, i, start, saved, sz, tmp: longint; L, E, S, fj, tj: longint; a, a2: TAdr; sy: TSym; sg: boolean;
  mk: int64; f: boolean;
begin
  mk := TempMark;
  if b <= 0 then c := Rnd(4) else c := Rnd(22);
  case c of
    0, 1, 2, 3: Assign(b);
    4: begin
      L := NoLabel;
      BoolExpr(b);
      JumpIf(L, false);
      Stmt(b - 1);
      Fix(L);
    end;
    5: begin
      L := NoLabel;
      AlignLoop;
      start := pc;
      BoolExpr(b);
      JumpIf(L, false);
      Stmt(b - 1);
      JumpBack(start);
      Fix(L);
    end;
    6: begin
      L := NoLabel;
      IntExpr(b); IntExpr(b);
      sy := Cmps[Rnd(6)]; sg := Flag;
      if Flag then JumpCmp(sy, sg, L) else JumpOut(sy, sg, L);
      Stmt(b - 1);
      Fix(L);
    end;
    7: begin
      fj := NoLabel; tj := NoLabel;
      IntExpr(b); IntExpr(b);
      sy := Cmps[Rnd(6)]; sg := Flag;
      CondValue(sy, sg, fj, tj);
      a := MemAdr;
      PopVar(a, 1);
    end;
    8: CallExpr(0, b);
    9: begin
      a := MemAdr;
      if a.base = bSlot then begin a.base := bFrame; a.off := slots[0] end;
      IntExpr(b);
      PopVar(a, 8);
      E := NoLabel;
      n := 2 + Rnd(4); lo := Rnd(5) - 2;
      if Flag then S := NoLabel else S := pc;
      start := JumpTable(a.off, lo, n, S, E);
      for i := 0 to n - 1 do TableEntry(start, pc + 4 * (n - i));
      for i := 0 to n - 1 do
        Stmt(b - 1);
      Fix(E);
    end;
    10: begin
      PushAdr(PushableAdr); PushAdr(PushableAdr);
      n := 1 + Rnd(150); lo := 8 * Rnd(3);
      CopyBlock(n, lo);
    end;
    11: begin
      PushAdr(PushableAdr);
      a := MemAdr;
      if Flag and (numRegs > 1) then begin
        a.base := bReg; a.chunk := regs[0]; a.hi := regs[1]; a.off := 0;
      end;
      n := 1 + Rnd(150);
      CopyTo(a, n);
    end;
    12: begin
      a := MemAdr;
      n := 1 + Rnd(100);
      ZeroVar(a, n);
    end;
    13: begin
      tmp := AllocTemp(16, 8);
      n := Rnd(3);
      sz := Size; sg := Flag;
      if n = 0 then begin
        a := PushableAdr;
        PushAdr(a); IntExpr(b); IntExpr(b);
        a := StackAdr; a.off := 0;
        f := Flag; n := 10 + Rnd(50);
        Slice(a, f, n, sz, tmp, sg, Pos);
      end else if n = 1 then begin
        a := MemAdr;
        if a.base = bGlobal then a.base := bFrame;
        IntExpr(b); IntExpr(b);
        Slice(a, false, 0, sz, tmp, sg, Pos);
      end else begin
        IntExpr(b); IntExpr(b); IntExpr(b);
        SlicePtr(sz, tmp, sg, Pos);
      end;
    end;
    14: begin
      a.off := Slot; a2.off := Slot; sz := Size; f := Flag;
      CopySlice(a.off, a2.off, sz, f, Pos);
    end;
    15: begin
      n := Rnd(4); sz := Size; sg := Flag;
      if n = 0 then begin
        PushAdr(PushableAdr); IntExpr(b);
        f := Flag;
        IncDec(sz, sg, f);
      end else if (n = 1) and (numRegs > 0) then begin
        IntExpr(b);
        IncDecReg(regs[0], sz, sg, Flag);
      end else if n = 2 then begin
        IntExpr(b);
        n := 3 + Rnd(6); lo := FirstGlob + Rnd(NumGlobs);
        CheckEnum(n, lo, Pos);
        Drop;
      end else begin
        IntExpr(b);
        n := Rnd(8000);
        CheckNil(n, Pos);
        Drop;
      end;
    end;
    16: begin
      n := Rnd(3);
      if n = 0 then begin
        a.off := Slot; a2.off := Slot; n := Rnd(4); f := Flag;
        CompareSeq(a.off, a2.off, n, f);
        Drop;
      end else if n = 1 then begin
        IntExpr(b);
        ErrorText(AllocTemp(16, 8));
      end else begin
        IntExpr(b);
        n := 1 + Rnd(200);
        ZeroNew(n);
        Drop;
      end;
    end;
    17: begin
      n := Rnd(3);
      if n = 0 then begin
        IntExpr(b); IntExpr(b); IntExpr(b);
        Atomic(bCas);
      end else if n = 1 then begin
        IntExpr(b); IntExpr(b);
        Atomic(bXchg);
      end else begin
        IntExpr(b); IntExpr(b);
        Atomic(bXadd);
      end;
      Drop;
    end;
    18: begin
      n := Rnd(7);
      for i := 1 to n do IntExpr(b);
      SysCall(n);
      Drop;
      if Flag then Fence;
    end;
    19: begin
      L := NoLabel;
      start := DeferBegin(L, saved);
      Stmt(b - 1);
      DeferEnd(L, saved);
      RunDefer(start);
    end;
    20: if curRes <> 0 then RetStmt(b) else Assign(b);
  else
    if curRes <> 0 then begin
      TryAlign;
      TryReturn(Slot);
    end else
      Assign(b);
  end;
  ReleaseTemps(mk);
end;

procedure GenProc(c: longint);
var
  sig: PType; params, p, last: PObj; i, n, kind, mask, j, ns, line: longint; t: PType;
  mk: TCodeMark; open: boolean;
begin
  sig := NewType(fProc, 8, 8);
  curRes := Rnd(9);
  sig^.base := results[curRes];
  params := nil; last := nil;
  n := Rnd(8);
  for i := 0 to n - 1 do begin
    kind := Rnd(5);
    if kind = 0 then t := tReal
    else if kind = 1 then t := sliceT
    else if kind = 2 then t := tI32
    else t := tInt;
    p := NewObj(oVar, 0, t);
    p^.param := true;
    p^.isVar := kind = 4;
    if last = nil then params := p else last^.next := p;
    last := p;
  end;
  BeginProc(sig, params);
  for i := 0 to 5 do slots[i] := AllocPerm(8, 8);
  mask := Rnd(32);
  j := Rnd(16);
  mask := mask or (j shl XBit);
  if Rnd(3) = 0 then mask := 0;
  numRegs := 0; numX := 0;
  for j := 0 to 4 do
    if mask and (1 shl j) <> 0 then begin regs[numRegs] := VarRegs[j]; inc(numRegs) end;
  for j := 0 to 3 do
    if mask and (1 shl (XBit + j)) <> 0 then begin
      xregs[numX] := XVarRegs[j]; inc(numX);
      XHome(XVarRegs[j], AllocPerm(8, 8));
    end;
  j := 0;
  p := params;
  while p <> nil do begin
    if (p^.typ = tInt) and (not p^.isVar) and (j < numRegs) and Flag then begin
      p^.reg := regs[j]; inc(j);
    end else if (p^.typ = tReal) and (numX > 0) and Flag then begin
      p^.reg := xregs[0];
    end else if Flag then
      KeepArrived(p);
    p := p^.next;
  end;
  UseRegs(mask);
  line := 1 + Rnd(40);
  EnterBody(c, line);
  MarkCode(mk);
  if Flag then begin
    Stmt(2);
    Rewind(mk);
    Redo(mk);
  end;
  ns := 2 + Rnd(8);
  for i := 1 to ns do Stmt(3);
  open := Flag and (sig^.base <> nil);
  if (sig^.base <> nil) and (not open) then RetStmt(2);
  EndProc(c, open);
  writeln('proc ', c, ' lost ', Bit(lost), ' regs ', mask, ' saves ', chunks^[c].saveMask, ' at ', chunks^[c].saveAt);
end;

function ChunkNameOf(i: longint): longint;
var s: string;
begin
  s := 'p' + chr(48 + i div 10) + chr(48 + i mod 10);
  ChunkNameOf := Intern(@s[1], 3);
end;

var
  i, c, entry: longint; path: string; links: array[0..1] of TLink; dyn: boolean;
begin
  seed := 5;
  path := 'lib/Rt.raz';
  if Open(path) <> '' then Fatal('no file');
  dyn := ParamCount >= 1;
  listing := true;
  curFile := Intern(@path[1], length(path));
  for i := 0 to NumProcs - 1 do begin c := NewChunk(secText, -1, ChunkNameOf(i)); chunks^[c].live := true end;
  for i := 0 to NumGlobs - 1 do begin
    c := NewChunk(secBss, -1, ChunkNameOf(NumProcs + i));
    SetBss(c, 64, 8);
  end;
  MakeTypes;
  for i := 0 to NumProcs - 1 do GenProc(FirstProc + i);
  links[0].chunk := FirstProc; links[0].into := FirstGlob;
  links[1].chunk := FirstProc + 1; links[1].into := FirstGlob + 1;
  entry := EntryPoint(dyn, nil, nil, FirstProc + 2, FirstProc + 3, links, 2);
  writeln('entry ', entry, ' pc ', pc, ' fixups ', numFixups, ' lines ', numLines, ' said ', SaidCount);
  for i := 0 to pc - 1 do write(HexStr(code^[i], 2));
  writeln;
  for i := 0 to numFixups - 1 do writeln('F ', fixups^[i].at, ' ', fixups^[i].chunk, ' ', fixups^[i].addend);
  for i := 0 to numLines - 1 do writeln('L ', lines^[i].at, ' ', lines^[i].chunk, ' ', lines^[i].line, ' ', lines^[i].col);
  List(-1);
end.
