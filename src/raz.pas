{ raz.pas: the command line.

    raz [-I dir]... [-o file] Main.raz
    raz run [-I dir]... Main.raz [arg]...
    raz --version

  Compiles the main module and every module it imports, writes the
  entry point, links what it reaches, and writes the executable: by
  default the main module's file without its .raz. raz run writes it
  to a memfd instead, a file that lives only in memory, and executes
  it in raz's place with the arguments after Main.raz, so its status
  is the program's; its argv[0] is Main.raz.

  The program starts by saving argc and argv, runs every module's body
  (those of the modules the program imports, imported modules first),
  then the main module's main, and ends with Rt.exit and main's
  status. A static program does this from its entry point. One that
  uses C starts through the C library, __libc_start_main, which sets
  C up and calls this as C's main; first it gives Rt C's exit, which
  Rt.exit then ends the program with.

  Depends on: everything else. }

program raz;

{$mode objfpc}{$H-}

uses math, BaseUnix, syscall, scan, diag, sym, x64, gen, parse, link, elf;

const
  { what git describe says, made by make: 0.3.0 at the tag v0.3.0,
    0.3.0-5-g38d29a8 five commits past it }
  Version = {$I version.inc};
  Report = '2026-10.10';    { the version of doc/raz.md it follows }
  MemfdCreate = 319;       { the system call; FPC 3.2.2 has no name for it }
  MfdCloexec = 1;          { an ELF still executes: the kernel opens it first }

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

{ Whether the program uses C: if so, the libraries it needs go to
  elf.pas, the C library first. }
function UsesC: boolean;
var m, st, c: PModule; l: PLib; i: longint; seen: boolean;
begin
  st := nil; c := nil;
  numNeeded := 1;
  needed[0] := Intern(PChar('libc.so.6'), 9);
  m := firstModule;
  while m <> nil do begin
    if m^.used and m^.linkStatic then st := m;
    if m^.used and m^.usesC then c := m;
    l := m^.libs;
    while m^.used and (l <> nil) do begin
      seen := false;
      for i := 0 to numNeeded - 1 do seen := seen or (needed[i] = l^.name);
      if not seen then begin
        if numNeeded > High(needed) then Fatal('more than ' + IntStr(High(needed) + 1) + ' libraries');
        needed[numNeeded] := l^.name;
        inc(numNeeded);
      end;
      l := l^.next;
    end;
    m := m^.next;
  end;
  if (st <> nil) and (c <> nil) then
    Fatal(NameOf(st^.name) + ' says link static, but ' + NameOf(c^.name) + ' uses C');
  if c = nil then numNeeded := 0;
  UsesC := c <> nil;
end;

function RtObj(rt: PModule; const n: shortstring): PObj;
var o: PObj;
begin
  o := Find(rt^.scope, Intern(@n[1], length(n)));
  if o = nil then Fatal('Rt has no ' + n);
  RtObj := o;
end;

var
  path, outPath, dir, s: shortstring;
  i, first, entry, start, fd: longint;
  m, rt: PModule;
  main: PObj;
  hasResult, dynamic, run: boolean;

