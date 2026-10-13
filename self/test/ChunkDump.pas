{ Makes a program of chunks by a fixed pseudo-random script and prints
  all of it: the seed's side of a test of self/Chunk.raz, whose
  ChunkDump.raz does the same and prints the same. }
program chunkdump;
{$mode objfpc}{$H-}
uses diag, scan, chunk;
var
  seed: int64;
  names: array[0..7] of longint;
  i, k, n, op, c, sum, open, x, y, z: longint;
  b: array[0..63] of byte;

function Rnd(n: longint): longint;
begin
  seed := (seed * 1103515245 + 12345) and $7FFFFFFF;
  Rnd := (seed shr 8) mod n;
end;

begin
  seed := 7;
  for i := 0 to 7 do begin b[0] := 97 + i; names[i] := Intern(@b[0], 1) end;
  open := -1;
  sum := 0;
  for k := 1 to 30000 do begin
    op := Rnd(16);
    case op of
      0..3: Put1(Rnd(256));
      4: begin x := Rnd(1 shl 30); y := Rnd(1 shl 30); Put4(x - y) end;
      5: begin x := Rnd(1 shl 30); y := Rnd(1 shl 30); Put8(int64(x) * 4096 - y) end;
      6: begin
        if open >= 0 then EndChunk(open);
        x := Rnd(5); y := Rnd(9);
        open := NewChunk(secText, x - 1, y - 1);
        BeginChunk(open);
      end;
      7: begin x := Rnd(8); curFile := names[x]; x := Rnd(300); y := Rnd(80); NoteLine(x, y) end;
      8: if numChunks > 0 then begin x := Rnd(numChunks); y := Rnd(100); AddFixup(pc, x, y - 50) end;
      9: if (open >= 0) and (pc - chunks^[open].start > 8) then begin x := Rnd(6); TakeBack(x) end;
      10: begin
        x := Rnd(5); y := Rnd(9);
        c := NewChunk(secRodata, x - 1, y - 1);
        n := Rnd(64);
        for i := 0 to n - 1 do b[i] := Rnd(256);
        x := Rnd(4);
        SetData(c, @b[0], n, 1 shl x);
        n := Rnd(4);
        for i := 1 to n do begin x := Rnd(8); y := Rnd(numChunks); z := Rnd(10); AddDataFixup(c, x * 8, y, z) end;
      end;
      11: begin
        x := Rnd(5); y := Rnd(9);
        c := NewChunk(secBss, x - 1, y - 1);
        x := Rnd(100); y := Rnd(4);
        SetBss(c, x, 1 shl y);
      end;
      12: begin x := Rnd(8); c := ExternChunk(names[x]) end;
      13: if numChunks > 0 then begin
        x := Rnd(numChunks); y := Rnd(8); z := Rnd(200); n := Rnd(5);
        NoteVar(x, names[y], z - 100, n);
      end;
      14: if pc >= 8 then begin
        x := Rnd(1 shl 30); y := Rnd(1 shl 30);
        Put4At(pc - 8, x - y);
        sum := (sum + Get4At(pc - 8)) and $FFFFFF;
      end;
      15: if numChunks > 0 then begin
        x := Rnd(numChunks); chunks^[x].live := true;
        x := Rnd(numChunks); y := Rnd(1 shl 30); chunks^[x].adr := y;
      end;
    end;
  end;
  if open >= 0 then EndChunk(open);
  writeln('sum ', sum, ' pc ', pc, ' rolen ', rolen);
  for i := 0 to numChunks - 1 do
    with chunks^[i] do
      writeln('C ', i, ' ', ord(sec), ' ', start, ' ', size, ' ', align, ' ', firstFix, ' ', numFix, ' ',
        module, ' ', name, ' ', adr, ' ', ord(live), ' ', ord(ext), ' ', ChunkName(i));
  for i := 0 to numFixups - 1 do
    writeln('F ', fixups^[i].at, ' ', fixups^[i].chunk, ' ', fixups^[i].addend);
  for i := 0 to numDataFixups - 1 do
    writeln('D ', dataFixups^[i].at, ' ', dataFixups^[i].chunk, ' ', dataFixups^[i].addend);
  for i := 0 to numLines - 1 do
    writeln('L ', lines^[i].at, ' ', lines^[i].chunk, ' ', lines^[i].path, ' ', lines^[i].line, ' ', lines^[i].col);
  for i := 0 to numVarNotes - 1 do
    writeln('V ', varNotes[i].chunk, ' ', varNotes[i].name, ' ', varNotes[i].off, ' ', varNotes[i].kind);
  for i := 0 to pc - 1 do write(HexStr(code^[i], 2));
  writeln;
  for i := 0 to rolen - 1 do write(HexStr(rodata^[i], 2));
  writeln;
end.
