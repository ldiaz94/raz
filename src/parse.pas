{ parse.pas: the parser.

  Reads modules by recursive descent and has gen.pas emit code as it
  goes: one pass, no tree. Importing a module that isn't compiled yet
  compiles it there and then, so modules are finished in an order where
  each comes after the modules it imports; that is the order in which
  their bodies run.

  A module may come in one file per target (Name.linux-x86_64.jed and
  so on). The file for this target is compiled; the others beside it
  are read for their declarations only, and must export the same
  interface.

  Depends on: scan, tok, x64, gen.
  Leaves out (for later stages): multiple results, errors, enumerations
  and sets, record literals, defer, NEW, generic modules, extern. }

unit parse;

{$mode objfpc}{$H-}

interface

uses scan, sym, x64, gen;

const
  Target = 'linux-x86_64';
  TargetOS = 'linux';
  TargetArch = 'x86_64';

var
  libDir, mainDir: shortstring;
  incDirs: array[0..15] of shortstring;
  numInc: longint;
  firstModule, lastModule: PModule;   { in the order they were finished }

function CompileMain(const path: shortstring): PModule;
function ImportModule(name: longint): PModule;

implementation

uses BaseUnix;

var
  checkMode: boolean;     { reading a file only for its interface }
  inTypes: boolean;       { in a type section: ^T may name a later type }
  fwdTypes: array[0..255] of PType;
  numFwd: longint;
  declExported: boolean;  { the export mark of the declaration being read }
  curBreak: PLongint;     { the break chain of the innermost loop, or nil }
  curResult: PType;       { the result type of the procedure being compiled }
  tArgv, tBodySig: PType;
  nameRt, nameFail, nameEq, nameMain, nameBody: longint;

procedure Expression(var x: TItem; want: PType); forward;
function ParseType: PType; forward;
procedure Statements; forward;

{ Little helpers }

procedure Expect(s: TSym; const what: shortstring);
begin
  if tok <> s then Mark(what + ' expected');
  Next;
end;

function Name(const s: shortstring): longint;
begin
  Name := Intern(@s[1], length(s));
end;

procedure IdentDef(var n: longint; var exp: boolean);
begin
  if tok <> sIdent then Mark('name expected');
  n := id;
  Next;
  exp := false;
  if tok = sTimes then begin
    exp := true;
    Next;
  end;
end;

{ Declares o in the innermost scope; a module's own declarations are
  also kept in order, for the interface check. }
procedure Declare(o: PObj);
begin
  Insert(o, TopScope);
  if TopScope = curModule^.scope then begin
    if curModule^.last = nil then curModule^.first := o
    else curModule^.last^.link := o;
    curModule^.last := o;
  end;
end;

function ConstValue(var x: TItem): int64;
begin
  if x.mode <> mConst then Mark('constant expected');
  ConstValue := x.val;
end;

function ConstExpr: int64;
var x: TItem;
begin
  Expression(x, nil);
  if not IsInt(x.typ) then Mark('integer constant expected');
  ConstExpr := ConstValue(x);
end;

function QualIdent: PObj;
var o: PObj;
begin
  if tok <> sIdent then Mark('name expected');
  o := Lookup(id);
  if o = nil then Mark(NameOf(id) + ' isn''t declared');
  Next;
  if o^.cls = oModule then begin
    Expect(sPeriod, '.');
    if tok <> sIdent then Mark('name expected');
    o := Find(o^.module^.scope, id);
    if (o = nil) or not o^.exported then Mark(NameOf(id) + ' isn''t exported');
    Next;
  end;
  QualIdent := o;
end;

function NewPtr(base: PType; vol: boolean): PType;
var t: PType;
begin
  t := NewType(fPtr, 8, 8);
  t^.base := base;
  t^.vol := vol;
  NewPtr := t;
end;

{ Types }

function RecordType: PType;
var
  t, ft: PType; f, last: PObj; names: array[0..63] of longint;
  exps: array[0..63] of boolean; n, i: longint; off, a, maxA: int64;
begin
  t := NewType(fRecord, 0, 1);
  if tok = sPacked then begin t^.packd := true; Next end;
  Expect(sRecord, 'record');
  t^.scope := NewScope;
  off := 0; maxA := 1; last := nil;
  while tok = sIdent do begin
    n := 0;
    repeat
      if n > High(names) then Mark('too many names');
      IdentDef(names[n], exps[n]);
      inc(n);
      if tok <> sComma then break;
      Next;
    until false;
    Expect(sColon, ':');
    ft := ParseType;
    if t^.packd then a := 1 else a := ft^.align;
    for i := 0 to n - 1 do begin
      off := AlignUp(off, a);
      f := NewObj(oField, names[i], ft);
      f^.exported := exps[i];
      f^.val := off;
      Insert(f, t^.scope);
      if last = nil then t^.fields := f else last^.next := f;
      last := f;
      off := off + ft^.size;
    end;
    if a > maxA then maxA := a;
    Expect(sSemicolon, ';');
  end;
  Expect(sEnd, 'end');
  t^.align := maxA;
  t^.size := AlignUp(off, maxA);
  RecordType := t;
end;

