{ Builds types and objects by a fixed pseudo-random script, asks of them
  what the parser asks of sym, and prints the answers: the seed's side
  of a test of src/Sym.raz, whose SymDump.raz does the same and prints
  the same. With the argument dup or deep it ends in the error of a name
  declared twice, or of too many scopes. }
program symdump;
{$mode objfpc}{$H-}
uses diag, scan, seedcontinue, sym;
const
  Words: array[0..19] of string = ('alpha', 'alpho', 'beta', 'bet', 'gamma', 'gama', 'delta', 'Delta',
    'eps', 'zeta', 'eta', 'theta', 'iota', 'kappa', 'lambda', 'mu', 'nu', 'xi', 'omicron', 'pi');
var
  seed: int64;
  names: array[0..19] of longint;
  mods: array[0..2] of PModule;
  base: array[0..11] of PType;
  pool: array[0..299] of PType;
  objs: array[0..299] of PObj;
  numPool, numObjs, i, k, n, op, x, y, z: longint;
  t, o2: PType;
  o: PObj;
  saved: array[0..MaxDepth - 1] of longint;
  d: longint;
  v: int64;

function Rnd(n: longint): longint;
begin
  seed := (seed * 1103515245 + 12345) and $7FFFFFFF;
  Rnd := (seed shr 8) mod n;
end;

function Fields(m: longint; allowVar: boolean): PObj;
var f, first, last: PObj; j, x, y, z: longint;
begin
  first := nil; last := nil;
  for j := 1 to m do begin
    x := Rnd(20); y := Rnd(numPool);
    f := NewObj(oField, names[x], pool[y]);
    z := Rnd(2); f^.exported := z = 0;
    z := Rnd(3); f^.isVar := allowVar and (z = 0);
    f^.val := j * 8;
    if first = nil then first := f else last^.next := f;
    last := f;
  end;
  Fields := first;
end;

procedure Add(t: PType);
begin
  if numPool <= High(pool) then begin pool[numPool] := t; inc(numPool) end;
end;

procedure MakeType;
var t: PType; r, m, x: longint; f: PObj;
begin
  r := Rnd(11);
  case r of
    0: t := NewType(fPtr, 8, 8);
    1: t := NewType(fArray, 0, 1);
    2: t := NewType(fSlice, 16, 8);
    3: t := NewType(fRecord, 0, 8);
    4: t := NewType(fProc, 8, 8);
    5: t := NewType(fSet, 8, 8);
    6: t := NewType(fVariant, 16, 8);
    7: t := NewType(fEnum, 1, 1);
    8: t := NewType(fRecord, 16, 8);
    9: t := NewType(fProc, 8, 8);
  else t := NewType(fPtr, 8, 8);
  end;
  x := Rnd(numPool); t^.base := pool[x];
  t^.len := Rnd(5);
  x := Rnd(4); t^.vol := x = 0;
  x := Rnd(4); t^.variadic := (t^.form = fProc) and (x = 0);
  x := Rnd(2); t^.tuple := (t^.form = fRecord) and (x = 0);
  if t^.form in [fRecord, fProc, fVariant] then begin
    m := Rnd(4);
    t^.fields := Fields(m, t^.form = fProc);
    t^.len := m;
    if t^.form = fRecord then t^.base := nil;
    x := Rnd(2);
    if (t^.form = fProc) and (x = 0) then t^.base := nil;
    if t^.form = fVariant then begin
      f := t^.fields;
      while f <> nil do begin f^.cls := oCase; x := Rnd(3); f^.fields := Fields(x, false); f := f^.next end;
    end;
  end;
  x := Rnd(3);
  if x = 0 then begin
    x := Rnd(20); t^.obj := NewObj(oType, names[x], t);
    x := Rnd(3); t^.obj^.module := mods[x];
  end;
  Add(t);
end;

