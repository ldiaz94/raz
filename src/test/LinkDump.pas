{ Makes a program of chunks by a fixed pseudo-random script, links it and
  writes it as an executable to the file of the second argument, in the
  way the first says (0 static, 1 dynamic, 2 stripped): the seed's side
  of a test of src/Link.raz and src/Elf.raz, whose LinkDump.raz does
  the same and writes the same file. }
program linkdump;
{$mode objfpc}{$H-}
uses diag, scan, seedcontinue, chunk, link, elf;
const NumC = 200;
var
  seed: int64;
  names: array[0..7] of longint;
  i, j, k, kind, n, x, y, z, mode: longint;
  b: array[0..63] of byte;

function Rnd(n: longint): longint;
begin
  seed := (seed * 1103515245 + 12345) and $7FFFFFFF;
  Rnd := (seed shr 8) mod n;
end;

var c, e, line, col: longint;
begin
  seed := 5;
  mode := ord(ParamStr(1)[1]) - 48;
  for i := 0 to 7 do begin b[0] := 97 + i; names[i] := Intern(@b[0], 1) end;
  placesChunk := NewChunk(secRodata, -1, -1);
  SetData(placesChunk, @b[0], 0, 8);
  for i := 0 to NumC - 1 do begin
    if i = 0 then kind := 0 else kind := Rnd(10);
    x := Rnd(4); y := Rnd(8);
    case kind of
      0..5: begin
        c := NewChunk(secText, x - 1, y);
        BeginChunk(c);
        z := Rnd(3); curFile := names[z];
        line := Rnd(300); col := Rnd(60);
        NoteLine(line, col);
        if i = 0 then begin AddFixup(pc, placesChunk, 0); Put4(0) end;
        n := 2 + Rnd(10);
        for j := 1 to n do begin
          z := Rnd(5);
          if z <= 1 then begin
            e := Rnd(NumC); y := Rnd(8);
            AddFixup(pc, e, y);
            Put4(0);
          end else if z = 2 then begin
            z := Rnd(3); curFile := names[z];
            line := Rnd(300); col := Rnd(60);
            NoteLine(line, col);
          end else begin x := Rnd(1 shl 30); Put4(x); x := Rnd(256); Put1(x) end;
        end;
        EndChunk(c);
        n := Rnd(3);
        for j := 1 to n do begin
          x := Rnd(8); y := Rnd(200); z := Rnd(6);
          NoteVar(c, names[x], y - 100, z);
        end;
      end;
      6, 7: begin
        c := NewChunk(secRodata, x - 1, y);
        n := 8 * (1 + Rnd(4));
        for j := 0 to n - 1 do b[j] := Rnd(256);
        SetData(c, @b[0], n, 8);
        for j := 0 to n div 8 - 1 do begin
          z := Rnd(2);
          if z = 0 then begin e := Rnd(NumC); y := Rnd(8); AddDataFixup(c, j * 8, e, y) end;
        end;
      end;
      8: begin
        c := NewChunk(secBss, x - 1, y);
        z := Rnd(200); e := Rnd(4);
        SetBss(c, 1 + z, 1 shl e);
      end;
      9: begin z := Rnd(8); c := ExternChunk(names[z]) end;
    end;
  end;
  { every chunk a fixup names must exist, and be defined if it is reached }
  while numChunks < NumC do begin c := NewChunk(secBss, -1, -1); SetBss(c, 8, 8) end;
  for i := 0 to numChunks - 1 do
    if chunks^[i].size < 0 then SetBss(i, 8, 8);
  mainPath := 'some/main.raz';
  if mode = 1 then begin
    numNeeded := 2;
    needed[0] := names[0]; needed[1] := names[1];
  end;
  stripped := mode = 2;
  if mode = 2 then placesChunk := -1;
  MarkLive(1);
  WriteElf(ParamStr(2), 1);
end.
