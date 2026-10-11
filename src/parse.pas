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

  { A generic module's import whose instance isn't made yet }
  TDeferred = record
    o: PObj;           { the name it imports as }
    m: PModule;        { the module that imports it }
    mname: longint;    { the generic module }
    args: TScanState;  { at the "(" of its arguments }
    at: TPos;          { the import }
  end;

var
  checkMode: boolean;     { reading a file only for its interface }
  inTypes: boolean;       { in a type section: ^T may name a later type }
  fwdTypes: array[0..255] of PType;
  fwdPos: array[0..255] of TPos;    { where each names its type }
  numFwd: longint;
  lastCalled: PObj;      { the procedure the last call was of, if it had a name }
  passOn: boolean;       { the next factor may be a call with several results, for return }
  curProc: PObj;          { the procedure being compiled, or nil }
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
  nameRt, nameFail, nameMain, nameBody, nameStatic: longint;
  declaring: array[0..63] of longint;   { the names the declaration being read declares }
  numDeclaring: longint;
  skipped: boolean;       { the last statement had an error and was skipped }
  deferred: array[0..63] of TDeferred;
  numDeferred: longint;
  making: boolean;        { reading an instance's arguments, at its first use }
  useAt: TPos;            { ... which is here }

procedure Expression(var x: TItem; want: PType); forward;
function ParseType: PType; forward;
procedure Statements; forward;
procedure Statement; forward;

{ Little helpers }

{ A missing symbol is reported just after the one before it. }
procedure Expected(const what: shortstring);
begin
  MarkAt(MissingPos, 'expected ' + what + ', found ' + Found);
end;

procedure Expect(s: TSym);
begin
  if (tok = sLbrace) and (s in [sThen, sDo]) then
    MarkHelp(MissingPos, 'expected ' + SymText(s) + ', found ' + Found, 'a block is written ' + SymText(s) + ' ... end');
  if tok <> s then Expected(SymText(s));
  Next;
end;

function Name(const s: shortstring): longint;
begin
  Name := Intern(@s[1], length(s));
end;

{ A name being declared, and whether it is exported; at is the name }
procedure IdentDef(var n: longint; var exp: boolean; var at: TPos);
begin
  if tok <> sIdent then Expected('a name');
  n := id;
  at := TokPos;
  Next;
  exp := false;
  if tok = sTimes then begin
    exp := true;
    Next;
  end;
end;

{ Declares o in the innermost scope. Its module keeps its declarations
  in order: its own, for the interface check, and its procedures', to
  warn of those never used. }
procedure Declare(o: PObj);
begin
  Insert(o, TopScope);
  if TopScope = curModule^.scope then begin
    if curModule^.last = nil then curModule^.first := o
    else curModule^.last^.link := o;
    curModule^.last := o;
  end else begin
    if curModule^.lastLocal = nil then curModule^.locals := o
    else curModule^.lastLocal^.link := o;
    curModule^.lastLocal := o;
  end;
end;

{ o is named: a procedure naming itself doesn't count }
procedure Named(o: PObj);
begin
  if o <> curProc then begin
    o^.used := true;
    o^.read := true;
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
  skipping := false;
end;

{ After an error: the state as it was at the start of r's construct,
  whose first symbol is again the current one }
procedure Restore(var r: TRecover);
begin
  RestoreScan(r.scan);
  skipping := true;
  CutScopes(r.scopes); depth := r.depth; numDefers := r.numDefers;
  curLoop := r.loop; curResult := r.result;
  deferring := r.deferring; directDefer := r.directDefer;
  inTypes := false; declExported := false; inExtern := false; making := false;
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
  "else", "elsif", "until" or "|" of the statement around it (an arm's
  "|" comes after a ";", the operator's after an operand). False if it
  stopped at a symbol that starts a line, or the end of the file. }
function SkipConstruct: boolean;
var d, p: longint; prev: TSym;
begin
  d := 0; p := 0; prev := sSemicolon;
  repeat
    case tok of
      sIf, sWhile, sFor, sMatch, sRepeat, sRecord, sVariant: inc(d);
      sEnd, sUntil: if d = 0 then exit(true) else dec(d);
      sElse, sElsif: if (d = 0) and (p = 0) then exit(true);
      sBar: if (d = 0) and (p = 0) and (prev = sSemicolon) then exit(true);
      sLparen, sLbrak, sLbrace: inc(p);
      sRparen, sRbrak, sRbrace: if p > 0 then dec(p);
      sSemicolon: if (d = 0) and (p = 0) then exit(true);
      sEof: exit(false);
    end;
    prev := tok;
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
  if x.mode <> mConst then MarkAt(x.pos, 'expected a constant');
  ConstValue := x.val;
end;

function ConstExpr: int64;
var x: TItem;
begin
  Expression(x, nil);
  if not IsInt(x.typ) then MarkAt(x.pos, 'expected an integer constant, found ' + What(x));
  ConstExpr := ConstValue(x);
end;

{ Help after a name that isn't found: o, the closest name in reach }
procedure DidYouMean(o: PObj);
begin
  if o <> nil then Help('did you mean ' + NameOf(o^.name) + '?');
end;

{ Where module n is found, if it is: dir and the file in it }
function ModuleFile(n: longint; var dir, f: shortstring): boolean; forward;

{ Reports name n at p as not declared, with what it may have meant }
procedure NotDeclared(const p: TPos; n: longint);
var dir, f: shortstring;
begin
  Error(p, NameOf(n) + ' isn''t declared');
  if ModuleFile(n, dir, f) then Help(NameOf(n) + ' is a module: import ' + NameOf(n))
  else if (NameOf(n) = 'elif') or (NameOf(n) = 'elseif') then Help('raz writes elsif')
  else DidYouMean(Closest(n, -1));
end;

procedure FirstUse(o: PObj; const at: TPos); forward;
procedure InstancesFor(wholeRest: boolean); forward;
procedure AddImport(m, im: PModule); forward;

function QualIdent: PObj;
var o: PObj; m: PModule; at: TPos;
begin
  if tok <> sIdent then Expected('a name');
  at := TokPos;
  o := Lookup(id);
  if o = nil then begin
    if not making then Poison(id);   { it may yet be declared }
    quiet := false;
    NotDeclared(at, id);
    if making then Note(useAt, 'the instance is made here, where it is first used');
    Fail;
  end;
  if o^.typ = tPoison then quiet := true;
  Named(o);
  Next;
  if o^.cls = oModule then begin
    if o^.module = nil then FirstUse(o, at);
    Expect(sPeriod);
    if tok <> sIdent then Expected('a name');
    m := o^.module;
    o := Find(m^.scope, id);
    if (o = nil) or not o^.exported then begin
      Error(TokPos, NameOf(id) + ' isn''t exported by ' + NameOf(m^.name));
      if o <> nil then Note(o^.pos, NameOf(id) + ' is declared here, without a *')
      else DidYouMean(Closest(id, m^.scope));
      Fail;
    end;
    Next;
  end;
  QualIdent := o;
end;

{ The field of record type t named by the current symbol }
function FieldOf(t: PType): PObj;
var f: PObj;
begin
  f := Find(t^.scope, id);
  if f = nil then begin
    Error(TokPos, TypeName(t) + ' has no field ' + NameOf(id));
    DidYouMean(Closest(id, t^.scope));
    Fail;
  end;
  if not f^.exported and (t^.module <> curModule) then begin
    Error(TokPos, 'field ' + NameOf(id) + ' of ' + TypeName(t) + ' isn''t exported');
    Note(f^.pos, NameOf(id) + ' is declared here, without a *');
    Fail;
  end;
  FieldOf := f;
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
  exps: array[0..63] of boolean; poss: array[0..63] of TPos;
  n, i: longint; off, a, maxA: int64;
begin
  t := NewType(fRecord, 0, 1);
  if tok = sPacked then begin t^.packd := true; Next end;
  Expect(sRecord);
  t^.scope := NewScope;
  off := 0; maxA := 1; last := nil;
  while tok = sIdent do begin
    n := 0;
    repeat
      if n > High(names) then Mark('more than ' + IntStr(High(names) + 1) + ' names in one declaration');
      IdentDef(names[n], exps[n], poss[n]);
      inc(n);
      if tok <> sComma then break;
      Next;
    until false;
    Expect(sColon);
    ft := ParseType;
    if t^.packd then a := 1 else a := ft^.align;
    for i := 0 to n - 1 do begin
      off := AlignUp(off, a);
      f := NewObj(oField, names[i], ft);
      f^.exported := exps[i];
      f^.pos := poss[i];
      f^.val := off;
      Insert(f, t^.scope);
      if last = nil then t^.fields := f else last^.next := f;
      last := f;
      off := off + ft^.size;
    end;
    if a > maxA then maxA := a;
    Expect(sSemicolon);
  end;
  Expect(sEnd);
  t^.align := maxA;
  t^.size := AlignUp(off, maxA);
  RecordType := t;
end;

function VariantType: PType;
var t, ft: PType; c, lastC, f, lastF: PObj; tag, off, maxSize: int64; n: longint;
begin
  Expect(sVariant);
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
          if tok <> sIdent then Expected('a name');
          f := NewObj(oField, id, nil);
          f^.exported := true;
          if lastF = nil then c^.fields := f else lastF^.next := f;
          lastF := f;
          inc(n);
          Next;
          if tok <> sComma then break;
          Next;
        until false;
        Expect(sColon);
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
      Expect(sRparen);
    end;
    if off > maxSize then maxSize := off;
    Expect(sSemicolon);
    inc(tag);
  end;
  Expect(sEnd);
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
  Expect(sRparen);
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
          if tok <> sIdent then Expected('a name');
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
        Expect(sColon);
        pt := ParseType;
        while first <> nil do begin first^.typ := pt; first := first^.next end;
        if tok <> sSemicolon then break;
        Next;
      until false;
    Expect(sRparen);
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
    if tok <> sIdent then Expected('a name');
    o := NewObj(oConst, id, t);
    o^.val := t^.len;
    o^.exported := declExported;
    o^.used := true;   { an enumeration's names are its type's, warned of with it }
    Declare(o);
    if last = nil then t^.fields := o else last^.next := o;
    last := o;
    inc(t^.len);
    Next;
  until tok <> sComma;
  Expect(sRparen);
  if t^.len > 256 then MarkAt(SpanFrom(start), 'an enumeration has at most 256 names');
  EnumType := t;
end;

function SetOf(e: PType; const at: TPos): PType;
var t: PType;
begin
  if (e^.form <> fEnum) or (e^.len > 64) then MarkAt(at, 'a set needs an enumeration of at most 64 names, found ' + TypeName(e));
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
      if o^.cls <> oType then MarkAt(SpanFrom(start), NameOf(o^.name) + ' isn''t a type');
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
        if (n <= 0) or (n > (int64(1) shl 40)) then MarkAt(SpanFrom(start), 'an array''s length is from 1 to 2^40, found ' + IntStr(n));
        Expect(sRbrak);
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
        if numFwd > High(fwdTypes) then Mark('more than ' + IntStr(High(fwdTypes) + 1) + ' pointers to types not yet declared');
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
      Expect(sOf);
      start := TokPos;
      t := SetOf(ParseType(), start);
    end;
  else Expected('a type');
  end;
  ParseType := t;
end;

{ Expressions }

procedure Call(var x: TItem);
var c: TCall; a: TItem; want: PType;
begin
  BeginCall(c, x);
  Expect(sLparen);
  if tok <> sRparen then
    repeat
      if c.param <> nil then want := c.param^.typ else want := nil;
      Expression(a, want);
      PassArg(c, a);
      if tok <> sComma then break;
      Next;
    until false;
  Expect(sRparen);
  EndCall(c, x);
end;

procedure Args(n: longint; var slots: array of int64);
var i: longint; a: TItem;
begin
  for i := 0 to n - 1 do begin
    if i > 0 then Expect(sComma);
    Expression(a, nil);
    if not (IsScalar(a.typ) and (a.typ^.form <> fReal)) then MarkAt(a.pos, 'expected an integer or a pointer, found ' + What(a));
    if a.typ^.form = fConst then Coerce(a, tI64);
    slots[i] := ToSlot(a);
  end;
end;

procedure Atomic(var x: TItem; which: longint);
var p, a: TItem; t: PType; s: array[0..2] of int64; i, n: longint;
begin
  Expression(p, nil);
  if p.typ^.form <> fPtr then MarkAt(p.pos, 'expected a pointer, found ' + What(p));
  t := p.typ^.base;
  if not (((t^.form = fInt) or ((t^.form = fPtr) and (which <> bXadd))) and (t^.size = 8)) then
    MarkAt(p.pos, 'expected an 8-byte integer or a pointer, found ' + TypeName(t));
  s[0] := ToSlot(p);
  if which = bCas then n := 2 else n := 1;
  for i := 1 to n do begin
    Expect(sComma);
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
  Expect(sComma);
  Expression(y, nil);
  if (y.typ^.form <> fPtr) or (y.typ^.base^.obj = nil) or (y.typ^.base^.obj^.module = nil)
    or (NameOf(y.typ^.base^.obj^.name) <> 'Allocator')
    or (NameOf(y.typ^.base^.obj^.module^.name) <> 'Mem') then MarkAt(y.pos, 'NEW needs a ^Mem.Allocator, found ' + What(y));
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

function IncOrDec(which: longint): shortstring;
begin
  if which = bDec then IncOrDec := 'DEC' else IncOrDec := 'INC';
end;

procedure Builtin(var x: TItem);
const SysRegs: array[0..6] of longint = (RAX, RDI, RSI, RDX, R10, R8, R9);
var which, n, i: longint; y: TItem; t: PType; slots: array[0..6] of int64;
begin
  which := x.obj^.val;
  if which in [bFence, bArgc, bArgv] then begin
    if tok = sLparen then begin Next; Expect(sRparen) end;
    MakeConst(x, tNone, 0);
    case which of
      bFence: begin Mfence; x.mode := mNone end;
      bArgc: begin Load(RAX, MemRip(argcChunk, 0), 8, false); x.typ := tI64; x.mode := mReg end;
      bArgv: begin Load(RAX, MemRip(argvChunk, 0), 8, false); x.typ := tArgv; x.mode := mReg end;
    end;
    exit;
  end;
  Expect(sLparen);
  case which of
    bSize: begin
      t := ParseType;
      MakeConst(x, tConst, t^.size);
    end;
    bAdr: begin
      Expression(y, nil);
      if (y.mode <> mVar) or not y.isVar then MarkAt(y.pos, 'ADR needs a variable');
      if y.odd then MarkAt(y.pos, 'a field of a packed record has no address');
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
      end else MarkAt(y.pos, 'LEN needs an array or a slice, found ' + What(y));
    end;
    bSyscall: begin
      n := 1;
      Args(1, slots);
      while (tok = sComma) and (n < 7) do begin
        Next;
        Expression(y, nil);
        if not (IsScalar(y.typ) and (y.typ^.form <> fReal)) then MarkAt(y.pos, 'expected an integer or a pointer, found ' + What(y));
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
        MarkAt(x.pos, IncOrDec(which) + ' needs an integer variable');
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
  Expect(sRparen);
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
      if f <> nil then Expect(sComma);
    end;
    Expect(sRparen);
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
  if o^.cls = oModule then MarkAt(SpanFrom(start), NameOf(o^.name) + ' is a module, not a value');
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
        if (x.mode <> mVar) or (x.typ^.form <> fRecord) then MarkAt(x.pos, 'expected a record, found ' + What(x));
        if tok <> sIdent then Expected('a field');
        f := FieldOf(x.typ);
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
        Expect(sRbrak);
        called := false;
      end;
      sLparen: begin
        if x.mode = mType then begin
          t := x.typ;
          Next;
          Expression(x, nil);
          Expect(sRparen);
          Convert(x, t);
        end else begin
          if x.mode = mProc then lastCalled := x.obj else lastCalled := nil;
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
      if n > High(slots) then Mark('more than ' + IntStr(High(slots) + 1) + ' elements');
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
  Expect(sRbrak);
  if (want^.form = fArray) and (n <> want^.len) then MarkAt(SpanFrom(start), 'expected ' + IntStr(want^.len) + ' elements, found ' + IntStr(n));
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
      if tok <> sIdent then Expected('a field');
      f := FieldOf(t);
      for i := 0 to n - 1 do if seen[i] = id then Mark('field ' + NameOf(id) + ' is given twice');
      if n <= High(seen) then begin seen[n] := id; inc(n) end;
      Next;
      Expect(sColon);
      Expression(a, f^.typ);
      SetField(x, f, a);
      if tok <> sComma then break;
      Next;
    until false;
  Expect(sRbrace);
end;

{ A set literal: the bits of the constant names, or'd at run time with
  those of the others. }
procedure SetLiteral(var x: TItem; t: PType);
var e: TItem; bits, slot: int64; start: TPos; s: shortstring;
begin
  start := TokPos;
  Next;
  if (t <> nil) and (t^.form <> fSet) then MarkAt(SpanFrom(start), 'expected a set type, found ' + TypeName(t));
  bits := 0;
  slot := 0;
  if tok <> sRbrace then
    repeat
      if t = nil then Expression(e, nil) else Expression(e, t^.base);
      if t = nil then begin
        if e.typ^.form <> fEnum then MarkAt(e.pos, 'a set holds names of an enumeration, found ' + What(e));
        t := SetOf(e.typ, e.pos);
      end;
      if not Same(e.typ, t^.base) then begin
        if e.obj <> nil then s := NameOf(e.obj^.name) else s := What(e);
        MarkAt(e.pos, s + ' isn''t a name of ' + TypeName(t^.base));
      end;
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
  Expect(sRbrace);
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
var called, vol, several: boolean; t: PType; start: TPos; s: shortstring;
begin
  several := passOn;
  passOn := false;
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
      if x.mode = mNone then begin
        if lastCalled <> nil then s := NameOf(lastCalled^.name) else s := 'this procedure';
        MarkAt(x.pos, s + ' returns nothing');
      end;
      if x.typ^.tuple and not several then begin
        if lastCalled <> nil then s := NameOf(lastCalled^.name) else s := 'this procedure';
        MarkHelp(x.pos, s + ' returns several results', 'they go to variables: a, b := ' + s + '(...)');
      end;
    end;
    sLparen: begin Next; Expression(x, want); Expect(sRparen) end;
    sNot: begin Next; Factor(x, nil); NotOp(x) end;
    sTilde: begin Next; Factor(x, nil); Complement(x) end;
    sLbrak: ArrayLiteral(x, want);
    sLbrace: if (want <> nil) and (want^.form = fRecord) then RecordLiteral(x, want)
             else SetLiteral(x, want);
    sArrow: begin
      Next;
      vol := tok = sVolatile;
      if vol then Next;
      t := NewPtr(ParseType, vol);
      Expect(sLparen);
      Expression(x, nil);
      Expect(sRparen);
      Convert(x, t);
    end;
  else Expected('an expression');
  end;
  x.pos := SpanFrom(start);
end;

procedure Term(var x: TItem; want: PType);
var op: TSym; y: TItem; L: longint; start: TPos;
begin
  start := TokPos;
  Factor(x, want);
  while tok in [sTimes, sSlash, sDiv, sMod, sAmp, sShl, sShr] do begin
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
  while tok in [sPlus, sMinus, sBar, sXor] do begin
    op := tok;
    Next;
    Op1(op, x, L);
    Term(y, nil);
    Op2(op, x, y, L);
    x.pos := SpanFrom(start);
  end;
end;

procedure Relation(var x: TItem; want: PType);
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

{ and binds tighter than or, and both below the relations }
procedure Conjunct(var x: TItem; want: PType);
var y: TItem; L: longint; start: TPos;
begin
  start := TokPos;
  Relation(x, want);
  while tok = sAnd do begin
    Next;
    Op1(sAnd, x, L);
    Relation(y, nil);
    Op2(sAnd, x, y, L);
    x.pos := SpanFrom(start);
  end;
end;

procedure Expression(var x: TItem; want: PType);
var y: TItem; L: longint; start: TPos;
begin
  start := TokPos;
  Conjunct(x, want);
  while tok = sOr do begin
    Next;
    Op1(sOr, x, L);
    Conjunct(y, nil);
    Op2(sOr, x, y, L);
    x.pos := SpanFrom(start);
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
  Expect(sThen);
  L := NoLabel;
  CondJump(x, L);
  Statements;
  endL := NoLabel;
  while tok = sElsif do begin
    Jmp(endL);
    FixLink(L);
    Next;
    Expression(x, nil);
    Expect(sThen);
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
  Expect(sEnd);
  FixLink(endL);
end;

procedure WhileStatement;
var x: TItem; top, L: longint; lp: TLoop; old: PLoop;
begin
  Next;
  top := pc;
  Expression(x, nil);
  Expect(sDo);
  L := NoLabel;
  CondJump(x, L);
  Loop(lp, old);
  Statements;
  JmpBack(top);
  Expect(sEnd);
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
  Expect(sUntil);
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
  if tok <> sIdent then Expected('a name');
  o := Lookup(id);
  if o = nil then begin NotDeclared(TokPos, id); Fail end;
  Named(o);
  if (o^.cls <> oVar) or not (o^.typ^.form in [fInt, fEnum]) then
    if o^.cls = oVar then
      Mark('a for loop needs an integer or enumeration variable, found ' + TypeName(o^.typ))
    else Mark(NameOf(id) + ' isn''t a variable');
  Next;
  Expect(sBecomes);
  MakeItem(v, o);
  Save(v);
  Expression(a, o^.typ);
  Assign(v, a);
  Expect(sTo);
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
  Expect(sDo);
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
  Expect(sEnd);
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
  Expect(sOf);
  FillChar(seen, SizeOf(seen), 0);
  hasElse := false;
  endL := NoLabel;
  while tok = sBar do begin
    Next;
    if hasElse then Mark('else must be the last arm');
    if tok = sElse then begin
      Next;
      Expect(sColon);
      Statements;
      hasElse := true;
    end else begin
      if tok <> sIdent then Expected('a case');
      c := t^.fields;
      while (c <> nil) and (c^.name <> id) do c := c^.next;
      if c = nil then Mark(NameOf(id) + ' isn''t a case of ' + TypeName(t));
      if (c^.val <= High(seen)) and seen[c^.val] then Mark(NameOf(c^.name) + ' has two arms');
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
          if tok <> sIdent then Expected('a name');
          if f = nil then Mark('more names than ' + NameOf(c^.name) + ' has fields');
          o := NewObj(oVar, id, f^.typ);
          o^.lev := 1; o^.ind := true; o^.isVar := true;
          o^.val := p; o^.off := f^.val;
          Declare(o);
          f := f^.next;
          inc(n);
          Next;
          if tok <> sComma then break;
          Next;
        until false;
        if f <> nil then Mark('name all the fields of ' + NameOf(c^.name) + ', or none');
        Expect(sRparen);
      end;
      Expect(sColon);
      Statements;
      CloseScope;
      Jmp(endL);
      FixLink(L);
    end;
  end;
  endAt := TokPos;
  Expect(sEnd);
  if not hasElse then begin
    c := t^.fields;
    while c <> nil do begin
      if (c^.val > High(seen)) or not seen[c^.val] then MarkAt(endAt, 'no arm for ' + NameOf(c^.name));
      c := c^.next;
    end;
  end;
  FixLink(endL);
end;

{ What a message calls x: its name n when x is just that name, else what
  it is. }
function Subject(const x: TItem; n: longint): shortstring;
begin
  if x.pos.b - x.pos.a = length(NameOf(n)) then Subject := NameOf(n)
  else if x.mode = mConst then Subject := 'a constant'
  else Subject := 'a value';
end;

{ The designator a statement starts with. A variable named whole
  before := is assigned, not read: naming it there leaves it as unread
  as it was. }
procedure LeftSide(var x: TItem; var called: boolean);
var o: PObj; wasRead: boolean; n: longint;
begin
  n := id;
  o := Lookup(n);
  wasRead := (o <> nil) and o^.read;
  Designator(x, called);
  if (tok in [sBecomes, sComma]) and (x.pos.b - x.pos.a = length(NameOf(n))) then
    o^.read := wasRead;
end;

{ a, b := f(x): the variables first, left to right, then the call;
  then each result to its variable, in order. }
procedure MultiAssign(var x: TItem; first: longint);
var d: array[0..15] of TItem; dn: array[0..15] of longint; y, z: TItem; n, i: longint; called: boolean; f: PObj;
begin
  n := 0;
  d[0] := x;
  dn[0] := first;
  repeat
    if (d[n].mode <> mVar) or not d[n].isVar then MarkAt(d[n].pos, 'can''t assign to ' + Subject(d[n], dn[n]));
    Pin(d[n]);
    inc(n);
    if tok <> sComma then break;
    if n > High(d) then Mark('more than ' + IntStr(High(d) + 1) + ' variables in one assignment');
    Next;
    dn[n] := id;
    LeftSide(d[n], called);
  until false;
  Expect(sBecomes);
  Designator(y, called);
  if not called or not y.typ^.tuple or (y.typ^.len <> n) then
    MarkAt(y.pos, 'expected a call with ' + IntStr(n) + ' results');
  f := y.typ^.fields;
  for i := 0 to n - 1 do begin
    z := y;
    Field(z, f);
    Assign(d[i], z);
    f := f^.next;
  end;
end;

{ return a, b; or return f(x); with f's several results passed on }
procedure ReturnResults;
var f: PObj; x: TItem;
begin
  f := curResult^.fields;
  passOn := true;
  while f <> nil do begin
    Expression(x, f^.typ);
    if x.typ^.tuple then begin
      if not Same(x.typ, curResult) then
        MarkAt(x.pos, 'expected the results ' + TypeName(curResult) + ', found ' + TypeName(x.typ));
      ReturnAll(x);
      exit;
    end;
    ReturnField(f, x);
    f := f^.next;
    if f <> nil then Expect(sComma);
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
  if numDefers > High(defers) then MarkAt(SpanFrom(start), 'more than ' + IntStr(High(defers) + 1) + ' deferred statements in one procedure');
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
var x, y: TItem; called: boolean; m: int64; c: TCall; start: TPos; first: longint;
begin
  start := TokPos;
  first := id;
  NoteLine(CurLine, CurCol);
  m := TempMark;
  case tok of
    sIdent: begin
      LeftSide(x, called);
      if tok = sBecomes then begin
        if (x.mode <> mVar) or not x.isVar then MarkAt(x.pos, 'can''t assign to ' + Subject(x, first));
        Save(x);
        Next;
        Expression(y, x.typ);
        Assign(x, y);
      end else if tok = sComma then
        MultiAssign(x, first)
      else if not called then begin
        if (x.mode = mProc) or ((x.mode in [mVar, mReg]) and (x.typ^.form = fProc)) then begin
          BeginCall(c, x);
          EndCall(c, x);
        end else if tok = sEql then
          MarkHelp(x.pos, Subject(x, first) + ' isn''t a statement', 'assignment is written :=')
        else MarkAt(x.pos, Subject(x, first) + ' isn''t a statement');
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
  else if AtLineStart then Expected('"end"')
  else Expected('a statement');
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
    if not skipped or (tok = sSemicolon) then Expect(sSemicolon);
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
      sEof: Expected('"end"');
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
    o^.pos := q^.pos;
    o^.lev := 1;
    o^.isVar := q^.isVar;
    o^.param := true;
    if last = nil then params := o else last^.next := o;
    last := o;
    q := q^.next;
  end;
  BeginProc(sig, params);
  deferSlot := 0;
  o := params;
  while o <> nil do begin
    q := o^.next;
    Declare(o);
    o := q;
  end;
  curProc := p;
  Declarations(false);
  Expect(sBegin);
  old := curResult;
  curResult := sig^.base;
  EnterBody(p^.chunk, line);
  Statements;
  NoteLine(CurLine, CurCol);
  Expect(sEnd);
  EndProc(p^.chunk);
  curResult := old;
  curProc := nil;
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
    if (v < 0) or (v > 255) then MarkAt(SpanFrom(start), 'expected a byte from 0 to 255, found ' + IntStr(v));
    Put1(v);
    if tok <> sComma then break;
    Next;
  until false;
  EndChunk(p^.chunk);
end;

procedure ProcDecl;
var n, line: longint; exp: boolean; sig: PType; p: PObj; at: TPos;
begin
  InstancesFor(false);
  line := CurLine;
  Next;
  IdentDef(n, exp, at);
  sig := Signature;
  Expect(sSemicolon);
  p := Find(TopScope, n);
  if (p <> nil) and (p^.cls = oProc) and p^.fwd then begin
    if not Same(p^.typ, sig) then begin
      Error(at, NameOf(n) + ' doesn''t have the signature it was declared forward with');
      Note(p^.pos, 'the signature is here');
      Fail;
    end;
    if tok = sForward then Mark(NameOf(n) + ' is declared forward twice');
    p^.exported := p^.exported or exp;
  end else begin
    p := NewObj(oProc, n, sig);
    p^.pos := at;
    p^.exported := exp;
    if (curModule^.name = nameRt) and not checkMode and (n = nameFail) then p^.chunk := rtFail
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
    if id <> n then Mark('expected ' + NameOf(n) + ', found ' + NameOf(id));
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
    IdentDef(n, exp, at);
    WillDeclare(n);
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
    if tok <> sVar then Expected('"proc" or "var"');
    Next;
    IdentDef(n, exp, at);
    WillDeclare(n);
    Expect(sColon);
    declExported := exp;
    t := ParseType;
    declExported := false;
    o := NewObj(oVar, n, t);
  end;
  o^.pos := at;
  o^.exported := exp;
  o^.ext := true;
  o^.chunk := ExternChunk(n);
  Declare(o);
end;

procedure ConstDecl(top: boolean);
var n: longint; exp: boolean; x: TItem; o: PObj; t: PType; start, at: TPos;
begin
  IdentDef(n, exp, at);
  WillDeclare(n);
  t := nil;
  if tok = sColon then begin
    Next;
    start := TokPos;
    t := ParseType;
    if t <> tError then MarkAt(SpanFrom(start), 'only an ERROR constant has a type');
  end;
  Expect(sEql);
  Expression(x, nil);
  o := NewObj(oConst, n, x.typ);
  o^.pos := at;
  o^.exported := exp and top;
  if t = tError then begin
    o^.typ := tError;
    o^.val := ErrorChunk(x, curModule^.sname, n) + 1;
  end else if x.mode = mStr then begin o^.val := x.val; o^.chunk := x.chunk end
  else o^.val := ConstValue(x);
  Declare(o);
  Expect(sSemicolon);
end;

procedure TypeDecl(top: boolean);
var n: longint; exp: boolean; o: PObj; t: PType; at: TPos;
begin
  IdentDef(n, exp, at);
  WillDeclare(n);
  Expect(sEql);
  declExported := exp and top;
  inTypes := true;
  t := ParseType;
  o := NewObj(oType, n, t);
  o^.pos := at;
  o^.exported := exp and top;
  if t^.obj = nil then t^.obj := o;
  Declare(o);
  Expect(sSemicolon);
end;

procedure VarDecl(top: boolean);
var
  i, k: longint; o: PObj; t: PType;
  names: array[0..63] of longint; exps: array[0..63] of boolean;
  poss: array[0..63] of TPos;
begin
  k := 0;
  repeat
    if k > High(names) then Mark('more than ' + IntStr(High(names) + 1) + ' names in one declaration');
    IdentDef(names[k], exps[k], poss[k]);
    WillDeclare(names[k]);
    inc(k);
    if tok <> sComma then break;
    Next;
  until false;
  Expect(sColon);
  declExported := top and exps[0];
  t := ParseType;
  declExported := false;
  for i := 0 to k - 1 do begin
    o := NewObj(oVar, names[i], t);
    o^.pos := poss[i];
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
  Expect(sSemicolon);
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
        Expect(sSemicolon);
      end;
      sExtern: begin
        if not top then Mark('extern is only for the top of a module');
        ExternDecl;
        Expect(sSemicolon);
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
            NotDeclared(fwdPos[i], fwdTypes[i]^.fwd);
            fwdTypes[i]^.base := tPoison;
          end else begin
            fwdTypes[i]^.base := o^.typ;
            Named(o);
          end;
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
procedure ParseArgs(var args: TArgs; const mname: shortstring);
var o: PObj; start: TPos;
begin
  Next;
  repeat
    if args.n > High(args.t) then Mark('too many type arguments for ' + mname);
    args.o[args.n] := nil;
    start := TokPos;
    if tok = sIdent then begin
      o := QualIdent;
      if o^.cls = oProc then args.o[args.n] := o
      else if o^.cls <> oType then MarkAt(SpanFrom(start), NameOf(o^.name) + ' isn''t a type or a procedure');
      args.t[args.n] := o^.typ;
    end else args.t[args.n] := ParseType;
    args.pos[args.n] := SpanFrom(start);
    inc(args.n);
    if tok <> sComma then break;
    Next;
  until false;
  Expect(sRparen);
end;

{ Past an instance's arguments, to be read when it is made }
procedure SkipArgs;
var p: longint;
begin
  p := 0;
  repeat
    if tok = sLparen then inc(p)
    else if tok = sRparen then dec(p)
    else if tok in [sSemicolon, sEof] then Expected('")"');
    Next;
  until p = 0;
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
    if tok <> sIdent then Expected('a name');
    if i >= m^.args.n then MarkAt(m^.args.at, NameOf(m^.name) + ' needs a type for ' + NameOf(id));
    if m^.args.o[i] <> nil then MarkAt(m^.args.pos[i], NameOf(m^.name) + ' needs a type for ' + NameOf(id));
    o := NewObj(oType, id, m^.args.t[i]);
    o^.used := true;   { a parameter of the module, not a declaration }
    Declare(o);
    s := s + TypeName(m^.args.t[i]) + ',';
    inc(i);
    Next;
    if tok <> sComma then break;
    Next;
  until false;
  while tok = sSemicolon do begin
    Next;
    if tok <> sIdent then Expected('a name');
    at := TokPos;
    o := NewObj(oProc, id, nil);
    Next;
    Expect(sColon);
    Expect(sProc);
    sig := Signature;
    if i >= m^.args.n then MarkAt(m^.args.at, NameOf(m^.name) + ' needs a procedure for ' + NameOf(o^.name));
    a := m^.args.o[i];
    if a = nil then MarkAt(m^.args.pos[i], NameOf(m^.name) + ' needs a procedure for ' + NameOf(o^.name));
    if not Same(a^.typ, sig) then begin
      Error(m^.args.pos[i], NameOf(a^.name) + ' doesn''t have the signature of ' + NameOf(o^.name));
      Note(at, 'the signature is here');
      Finish;
    end;
    o^.typ := a^.typ; o^.chunk := a^.chunk; o^.isCode := a^.isCode; o^.ext := a^.ext;
    o^.used := true;
    Declare(o);
    s := s + NameOf(a^.module^.name) + '.' + NameOf(a^.name) + ',';
    inc(i);
  end;
  Expect(sRparen);
  if i <> m^.args.n then MarkAt(m^.args.at, 'too many type arguments for ' + NameOf(m^.name));
  s[length(s)] := ')';
  m^.sname := Name(s);
end;

{ Warns of o if it is never used, or a variable only assigned. What
  is exported may be used elsewhere, and a name that starts with _ says
  it is meant to go unused. Writing a var parameter, a match's name for
  a field or C's variable is what it is for. }
procedure Warn(o: PObj);
var s: shortstring;
begin
  s := NameOf(o^.name);
  if o^.exported or (s[1] = '_') then exit;
  if o^.used and (o^.read or (o^.cls <> oVar) or o^.isVar or o^.ext) then exit;
  case o^.cls of
    oConst: s := 'constant ' + s;
    oType: s := 'type ' + s;
    oVar: if o^.param then s := 'parameter ' + s else s := 'variable ' + s;
    oProc: s := 'procedure ' + s;
    oModule: s := 'module ' + s;
  else exit;
  end;
  if o^.used then Warning(o^.pos, s + ' is assigned but never read')
  else if o^.cls = oModule then Warning(o^.pos, s + ' is imported but never used')
  else Warning(o^.pos, s + ' is never used');
  if not o^.used and (o^.param or o^.ind) then
    Help('if it must be there, call it _' + NameOf(o^.name));
end;

{ The warnings of module m, by where each declaration is: its own
  declarations and its procedures' are two lists, each in order. The
  instances of a generic module share its text, and so its warnings:
  only the first is warned of. }
procedure Warnings(m: PModule);
var a, b: PObj; n: PModule;
begin
  n := firstModule;
  while (n <> nil) and (n^.name <> m^.name) do n := n^.next;
  if n <> nil then exit;
  a := m^.first; b := m^.locals;
  while (a <> nil) or (b <> nil) do
    if (b = nil) or (a <> nil) and (a^.pos.a < b^.pos.a) then begin
      Warn(a);
      a := a^.link;
    end else begin
      Warn(b);
      b := b^.link;
    end;
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
  oldMod: PModule; oldCheck: boolean; m: PModule;
  lib: PLib; start: TPos; alias, mname, line, oldPath: longint; o: PObj; body: longint; iargs: TArgs;
  generic: boolean; argsAt: TScanState;
begin
  SaveScan(st);
  SaveScopes(d, saved);
  oldMod := curModule; oldCheck := checkMode; oldPath := curFile;
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
  checkMode := checkOnly;
  if not checkOnly then begin
    if numPending > High(pending) then Mark('imports nested more than ' + IntStr(High(pending) + 1) + ' deep');
    pending[numPending] := m;
    inc(numPending);
  end;
  OpenScope(m^.scope);
  Next;
  Expect(sModule);
  if (tok <> sIdent) or (id <> n) then Mark('expected module ' + NameOf(n) + ', found ' + Found);
  Next;
  if tok = sLparen then Params(m)
  else if args.n > 0 then MarkAt(args.at, NameOf(n) + ' isn''t generic');
  Expect(sSemicolon);
  while tok = sImport do begin
    Next;
    repeat
      if tok <> sIdent then Expected('a module name');
      start := TokPos;
      alias := id;
      mname := id;
      iargs.n := 0;
      generic := false;
      Next;
      if tok = sBecomes then begin
        Next;
        if tok <> sIdent then Expected('a module name');
        mname := id;
        Next;
        if tok = sLparen then begin
          generic := true;
          SaveScan(argsAt);
          SkipArgs;
        end;
      end;
      iargs.at := SpanFrom(start);
      o := NewObj(oModule, alias, nil);
      o^.pos := start;
      Declare(o);
      if not generic then begin
        o^.module := ImportModule(mname, iargs);
        AddImport(m, o^.module);
      end else begin
        o^.module := nil;   { until the instance is made, at its first use }
        if numDeferred > High(deferred) then Mark('more than ' + IntStr(High(deferred) + 1) + ' generic imports');
        deferred[numDeferred].o := o;
        deferred[numDeferred].m := m;
        deferred[numDeferred].mname := mname;
        deferred[numDeferred].args := argsAt;
        deferred[numDeferred].at := iargs.at;
        inc(numDeferred);
      end;
      if tok <> sComma then break;
      Next;
    until false;
    Expect(sSemicolon);
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
    end else Expected('a library or "static"');
    Next;
    Expect(sSemicolon);
  end;
  Declarations(true);
  if tok = sBegin then begin
    if checkMode then SkipBody
    else begin
      InstancesFor(true);
      line := CurLine;
      Next;
      body := NewChunk(secText, m^.sname, nameBody);
      m^.body := body;
      BeginProc(tBodySig, nil);
      deferSlot := 0;
      curResult := nil;
      EnterBody(body, line);
      Statements;
      NoteLine(CurLine, CurCol);
      Expect(sEnd);
      EndProc(body);
    end;
  end else Expect(sEnd);
  if (tok <> sIdent) or (id <> n) then Expected(NameOf(n));
  Next;
  if tok <> sPeriod then Expected('"."');
  o := m^.first;
  while o <> nil do begin
    if (o^.cls = oProc) and o^.fwd then Error(TokPos, NameOf(o^.name) + ' is declared forward but never defined');
    o := o^.link;
  end;
  if (errors = 0) and not checkOnly then Warnings(m);
  if errors > 0 then Finish;   { a module with errors stops the compiler after it }
  CloseScope;
  m^.done := true;
  if not checkOnly then begin
    dec(numPending);
    if lastModule = nil then firstModule := m else lastModule^.next := m;
    lastModule := m;
  end;
  curModule := oldMod; checkMode := oldCheck; curFile := oldPath;
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

const Suffixes: array[0..3] of string[16] = ('.' + Target, '.' + TargetOS, '.' + TargetArch, '');

{ The directories searched for modules, in order, from -1 to numInc }
function SearchDir(i: longint): shortstring;
begin
  if i = -1 then SearchDir := mainDir
  else if i = numInc then SearchDir := libDir
  else SearchDir := incDirs[i];
end;

function ModuleFile(n: longint; var dir, f: shortstring): boolean;
var i, j: longint;
begin
  for i := -1 to numInc do begin
    dir := SearchDir(i);
    for j := 0 to 3 do begin
      f := NameOf(n) + Suffixes[j] + '.raz';
      if Exists(dir + '/' + f) then exit(true);
    end;
  end;
  ModuleFile := false;
end;

{ A program has one module of each name: module n, found as dir/f,
  must have no files in a later directory, unless dir/f is a link to
  one of them, which chooses it (report, section 3) }
procedure CheckOneModule(n: longint; const dir, f: shortstring; const at: TPos);
var i, j: longint; past, chosen: boolean; g, files, others: shortstring;
  st, mine: Stat;
begin
  g := dir + '/' + f + #0;
  FpStat(@g[1], mine);
  others := '';
  past := false;
  for i := -1 to numInc do begin
    if past then begin
      files := '';
      chosen := false;
      for j := 0 to 3 do begin
        g := SearchDir(i) + '/' + NameOf(n) + Suffixes[j] + '.raz';
        if Exists(g) then begin
          files := files + ' and ' + ShownPath(g);
          g := g + #0;
          FpStat(@g[1], st);
          chosen := chosen or ((st.st_dev = mine.st_dev) and (st.st_ino = mine.st_ino));
        end;
      end;
      if not chosen then others := others + files;
    end;
    past := past or (SearchDir(i) = dir);
  end;
  if others = '' then exit;
  Error(at, 'module ' + NameOf(n) + ' is in ' + ShownPath(dir + '/' + f) + others);
  Help('a program has one module of each name; a symbolic link to one of these files chooses it');
  Fail;
end;

function ImportModule(name: longint; const args: TArgs): PModule;
var m: PModule; i: longint; dir, f: shortstring;
begin
  m := FindModule(name, args);
  if m <> nil then exit(m);
  for i := 0 to numPending - 1 do
    if IsModule(pending[i], name, args) then MarkAt(args.at, NameOf(name) + ' imports itself');
  if not ModuleFile(name, dir, f) then MarkAt(args.at, 'can''t find module ' + NameOf(name));
  CheckOneModule(name, dir, f, args.at);
  m := CompileFile(dir + '/' + f, name, args, false);
  CheckSiblings(dir, f, name, m, args);
  ImportModule := m;
end;

procedure AddImport(m, im: PModule);
var imp: PImport;
begin
  New(imp);
  imp^.module := im;
  imp^.next := m^.imports;
  m^.imports := imp;
end;

{ Makes the instance that deferred[i] imports: its arguments are read
  where the import wrote them, and must be declared by now. Compiling
  the instance comes in the middle of a declaration, so what that
  declaration has under way is kept aside meanwhile. }
procedure MakeInstance(i: longint; const at: TPos);
var
  d: TDeferred; st: TScanState; args: TArgs; types, exported, ext, wasQuiet: boolean; nf, nd: longint;
  ft: array[0..255] of PType; fp: array[0..255] of TPos; decl: array[0..63] of longint;
begin
  d := deferred[i];
  dec(numDeferred);
  deferred[i] := deferred[numDeferred];
  SaveScan(st);
  RestoreScan(d.args);
  args.n := 0;
  making := true; useAt := at;
  ParseArgs(args, NameOf(d.mname));
  making := false;
  RestoreScan(st);
  args.at := d.at;
  types := inTypes; exported := declExported; ext := inExtern; wasQuiet := quiet;
  nf := numFwd; ft := fwdTypes; fp := fwdPos; nd := numDeclaring; decl := declaring;
  d.o^.module := ImportModule(d.mname, args);
  inTypes := types; declExported := exported; inExtern := ext; quiet := wasQuiet;
  numFwd := nf; fwdTypes := ft; fwdPos := fp; numDeclaring := nd; declaring := decl;
  AddImport(curModule, d.o^.module);
end;

procedure FirstUse(o: PObj; const at: TPos);
var i: longint;
begin
  for i := 0 to numDeferred - 1 do
    if deferred[i].o = o then begin MakeInstance(i, at); exit end;
  Fail;   { its arguments had an error, already reported }
end;

{ An instance can't be compiled in the middle of another procedure's
  code, so before a procedure's code begins, from its "proc" on, or
  the module body's, from its "begin" to the end of the file, this
  reads ahead for the names of imports not yet made, and makes those. }
procedure InstancesFor(wholeRest: boolean);
var st: TScanState; d, i: longint; begun: boolean;
begin
  if checkMode then exit;
  i := numDeferred - 1;
  while (i >= 0) and (deferred[i].m <> curModule) do dec(i);
  if i < 0 then exit;
  SaveScan(st);
  d := 0; begun := false;
  repeat
    case tok of
      sIdent: for i := numDeferred - 1 downto 0 do
        if (deferred[i].m = curModule) and (deferred[i].o^.name = id) then MakeInstance(i, TokPos);
      sBegin: begin begun := begun or (d = 0); inc(d) end;
      sIf, sWhile, sFor, sMatch, sRepeat, sRecord, sVariant: inc(d);
      sEnd, sUntil: dec(d);
    end;
    if not wholeRest and (d = 0) and (begun or (tok in [sForward, sCode])) then break;
    Next;
  until tok = sEof;
  RestoreScan(st);
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
  nameMain := Name('main');
  nameBody := Name('body');
  nameStatic := Name('static');
  rtFail := NewChunk(secText, nameRt, nameFail);
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