begin
  seed := 11;
  for i := 0 to 19 do names[i] := Intern(@Words[i][1], length(Words[i]));
  for i := 0 to 2 do begin
    New(mods[i]); FillChar(mods[i]^, SizeOf(TModule), 0);
    mods[i]^.sname := names[i * 5];
  end;
  curModule := mods[0];
  base[0] := tI8; base[1] := tI16; base[2] := tI32; base[3] := tI64; base[4] := tU8;
  base[5] := tU16; base[6] := tU32; base[7] := tU64; base[8] := tBool; base[9] := tF32;
  base[10] := tReal; base[11] := tInt;
  for i := 0 to 11 do Add(base[i]);
  if ParamCount >= 1 then begin if Open('lib/Rt.raz') <> '' then Fatal('no file'); Next; Next end;
  numObjs := 0;
  for k := 1 to 4000 do begin
    op := Rnd(14);
    case op of
      0, 1, 2: MakeType;
      3, 4: if numObjs <= High(objs) then begin
        x := Rnd(8); y := Rnd(20);
        if Find(x, names[y]) = nil then begin
          z := Rnd(8); n := Rnd(numPool);
          o := NewObj(TClass(z), names[y], pool[n]);
          z := Rnd(2); o^.exported := z = 0;
          z := Rnd(3); o^.module := mods[z];
          Insert(o, x);
          objs[numObjs] := o; inc(numObjs);
          writeln('I ', x, ' ', NameOf(names[y]), ' ', o^.scope);
        end;
      end;
      5: begin x := Rnd(8); y := Rnd(20); o := Find(x, names[y]);
        write('F ', x, ' ', NameOf(names[y]), ' ');
        if o = nil then writeln('-') else writeln(ord(o^.cls), ' ', o^.scope);
      end;
      6: begin
        x := Rnd(8); y := Rnd(20);
        if ScopeDepth < 6 then OpenScope(x);
        o := Lookup(names[y]);
        write('L ', ScopeDepth, ' ', NameOf(names[y]), ' ');
        if o = nil then writeln('-') else writeln(ord(o^.cls), ' ', o^.scope);
        z := Rnd(2);
        if (ScopeDepth > 1) and (z = 0) then CloseScope;
      end;
      7: begin
        y := Rnd(20); x := Rnd(9) - 1; z := Rnd(3); curModule := mods[z];
        o := Closest(names[y], x);
        write('C ', NameOf(names[y]), ' ', x, ' ');
        if o = nil then writeln('-') else writeln(NameOf(o^.name), ' ', o^.scope);
      end;
      8: begin
        x := Rnd(numPool); z := Rnd(3); curModule := mods[z];
        writeln('T ', TypeName(pool[x]));
      end;
      9: begin
        x := Rnd(numPool); y := Rnd(numPool);
        writeln('S ', ord(Same(pool[x], pool[y])), ' ', ord(Same(pool[x], pool[x])));
        t := NewType(fPtr, 8, 8); t^.base := pool[x];
        o2 := t; t := NewType(fPtr, 8, 8); t^.base := pool[x];
        writeln('S ', ord(Same(o2, t)));
      end;
      10: if numObjs > 0 then begin x := Rnd(numObjs); writeln('P ', HexStr(Fingerprint(objs[x]), 16)) end;
      11: begin
        x := Rnd(numPool); y := Rnd(1 shl 20); z := Rnd(2); n := Rnd(2);
        v := int64(y) * 4096 * z - y * n;
        t := pool[x];
        writeln('B ', ord(Fits(v, t)), ' ', ord(IsInt(t)), ' ', ord(IsScalar(t)), ' ', ord(IsAggregate(t)), ' ',
          ord(InTwoRegs(t)), ' ', ord(BehindPointer(t)), ' ', AlignUp(y, 1 shl z));
      end;
      12: if (ScopeDepth > 1) and (ScopeDepth < 6) then begin
        d := ScopeDepth; SaveScopes(d, saved);
        writeln('V ', ScopeDepth, ' ', TopScope);
        RestoreScopes(d, saved);
        writeln('V ', ScopeDepth, ' ', TopScope);
        x := NewScope; writeln('N ', x);
      end;
      13: begin x := ScopeDepth; if x > 3 then CutScopes(2); writeln('X ', x, ' ', ScopeDepth) end;
    end;
  end;
  { the universe, and the sizes it made }
  for i := 0 to 11 do writeln('U ', ord(base[i]^.form), ' ', base[i]^.size, ' ', ord(base[i]^.signed), ' ', NameOf(base[i]^.obj^.name));
  if ParamCount >= 1 then begin
    if ParamStr(1) = 'dup' then begin
      o := NewObj(oVar, names[3], tI8);
      Insert(o, 100); Insert(o, 100);
    end;
    if ParamStr(1) = 'deep' then begin
      CutScopes(1);
      for i := 1 to MaxDepth + 1 do OpenScope(i);
    end;
  end;
end.
