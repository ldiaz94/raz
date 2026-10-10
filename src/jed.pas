{ jed.pas: the command line.

    jed [-I dir]... [-o file] Main.jed

  Compiles the main module and every module it imports, writes the
  entry point, links what it reaches, and writes the executable: by
  default the main module's file without its .jed.

  The entry point saves argc and argv, runs every module's body (those
  of the modules the program imports, imported modules first), then
  the main module's main, and exits with its status.

  Depends on: everything else. }

program jed;

{$mode objfpc}{$H-}

uses math, scan, sym, x64, gen, parse, link, elf;

{ The modules the program uses: the main module, Rt, and every module
  they import. A module read only for the interface check is not. }
procedure Use(m: PModule);
var i: PImport;
begin
  if m^.used then exit;
  m^.used := true;
  i := m^.imports;
  while i <> nil do begin
    Use(i^.module);
    i := i^.next;
  end;
end;

var
  path, outPath, dir, s: shortstring;
  i, entry: longint;
  m, rt: PModule;
  main: PObj;
  hasResult: boolean;

begin
  { constants fold as the machine computes: NaN and infinities, no traps }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  path := '';
  outPath := '';
  numInc := 0;
  i := 1;
  while i <= ParamCount do begin
    s := ParamStr(i);
    if s = '-I' then begin
      inc(i);
      if numInc > High(incDirs) then Fatal('too many -I');
      incDirs[numInc] := ParamStr(i);
      inc(numInc);
    end else if s = '-o' then begin
      inc(i);
      outPath := ParamStr(i);
    end else if (s <> '') and (s[1] = '-') then
      Fatal('unknown option ' + s)
    else path := s;
    inc(i);
  end;
  if path = '' then Fatal('usage: jed [-I dir]... [-o file] Main.jed');
  dir := ParamStr(0);
  i := length(dir);
  while (i > 0) and (dir[i] <> '/') do dec(i);
  if i = 0 then libDir := 'lib' else libDir := copy(dir, 1, i) + 'lib';
  if outPath = '' then begin
    outPath := path;
    if copy(outPath, length(outPath) - 3, 4) = '.jed' then
      outPath := copy(outPath, 1, length(outPath) - 4)
    else outPath := outPath + '.out';
  end;

  m := CompileMain(path);

  Use(m);
  rt := firstModule;
  while (rt <> nil) and (NameOf(rt^.name) <> 'Rt') do rt := rt^.next;
  if rt <> nil then Use(rt);

  main := Find(m^.scope, Intern('main', 4));
  hasResult := false;
  if main <> nil then begin
    if (main^.cls <> oProc) or not main^.exported then Fatal('main must be an exported procedure');
    if (main^.typ^.len <> 0) or ((main^.typ^.base <> nil) and (main^.typ^.base <> tI64)) then
      Fatal('main must be proc main* or proc main*: I64');
    hasResult := main^.typ^.base <> nil;
  end;

  entry := NewChunk(secText, -1, Intern('_start', 6));
  BeginChunk(entry);
  Load(RAX, Mem(RSP, 0), 8, false);
  Store(MemRip(argcChunk, 0), RAX, 8);
  Lea(RAX, Mem(RSP, 8));
  Store(MemRip(argvChunk, 0), RAX, 8);
  m := firstModule;
  while m <> nil do begin
    if m^.used and (m^.body >= 0) then CallChunk(m^.body);
    m := m^.next;
  end;
  if main <> nil then CallChunk(main^.chunk);
  if hasResult then MovRR(RDI, RAX) else MovRI(RDI, 0);
  MovRI(RAX, 231);    { exit_group }
  Syscall;
  EndChunk(entry);

  LinkAll(entry, HeaderSize);
  WriteElf(outPath, entry);
end.