function VariantType: PType;
var t, ft: PType; c, lastC, f, lastF: PObj; tag, off, maxSize: int64; n: longint;
begin
  Expect(sVariant, 'variant');
  t := NewType(fVariant, 8, 8);
  tag := 0; maxSize := 8; lastC := nil;
  while tok = sIdent do begin
    c := NewObj(oCase, id, t);
    c^.val := tag;
    c^.exported := declExported;
    Declare(c);
    if lastC = nil then t^.fields := c else lastC^.next := c;
    lastC := c;
    Next;
    off := 8;
    if tok = sLparen then begin
      Next;
      lastF := nil;
      repeat
        n := 0;
        repeat
          if tok <> sIdent then Mark('name expected');
          f := NewObj(oField, id, nil);
          f^.exported := true;
          if lastF = nil then c^.fields := f else lastF^.next := f;
          lastF := f;
          inc(n);
          Next;
          if tok <> sComma then break;
          Next;
        until false;
        Expect(sColon, ':');
        ft := ParseType;
        f := c^.fields;
        while f^.typ <> nil do f := f^.next;
        while f <> nil do begin
          f^.typ := ft;
          off := AlignUp(off, ft^.align);
          f^.val := off;
          off := off + ft^.size;
          f := f^.next;
        end;
        if ft^.align > t^.align then t^.align := ft^.align;
        if tok <> sSemicolon then break;
        Next;
      until false;
      Expect(sRparen, ')');
    end;
    if off > maxSize then maxSize := off;
    Expect(sSemicolon, ';');
    inc(tag);
  end;
  Expect(sEnd, 'end');
  t^.len := tag;
  t^.size := AlignUp(maxSize, t^.align);
  VariantType := t;
end;

function Signature: PType;
var
  t, pt: PType; p, first, last: PObj; isVar: boolean; n: longint;
begin
  t := NewType(fProc, 8, 8);
  last := nil; n := 0;
  if tok = sLparen then begin
    Next;
    if tok <> sRparen then
      repeat
        if tok = sEllipsis then begin
          Next; t^.variadic := true; break
        end;
        isVar := tok = sVar;
        if isVar then Next;
        first := nil;
        repeat
          if tok <> sIdent then Mark('name expected');
          p := NewObj(oVar, id, nil);
          p^.isVar := isVar;
          p^.lev := 1;
          if last = nil then t^.fields := p else last^.next := p;
          last := p;
          if first = nil then first := p;
          inc(n);
          Next;
          if tok <> sComma then break;
          Next;
        until false;
        Expect(sColon, ':');
        pt := ParseType;
        while first <> nil do begin first^.typ := pt; first := first^.next end;
        if tok <> sSemicolon then break;
        Next;
      until false;
    Expect(sRparen, ')');
  end;
  t^.len := n;
  if tok = sColon then begin
    Next;
    if tok = sLparen then Mark('several results come in stage 2');
    t^.base := ParseType;
  end;
  Signature := t;
end;

function ParseType: PType;
var t: PType; o: PObj; n: int64; vol: boolean;
begin
  case tok of
    sIdent: begin
      o := QualIdent;
      if o^.cls <> oType then Mark('type expected');
      t := o^.typ;
    end;
    sLbrak: begin
      Next;
      if tok = sRbrak then begin
        Next;
        t := NewType(fSlice, 16, 8);
        t^.base := ParseType();
      end else begin
        n := ConstExpr;
        if (n <= 0) or (n > (int64(1) shl 40)) then Mark('bad array length');
        Expect(sRbrak, ']');
        t := NewType(fArray, 0, 1);
        t^.len := n;
        t^.base := ParseType();
        t^.size := n * t^.base^.size;
        t^.align := t^.base^.align;
      end;
    end;
    sArrow: begin
      Next;
      vol := tok = sVolatile;
      if vol then Next;
      if inTypes and (tok = sIdent) and (Lookup(id) = nil) then begin
        { a type declared later in this section }
        t := NewPtr(nil, vol);
        t^.fwd := id;
        if numFwd > High(fwdTypes) then Mark('too many forward pointers');
        fwdTypes[numFwd] := t;
        inc(numFwd);
        Next;
      end else
        t := NewPtr(ParseType(), vol);
    end;
    sPacked, sRecord: t := RecordType;
    sVariant: t := VariantType;
    sProc: begin Next; t := Signature end;
    sLparen, sSet: Mark('enumerations and sets come in stage 2');
  else Mark('type expected');
  end;
  ParseType := t;
end;

{ Expressions }

procedure Call(var x: TItem);
var c: TCall; a: TItem; want: PType;
begin
  BeginCall(c, x);
  Expect(sLparen, '(');
  if tok <> sRparen then
    repeat
      if c.param <> nil then want := c.param^.typ else want := nil;
      Expression(a, want);
      PassArg(c, a);
      if tok <> sComma then break;
      Next;
    until false;
  Expect(sRparen, ')');
  EndCall(c, x);
end;

procedure Args(n: longint; var slots: array of int64);
var i: longint; a: TItem;
begin
  for i := 0 to n - 1 do begin
    if i > 0 then Expect(sComma, ',');
    Expression(a, nil);
    if not (IsScalar(a.typ) and (a.typ^.form <> fReal)) then Mark('integer or pointer expected');
    if a.typ^.form = fConst then Coerce(a, tI64);
    slots[i] := ToSlot(a);
  end;
end;

