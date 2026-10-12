{ chunk.pas: the compiled program, before it is linked.

  The code of a program is a set of chunks: one per procedure, module
  variable and string. A chunk's bytes go in one of three sections:
  text (code), rodata (strings and other constants), bss (variables,
  which are all zero). A reference from code to another chunk (a call,
  or an address) is a fixup, patched once the linker has placed every
  chunk. Line notes say which place in the source the code from each
  point on is for.

  Nothing here depends on the machine: text is bytes, written by the
  encoder for the target (x64.pas).

  Depends on: scan, for errors.
  Leaves out: the instructions; that is x64.pas. }

unit chunk;

{$mode objfpc}{$H-}

interface

uses scan, diag;

type
  TSection = (secText, secRodata, secBss);

  TChunk = record
    sec: TSection;
    start, size, align: longint;   { in its section's buffer }
    firstFix, numFix: longint;     { its fixups: text's in fixups, rodata's in dataFixups }
    module, name: longint;         { for the symbol table; -1 if none }
    adr: int64;                    { its address, set by the linker }
    live: boolean;                 { reached from the entry point }
    ext: boolean;                  { bss: the address of a C symbol, its name }
    reals: boolean;                { code: computes with reals, first at realsAt }
    realsAt: TPos;
    saveMask: longint;             { code: the registers of variables it saves, as bits of gen's VarRegs }
    saveAt: longint;               { ... at this offset from the frame, one quadword each }
  end;

  { A place in the source whose code starts at a place in text: for
    gdb, and for Rt to say where a failed check or a signal was }
  TLine = record
    at, chunk: longint;   { the place in text, and its chunk }
    path, line, col: longint;  { the file's path, interned, the line and column }
  end;

  { A variable of a procedure, for the trap report: Rt shows it, by
    kind, from its place in the frame }
  TVarNote = record
    chunk, name: longint;
    off: longint;      { from the frame pointer }
    kind: longint;     { how Rt shows it: see link.pas }
  end;

  TFixup = record
    at: longint;      { the 32-bit field, as an offset in text; in
                        dataFixups, the 64-bit one, from its chunk's start }
    chunk: longint;   { the chunk it refers to }
    addend: longint;  { added to the chunk's address }
  end;

  PChunks = ^TChunkArray;
  TChunkArray = array[0..MaxInt div SizeOf(TChunk) - 1] of TChunk;
  PLines = ^TLineArray;
  TLineArray = array[0..MaxInt div SizeOf(TLine) - 1] of TLine;
  PFixups = ^TFixupArray;
  TFixupArray = array[0..MaxInt div SizeOf(TFixup) - 1] of TFixup;

var
  code: PBytes;      { text }
  pc: longint;       { its length }
  rodata: PBytes;
  rolen: longint;
  chunks: PChunks;
  numChunks: longint;
  fixups: PFixups;
  numFixups: longint;
  { Addresses in read-only data, as in an array constant of strings:
    each 8 bytes, the chunk's absolute address, since the executable
    is loaded where the linker placed it }
  dataFixups: PFixups;
  numDataFixups: longint;
  lines: PLines;
  numLines: longint;
  curFile: longint;   { the file being compiled, for NoteLine }
  curChunk: longint;  { the chunk of code being written }
  varNotes: ^TVarNote;
  numVarNotes: longint;

function NewChunk(sec: TSection; module, name: longint): longint;
procedure BeginChunk(c: longint);
procedure EndChunk(c: longint);
procedure SetData(c: longint; p: PBytes; n, align: longint);
procedure SetBss(c: longint; size, align: longint);
function ExternChunk(name: longint): longint;
procedure NoteLine(line, col: longint);
procedure AddFixup(at, chunk, addend: longint);
procedure AddDataFixup(c, at, chunk, addend: longint);
procedure NoteVar(chunk, name, off, kind: longint);
function ChunkName(c: longint): shortstring;

procedure Put1(b: longint);
procedure Put4(v: longint);
procedure Put8(v: int64);
procedure Put4At(at, v: longint);
function Get4At(at: longint): longint;

implementation

var
  codeCap, roCap, chunkCap, fixCap, lineCap: longint;

procedure Room(n: longint);
begin
  if pc + n > codeCap then begin
    codeCap := codeCap * 2 + n;
    code := ReAllocMem(code, codeCap);
  end;
end;

procedure Put1(b: longint);
begin
  if pc + 16 > codeCap then Room(16);
  code^[pc] := byte(b);
  inc(pc);
end;

procedure Put4(v: longint);
begin
  if pc + 16 > codeCap then Room(16);
  PLongint(@code^[pc])^ := v;
  inc(pc, 4);
end;

procedure Put4At(at, v: longint);
begin
  PLongint(@code^[at])^ := v;
end;

function Get4At(at: longint): longint;
begin
  Get4At := PLongint(@code^[at])^;
end;

procedure Put8(v: int64);
begin
  Put4(longint(v and $FFFFFFFF));
  Put4(longint(v shr 32));
end;

function NewChunk(sec: TSection; module, name: longint): longint;
begin
  if numChunks = chunkCap then begin
    chunkCap := chunkCap * 2;
    chunks := ReAllocMem(chunks, chunkCap * SizeOf(TChunk));
  end;
  FillChar(chunks^[numChunks], SizeOf(TChunk), 0);
  chunks^[numChunks].sec := sec;
  chunks^[numChunks].module := module;
  chunks^[numChunks].name := name;
  chunks^[numChunks].align := 1;
  chunks^[numChunks].size := -1;   { not yet defined }
  NewChunk := numChunks;
  inc(numChunks);
end;

procedure BeginChunk(c: longint);
begin
  { code is aligned to 16 bytes, padded with CC, x86's int3: a trap if
    it were ever run }
  while pc and 15 <> 0 do Put1($CC);
  curChunk := c;
  chunks^[c].start := pc;
  chunks^[c].align := 16;
  chunks^[c].firstFix := numFixups;
end;

procedure EndChunk(c: longint);
begin
  chunks^[c].size := pc - chunks^[c].start;
  chunks^[c].numFix := numFixups - chunks^[c].firstFix;
end;

procedure SetData(c: longint; p: PBytes; n, align: longint);
begin
  if rolen + n > roCap then begin
    roCap := roCap * 2 + n;
    rodata := ReAllocMem(rodata, roCap);
  end;
  Move(p^, rodata^[rolen], n);
  chunks^[c].firstFix := numDataFixups;
  chunks^[c].numFix := 0;
  chunks^[c].start := rolen;
  chunks^[c].size := n;
  chunks^[c].align := align;
  inc(rolen, n);
end;

procedure SetBss(c: longint; size, align: longint);
begin
  chunks^[c].size := size;
  chunks^[c].align := align;
end;

{ The code from here on is for line and column of the current file. A
  place with no code of its own gives way to the next. }
procedure NoteLine(line, col: longint);
begin
  if (numLines > 0) and (lines^[numLines - 1].at = pc) then dec(numLines);
  if (numLines > 0) and (lines^[numLines - 1].chunk = curChunk) and (lines^[numLines - 1].line = line)
    and (lines^[numLines - 1].col = col) and (lines^[numLines - 1].path = curFile) then exit;
  if numLines = lineCap then begin
    lineCap := lineCap * 2;
    lines := ReAllocMem(lines, lineCap * SizeOf(TLine));
  end;
  lines^[numLines].at := pc;
  lines^[numLines].chunk := curChunk;
  lines^[numLines].path := curFile;
  lines^[numLines].line := line;
  lines^[numLines].col := col;
  inc(numLines);
end;

{ The quadword that holds the address of C's symbol name, filled in
  when the program starts; one for each name. }
function ExternChunk(name: longint): longint;
var c: longint;
begin
  for c := 0 to numChunks - 1 do
    if chunks^[c].ext and (chunks^[c].name = name) then exit(c);
  c := NewChunk(secBss, -1, name);
  SetBss(c, 8, 8);
  chunks^[c].ext := true;
  ExternChunk := c;
end;

procedure AddFixup(at, chunk, addend: longint);
begin
  if numFixups = fixCap then begin
    fixCap := fixCap * 2;
    fixups := ReAllocMem(fixups, fixCap * SizeOf(TFixup));
  end;
  fixups^[numFixups].at := at;
  fixups^[numFixups].chunk := chunk;
  fixups^[numFixups].addend := addend;
  inc(numFixups);
end;

{ The address of chunk, plus addend, at offset at of rodata chunk c,
  whose data is set: its fixups follow one another. }
procedure AddDataFixup(c, at, chunk, addend: longint);
begin
  if numDataFixups and 255 = 0 then
    dataFixups := ReAllocMem(dataFixups, (numDataFixups + 256) * SizeOf(TFixup));
  dataFixups^[numDataFixups].at := at;
  dataFixups^[numDataFixups].chunk := chunk;
  dataFixups^[numDataFixups].addend := addend;
  inc(numDataFixups);
  inc(chunks^[c].numFix);
end;

procedure NoteVar(chunk, name, off, kind: longint);
begin
  if numVarNotes and 255 = 0 then varNotes := ReAllocMem(varNotes, (numVarNotes + 256) * SizeOf(TVarNote));
  varNotes[numVarNotes].chunk := chunk;
  varNotes[numVarNotes].name := name;
  varNotes[numVarNotes].off := off;
  varNotes[numVarNotes].kind := kind;
  inc(numVarNotes);
end;

{ The name of chunk c: its module's and its own, or literal and its
  number for a literal }
function ChunkName(c: longint): shortstring;
begin
  with chunks^[c] do
    if name < 0 then ChunkName := 'literal' + IntStr(c)
    else if module < 0 then ChunkName := NameOf(name)
    else ChunkName := NameOf(module) + '.' + NameOf(name);
end;

initialization
  codeCap := 1 shl 20;
  code := GetMem(codeCap);
  pc := 0;
  roCap := 1 shl 16;
  rodata := GetMem(roCap);
  rolen := 0;
  chunkCap := 1 shl 10;
  chunks := GetMem(chunkCap * SizeOf(TChunk));
  numChunks := 0;
  fixCap := 1 shl 12;
  fixups := GetMem(fixCap * SizeOf(TFixup));
  numFixups := 0;
  lineCap := 1 shl 12;
  lines := GetMem(lineCap * SizeOf(TLine));
  numLines := 0;
end.