begin
  { constants fold as the machine computes: NaN and infinities, no traps }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  path := '';
  outPath := '';
  numInc := 0;
  run := (ParamCount >= 1) and (ParamStr(1) = 'run');
  i := 1 + ord(run);
  while i <= ParamCount do begin
    s := ParamStr(i);
    if s = '-I' then begin
      inc(i);
      if numInc > High(incDirs) then Fatal('more than ' + IntStr(High(incDirs) + 1) + ' -I directories');
      incDirs[numInc] := ParamStr(i);
      inc(numInc);
    end else if s = '-o' then begin
      inc(i);
      outPath := ParamStr(i);
    end else if s = '-Werror' then
      werror := true
    else if s = '--version' then begin
      writeln('raz ', Version, ', report ', Report);
      Halt(0);
    end else if (s <> '') and (s[1] = '-') then
      Fatal('unknown option ' + s)
    else begin
      path := s;
      first := i;
      if run then break;   { the rest are the program's }
    end;
    inc(i);
  end;
  if path = '' then
    Fatal('usage: raz [-I dir]... [-o file] [-Werror] Main.raz, or raz run [options] Main.raz [arg]...');
  if run and (outPath <> '') then Fatal('raz run takes no -o');
  dir := ParamStr(0);
  i := length(dir);
  while (i > 0) and (dir[i] <> '/') do dec(i);
  if i = 0 then libDir := 'lib' else libDir := copy(dir, 1, i) + 'lib';
  if outPath = '' then begin
    outPath := path;
    if copy(outPath, length(outPath) - 3, 4) = '.raz' then
      outPath := copy(outPath, 1, length(outPath) - 4)
    else outPath := outPath + '.out';
  end;

  m := CompileMain(path);
  if errors > 0 then Finish;

  Use(m);
  rt := firstModule;
  while (rt <> nil) and (NameOf(rt^.name) <> 'Rt') do rt := rt^.next;
  if rt <> nil then Use(rt);

  main := Find(m^.scope, Intern('main', 4));
  hasResult := false;
  if main <> nil then begin
    if (main^.cls <> oProc) or not main^.exported then Error(main^.pos, 'main must be an exported procedure')
    else if (main^.typ^.len <> 0) or ((main^.typ^.base <> nil) and (main^.typ^.base <> tInt)) then
      Error(main^.pos, 'main must be proc main* or proc main*: INT');
    if errors > 0 then Finish;
    hasResult := main^.typ^.base <> nil;
  end;
  Finish;

  if rt = nil then Fatal('can''t find module Rt');
  dynamic := UsesC;
  entry := NewChunk(secText, -1, Intern('_start', 6));
  if dynamic then begin
    { _start as C's crt1 does it: __libc_start_main(main, argc, argv,
      nil, nil, rtld_fini, stack_end), with rsp aligned }
    start := NewChunk(secText, -1, Intern('main', 4));
    BeginChunk(entry);
    MovRI(RBP, 0);
    MovRR(R9, RDX);
    Pop(RSI);
    MovRR(RDX, RSP);
    AluI(aluAnd, RSP, -16);
    Push(RAX);
    Push(RSP);
    MovRI(R8, 0);
    MovRI(RCX, 0);
    Lea(RDI, MemRip(start, 0));
    CallM(MemRip(ExternChunk(Intern('__libc_start_main', 17)), 0));
    Ud2;
    EndChunk(entry);
    BeginChunk(start);
    Push(RBP);   { aligns the stack again }
    Store(MemRip(argcChunk, 0), RDI, 8);
    Store(MemRip(argvChunk, 0), RSI, 8);
    Load(RAX, MemRip(ExternChunk(Intern('exit', 4)), 0), 8, false);
    Store(MemRip(RtObj(rt, 'cExit')^.chunk, 0), RAX, 8);
  end else begin
    start := entry;
    BeginChunk(entry);
    Load(RAX, Mem(RSP, 0), 8, false);
    Store(MemRip(argcChunk, 0), RAX, 8);
    Lea(RAX, Mem(RSP, 8));
    Store(MemRip(argvChunk, 0), RAX, 8);
  end;
  { the places, which the linker makes, for Rt to say where a failed
    check or a signal was }
  placesChunk := NewChunk(secRodata, -1, -1);
  SetData(placesChunk, nil, 0, 8);
  Lea(RAX, MemRip(placesChunk, 0));
  Store(MemRip(RtObj(rt, 'places')^.chunk, 0), RAX, 8);
  m := firstModule;
  while m <> nil do begin
    if m^.used and (m^.body >= 0) then CallChunk(m^.body);
    m := m^.next;
  end;
  if main <> nil then CallChunk(main^.chunk);
  if hasResult then MovRR(RDI, RAX) else MovRI(RDI, 0);
  CallChunk(RtObj(rt, 'exit')^.chunk);
  Ud2;
  EndChunk(start);

  MarkLive(entry);
  if not HasReals then
    for i := 0 to numChunks - 1 do
      if chunks^[i].live and chunks^[i].reals then
        Error(chunks^[i].realsAt, 'this target has no reals');
  if errors > 0 then Finish;

  mainPath := path;
  if run then begin
    { argv from Main.raz on is the program's, ending in nil as it must }
    fd := Do_SysCall(MemfdCreate, TSysParam(PChar('raz')), MfdCloexec);
    if fd < 0 then Fatal('can''t create a memfd');
    Str(fd, s);
    outPath := '/proc/self/fd/' + s + #0;
    WriteElf(outPath, entry);
    FpExecve(@outPath[1], @argv[first], envp);
    Fatal('can''t run ' + path);
  end;
  WriteElf(outPath, entry);
end.