procedure Atomic(var x: TItem; which: longint);
var p, a: TItem; t: PType; s: array[0..2] of int64; i, n: longint;
begin
  Expression(p, nil);
  if p.typ^.form <> fPtr then Mark('a pointer expected');
  t := p.typ^.base;
  if not (((t^.form = fInt) or ((t^.form = fPtr) and (which <> bXadd))) and (t^.size = 8)) then
    Mark('an 8-byte integer or pointer expected');
  s[0] := ToSlot(p);
  if which = bCas then n := 2 else n := 1;
  for i := 1 to n do begin
    Expect(sComma, ',');
    Expression(a, t);
    Coerce(a, t);
    s[i] := ToSlot(a);
  end;
  Load(RCX, Mem(RBP, s[0]), 8, false);
  Load(RAX, Mem(RBP, s[1]), 8, false);
  MakeConst(x, t, 0);
  case which of
    bCas: begin
      Load(RDX, Mem(RBP, s[2]), 8, false);
      LockCmpxchg(Mem(RCX, 0), RDX);
      SetCC(ccE, RAX);
      x.typ := tBool;
    end;
    bXchg: Xchg(Mem(RCX, 0), RAX);
    bXadd: LockXadd(Mem(RCX, 0), RAX);
  end;
  x.mode := mReg;
end;

procedure Builtin(var x: TItem);
const SysRegs: array[0..6] of longint = (RAX, RDI, RSI, RDX, R10, R8, R9);
var which, n, i: longint; y: TItem; t: PType; slots: array[0..6] of int64;
begin
  which := x.obj^.val;
  if which in [bFence, bArgc, bArgv] then begin
    if tok = sLparen then begin Next; Expect(sRparen, ')') end;
    MakeConst(x, tNone, 0);
    case which of
      bFence: begin Mfence; x.mode := mNone end;
      bArgc: begin Load(RAX, MemRip(argcChunk, 0), 8, false); x.typ := tI64; x.mode := mReg end;
      bArgv: begin Load(RAX, MemRip(argvChunk, 0), 8, false); x.typ := tArgv; x.mode := mReg end;
    end;
    exit;
  end;
  Expect(sLparen, '(');
  case which of
    bSize: begin
      t := ParseType;
      MakeConst(x, tConst, t^.size);
    end;
    bAdr: begin
      Expression(y, nil);
      if (y.mode <> mVar) or not y.isVar then Mark('ADR needs a variable');
      t := NewPtr(y.typ, y.vol);
      Address(y, RAX);
      MakeConst(x, t, 0);
      x.mode := mReg;
    end;
    bLen: begin
      Expression(y, nil);
      if y.mode = mStr then MakeConst(x, tConst, y.val)
      else if y.typ^.form = fArray then MakeConst(x, tConst, y.typ^.len)
      else if (y.typ^.form = fSlice) and (y.mode = mVar) then begin
        Address(y, RAX);
        Load(RAX, Mem(RAX, 8), 8, false);
        MakeConst(x, tI64, 0);
        x.mode := mReg;
      end else Mark('LEN needs an array or slice');
    end;
    bSyscall: begin
      n := 1;
      Args(1, slots);
      while (tok = sComma) and (n < 7) do begin
        Next;
        Expression(y, nil);
        if not (IsScalar(y.typ) and (y.typ^.form <> fReal)) then Mark('integer or pointer expected');
        if y.typ^.form = fConst then Coerce(y, tI64);
        slots[n] := ToSlot(y);
        inc(n);
      end;
      for i := 0 to n - 1 do Load(SysRegs[i], Mem(RBP, slots[i]), 8, false);
      Syscall;
      MakeConst(x, tI64, 0);
      x.mode := mReg;
    end;
    bCas, bXchg, bXadd: Atomic(x, which);
    bNew, bMsg: Mark('NEW and MSG come in stage 2');
  end;
  Expect(sRparen, ')');
end;

procedure ConstructCase(var x: TItem; c: PObj);
var f: PObj; a: TItem;
begin
  Construct(x, c);
  f := c^.fields;
  if tok = sLparen then begin
    Next;
    while f <> nil do begin
      Expression(a, f^.typ);
      SetField(x, f, a);
      f := f^.next;
      if f <> nil then Expect(sComma, ',');
    end;
    Expect(sRparen, ')');
  end else if f <> nil then Mark(NameOf(c^.name) + ' needs its fields');
end;

{ A designator, with any selectors and calls after it. called tells
  whether the last thing done was a call. }
procedure Designator(var x: TItem; var called: boolean);
var o, f: PObj; y, z: TItem; t: PType;
begin
  o := QualIdent;
  called := false;
  if o^.cls = oModule then Mark('a module is not a value');
  MakeItem(x, o);
  if x.mode = mBuiltin then begin
    Builtin(x);
    called := true;
  end else if x.mode = mCase then begin
    ConstructCase(x, o);
  end;
  repeat
    case tok of
      sPeriod: begin
        Next;
        if (x.mode <> mVar) or (x.typ^.form <> fRecord) then Mark('not a record');
        if tok <> sIdent then Mark('field expected');
        f := Find(x.typ^.scope, id);
        if f = nil then Mark('no field ' + NameOf(id));
        if not f^.exported and (x.typ^.module <> curModule) then
          Mark('field ' + NameOf(id) + ' isn''t exported');
        Next;
        Field(x, f);
        called := false;
      end;
      sArrow: begin Next; Deref(x); called := false end;
      sLbrak: begin
        Next;
        IndexPrep(x);
        Expression(y, nil);
        if tok = sUpto then begin
          Next;
          SliceLo(y);
          Expression(z, nil);
          Slice(x, y, z);
        end else Index(x, y);
        Expect(sRbrak, ']');
        called := false;
      end;
      sLparen: begin
        if x.mode = mType then begin
          t := x.typ;
          Next;
          Expression(x, nil);
          Expect(sRparen, ')');
          Convert(x, t);
        end else begin
          Call(x);
          called := true;
        end;
      end;
    else break;
    end;
  until false;
