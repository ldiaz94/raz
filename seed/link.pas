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
  textOff, textSize: int64;    { file offset and size of text, at Base + textOff }
  roOff, roSize: int64;        { rodata, the room for the loader's tables included }
  roAdr: int64;                { where rodata is loaded }
  extraAdr: int64;             { that room }
  bssAdr, bssSize: int64;      { the writable segment, the loader's table first }
  bssOff: int64;               { the file offset of that table }
  textImg, roImg: PBytes;
  placesChunk: longint = -1;   { the rodata chunk of the places, made here }
  linesOff, linesSize: int64;  { the line table, in the places: .debug_line }

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

{ The line table, DWARF 4's line program, which gdb reads as
  .debug_line and Rt to say where code comes from: one sequence for
  each live procedure with lines, a row for each place noted, its
  address, file, line and column. A row whose address and line move a
  little is one byte, a special opcode; the others are made of the
  standard ones. Made in lp, lpLen bytes long. }
const
  LineBase = -5; LineRange = 14; OpcodeBase = 13;   { the special opcodes' }

var
  lp: PBytes;
  lpLen, lpCap: longint;

procedure PutB(v: int64);
begin
  if lpLen = lpCap then begin
    lpCap := lpCap * 2 + 256;
    lp := ReAllocMem(lp, lpCap);
  end;
  lp^[lpLen] := byte(v);
  inc(lpLen);
end;

procedure PutN(v: int64; n: longint);
var i: longint;
begin
  for i := 1 to n do begin PutB(v); v := v shr 8 end;
end;

{ LEB128, unsigned and signed }
procedure PutU(v: int64);
begin
  while v >= $80 do begin PutB(v and $7F or $80); v := v shr 7 end;
  PutB(v);
end;

procedure PutS(v: int64);
begin
  while (v < -64) or (v >= 64) do begin PutB(v and $7F or $80); v := SarInt64(v, 7) end;
  PutB(v and $7F);
end;

{ The line program of the files paths, nfiles of them, numbered from
  1, as they are written in the table }
procedure MakeLines(paths: PLongs; nfiles: longint);
var i, f, c, cf, cl, cc, op: longint; at, da, dl: int64; s: shortstring;
begin
  lpLen := 0;
  PutN(0, 4);              { unit_length, patched below }
  PutN(4, 2);              { version }
  PutN(0, 4);              { header_length, patched below }
  PutB(1); PutB(1);        { minimum_instruction_length, maximum_operations }
  PutB(1);                 { default_is_stmt }
  PutB(LineBase); PutB(LineRange); PutB(OpcodeBase);
  for i := 1 to OpcodeBase - 1 do PutB(ord(i in [2, 3, 4, 5, 9, 12]));   { their operands }
  PutB(0);                 { no include directories }
  for f := 0 to nfiles - 1 do begin
    s := ShownPath(NameOf(paths^[f]));
    for i := 1 to length(s) do PutB(ord(s[i]));
    PutN(0, 4);            { its end, directory, time, length }
  end;
  PutB(0);
  PLongint(@lp^[6])^ := lpLen - 10;
  i := 0;
  while i < numLines do begin
    c := lines^[i].chunk;
    if not chunks^[c].live then begin inc(i); continue end;
    PutB(0); PutU(9); PutB(2);   { DW_LNE_set_address }
    PutN(chunks^[c].adr + lines^[i].at - chunks^[c].start, 8);
    at := lines^[i].at; cf := 1; cl := 1; cc := 0;
    while (i < numLines) and (lines^[i].chunk = c) do begin
      f := 1;
      while paths^[f - 1] <> lines^[i].path do inc(f);
      if f <> cf then begin PutB(4); PutU(f); cf := f end;   { DW_LNS_set_file }
      if lines^[i].col <> cc then begin PutB(5); PutU(lines^[i].col); cc := lines^[i].col end;   { DW_LNS_set_column }
      da := lines^[i].at - at;
      dl := lines^[i].line - cl;
      op := (dl - LineBase) + LineRange * da + OpcodeBase;
      if (dl >= LineBase) and (dl < LineBase + LineRange) and (op <= 255) then PutB(op)   { a special opcode: a row }
      else begin
        if da > 0 then begin PutB(2); PutU(da) end;   { DW_LNS_advance_pc }
        if dl <> 0 then begin PutB(3); PutS(dl) end;  { DW_LNS_advance_line }
        PutB(1);           { DW_LNS_copy: a row }
      end;
      at := lines^[i].at; cl := lines^[i].line;
      inc(i);
    end;
    PutB(2); PutU(chunks^[c].start + chunks^[c].size - at);
    PutB(0); PutU(1); PutB(1);   { DW_LNE_end_sequence }
  end;
  PLongint(@lp^[0])^ := lpLen - 4;
end;

{ The places that Rt reads to say where a failed check or a signal
  was, and what calls were under way: where the line table is in them,
  where text starts and stops, the numbers of procedures and of their
  variables (I64s); for each live procedure where it starts and stops,
  the offset of its name, its first variable and how many it has, and
  the registers of variables it saves, as bits of gen's VarRegs, and
  the frame offset they are saved at (U32s); for each variable the
  offset of its name, its place in the frame and its kind, as
  parse.pas's VarKind (U32s); then the names, each ending in a zero
  byte; then the line table (MakeLines), at linesOff. They are in no
  order, since Rt looks at them only as the program stops. }
procedure MakePlaces(start, stop: int64);
var
  files, first, count: PLongs; buf: PBytes;
  i, f, nfiles, k, np, nv, c, v, at, names: longint;

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
  first := GetMem(numChunks * 4);
  count := GetMem(numChunks * 4);
  FillChar(count^, numChunks * 4, 0);
  for v := numVarNotes - 1 downto 0 do begin
    first^[varNotes[v].chunk] := v;
    inc(count^[varNotes[v].chunk]);
  end;
  nfiles := 0; k := 0; np := 0; nv := 0;
  for i := 0 to numLines - 1 do
    if chunks^[lines^[i].chunk].live then begin
      f := 0;
      while (f < nfiles) and (files^[f] <> lines^[i].path) do inc(f);
      if f = nfiles then begin
        files^[f] := lines^[i].path;
        inc(nfiles);
      end;
    end;
  MakeLines(files, nfiles);
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and (chunks^[c].sec = secText) and (chunks^[c].module >= 0) then begin
      inc(np);
      k := k + length(ChunkName(c)) + 1;
      for v := first^[c] to first^[c] + count^[c] - 1 do k := k + length(NameOf(varNotes[v].name)) + 1;
      nv := nv + count^[c];
    end;
  buf := GetMem(40 + 28 * np + 12 * nv + k + lpLen);
  { the pool of names starts at k, the line table after it }
  k := 40 + 28 * np + 12 * nv;
  names := k;
  at := 40;
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
  linesOff := names;
  linesSize := lpLen;
  Move(lp^, buf^[names], lpLen);
  PInt64(@buf^[0])^ := linesOff;
  PInt64(@buf^[8])^ := start;
  PInt64(@buf^[16])^ := stop;
  PInt64(@buf^[24])^ := np;
  PInt64(@buf^[32])^ := nv;
  SetData(placesChunk, buf, names + lpLen, 8);
  FreeMem(buf); FreeMem(files); FreeMem(first); FreeMem(count);
end;

{ Places the live chunks, leaving roExtra bytes at the end of rodata
  and dynSize at the start of the writable segment. The segments follow
  each other in the file with no padding, and each is loaded a page
  further from its file offset than the one before: rodata at Base +
  Page + roOff, the writable segment at Base + 2 * Page + bssOff. So an
  address and its offset agree within a page, as the loader needs, and
  no two segments, with their different permissions, share a page.
  The bss of a program without the loader's table has no bytes in the
  file, and starts on a page of its own. }
procedure LinkAll(headerSize, roExtra, dynSize: int64);
var c, f, at: longint; e, p, v: int64;
begin
  textOff := (headerSize + 31) div 32 * 32;   { as each code chunk is }
  e := Place(secText, Base + textOff);
  textSize := e - (Base + textOff);
  if placesChunk >= 0 then MakePlaces(Base + textOff, e);
  roOff := (textOff + textSize + 31) div 32 * 32;
  roAdr := Base + Page + roOff;
  e := Place(secRodata, roAdr);
  extraAdr := (e + 7) div 8 * 8;
  if roExtra > 0 then e := extraAdr + roExtra;
  roSize := e - roAdr;
  bssOff := (roOff + roSize + 31) div 32 * 32;
  if dynSize > 0 then bssAdr := Base + 2 * Page + bssOff
  else bssAdr := (roAdr + roSize + Page - 1) div Page * Page;
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
          p := chunks^[c].adr - roAdr;
          Move(rodata^[chunks^[c].start], roImg^[p], chunks^[c].size);
          for f := chunks^[c].firstFix to chunks^[c].firstFix + chunks^[c].numFix - 1 do
            PInt64(@roImg^[p + dataFixups^[f].at])^ :=
              chunks^[dataFixups^[f].chunk].adr + dataFixups^[f].addend;
        end;
      end;
end;

end.
