{ Assembles the instructions in the file of the argument, as the body of
  a code procedure that ends in end, and prints the bytes and the
  listing: the seed's side of a test of the assembler in src/X64.raz,
  whose AsmDump.raz does the same and prints the same. Constants are
  numbers, with a minus sign, and sums of them. }
program asmdump;
{$mode objfpc}{$H-}
uses diag, scan, seedcontinue, chunk, x64;
var i: longint; path: string;

function ConstVal(whole: boolean): int64;
var neg: boolean; v: int64;
begin
  neg := tok = sMinus;
  if neg then Next;
  if tok <> sInt then Mark('expected a number');
  v := ival;
  Next;
  if neg then v := -v;
  while whole and (tok in [sPlus, sMinus]) do begin
    neg := tok = sMinus;
    Next;
    if tok <> sInt then Mark('expected a number');
    if neg then v := v - ival else v := v + ival;
    Next;
  end;
  ConstVal := v;
end;

begin
  if Open(ParamStr(1)) <> '' then Fatal('no file');
  path := 'lib/Rt.raz';
  curFile := Intern(@path[1], length(path));
  listing := true;
  NewChunk(secText, 0, 0);
  BeginChunk(0);
  NoteLine(1, 1);
  Next;
  Assemble(@ConstVal);
  EndChunk(0);
  chunks^[0].live := true;
  for i := 0 to pc - 1 do write(HexStr(code^[i], 2));
  writeln;
  List(0);
  Finish;
end.