end;

procedure ArrayLiteral(var x: TItem; want: PType);
var
  et, at: PType; e: TItem; slots: array[0..1023] of int64; n, i: longint;
  off, es: int64;
begin
  if (want = nil) or not (want^.form in [fArray, fSlice]) then
    Mark('an array literal needs a known array or slice type');
  et := want^.base;
  es := et^.size;
  Next;
  n := 0;
  if tok <> sRbrak then
    repeat
      if n > High(slots) then Mark('too many elements');
      Expression(e, et);
      Coerce(e, et);
      if IsScalar(et) then slots[n] := ToSlot(e)
      else begin
        if e.isVar or e.vol or (e.mode <> mVar) or (e.base <> bFrame) then CopyToTemp(e);
        slots[n] := e.off;
      end;
      inc(n);
      if tok <> sComma then break;
      Next;
    until false;
  Expect(sRbrak, ']');
  if (want^.form = fArray) and (n <> want^.len) then Mark('wrong number of elements');
  if n = 0 then begin
    MovRI(RAX, 0);
    SliceOf(x, want, 0);
    exit;
  end;
  if want^.form = fArray then begin
    at := want;
    off := AllocTemp(at^.size, at^.align);
  end else begin
    at := NewType(fArray, n * es, et^.align);
    at^.len := n;
    at^.base := et;
    off := AllocPerm(at^.size, at^.align);   { lives as long as the call }
  end;
  for i := 0 to n - 1 do
    if IsScalar(et) then begin
      Load(RAX, Mem(RBP, slots[i]), 8, false);
      Store(Mem(RBP, off + i * es), RAX, ScalarSize(et));
    end else begin
      Lea(RSI, Mem(RBP, slots[i]));
      Lea(RDI, Mem(RBP, off + i * es));
      MovRI(RCX, es);
      RepMovsb;
    end;
  TempItem(x, at, off);
end;

procedure Factor(var x: TItem; want: PType);
var called, vol: boolean; t: PType;
begin
  case tok of
    sInt, sChar: begin
      { only a hex number can be above high(I64), and it is a U64 }
      if ival < 0 then MakeConst(x, tU64, ival) else MakeConst(x, tConst, ival);
      Next;
    end;
    sReal: begin MakeReal(x, rval); Next end;
    sString: begin MakeStr(x); Next end;
    sIdent: begin
      Designator(x, called);
      if x.mode = mNone then Mark('this procedure returns nothing');
    end;
    sLparen: begin Next; Expression(x, want); Expect(sRparen, ')') end;
    sNot: begin Next; Factor(x, nil); NotOp(x) end;
    sLbrak: ArrayLiteral(x, want);
    sLbrace: Mark('record and set literals come in stage 2');
    sArrow: begin
      Next;
      vol := tok = sVolatile;
      if vol then Next;
      t := NewPtr(ParseType, vol);
      Expect(sLparen, '(');
      Expression(x, nil);
      Expect(sRparen, ')');
      Convert(x, t);
    end;
  else Mark('expression expected');
  end;
end;

procedure Term(var x: TItem; want: PType);
var op: TSym; y: TItem; L: longint;
begin
  Factor(x, want);
  while tok in [sTimes, sSlash, sDiv, sMod, sAnd, sShl, sShr] do begin
    op := tok;
    Next;
    Op1(op, x, L);
    Factor(y, nil);
    Op2(op, x, y, L);
  end;
end;

procedure SimpleExpr(var x: TItem; want: PType);
var op: TSym; y: TItem; L: longint;
begin
  if tok = sMinus then begin
    Next;
    Term(x, nil);
    Neg(x);
  end else Term(x, want);
  while tok in [sPlus, sMinus, sOr, sXor] do begin
    op := tok;
    Next;
    Op1(op, x, L);
    Term(y, nil);
    Op2(op, x, y, L);
  end;
end;

procedure Expression(var x: TItem; want: PType);
var op: TSym; y: TItem; L: longint;
begin
  SimpleExpr(x, want);
  if tok in [sEql, sNeq, sLss, sLeq, sGtr, sGeq] then begin
    op := tok;
    Next;
    Op1(op, x, L);
    SimpleExpr(y, nil);
    Op2(op, x, y, L);
  end else if tok = sIn then Mark('sets come in stage 2');
end;

{ Statements }

procedure Loop(var brk: longint; var old: PLongint);
begin
  brk := NoLabel;
  old := curBreak;
  curBreak := @brk;
end;

