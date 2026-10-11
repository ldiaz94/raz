{ parse.pas: the parser.

  Reads modules by recursive descent and has gen.pas emit code as it
  goes: one pass, no tree. Importing a module that isn't compiled yet
  compiles it there and then, so modules are finished in an order where
  each comes after the modules it imports; that is the order in which
  their bodies run.

  A module may come in one file per target (Name.linux-x86_64.raz and
  so on). The file for this target is compiled; the others beside it
  are read for their declarations only, and must export the same
  interface.

  Depends on: scan, sym, x64, gen.
  Leaves out: linking; a module only records the libraries it names,
  and whether it uses C or says link static. }

unit parse;

{$mode objfpc}{$H-}

interface

uses scan, diag, sym, x64, gen;

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
function ImportModule(name: longint; const args: TArgs): PModule;

implementation

uses BaseUnix;

type
  PLoop = ^TLoop;
  TLoop = record
    brk: longint;     { the chain of its breaks }
    base: longint;    { the deferred statements in force outside it }
  end;

var
  checkMode: boolean;     { reading a file only for its interface }
  inTypes: boolean;       { in a type section: ^T may name a later type }
  fwdTypes: array[0..255] of PType;
  fwdPos: array[0..255] of TPos;    { where each names its type }
  numFwd: longint;
  declExported: boolean;  { the export mark of the declaration being read }
  curLoop: PLoop;         { the innermost loop, or nil }
  defers: array[0..63] of longint;   { the deferred statements in force }
  numDefers: longint;
  deferring: boolean;     { compiling a deferred statement }
  directDefer: boolean;   { ... as the statement itself, not in a list }
  deferSlot: int64;       { keeps a result while deferred statements run }
  curResult: PType;       { the result type of the procedure being compiled }
  inExtern: boolean;      { reading an extern's signature: ... allowed }
  tArgv, tBodySig: PType;
  nameRt, nameFail, nameEq, nameMain, nameBody, nameStatic: longint;
  declaring: array[0..63] of longint;   { the names the declaration being read declares }
  numDeclaring: longint;
  skipped: boolean;       { the last statement had an error and was skipped }

procedure Expression(var x: TItem; want: PType); forward;
function ParseType: PType; forward;
procedure Statements; forward;
procedure Statement; forward;

{ Little helpers }

procedure Expect(s: TSym; const what: shortstring);
begin
  if tok <> s then MarkAt(MissingPos, what + ' expected');
  Next;
end;

function Name(const s: shortstring): longint;
begin
  Name := Intern(@s[1], length(s));
end;

procedure IdentDef(var n: longint; var exp: boolean);
begin
  if tok <> sIdent then MarkAt(MissingPos, 'name expected');
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

{ Recovery

  After an error the parser goes on with the next statement or
  declaration, so that one run reports every error. Each statement and
  declaration is a recovery point: it notes the state of the scanner
  and the parser where it starts, and an error (MarkAt) jumps back to
  it. The state is put back, the scanner reads the construct again
  from its start, skipping to its end, and the parser carries on after
  it. Nothing is generated after an error, so the code half made for
  the construct does no harm. A name that isn't declared is declared
  where it is used, with type tPoison, and what follows from it is not
  reported again; so are the names of a declaration that had an error.

  Skipping counts the words that open and close blocks. A symbol at
  the start of a line is taken to start a declaration of the module,
  as layout has it: a statement skipped up to one gives up its
  procedure, and the procedure is skipped up to its end. }

type
  TRecover = record
    jb: jmp_buf;
    outer: ^jmp_buf;
    scan: TScanState;
    scopes, depth, numDefers: longint;
    loop: PLoop;
    result: PType;
    deferring, directDefer, quiet: boolean;
  end;

procedure Guard(var r: TRecover);
begin
  r.outer := recovery;
  SaveScan(r.scan);
  r.scopes := ScopeDepth; r.depth := depth; r.numDefers := numDefers;
  r.loop := curLoop; r.result := curResult;
  r.deferring := deferring; r.directDefer := directDefer; r.quiet := quiet;
  recovery := @r.jb;
  quiet := false;
end;

procedure Unguard(var r: TRecover);
begin
  recovery := r.outer;
  quiet := r.quiet;
end;

{ After an error: the state as it was at the start of r's construct,
  whose first symbol is again the current one }
procedure Restore(var r: TRecover);
begin
  RestoreScan(r.scan);
  CutScopes(r.scopes); depth := r.depth; numDefers := r.numDefers;
  curLoop := r.loop; curResult := r.result;
  deferring := r.deferring; directDefer := r.directDefer;
  inTypes := false; declExported := false; inExtern := false;
end;

{ Gives up the construct r is for, and the one around it }
procedure GiveUp(var r: TRecover);
begin
  Unguard(r);
  if recovery = nil then Finish;
  longjmp(recovery^, 1);
end;

{ Reads to the end of a statement or declaration, from its first
  symbol: up to the ";" that ends it, not read, or to the "end",
  "else", "elsif", "until" or "|" of the statement around it. False if
  it stopped at a symbol that starts a line, or the end of the file. }
function SkipConstruct: boolean;
var d, p: longint;
begin
  d := 0; p := 0;
  repeat
    case tok of
      sIf, sWhile, sFor, sMatch, sRepeat, sRecord, sVariant: inc(d);
      sEnd, sUntil: if d = 0 then exit(true) else dec(d);
      sElse, sElsif, sBar: if (d = 0) and (p = 0) then exit(true);
      sLparen, sLbrak, sLbrace: inc(p);
      sRparen, sRbrak, sRbrace: if p > 0 then dec(p);
      sSemicolon: if (d = 0) and (p = 0) then exit(true);
      sEof: exit(false);
    end;
    Next;
  until AtLineStart;
  SkipConstruct := false;
end;

{ Declares n where it is used, after it was reported as not declared,
  or after the declaration of it had an error }
function Poison(n: longint): PObj;
var o: PObj;
begin
  o := NewObj(oConst, n, tPoison);
  Insert(o, TopScope);
  Poison := o;
end;

procedure WillDeclare(n: longint);
begin
  if numDeclaring <= High(declaring) then declaring[numDeclaring] := n;
  inc(numDeclaring);
end;

{ After a declaration had an error: its names are poison, and reading
  goes on after it }
procedure SkipDeclaration;
var i: longint;
begin
  for i := 0 to numDeclaring - 1 do
    if (i <= High(declaring)) and (Find(TopScope, declaring[i]) = nil) then
      Poison(declaring[i]);
  if SkipConstruct and (tok = sSemicolon) then Next;
end;

function ConstValue(var x: TItem): int64;
begin
  if x.mode <> mConst then MarkAt(x.pos, 'constant expected');
  ConstValue := x.val;
end;

function ConstExpr: int64;
var x: TItem;
begin
  Expression(x, nil);
  if not IsInt(x.typ) then MarkAt(x.pos, 'integer constant expected');
  ConstExpr := ConstValue(x);
end;

function QualIdent: PObj;
var o: PObj;
begin
  if tok <> sIdent then MarkAt(MissingPos, 'name expected');
  o := Lookup(id);
  if o = nil then begin
    Poison(id);
    quiet := false;
    Mark(NameOf(id) + ' isn''t declared');
  end;
  if o^.typ = tPoison then quiet := true;
  Next;
  if o^.cls = oModule then begin
    Expect(sPeriod, '.');
    if tok <> sIdent then MarkAt(MissingPos, 'name expected');
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
          if tok <> sIdent then MarkAt(MissingPos, 'name expected');
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

{ Several results: a record of them, laid out as C would, and
  returned through a hidden pointer. }
function Results: PType;
var t, ft: PType; f, last: PObj; off: int64;
begin
  Next;
  t := NewType(fRecord, 0, 1);
  t^.tuple := true;
  off := 0; last := nil;
  repeat
    ft := ParseType;
    off := AlignUp(off, ft^.align);
    f := NewObj(oField, -1, ft);
    f^.val := off;
    off := off + ft^.size;
    if ft^.align > t^.align then t^.align := ft^.align;
    if last = nil then t^.fields := f else last^.next := f;
    last := f;
    inc(t^.len);
    if tok <> sComma then break;
    Next;
  until false;
  Expect(sRparen, ')');
  t^.size := AlignUp(off, t^.align);
  if t^.len = 1 then Results := t^.fields^.typ else Results := t;
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
          if not inExtern then Mark('... is only for extern procedures');
          Next; t^.variadic := true; break
        end;
        isVar := tok = sVar;
        if isVar then Next;
        first := nil;
        repeat
          if tok <> sIdent then MarkAt(MissingPos, 'name expected');
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
    if tok = sLparen then t^.base := Results else t^.base := ParseType;
  end;
  Signature := t;
end;

function EnumType: PType;
var t: PType; o, last: PObj; start: TPos;
begin
  start := TokPos;
  t := NewType(fEnum, 1, 1);
  last := nil;
  repeat
    Next;
    if tok <> sIdent then MarkAt(MissingPos, 'name expected');
    o := NewObj(oConst, id, t);
    o^.val := t^.len;
    o^.exported := declExported;
    Declare(o);
    if last = nil then t^.fields := o else last^.next := o;
    last := o;
    inc(t^.len);
    Next;
  until tok <> sComma;
  Expect(sRparen, ')');
  if t^.len > 256 then MarkAt(SpanFrom(start), 'more than 256 names');
  EnumType := t;
end;

function SetOf(e: PType; const at: TPos): PType;
var t: PType;
begin
  if (e^.form <> fEnum) or (e^.len > 64) then MarkAt(at, 'a set is of an enumeration of at most 64 names');
  t := NewType(fSet, 8, 8);
  if e^.len <= 8 then t^.size := 1
  else if e^.len <= 16 then t^.size := 2
  else if e^.len <= 32 then t^.size := 4;
  t^.align := t^.size;
  t^.base := e;
  t^.len := e^.len;
  SetOf := t;
end;

function ParseType: PType;
var t: PType; o: PObj; n: int64; vol: boolean; start: TPos;
begin
  start := TokPos;
  case tok of
    sIdent: begin
      o := QualIdent;
      if o^.cls <> oType then MarkAt(SpanFrom(start), 'type expected');
      t := o^.typ;
    end;
    sLbrak: begin
      Next;
      if tok = sRbrak then begin
        Next;
        t := NewType(fSlice, 16, 8);
        t^.base := ParseType();
      end else begin
        start := TokPos;
        n := ConstExpr;
        if (n <= 0) or (n > (int64(1) shl 40)) then MarkAt(SpanFrom(start), 'bad array length');
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
        fwdPos[numFwd] := TokPos;
        inc(numFwd);
        Next;
      end else
        t := NewPtr(ParseType(), vol);
    end;
    sPacked, sRecord: t := RecordType;
    sVariant: t := VariantType;
    sProc: begin Next; t := Signature end;
    sLparen: t := EnumType;
    sSet: begin
      Next;
      Expect(sOf, 'of');
      start := TokPos;
      t := SetOf(ParseType(), start);
    end;
  else MarkAt(MissingPos, 'type expected');
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
    if not (IsScalar(a.typ) and (a.typ^.form <> fReal)) then MarkAt(a.pos, 'integer or pointer expected');
    if a.typ^.form = fConst then Coerce(a, tI64);
    slots[i] := ToSlot(a);
  end;
end;

procedure Atomic(var x: TItem; which: longint);
var p, a: TItem; t: PType; s: array[0..2] of int64; i, n: longint;
begin
  Expression(p, nil);
  if p.typ^.form <> fPtr then MarkAt(p.pos, 'a pointer expected');
  t := p.typ^.base;
  if not (((t^.form = fInt) or ((t^.form = fPtr) and (which <> bXadd))) and (t^.size = 8)) then
    MarkAt(p.pos, 'an 8-byte integer or pointer expected');
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

{ NEW(p, a): p := a^.alloc(a, SIZE(T), alignment), zeroed if not nil.
  a is a ^Mem.Allocator, the one interface the compiler knows. }
procedure New_(var x: TItem);
var y, z: TItem; t: PType; f: PObj; s: int64; c: TCall; L: longint;
begin
  Expression(x, nil);
  if (x.mode <> mVar) or not x.isVar or (x.typ^.form <> fPtr) then MarkAt(x.pos, 'NEW needs a pointer variable');
  t := x.typ^.base;
  Save(x);
  Expect(sComma, ',');
  Expression(y, nil);
  if (y.typ^.form <> fPtr) or (y.typ^.base^.obj = nil) or (y.typ^.base^.obj^.module = nil)
    or (NameOf(y.typ^.base^.obj^.name) <> 'Allocator')
    or (NameOf(y.typ^.base^.obj^.module^.name) <> 'Mem') then MarkAt(y.pos, 'NEW needs a ^Mem.Allocator');
  f := Find(y.typ^.base^.scope, Name('alloc'));
  s := ToSlot(y);
  Load(RAX, Mem(RBP, s), 8, false);
  MakeConst(z, f^.typ, 0);
  z.mode := mVar; z.base := bReg; z.reg := RAX; z.off := f^.val;
  BeginCall(c, z);
  Load(RAX, Mem(RBP, s), 8, false);
  MakeConst(z, y.typ, 0);
  z.mode := mReg;
  PassArg(c, z);
  MakeConst(z, tI64, t^.size);
  PassArg(c, z);
  MakeConst(z, tI64, t^.align);
  PassArg(c, z);
  EndCall(c, z);
  L := NoLabel;
  TestRR(RAX, RAX);
  Jcc(ccE, L);
  MovRR(RDX, RAX);
  MovRR(RDI, RAX);
  MovRI(RCX, t^.size);
  MovRI(RAX, 0);
  RepStosb;
  MovRR(RAX, RDX);
  FixLink(L);
  z.typ := x.typ;
  Assign(x, z);
  MakeConst(x, tNone, 0);
  x.mode := mNone;
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
      if (y.mode <> mVar) or not y.isVar then MarkAt(y.pos, 'ADR needs a variable');
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
      end else MarkAt(y.pos, 'LEN needs an array or slice');
    end;
    bSyscall: begin
      n := 1;
      Args(1, slots);
      while (tok = sComma) and (n < 7) do begin
        Next;
        Expression(y, nil);
        if not (IsScalar(y.typ) and (y.typ^.form <> fReal)) then MarkAt(y.pos, 'integer or pointer expected');
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
    bMsg: begin Expression(x, tError); Msg(x) end;
    bInc, bDec: begin
      Expression(x, nil);
      if (x.mode <> mVar) or not x.isVar or (x.typ^.form <> fInt) then
        MarkAt(x.pos, 'INC and DEC need an integer variable');
      Save(x);
      if tok = sComma then begin
        Next;
        Expression(y, x.typ);
      end else MakeConst(y, x.typ, 1);
      IncDec(x, y, which = bDec);
      MakeConst(x, tNone, 0);
      x.mode := mNone;
    end;
    bNew: New_(x);
  end;
  Expect(sRparen, ')');
end;

procedure ConstructCase(var x: TItem; c: PObj; const at: TPos);
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
  end else if f <> nil then MarkAt(at, NameOf(c^.name) + ' needs its fields');
end;

{ A designator, with any selectors and calls after it. called tells
  whether the last thing done was a call. }
procedure Designator(var x: TItem; var called: boolean);
var o, f: PObj; y, z: TItem; t: PType; start: TPos;
begin
  start := TokPos;
  o := QualIdent;
  called := false;
  if o^.cls = oModule then MarkAt(SpanFrom(start), 'a module is not a value');
  MakeItem(x, o);
  if x.mode = mBuiltin then begin
    Builtin(x);
    called := true;
  end else if x.mode = mCase then begin
    ConstructCase(x, o, SpanFrom(start));
  end;
  repeat
    x.pos := SpanFrom(start);
    case tok of
      sPeriod: begin
        Next;
        if (x.mode <> mVar) or (x.typ^.form <> fRecord) then MarkAt(x.pos, 'not a record');
        if tok <> sIdent then MarkAt(MissingPos, 'field expected');
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
  x.pos := SpanFrom(start);
end;

procedure ArrayLiteral(var x: TItem; want: PType);
var
  et, at: PType; e: TItem; slots: array[0..1023] of int64; n, i: longint;
  off, es: int64; start: TPos;
begin
  start := TokPos;
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
  if (want^.form = fArray) and (n <> want^.len) then MarkAt(SpanFrom(start), 'wrong number of elements');
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

{ A record literal: a zeroed temporary, with the fields named filled in. }
procedure RecordLiteral(var x: TItem; t: PType);
var f: PObj; a: TItem; seen: array[0..63] of longint; n, i: longint;
begin
  Next;
  ZeroTemp(x, t);
  FillChar(seen, SizeOf(seen), 0);
  n := 0;
  if tok <> sRbrace then
    repeat
      if tok <> sIdent then MarkAt(MissingPos, 'field expected');
      f := Find(t^.scope, id);
      if f = nil then Mark('no field ' + NameOf(id));
      if not f^.exported and (t^.module <> curModule) then Mark('field ' + NameOf(id) + ' isn''t exported');
      for i := 0 to n - 1 do if seen[i] = id then Mark(NameOf(id) + ' twice');
      if n <= High(seen) then begin seen[n] := id; inc(n) end;
      Next;
      Expect(sColon, ':');
      Expression(a, f^.typ);
      SetField(x, f, a);
      if tok <> sComma then break;
      Next;
    until false;
  Expect(sRbrace, '}');
end;

{ A set literal: the bits of the constant names, or'd at run time with
  those of the others. }
procedure SetLiteral(var x: TItem; t: PType);
var e: TItem; bits, slot: int64; start: TPos;
begin
  start := TokPos;
  Next;
  if (t <> nil) and (t^.form <> fSet) then MarkAt(SpanFrom(start), 'a set literal needs a set type');
  bits := 0;
  slot := 0;
  if tok <> sRbrace then
    repeat
      if t = nil then Expression(e, nil) else Expression(e, t^.base);
      if t = nil then begin
        if e.typ^.form <> fEnum then MarkAt(e.pos, 'a set holds names of an enumeration');
        t := SetOf(e.typ, e.pos);
      end;
      if not Same(e.typ, t^.base) then MarkAt(e.pos, 'not a name of ' + TypeName(t^.base));
      if e.mode = mConst then bits := bits or (int64(1) shl e.val)
      else begin
        if slot = 0 then begin
          slot := AllocTemp(8, 8);
          MovRI(RAX, 0);
          Store(Mem(RBP, slot), RAX, 8);
        end;
        Value(e);
        MovRR(RCX, RAX);
        MovRI(RAX, 1);
        Shift(shShl, RAX);
        AluM(aluOr, RAX, Mem(RBP, slot));
        Store(Mem(RBP, slot), RAX, 8);
      end;
      if tok <> sComma then break;
      Next;
    until false;
  Expect(sRbrace, '}');
  if t = nil then MarkAt(SpanFrom(start), '{} needs a known set type');
  MakeConst(x, t, bits);
  if slot <> 0 then begin
    Load(RAX, Mem(RBP, slot), 8, false);
    MovRI(RCX, bits);
    Alu(aluOr, RAX, RCX);
    x.mode := mReg;
  end;
end;

procedure Factor(var x: TItem; want: PType);
var called, vol: boolean; t: PType; start: TPos;
begin
  start := TokPos;
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
      if x.mode = mNone then MarkAt(x.pos, 'this procedure returns nothing');
      if x.typ^.tuple then MarkAt(x.pos, 'several results go only to a, b := ...');
    end;
    sLparen: begin Next; Expression(x, want); Expect(sRparen, ')') end;
    sNot: begin Next; Factor(x, nil); NotOp(x) end;
    sLbrak: ArrayLiteral(x, want);
    sLbrace: if (want <> nil) and (want^.form = fRecord) then RecordLiteral(x, want)
             else SetLiteral(x, want);
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
  else MarkAt(MissingPos, 'expression expected');
  end;
  x.pos := SpanFrom(start);
end;

procedure Term(var x: TItem; want: PType);
var op: TSym; y: TItem; L: longint; start: TPos;
begin
  start := TokPos;
  Factor(x, want);
  while tok in [sTimes, sSlash, sDiv, sMod, sAnd, sShl, sShr] do begin
    op := tok;
    Next;
    Op1(op, x, L);
    Factor(y, nil);
    Op2(op, x, y, L);
    x.pos := SpanFrom(start);
  end;
end;

procedure SimpleExpr(var x: TItem; want: PType);
var op: TSym; y: TItem; L: longint; start: TPos;
begin
  start := TokPos;
  if tok = sMinus then begin
    Next;
    Term(x, nil);
    x.pos := SpanFrom(start);
    Neg(x);
  end else Term(x, want);
  while tok in [sPlus, sMinus, sOr, sXor] do begin
    op := tok;
    Next;
    Op1(op, x, L);
    Term(y, nil);
    Op2(op, x, y, L);
    x.pos := SpanFrom(start);
  end;
end;

procedure Expression(var x: TItem; want: PType);
var op: TSym; y: TItem; L: longint;
begin
  SimpleExpr(x, want);
  if tok in [sEql, sNeq, sLss, sLeq, sGtr, sGeq, sIn] then begin
    op := tok;
    Next;
    Op1(op, x, L);
    if op = sIn then SimpleExpr(y, nil) else SimpleExpr(y, x.typ);
    Op2(op, x, y, L);
    x.pos := Join(x.pos, y.pos);
  end;
end;

{ Statements }

procedure Loop(var lp: TLoop; var old: PLoop);
begin
  lp.brk := NoLabel;
  lp.base := numDefers;
  old := curLoop;
  curLoop := @lp;
end;

{ Runs the deferred statements in force above base, newest first. }
procedure RunDefers(base: longint);
var i: longint;
begin
  for i := numDefers - 1 downto base do CallBack(defers[i]);
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
var x: TItem; top, L: longint; lp: TLoop; old: PLoop;
begin
  Next;
  top := pc;
  Expression(x, nil);
  Expect(sDo, 'do');
  L := NoLabel;
  CondJump(x, L);
  Loop(lp, old);
  Statements;
  JmpBack(top);
  Expect(sEnd, 'end');
  FixLink(L);
  FixLink(lp.brk);
  curLoop := old;
end;

procedure RepeatStatement;
var x: TItem; top, L: longint; lp: TLoop; old: PLoop;
begin
  Next;
  top := pc;
  Loop(lp, old);
  Statements;
  curLoop := old;
  Expect(sUntil, 'until');
  Expression(x, nil);
  L := NoLabel;
  CondJump(x, L);
  FixLinkTo(L, top);
  FixLink(lp.brk);
end;

procedure ForStatement;
var
  o: PObj; v, a, b, s: TItem; bslot, step: int64; top, exitL: longint;
  lp: TLoop; old: PLoop;
begin
  Next;
  if tok <> sIdent then MarkAt(MissingPos, 'name expected');
  o := Lookup(id);
  if (o = nil) or (o^.cls <> oVar) or not (o^.typ^.form in [fInt, fEnum]) then
    Mark('a for loop needs an integer or enumeration variable');
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
    if step = 0 then MarkAt(s.pos, 'the step can''t be zero');
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
  Loop(lp, old);
  Statements;
  curLoop := old;
  Expect(sEnd, 'end');
  ForNext(o, bslot, step, exitL, top);
  FixLink(exitL);
  FixLink(lp.brk);
end;

procedure MatchStatement;
var
  x: TItem; t: PType; c, f, o: PObj; p: int64; L, endL, n: longint;
  seen: array[0..255] of boolean; hasElse: boolean; endAt: TPos;
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
      if tok <> sIdent then MarkAt(MissingPos, 'case expected');
      c := t^.fields;
      while (c <> nil) and (c^.name <> id) do c := c^.next;
      if c = nil then Mark(NameOf(id) + ' isn''t a case of ' + TypeName(t));
      if (c^.val <= High(seen)) and seen[c^.val] then Mark('case twice');
      if c^.val <= High(seen) then seen[c^.val] := true;
      Next;
      L := NoLabel;
      MatchTag(p, c^.val, L, t^.form = fEnum);
      OpenScope(NewScope);
      if tok = sLparen then begin
        Next;
        f := c^.fields;
        n := 0;
        repeat
          if tok <> sIdent then MarkAt(MissingPos, 'name expected');
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
  endAt := TokPos;
  Expect(sEnd, 'end');
  if not hasElse then begin
    c := t^.fields;
    while c <> nil do begin
      if (c^.val > High(seen)) or not seen[c^.val] then MarkAt(endAt, 'no arm for ' + NameOf(c^.name));
      c := c^.next;
    end;
  end;
  FixLink(endL);
end;

{ a, b := f(x): the variables first, left to right, then the call;
  then each result to its variable, in order. }
procedure MultiAssign(var x: TItem);
var d: array[0..15] of TItem; y, z: TItem; n, i: longint; called: boolean; f: PObj;
begin
  n := 0;
  d[0] := x;
  repeat
    if (d[n].mode <> mVar) or not d[n].isVar then MarkAt(d[n].pos, 'can''t assign to this');
    Pin(d[n]);
    inc(n);
    if tok <> sComma then break;
    if n > High(d) then Mark('too many variables');
    Next;
    Designator(d[n], called);
  until false;
  Expect(sBecomes, ':=');
  Designator(y, called);
  if not called or not y.typ^.tuple or (y.typ^.len <> n) then
    MarkAt(y.pos, 'needs a call with as many results as variables');
  f := y.typ^.fields;
  for i := 0 to n - 1 do begin
    z := y;
    Field(z, f);
    Assign(d[i], z);
    f := f^.next;
  end;
end;

procedure ReturnResults;
var f: PObj; x: TItem;
begin
  f := curResult^.fields;
  while f <> nil do begin
    Expression(x, f^.typ);
    ReturnField(f, x);
    f := f^.next;
    if f <> nil then Expect(sComma, ',');
  end;
end;

{ defer s: s is compiled where it stands, as a little subroutine of the
  procedure, jumped over; each way out of the statement list calls it. }
procedure Defer;
var L, pos, oldDepth: longint; oldLoop: PLoop; oldDeferring: boolean; start: TPos;
begin
  start := TokPos;
  Next;
  if directDefer then MarkAt(SpanFrom(start), 'defer can''t be deferred');
  if numDefers > High(defers) then MarkAt(SpanFrom(start), 'too many deferred statements');
  L := NoLabel;
  Jmp(L);
  pos := pc;
  oldDepth := depth; oldLoop := curLoop; oldDeferring := deferring;
  depth := 1;           { the return address }
  curLoop := nil;
  deferring := true;
  directDefer := true;
  Statement;
  directDefer := false;
  KeepTemps;
  depth := oldDepth; curLoop := oldLoop; deferring := oldDeferring;
  Ret;
  FixLink(L);
  defers[numDefers] := pos;
  inc(numDefers);
end;

procedure OneStatement;
var x, y: TItem; called: boolean; m: int64; c: TCall; start: TPos;
begin
  start := TokPos;
  NoteLine(CurLine);
  m := TempMark;
  case tok of
    sIdent: begin
      Designator(x, called);
      if tok = sBecomes then begin
        if (x.mode <> mVar) or not x.isVar then MarkAt(x.pos, 'can''t assign to this');
        Save(x);
        Next;
        Expression(y, x.typ);
        Assign(x, y);
      end else if tok = sComma then
        MultiAssign(x)
      else if not called then begin
        if (x.mode = mProc) or ((x.mode in [mVar, mReg]) and (x.typ^.form = fProc)) then begin
          BeginCall(c, x);
          EndCall(c, x);
        end else MarkAt(x.pos, 'not a statement');
      end;
    end;
    sIf: IfStatement;
    sWhile: WhileStatement;
    sRepeat: RepeatStatement;
    sFor: ForStatement;
    sMatch: MatchStatement;
    sReturn: begin
      Next;
      if deferring then MarkAt(SpanFrom(start), 'return can''t leave a deferred statement');
      if tok = sSemicolon then begin
        RunDefers(0);
        ReturnNone;
      end else begin
        if (curResult <> nil) and curResult^.tuple then ReturnResults
        else begin
          Expression(x, curResult);
          ReturnValue(x);
        end;
        if numDefers > 0 then begin
          if deferSlot = 0 then deferSlot := AllocPerm(8, 8);
          Store(Mem(RBP, deferSlot), RAX, 8);
          RunDefers(0);
          Load(RAX, Mem(RBP, deferSlot), 8, false);
        end;
        ReturnJump;
      end;
    end;
    sBreak: begin
      Next;
      if curLoop = nil then MarkAt(SpanFrom(start), 'break outside a loop');
      RunDefers(curLoop^.base);
      Jmp(curLoop^.brk);
    end;
    sDefer: Defer;
  else if AtLineStart then MarkAt(MissingPos, 'end expected')
  else MarkAt(MissingPos, 'statement expected');
  end;
  ReleaseTemps(m);
end;

procedure Statement;
var r: TRecover; m: int64;
begin
  m := TempMark;
  Guard(r);
  if setjmp(r.jb) = 0 then begin
    OneStatement;
    skipped := false;
  end else begin
    Restore(r);
    { a statement never starts a line: this is the next declaration }
    if AtLineStart or not SkipConstruct then GiveUp(r);
    ReleaseTemps(m);
    skipped := true;
  end;
  Unguard(r);
end;

procedure Statements;
var base: longint; old: boolean;
begin
  base := numDefers;
  old := directDefer;
  directDefer := false;
  while not (tok in [sEnd, sElse, sElsif, sUntil, sBar, sEof]) do begin
    Statement;
    if not skipped or (tok = sSemicolon) then Expect(sSemicolon, ';');
  end;
  RunDefers(base);
  numDefers := base;
  directDefer := old;
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

procedure Body(p: PObj; sig: PType; line: longint);
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
  deferSlot := 0;
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
  EnterBody(p^.chunk, line);
  Statements;
  NoteLine(CurLine);
  Expect(sEnd, 'end');
  EndProc(p^.chunk);
  curResult := old;
  CloseScope;
end;

procedure CodeBody(p: PObj; sig: PType; const at: TPos);
var q: PObj; ni, nf: longint; v: int64; start: TPos;
begin
  ni := 0; nf := 0;
  q := sig^.fields;
  while q <> nil do begin
    if not q^.isVar and not IsScalar(q^.typ) then
      MarkAt(at, 'a code procedure takes integers, BOOL, reals, pointers and procedures');
    if (q^.typ^.form = fReal) and not q^.isVar then inc(nf) else inc(ni);
    q := q^.next;
  end;
  if (ni > 6) or (nf > 8) or sig^.variadic then MarkAt(at, 'too many parameters for a code procedure');
  if sig^.base <> nil then
    if sig^.base^.tuple then begin
      q := sig^.base^.fields;
      if (sig^.base^.len <> 2) or (q^.typ^.size <> 8) or (q^.next^.typ^.size <> 8)
        or not IsScalar(q^.typ) or not IsScalar(q^.next^.typ)
        or (q^.typ^.form = fReal) or (q^.next^.typ^.form = fReal) then
        MarkAt(at, 'a code procedure returns two results only in rax and rdx');
    end else if not IsScalar(sig^.base) then MarkAt(at, 'a code procedure returns a single value');
  BeginChunk(p^.chunk);
  repeat
    start := TokPos;
    v := ConstExpr;
    if (v < 0) or (v > 255) then MarkAt(SpanFrom(start), 'a byte expected');
    Put1(v);
    if tok <> sComma then break;
    Next;
  until false;
  EndChunk(p^.chunk);
end;

procedure ProcDecl;
var n, line: longint; exp: boolean; sig: PType; p: PObj; at: TPos;
begin
  line := CurLine;
  Next;
  at := TokPos;
  IdentDef(n, exp);
  at := SpanFrom(at);
  sig := Signature;
  Expect(sSemicolon, ';');
  p := Find(TopScope, n);
  if (p <> nil) and (p^.cls = oProc) and p^.fwd then begin
    if not Same(p^.typ, sig) then MarkAt(at, 'not the signature it was declared with');
    if tok = sForward then Mark('declared forward twice');
    p^.exported := p^.exported or exp;
  end else begin
    p := NewObj(oProc, n, sig);
    p^.exported := exp;
    if (curModule^.name = nameRt) and not checkMode and (n = nameFail) then p^.chunk := rtFail
    else if (curModule^.name = nameRt) and not checkMode and (n = nameEq) then p^.chunk := rtEq
    else p^.chunk := NewChunk(secText, curModule^.sname, n);
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
    CodeBody(p, sig, at);
    exit;
  end;
  if checkMode then SkipBody else Body(p, sig, line);
  if tok = sIdent then begin
    if id <> n then Mark('the procedure is ' + NameOf(n));
    Next;
  end;
end;

{ An extern procedure or variable: C's, reached through the quadword
  that holds its address. }
procedure ExternDecl;
var n: longint; exp: boolean; o, q: PObj; t: PType; at: TPos;
begin
  Next;
  curModule^.usesC := true;
  if tok = sProc then begin
    Next;
    at := TokPos;
    IdentDef(n, exp);
    WillDeclare(n);
    at := SpanFrom(at);
    inExtern := true;
    t := Signature;
    inExtern := false;
    q := t^.fields;
    while q <> nil do begin
      if q^.isVar or not IsScalar(q^.typ) then
        MarkAt(at, 'C takes integers, BOOL, reals, pointers and procedures');
      q := q^.next;
    end;
    if (t^.base <> nil) and not IsScalar(t^.base) then MarkAt(at, 'C returns a single value');
    o := NewObj(oProc, n, t);
  end else begin
    if tok <> sVar then MarkAt(MissingPos, 'proc or var expected');
    Next;
    IdentDef(n, exp);
    WillDeclare(n);
    Expect(sColon, ':');
    declExported := exp;
    t := ParseType;
    declExported := false;
    o := NewObj(oVar, n, t);
  end;
  o^.exported := exp;
  o^.ext := true;
  o^.chunk := ExternChunk(n);
  Declare(o);
end;

procedure ConstDecl(top: boolean);
var n: longint; exp: boolean; x: TItem; o: PObj; t: PType; start: TPos;
begin
  IdentDef(n, exp);
  WillDeclare(n);
  t := nil;
  if tok = sColon then begin
    Next;
    start := TokPos;
    t := ParseType;
    if t <> tError then MarkAt(SpanFrom(start), 'only an ERROR constant has a type');
  end;
  Expect(sEql, '=');
  Expression(x, nil);
  o := NewObj(oConst, n, x.typ);
  o^.exported := exp and top;
  if t = tError then begin
    o^.typ := tError;
    o^.val := ErrorChunk(x, curModule^.sname, n) + 1;
  end else if x.mode = mStr then begin o^.val := x.val; o^.chunk := x.chunk end
  else o^.val := ConstValue(x);
  Declare(o);
  Expect(sSemicolon, ';');
end;

procedure TypeDecl(top: boolean);
var n: longint; exp: boolean; o: PObj; t: PType;
begin
  IdentDef(n, exp);
  WillDeclare(n);
  Expect(sEql, '=');
  declExported := exp and top;
  inTypes := true;
  t := ParseType;
  o := NewObj(oType, n, t);
  o^.exported := exp and top;
  if t^.obj = nil then t^.obj := o;
  Declare(o);
  Expect(sSemicolon, ';');
end;

procedure VarDecl(top: boolean);
var
  i, k: longint; o: PObj; t: PType;
  names: array[0..63] of longint; exps: array[0..63] of boolean;
begin
  k := 0;
  repeat
    if k > High(names) then Mark('too many names');
    IdentDef(names[k], exps[k]);
    WillDeclare(names[k]);
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
      o^.chunk := NewChunk(secBss, curModule^.sname, names[i]);
      SetBss(o^.chunk, t^.size, t^.align);
    end else begin
      o^.lev := 1;
      o^.val := AllocPerm(t^.size, t^.align);
    end;
    Declare(o);
  end;
  Expect(sSemicolon, ';');
end;

{ After a procedure had an error: its name is poison if it wasn't
  declared, and reading goes on after the "end Name;" that closes it,
  or at the next procedure if that is missing }
procedure SkipProc;
var st: TScanState;
begin
  Next;
  if (tok = sIdent) and (Find(TopScope, id) = nil) then Poison(id);
  repeat
    repeat Next until AtLineStart or (tok = sEof);
    if tok in [sProc, sExtern, sEof] then exit;
    if tok = sEnd then begin
      SaveScan(st);
      Next;
      if tok = sIdent then Next;
      if tok = sSemicolon then begin Next; exit end;
      RestoreScan(st);
      exit;
    end;
  until false;
end;

{ One declaration, of the kind k, as a recovery point }
procedure Declaration(k: TSym; top: boolean);
var r: TRecover;
begin
  Guard(r);
  numDeclaring := 0;
  if setjmp(r.jb) = 0 then
    case k of
      sConst: ConstDecl(top);
      sType: TypeDecl(top);
      sVar: VarDecl(top);
      sProc: begin
        if not top then Mark('procedures don''t nest');
        ProcDecl;
        Expect(sSemicolon, ';');
      end;
      sExtern: begin
        if not top then Mark('extern only at the top of a module');
        ExternDecl;
        Expect(sSemicolon, ';');
      end;
    end
  else begin
    Restore(r);
    if k = sProc then SkipProc else SkipDeclaration;
  end;
  Unguard(r);
end;

procedure Declarations(top: boolean);
var i: longint; o: PObj; k: TSym;
begin
  repeat
    k := tok;
    case k of
      sConst, sVar: begin
        Next;
        while tok = sIdent do Declaration(k, top);
      end;
      sType: begin
        Next;
        numFwd := 0;
        while tok = sIdent do Declaration(sType, top);
        inTypes := false;
        for i := 0 to numFwd - 1 do begin
          o := Lookup(fwdTypes[i]^.fwd);
          if (o = nil) or (o^.cls <> oType) then begin
            Error(fwdPos[i], NameOf(fwdTypes[i]^.fwd) + ' isn''t declared');
            fwdTypes[i]^.base := tPoison;
          end else fwdTypes[i]^.base := o^.typ;
          fwdTypes[i]^.fwd := -1;
        end;
      end;
      sProc, sExtern: Declaration(k, top);
    else exit;
    end;
  until false;
end;

{ Modules }

{ Whether m is module n with these arguments. }
function IsModule(m: PModule; n: longint; const args: TArgs): boolean;
var i: longint;
begin
  IsModule := false;
  if (m^.name <> n) or (m^.args.n <> args.n) then exit;
  for i := 0 to args.n - 1 do
    if (m^.args.o[i] <> args.o[i]) or not Same(m^.args.t[i], args.t[i]) then exit;
  IsModule := true;
end;

function FindModule(n: longint; const args: TArgs): PModule;
var m: PModule;
begin
  m := firstModule;
  while (m <> nil) and not IsModule(m, n, args) do m := m^.next;
  FindModule := m;
end;

{ The arguments of an instance: types, or procedures named. }
procedure ParseArgs(var args: TArgs);
var o: PObj; start: TPos;
begin
  Next;
  repeat
    if args.n > High(args.t) then Mark('too many arguments');
    args.o[args.n] := nil;
    start := TokPos;
    if tok = sIdent then begin
      o := QualIdent;
      if o^.cls = oProc then args.o[args.n] := o
      else if o^.cls <> oType then MarkAt(SpanFrom(start), 'a type or a procedure expected');
      args.t[args.n] := o^.typ;
    end else args.t[args.n] := ParseType;
    args.pos[args.n] := SpanFrom(start);
    inc(args.n);
    if tok <> sComma then break;
    Next;
  until false;
  Expect(sRparen, ')');
end;

{ A generic module's parameters, bound to the instance's arguments: a
  type parameter names its type, a procedure parameter its procedure. }
procedure Params(m: PModule);
var i: longint; o, a: PObj; sig: PType; s: shortstring; at: TPos;
begin
  i := 0;
  s := NameOf(m^.name) + '(';
  Next;
  repeat
    if (tok <> sIdent) or (i >= m^.args.n) then MarkAt(m^.args.at, 'needs a type for each type parameter');
    if m^.args.o[i] <> nil then MarkAt(m^.args.pos[i], 'needs a type for each type parameter');
    Declare(NewObj(oType, id, m^.args.t[i]));
    s := s + TypeName(m^.args.t[i]) + ',';
    inc(i);
    Next;
    if tok <> sComma then break;
    Next;
  until false;
  while tok = sSemicolon do begin
    Next;
    if tok <> sIdent then MarkAt(MissingPos, 'name expected');
    at := TokPos;
    o := NewObj(oProc, id, nil);
    Next;
    Expect(sColon, ':');
    Expect(sProc, 'proc');
    sig := Signature;
    if i >= m^.args.n then MarkAt(m^.args.at, 'needs a procedure for ' + NameOf(o^.name));
    a := m^.args.o[i];
    if (a = nil) or not Same(a^.typ, sig) then begin
      Error(m^.args.pos[i], 'needs a procedure with the signature of ' + NameOf(o^.name));
      Note(at, NameOf(o^.name) + ' is declared here');
      Finish;
    end;
    o^.typ := a^.typ; o^.chunk := a^.chunk; o^.isCode := a^.isCode; o^.ext := a^.ext;
    Declare(o);
    s := s + NameOf(a^.module^.name) + '.' + NameOf(a^.name) + ',';
    inc(i);
  end;
  Expect(sRparen, ')');
  if i <> m^.args.n then MarkAt(m^.args.at, 'too many arguments');
  s[length(s)] := ')';
  m^.sname := Name(s);
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

function CompileFile(const path: shortstring; n: longint; const args: TArgs; checkOnly: boolean): PModule;
var
  st: TScanState; saved: array[0..MaxDepth - 1] of longint; d: longint;
  oldMod: PModule; oldFile: longint; oldCheck: boolean; m, im: PModule;
  imp: PImport; lib: PLib; start: TPos; alias, mname, line, oldPath: longint; o: PObj; body: longint; iargs: TArgs;
begin
  SaveScan(st);
  SaveScopes(d, saved);
  oldMod := curModule; oldFile := fileChunk; oldCheck := checkMode; oldPath := curFile;
  curFile := Name(path);
  if not Open(path) then Fatal('can''t read ' + path);
  New(m);
  FillChar(m^, SizeOf(TModule), 0);
  m^.name := n;
  m^.sname := n;
  m^.args := args;
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
  if tok = sLparen then Params(m)
  else if args.n > 0 then MarkAt(args.at, NameOf(n) + ' isn''t generic');
  Expect(sSemicolon, ';');
  while tok = sImport do begin
    Next;
    repeat
      if tok <> sIdent then MarkAt(MissingPos, 'module name expected');
      start := TokPos;
      alias := id;
      mname := id;
      iargs.n := 0;
      Next;
      if tok = sBecomes then begin
        Next;
        if tok <> sIdent then MarkAt(MissingPos, 'module name expected');
        mname := id;
        Next;
        if tok = sLparen then ParseArgs(iargs);
      end;
      iargs.at := SpanFrom(start);
      im := ImportModule(mname, iargs);
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
  while tok = sLink do begin
    Next;
    if (tok = sIdent) and (id = nameStatic) then m^.linkStatic := true
    else if tok = sString then begin
      New(lib);
      lib^.name := Intern(@sbuf, slen);
      lib^.next := m^.libs;
      m^.libs := lib;
      m^.usesC := true;
    end else Mark('a library or static expected');
    Next;
    Expect(sSemicolon, ';');
  end;
  Declarations(true);
  if tok = sBegin then begin
    if checkMode then SkipBody
    else begin
      line := CurLine;
      Next;
      body := NewChunk(secText, m^.sname, nameBody);
      m^.body := body;
      BeginProc(tBodySig, nil);
      deferSlot := 0;
      curResult := nil;
      EnterBody(body, line);
      Statements;
      NoteLine(CurLine);
      Expect(sEnd, 'end');
      EndProc(body);
    end;
  end else Expect(sEnd, 'end');
  if (tok <> sIdent) or (id <> n) then Mark('end ' + NameOf(n) + ' expected');
  Next;
  if tok <> sPeriod then MarkAt(MissingPos, '. expected');
  o := m^.first;
  while o <> nil do begin
    if (o^.cls = oProc) and o^.fwd then Error(TokPos, NameOf(o^.name) + ' is declared forward but never defined');
    o := o^.link;
  end;
  if errors > 0 then Finish;   { a module with errors stops the compiler after it }
  CloseScope;
  m^.done := true;
  if not checkOnly then begin
    dec(numPending);
    if lastModule = nil then firstModule := m else lastModule^.next := m;
    lastModule := m;
  end;
  curModule := oldMod; fileChunk := oldFile; checkMode := oldCheck; curFile := oldPath;
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
procedure CheckSiblings(const dir, chosen: shortstring; n: longint; m: PModule; const args: TArgs);
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
      and (copy(f, length(f) - 3, 4) = '.raz') and (f <> chosen)
      and (numOthers <= High(others)) then begin
      others[numOthers] := f;
      inc(numOthers);
    end;
  until false;
  FpCloseDir(dp^);
  for i := 0 to numOthers - 1 do
    CompareIface(m, CompileFile(dir + '/' + others[i], n, args, true));
end;

function ImportModule(name: longint; const args: TArgs): PModule;
const Suffixes: array[0..3] of string[16] = ('.' + Target, '.' + TargetOS, '.' + TargetArch, '');
var m: PModule; i, j: longint; dir, f: shortstring;
begin
  m := FindModule(name, args);
  if m <> nil then exit(m);
  for i := 0 to numPending - 1 do
    if IsModule(pending[i], name, args) then MarkAt(args.at, NameOf(name) + ' imports itself');
  for i := -1 to numInc do begin
    if i = -1 then dir := mainDir
    else if i = numInc then dir := libDir
    else dir := incDirs[i];
    for j := 0 to 3 do begin
      f := NameOf(name) + Suffixes[j] + '.raz';
      if Exists(dir + '/' + f) then begin
        m := CompileFile(dir + '/' + f, name, args, false);
        CheckSiblings(dir, f, name, m, args);
        exit(m);
      end;
    end;
  end;
  MarkAt(args.at, 'can''t find module ' + NameOf(name));
  ImportModule := nil;
end;

function CompileMain(const path: shortstring): PModule;
var base: shortstring; i, n: longint; none: TArgs;
begin
  none.n := 0;
  i := length(path);
  while (i > 0) and (path[i] <> '/') do dec(i);
  if i = 0 then mainDir := '.' else mainDir := copy(path, 1, i - 1);
  base := copy(path, i + 1, 255);
  i := pos('.', base);
  if i > 0 then base := copy(base, 1, i - 1);
  if base = '' then Fatal('no module in ' + path);
  n := Name(base);
  none.at := TokPos;
  if n <> nameRt then ImportModule(nameRt, none);
  if FindModule(n, none) <> nil then CompileMain := FindModule(n, none)
  else CompileMain := CompileFile(path, n, none, false);
end;

initialization
  nameRt := Name('Rt');
  nameFail := Name('fail');
  nameEq := Name('eq');
  nameMain := Name('main');
  nameBody := Name('body');
  nameStatic := Name('static');
  rtFail := NewChunk(secText, nameRt, nameFail);
  rtEq := NewChunk(secText, nameRt, nameEq);
  argcChunk := NewChunk(secBss, -1, Name('argc'));
  SetBss(argcChunk, 8, 8);
  argvChunk := NewChunk(secBss, -1, Name('argv'));
  SetBss(argvChunk, 8, 8);
  tArgv := NewPtr(NewPtr(tU8, false), false);
  tBodySig := NewType(fProc, 8, 8);
  curLoop := nil;
  numPending := 0;
  firstModule := nil;
  lastModule := nil;
end.
