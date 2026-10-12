{ link.pas: tree shaking, layout and patching.

  Starting from the entry chunk, marks every chunk the program can
  reach through fixups; the rest is left out. Then gives each live
  chunk its address and builds the images of text and rodata, with
  every fixup patched.

  The file is laid out so that each section can be mapped as it lies:
  text right after the headers, rodata on the next page, then a
  writable page that starts with the table the dynamic loader reads
  (none in a static program) and goes on as bss, in memory only. The
  loader's other tables come at the end of rodata; elf.pas writes them
  in the room left there.

  Depends on: chunk for chunks and fixups, scan for names and errors.
  Leaves out: the file format; that is elf.pas. }

unit link;

{$mode objfpc}{$H-}

interface

uses scan, diag, chunk;

const
  Base = $400000;
  Page = 4096;

var
  textOff, textSize: int64;    { file offset and size of text }
  roOff, roSize: int64;        { rodata, the room for the loader's tables included }
  extraAdr: int64;             { that room }
  bssAdr, bssSize: int64;      { the writable segment, the loader's table first }
  textImg, roImg: PBytes;
  placesChunk: longint = -1;   { the rodata chunk of the places, made here }

procedure MarkLive(entry: longint);
procedure LinkAll(headerSize, roExtra, dynSize: int64);
function ChunkName(c: longint): shortstring;

implementation

function ChunkName(c: longint): shortstring;
begin
  if chunks^[c].name < 0 then exit('a literal');
  if chunks^[c].module < 0 then exit(NameOf(chunks^[c].name));
  ChunkName := NameOf(chunks^[c].module) + '.' + NameOf(chunks^[c].name);
end;

procedure MarkLive(entry: longint);
var stack: PLongs; sp, c, f, t: longint;
begin
  stack := GetMem(numChunks * 4);
  sp := 0;
  chunks^[entry].live := true;
  stack^[0] := entry;
  sp := 1;
  while sp > 0 do begin
    dec(sp);
    c := stack^[sp];
    if chunks^[c].size < 0 then Fatal(ChunkName(c) + ' is declared but never defined');
    if chunks^[c].sec <> secText then continue;
    for f := chunks^[c].firstFix to chunks^[c].firstFix + chunks^[c].numFix - 1 do begin
      t := fixups^[f].chunk;
      if not chunks^[t].live then begin
        chunks^[t].live := true;
        stack^[sp] := t;
        inc(sp);
      end;
    end;
  end;
  FreeMem(stack);
end;

{ Gives the live chunks of one section their places, from start;
  returns the end. }
function Place(sec: TSection; start: int64): int64;
var c: longint; a: int64;
begin
  a := start;
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and (chunks^[c].sec = sec) then begin
      a := (a + chunks^[c].align - 1) div chunks^[c].align * chunks^[c].align;
      chunks^[c].adr := a;
      a := a + chunks^[c].size;
    end;
  Place := a;
end;

{ The places that Rt reads to say where a failed check or a signal
  was: their number and where text starts and stops (I64s); for each
  place in live code its address, line, column and the offset of its
  file's path (U32s); then the paths, each ending in a zero byte. They
  are in no order, since Rt looks at them only as the program stops. }
procedure MakePlaces(start, stop: int64);
var files, offs: PLongs; buf: PBytes; i, f, n, nfiles, k: longint; s: shortstring;
begin
  files := GetMem(numLines * 4 + 4);
  offs := GetMem(numLines * 4 + 4);
  n := 0; nfiles := 0; k := 0;
  for i := 0 to numLines - 1 do
    if chunks^[lines^[i].chunk].live then begin
      inc(n);
      f := 0;
      while (f < nfiles) and (files^[f] <> lines^[i].path) do inc(f);
      if f = nfiles then begin
        files^[f] := lines^[i].path;
        offs^[f] := k;
        k := k + length(ShownPath(NameOf(files^[f]))) + 1;
        inc(nfiles);
      end;
    end;
  buf := GetMem(24 + 16 * n + k);
  PInt64(@buf^[0])^ := n;
  PInt64(@buf^[8])^ := start;
  PInt64(@buf^[16])^ := stop;
  k := 24;
  for i := 0 to numLines - 1 do
    if chunks^[lines^[i].chunk].live then begin
      f := 0;
      while files^[f] <> lines^[i].path do inc(f);
      PLongint(@buf^[k])^ := chunks^[lines^[i].chunk].adr + lines^[i].at - chunks^[lines^[i].chunk].start;
      PLongint(@buf^[k + 4])^ := lines^[i].line;
      PLongint(@buf^[k + 8])^ := lines^[i].col;
      PLongint(@buf^[k + 12])^ := offs^[f];
      k := k + 16;
    end;
  for f := 0 to nfiles - 1 do begin
    s := ShownPath(NameOf(files^[f])) + #0;
    Move(s[1], buf^[k], length(s));
    k := k + length(s);
  end;
  SetData(placesChunk, buf, k, 8);
  FreeMem(buf); FreeMem(files); FreeMem(offs);
end;

{ Places the live chunks, leaving roExtra bytes at the end of rodata
  and dynSize at the start of the writable segment. }
procedure LinkAll(headerSize, roExtra, dynSize: int64);
var c, f, at: longint; e, p, v: int64;
begin
  textOff := (headerSize + 15) div 16 * 16;
  e := Place(secText, Base + textOff);
  textSize := e - (Base + textOff);
  if placesChunk >= 0 then MakePlaces(Base + textOff, e);
  roOff := (textOff + textSize + Page - 1) div Page * Page;
  e := Place(secRodata, Base + roOff);
  extraAdr := (e + 7) div 8 * 8;
  if roExtra > 0 then e := extraAdr + roExtra;
  roSize := e - (Base + roOff);
  bssAdr := (Base + roOff + roSize + Page - 1) div Page * Page;
  e := Place(secBss, bssAdr + dynSize);
  bssSize := e - bssAdr;

  textImg := GetMem(textSize + 1);
  FillChar(textImg^, textSize + 1, $CC);
  roImg := GetMem(roSize + 1);
  FillChar(roImg^, roSize + 1, 0);
  for c := 0 to numChunks - 1 do
    if chunks^[c].live then
      case chunks^[c].sec of
        secText: begin
          p := chunks^[c].adr - (Base + textOff);
          Move(code^[chunks^[c].start], textImg^[p], chunks^[c].size);
          for f := chunks^[c].firstFix to chunks^[c].firstFix + chunks^[c].numFix - 1 do begin
            at := fixups^[f].at - chunks^[c].start;
            { rel32: from the end of the field to the target }
            v := chunks^[fixups^[f].chunk].adr + fixups^[f].addend
              - (chunks^[c].adr + at + 4);
            PLongint(@textImg^[p + at])^ := longint(v);
          end;
        end;
        secRodata:
          Move(rodata^[chunks^[c].start], roImg^[chunks^[c].adr - (Base + roOff)],
            chunks^[c].size);
      end;
end;

end.