procedure IfStatement;
var x: TItem; L, endL: longint;
begin
  Next;
  Expression(x, nil);
  Expect(sThen, 'then');
  L := NoLabel;
  CondJump(x, L);
  Statements;
  endL := NoLabel;
  while tok = sElsif do begin
    Jmp(endL);
    FixLink(L);
    Next;
    Expression(x, nil);
    Expect(sThen, 'then');
    L := NoLabel;
    CondJump(x, L);
    Statements;
  end;
  if tok = sElse then begin
    Jmp(endL);
    FixLink(L);
    Next;
    Statements;
  end else FixLink(L);
  Expect(sEnd, 'end');
  FixLink(endL);
end;

procedure WhileStatement;
var x: TItem; top, L, brk: longint; old: PLongint;
begin
  Next;
  top := pc;
  Expression(x, nil);
  Expect(sDo, 'do');
  L := NoLabel;
  CondJump(x, L);
  Loop(brk, old);
  Statements;
  JmpBack(top);
  Expect(sEnd, 'end');
  FixLink(L);
  FixLink(brk);
  curBreak := old;
end;

procedure RepeatStatement;
var x: TItem; top, L, brk: longint; old: PLongint;
begin
  Next;
  top := pc;
  Loop(brk, old);
  Statements;
  curBreak := old;
  Expect(sUntil, 'until');
  Expression(x, nil);
  L := NoLabel;
  CondJump(x, L);
  FixLinkTo(L, top);
  FixLink(brk);
end;

procedure ForStatement;
var
  o: PObj; v, a, b, s: TItem; bslot, step: int64; top, exitL, brk: longint;
  old: PLongint;
begin
  Next;
  if tok <> sIdent then Mark('name expected');
  o := Lookup(id);
  if (o = nil) or (o^.cls <> oVar) or (o^.typ^.form <> fInt) then
    Mark('a for loop needs an integer variable');
  Next;
  Expect(sBecomes, ':=');
  MakeItem(v, o);
  Save(v);
  Expression(a, o^.typ);
  Assign(v, a);
  Expect(sTo, 'to');
  Expression(b, o^.typ);
  Coerce(b, o^.typ);
  bslot := ToSlot(b);
  step := 1;
  if tok = sBy then begin
    Next;
    Expression(s, nil);
    step := ConstValue(s);
    if step = 0 then Mark('the step can''t be zero');
  end;
  Expect(sDo, 'do');
  exitL := NoLabel;
  top := pc;
  MakeItem(v, o);
  Value(v);
  Load(RCX, Mem(RBP, bslot), 8, false);
  Alu(aluCmp, RAX, RCX);
  if o^.typ^.signed then begin
    if step > 0 then Jcc(ccG, exitL) else Jcc(ccL, exitL)
  end else begin
    if step > 0 then Jcc(ccA, exitL) else Jcc(ccB, exitL)
  end;
  Loop(brk, old);
  Statements;
  curBreak := old;
  Expect(sEnd, 'end');
  ForNext(o, bslot, step, exitL, top);
  FixLink(exitL);
  FixLink(brk);
end;

procedure MatchStatement;
var
  x: TItem; t: PType; c, f, o: PObj; p: int64; L, endL, n: longint;
  seen: array[0..255] of boolean; hasElse: boolean;
begin
  Next;
  Expression(x, nil);
  p := MatchBegin(x);
  t := x.typ;
  Expect(sOf, 'of');
  FillChar(seen, SizeOf(seen), 0);
  hasElse := false;
  endL := NoLabel;
  while tok = sBar do begin
    Next;
    if hasElse then Mark('else must be the last arm');
    if tok = sElse then begin
      Next;
      Expect(sColon, ':');
      Statements;
      hasElse := true;
    end else begin
      if tok <> sIdent then Mark('case expected');
      c := t^.fields;
      while (c <> nil) and (c^.name <> id) do c := c^.next;
      if c = nil then Mark(NameOf(id) + ' isn''t a case of ' + TypeName(t));
      if (c^.val <= High(seen)) and seen[c^.val] then Mark('case twice');
      if c^.val <= High(seen) then seen[c^.val] := true;
      Next;
      L := NoLabel;
      MatchTag(p, c^.val, L);
      OpenScope(NewScope);
      if tok = sLparen then begin
        Next;
        f := c^.fields;
        n := 0;
        repeat
          if tok <> sIdent then Mark('name expected');
          if f = nil then Mark('too many fields');
          o := NewObj(oVar, id, f^.typ);
          o^.lev := 1; o^.ind := true; o^.isVar := true;
          o^.val := p; o^.off := f^.val;
          Insert(o, TopScope);
          f := f^.next;
          inc(n);
          Next;
          if tok <> sComma then break;
          Next;
        until false;
        if f <> nil then Mark('name all the fields, or none');
        Expect(sRparen, ')');
      end;
      Expect(sColon, ':');
      Statements;
      CloseScope;
      Jmp(endL);
      FixLink(L);
    end;
  end;
  Expect(sEnd, 'end');
  if not hasElse then begin
    c := t^.fields;
    while c <> nil do begin
      if (c^.val > High(seen)) or not seen[c^.val] then Mark('no arm for ' + NameOf(c^.name));
      c := c^.next;
    end;
  end;
  FixLink(endL);
end;

