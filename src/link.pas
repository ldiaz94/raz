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

implementation

{ Marks live each chunk reached from entry through the fixups. }
procedure MarkLive(entry: longint);
var stack: PLongs; sp, c, f, t: longint; fx: PFixups;
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
    { code and constants have fixups; variables start at zero, holding
      no addresses }
    case chunks^[c].sec of
      secText: fx := fixups;
      secRodata: fx := dataFixups;
    else continue;
    end;
    for f := chunks^[c].firstFix to chunks^[c].firstFix + chunks^[c].numFix - 1 do begin
      t := fx^[f].chunk;
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
  was, and what calls were under way: their numbers, the places', where
  text starts and stops, the procedures' and their variables' (I64s);
  for each place in live code its address, line, column and the offset
  of its file's path (U32s); for each live procedure where it starts and
  stops, the offset of its name, its first variable and how many it
  has, and the registers of variables it saves, as bits of gen's
  VarRegs, and the frame offset they are saved at (U32s); for each
  variable the offset of its name, its place in the frame and its
  kind, as parse.pas's VarKind (U32s); then the paths and names, each
  ending in a zero byte. They are in no order, since Rt
  looks at them only as the program stops. }
procedure MakePlaces(start, stop: int64);
var
  files, offs, first, count: PLongs; buf: PBytes;
  i, f, n, nfiles, k, np, nv, c, v, at, names: longint;

  procedure Name(const s: shortstring);
  begin
    PLongint(@buf^[at])^ := names - k;
    Move(s[1], buf^[names], length(s));
    buf^[names + length(s)] := 0;
    names := names + length(s) + 1;
    at := at + 4;
  end;

begin
  files := GetMem(numLines * 4 + 4);
  offs := GetMem(numLines * 4 + 4);
  first := GetMem(numChunks * 4);
  count := GetMem(numChunks * 4);
  FillChar(count^, numChunks * 4, 0);
  for v := numVarNotes - 1 downto 0 do begin
    first^[varNotes[v].chunk] := v;
    inc(count^[varNotes[v].chunk]);
  end;
  n := 0; nfiles := 0; k := 0; np := 0; nv := 0;
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
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and (chunks^[c].sec = secText) and (chunks^[c].module >= 0) then begin
      inc(np);
      k := k + length(ChunkName(c)) + 1;
      for v := first^[c] to first^[c] + count^[c] - 1 do k := k + length(NameOf(varNotes[v].name)) + 1;
      nv := nv + count^[c];
    end;
  buf := GetMem(40 + 16 * n + 28 * np + 12 * nv + k);
  PInt64(@buf^[0])^ := n;
  PInt64(@buf^[8])^ := start;
  PInt64(@buf^[16])^ := stop;
  PInt64(@buf^[24])^ := np;
  PInt64(@buf^[32])^ := nv;
  at := 40;
  for i := 0 to numLines - 1 do
    if chunks^[lines^[i].chunk].live then begin
      f := 0;
      while files^[f] <> lines^[i].path do inc(f);
      PLongint(@buf^[at])^ := chunks^[lines^[i].chunk].adr + lines^[i].at - chunks^[lines^[i].chunk].start;
      PLongint(@buf^[at + 4])^ := lines^[i].line;
      PLongint(@buf^[at + 8])^ := lines^[i].col;
      PLongint(@buf^[at + 12])^ := offs^[f];
      at := at + 16;
    end;
  { the pool of paths and names starts at k }
  k := 40 + 16 * n + 28 * np + 12 * nv;
  names := k;
  { the paths first, at the offsets offs gave the places: Name puts
    each in the pool, and also writes its offset at at, which a path
    doesn't want, so at is put back for the procedures to overwrite }
  for f := 0 to nfiles - 1 do begin
    i := at;
    Name(ShownPath(NameOf(files^[f])));
    at := i;
  end;
  v := 0;
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and (chunks^[c].sec = secText) and (chunks^[c].module >= 0) then begin
      PLongint(@buf^[at])^ := chunks^[c].adr;
      PLongint(@buf^[at + 4])^ := chunks^[c].adr + chunks^[c].size;
      at := at + 8;
      Name(ChunkName(c));
      PLongint(@buf^[at])^ := v;
      PLongint(@buf^[at + 4])^ := count^[c];
      PLongint(@buf^[at + 8])^ := chunks^[c].saveMask;
      PLongint(@buf^[at + 12])^ := chunks^[c].saveAt;
      at := at + 16;
      v := v + count^[c];
    end;
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and (chunks^[c].sec = secText) and (chunks^[c].module >= 0) then
      for v := first^[c] to first^[c] + count^[c] - 1 do begin
        Name(NameOf(varNotes[v].name));
        PLongint(@buf^[at])^ := varNotes[v].off;
        PLongint(@buf^[at + 4])^ := varNotes[v].kind;
        at := at + 8;
      end;
  SetData(placesChunk, buf, names, 8);
  FreeMem(buf); FreeMem(files); FreeMem(offs); FreeMem(first); FreeMem(count);
end;

{ Places the live chunks, leaving roExtra bytes at the end of rodata
  and dynSize at the start of the writable segment. }
procedure LinkAll(headerSize, roExtra, dynSize: int64);
var c, f, at: longint; e, p, v: int64;
begin
  textOff := (headerSize + 15) div 16 * 16;   { as each code chunk is }
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
  { the gaps between code chunks are int3, a trap if ever run }
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
        secRodata: begin
          p := chunks^[c].adr - (Base + roOff);
          Move(rodata^[chunks^[c].start], roImg^[p], chunks^[c].size);
          for f := chunks^[c].firstFix to chunks^[c].firstFix + chunks^[c].numFix - 1 do
            PInt64(@roImg^[p + dataFixups^[f].at])^ :=
              chunks^[dataFixups^[f].chunk].adr + dataFixups^[f].addend;
        end;
      end;
end;

end.