procedure Statement;
var x, y: TItem; called: boolean; m: int64; c: TCall;
begin
  m := TempMark;
  case tok of
    sIdent: begin
      Designator(x, called);
      if tok = sBecomes then begin
        if (x.mode <> mVar) or not x.isVar then Mark('can''t assign to this');
        Save(x);
        Next;
        Expression(y, x.typ);
        Assign(x, y);
      end else if tok = sComma then
        Mark('several results come in stage 2')
      else if not called then begin
        if (x.mode = mProc) or ((x.mode in [mVar, mReg]) and (x.typ^.form = fProc)) then begin
          BeginCall(c, x);
          EndCall(c, x);
        end else Mark('not a statement');
      end;
    end;
    sIf: IfStatement;
    sWhile: WhileStatement;
    sRepeat: RepeatStatement;
    sFor: ForStatement;
    sMatch: MatchStatement;
    sReturn: begin
      Next;
      if tok = sSemicolon then ReturnNone
      else begin
        Expression(x, curResult);
        ReturnValue(x);
      end;
    end;
    sBreak: begin
      Next;
      if curBreak = nil then Mark('break outside a loop');
      Jmp(curBreak^);
    end;
    sDefer: Mark('defer comes in stage 2');
  else Mark('statement expected');
  end;
  ReleaseTemps(m);
end;

procedure Statements;
begin
  while not (tok in [sEnd, sElse, sElsif, sUntil, sBar, sEof]) do begin
    Statement;
    Expect(sSemicolon, ';');
  end;
end;

{ Declarations }

{ In a file read for its interface only: skip a procedure's body, from
  its local declarations to the end that closes it. }
procedure SkipBody;
var d: longint; sawBegin: boolean;
begin
  d := 0;
  sawBegin := false;
  repeat
    case tok of
      sBegin: begin if d = 0 then sawBegin := true; inc(d) end;
      sIf, sWhile, sFor, sMatch, sRecord, sVariant: inc(d);
      sEnd: begin
        dec(d);
        if (d = 0) and sawBegin then begin Next; exit end;
      end;
      sEof: Mark('end expected');
    end;
    Next;
  until false;
end;

procedure Declarations(top: boolean); forward;

procedure Body(p: PObj; sig: PType);
var q, params, last, o: PObj; old: PType;
begin
  OpenScope(NewScope);
  params := nil; last := nil;
  q := sig^.fields;
  while q <> nil do begin
    o := NewObj(oVar, q^.name, q^.typ);
    o^.lev := 1;
    o^.isVar := q^.isVar;
    if last = nil then params := o else last^.next := o;
    last := o;
    q := q^.next;
  end;
  BeginProc(sig, params);
  o := params;
  while o <> nil do begin
    q := o^.next;
    Insert(o, TopScope);
    o := q;
  end;
  Declarations(false);
  Expect(sBegin, 'begin');
  old := curResult;
  curResult := sig^.base;
  EnterBody(p^.chunk);
  Statements;
  Expect(sEnd, 'end');
  EndProc(p^.chunk);
  curResult := old;
  CloseScope;
end;

procedure CodeBody(p: PObj; sig: PType);
var q: PObj; ni, nf: longint; v: int64;
begin
  ni := 0; nf := 0;
  q := sig^.fields;
  while q <> nil do begin
    if not q^.isVar and not IsScalar(q^.typ) then
      Mark('a code procedure takes integers, BOOL, F64, pointers and procedures');
    if (q^.typ^.form = fReal) and not q^.isVar then inc(nf) else inc(ni);
    q := q^.next;
  end;
  if (ni > 6) or (nf > 8) or sig^.variadic then Mark('too many parameters for a code procedure');
  if (sig^.base <> nil) and not IsScalar(sig^.base) then Mark('a code procedure returns a single value');
  BeginChunk(p^.chunk);
  repeat
    v := ConstExpr;
    if (v < 0) or (v > 255) then Mark('a byte expected');
    Put1(v);
    if tok <> sComma then break;
    Next;
  until false;
  EndChunk(p^.chunk);
end;

procedure ProcDecl;
var n: longint; exp: boolean; sig: PType; p: PObj;
begin
  Next;
  IdentDef(n, exp);
  sig := Signature;
  Expect(sSemicolon, ';');
  p := Find(TopScope, n);
  if (p <> nil) and (p^.cls = oProc) and p^.fwd then begin
    if not Same(p^.typ, sig) then Mark('not the signature it was declared with');
    if tok = sForward then Mark('declared forward twice');
    p^.exported := p^.exported or exp;
  end else begin
    p := NewObj(oProc, n, sig);
    p^.exported := exp;
    if (curModule^.name = nameRt) and not checkMode and (n = nameFail) then p^.chunk := rtFail
    else if (curModule^.name = nameRt) and not checkMode and (n = nameEq) then p^.chunk := rtEq
    else p^.chunk := NewChunk(secText, curModule^.name, n);
    Declare(p);
  end;
  if tok = sForward then begin
    Next;
    p^.fwd := true;
    exit;
  end;
  p^.fwd := false;
  if tok = sCode then begin
    Next;
    p^.isCode := true;
    CodeBody(p, sig);
    exit;
  end;
  if checkMode then SkipBody else Body(p, sig);
  if tok = sIdent then begin
    if id <> n then Mark('the procedure is ' + NameOf(n));
    Next;
  end;
end;

procedure Declarations(top: boolean);
var
  n, i, k: longint; exp: boolean; x: TItem; o: PObj; t: PType;
  names: array[0..63] of longint; exps: array[0..63] of boolean;
begin
  repeat
    case tok of
      sConst: begin
        Next;
        while tok = sIdent do begin
          IdentDef(n, exp);
          if tok = sColon then Mark('errors come in stage 2');
          Expect(sEql, '=');
          Expression(x, nil);
          o := NewObj(oConst, n, x.typ);
          o^.exported := exp and top;
          if x.mode = mStr then begin o^.val := x.val; o^.chunk := x.chunk end
          else o^.val := ConstValue(x);
          Declare(o);
          Expect(sSemicolon, ';');
        end;
      end;
      sType: begin
        Next;
        inTypes := true;
        numFwd := 0;
        while tok = sIdent do begin
          IdentDef(n, exp);
          Expect(sEql, '=');
          declExported := exp and top;
          t := ParseType;
          o := NewObj(oType, n, t);
          o^.exported := exp and top;
          if t^.obj = nil then t^.obj := o;
          Declare(o);
          Expect(sSemicolon, ';');
        end;
        for i := 0 to numFwd - 1 do begin
          o := Lookup(fwdTypes[i]^.fwd);
          if (o = nil) or (o^.cls <> oType) then Mark(NameOf(fwdTypes[i]^.fwd) + ' isn''t declared');
          fwdTypes[i]^.base := o^.typ;
          fwdTypes[i]^.fwd := -1;
        end;
        inTypes := false;
        declExported := false;
      end;
      sVar: begin
        Next;
        while tok = sIdent do begin
          k := 0;
          repeat
            if k > High(names) then Mark('too many names');
            IdentDef(names[k], exps[k]);
            inc(k);
            if tok <> sComma then break;
            Next;
          until false;
          Expect(sColon, ':');
          declExported := top and exps[0];
          t := ParseType;
          declExported := false;
          for i := 0 to k - 1 do begin
            o := NewObj(oVar, names[i], t);
            o^.exported := exps[i] and top;
            o^.isVar := false;
            if top then begin
              o^.lev := 0;
              o^.chunk := NewChunk(secBss, curModule^.name, names[i]);
              SetBss(o^.chunk, t^.size, t^.align);
            end else begin
              o^.lev := 1;
              o^.val := AllocPerm(t^.size, t^.align);
            end;
            Declare(o);
          end;
          Expect(sSemicolon, ';');
        end;
      end;
      sProc: begin
        if not top then Mark('procedures don''t nest');
        ProcDecl;
        Expect(sSemicolon, ';');
      end;
      sExtern: Mark('extern comes in stage 3');
    else exit;
    end;
  until false;
end;

{ Modules }

function FindModule(n: longint): PModule;
var m: PModule;
begin
  m := firstModule;
  while (m <> nil) and (m^.name <> n) do m := m^.next;
  FindModule := m;
end;

{ Modules being compiled, not yet finished: for finding a cycle. }
var
  pending: array[0..63] of PModule;
  numPending: longint;

function Exists(const path: shortstring): boolean;
var st: Stat; p: shortstring;
begin
  p := path + #0;
  Exists := (FpStat(@p[1], st) = 0) and ((st.st_mode and S_IFMT) = S_IFREG);
end;

function CompileFile(const path: shortstring; n: longint; checkOnly: boolean): PModule;
var
  st: TScanState; saved: array[0..MaxDepth - 1] of longint; d: longint;
  oldMod: PModule; oldFile: longint; oldCheck: boolean; m, im: PModule;
  imp: PImport; alias, mname: longint; o: PObj; body: longint;
begin
  SaveScan(st);
  SaveScopes(d, saved);
  oldMod := curModule; oldFile := fileChunk; oldCheck := checkMode;
  if not Open(path) then Fatal('can''t read ' + path);
  New(m);
  FillChar(m^, SizeOf(TModule), 0);
  m^.name := n;
  m^.scope := NewScope;
  m^.path := path;
  m^.body := -1;
  m^.checkOnly := checkOnly;
  curModule := m;
  fileChunk := -1;
  checkMode := checkOnly;
  if not checkOnly then begin
    if numPending > High(pending) then Mark('modules nested too deeply');
    pending[numPending] := m;
    inc(numPending);
  end;
  OpenScope(m^.scope);
  Next;
  Expect(sModule, 'module');
  if (tok <> sIdent) or (id <> n) then Mark('this file must hold module ' + NameOf(n));
  Next;
  if tok = sLparen then Mark('generic modules come in stage 2');
  Expect(sSemicolon, ';');
  while tok = sImport do begin
    Next;
    repeat
      if tok <> sIdent then Mark('module name expected');
      alias := id;
      mname := id;
      Next;
      if tok = sBecomes then begin
        Next;
        if tok <> sIdent then Mark('module name expected');
        mname := id;
        Next;
        if tok = sLparen then Mark('generic modules come in stage 2');
      end;
      im := ImportModule(mname);
      o := NewObj(oModule, alias, nil);
      o^.module := im;
      Declare(o);
      New(imp);
      imp^.module := im;
      imp^.next := m^.imports;
      m^.imports := imp;
      if tok <> sComma then break;
      Next;
    until false;
    Expect(sSemicolon, ';');
  end;
  if tok = sLink then Mark('link comes in stage 3');
  Declarations(true);
  if tok = sBegin then begin
    if checkMode then SkipBody
    else begin
      Next;
      body := NewChunk(secText, n, nameBody);
      m^.body := body;
      BeginProc(tBodySig, nil);
      curResult := nil;
      EnterBody(body);
      Statements;
      Expect(sEnd, 'end');
      EndProc(body);
    end;
  end else Expect(sEnd, 'end');
  if (tok <> sIdent) or (id <> n) then Mark('end ' + NameOf(n) + ' expected');
  Next;
  if tok <> sPeriod then Mark('. expected');
  o := m^.first;
  while o <> nil do begin
    if (o^.cls = oProc) and o^.fwd then Mark(NameOf(o^.name) + ' is declared forward but never defined');
    o := o^.link;
  end;
  CloseScope;
  m^.done := true;
  if not checkOnly then begin
    dec(numPending);
    if lastModule = nil then firstModule := m else lastModule^.next := m;
    lastModule := m;
  end;
  curModule := oldMod; fileChunk := oldFile; checkMode := oldCheck;
  RestoreScopes(d, saved);
  RestoreScan(st);
  CompileFile := m;
end;

{ The interface check: b must export just what a does. }
procedure CompareIface(a, b: PModule);
var o, q: PObj;
begin
  o := a^.first;
  while o <> nil do begin
    if o^.exported then begin
      q := Find(b^.scope, o^.name);
      if (q = nil) or not q^.exported or (Fingerprint(o) <> Fingerprint(q)) then
        Fatal(b^.path + ': ' + NameOf(o^.name) + ' isn''t exported as in ' + a^.path);
    end;
    o := o^.link;
  end;
  q := b^.first;
  while q <> nil do begin
    o := Find(a^.scope, q^.name);
    if q^.exported and ((o = nil) or not o^.exported) then
      Fatal(b^.path + ': ' + NameOf(q^.name) + ' isn''t exported by ' + a^.path);
    q := q^.link;
  end;
end;

{ Reads every other file of module n in dir, and checks its interface
  against m, compiled from the file named chosen. }
procedure CheckSiblings(const dir, chosen: shortstring; n: longint; m: PModule);
var
  dp: pDir; e: pDirent; f, prefix: shortstring; i: longint;
  others: array[0..31] of shortstring; numOthers: longint;
begin
  prefix := NameOf(n) + '.';
  numOthers := 0;
  dp := FpOpenDir(dir);
  if dp = nil then exit;
  repeat
    e := FpReadDir(dp^);
    if e = nil then break;
    f := '';
    i := 0;
    while (e^.d_name[i] <> #0) and (i < 255) do begin
      f := f + e^.d_name[i];
      inc(i);
    end;
    if (copy(f, 1, length(prefix)) = prefix) and (length(f) > 4)
      and (copy(f, length(f) - 3, 4) = '.jed') and (f <> chosen)
      and (numOthers <= High(others)) then begin
      others[numOthers] := f;
      inc(numOthers);
    end;
  until false;
  FpCloseDir(dp^);
  for i := 0 to numOthers - 1 do
    CompareIface(m, CompileFile(dir + '/' + others[i], n, true));
end;

function ImportModule(name: longint): PModule;
const Suffixes: array[0..3] of string[16] = ('.' + Target, '.' + TargetOS, '.' + TargetArch, '');
var m: PModule; i, j: longint; dir, f: shortstring;
begin
  m := FindModule(name);
  if m <> nil then exit(m);
  for i := 0 to numPending - 1 do
    if pending[i]^.name = name then Mark(NameOf(name) + ' imports itself');
  for i := -1 to numInc do begin
    if i = -1 then dir := mainDir
    else if i = numInc then dir := libDir
    else dir := incDirs[i];
    for j := 0 to 3 do begin
      f := NameOf(name) + Suffixes[j] + '.jed';
      if Exists(dir + '/' + f) then begin
        m := CompileFile(dir + '/' + f, name, false);
        CheckSiblings(dir, f, name, m);
        exit(m);
      end;
    end;
  end;
  Mark('can''t find module ' + NameOf(name));
  ImportModule := nil;
end;

function CompileMain(const path: shortstring): PModule;
var base: shortstring; i, n: longint;
begin
  i := length(path);
  while (i > 0) and (path[i] <> '/') do dec(i);
  if i = 0 then mainDir := '.' else mainDir := copy(path, 1, i - 1);
  base := copy(path, i + 1, 255);
  i := pos('.', base);
  if i > 0 then base := copy(base, 1, i - 1);
  if base = '' then Fatal('no module in ' + path);
  n := Name(base);
  if n <> nameRt then ImportModule(nameRt);
  if FindModule(n) <> nil then CompileMain := FindModule(n)
  else CompileMain := CompileFile(path, n, false);
end;

initialization
  nameRt := Name('Rt');
  nameFail := Name('fail');
  nameEq := Name('eq');
  nameMain := Name('main');
  nameBody := Name('body');
  rtFail := NewChunk(secText, nameRt, nameFail);
  rtEq := NewChunk(secText, nameRt, nameEq);
  argcChunk := NewChunk(secBss, -1, Name('argc'));
  SetBss(argcChunk, 8, 8);
  argvChunk := NewChunk(secBss, -1, Name('argv'));
  SetBss(argvChunk, 8, 8);
  tArgv := NewPtr(NewPtr(tU8, false), false);
  tBodySig := NewType(fProc, 8, 8);
  curBreak := nil;
  numPending := 0;
  firstModule := nil;
  lastModule := nil;
end.
