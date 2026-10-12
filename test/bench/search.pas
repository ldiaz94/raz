{ Search.raz's twin. }
program search;
{$mode objfpc}
const
  N = 100000;
  Rounds = 400;
var
  text: array[0..N - 1] of byte;
  word: array[0..15] of byte;
  i, r, x, total: int64;

function Find(const s, sub: array of byte): int64;
var i, j: int64;
begin
  for i := 0 to Length(s) - Length(sub) do begin
    j := 0;
    while (j < Length(sub)) and (s[i + j] = sub[j]) do inc(j);
    if j = Length(sub) then exit(i);
  end;
  Find := -1;
end;

begin
  x := 1;
  for i := 0 to N - 1 do begin
    x := (x * 1103515245 + 12345) and $7FFFFFFF;
    text[i] := ord('a') + (x shr 16) and 3;
  end;
  total := 0;
  for r := 1 to Rounds do begin
    Move(text[N - 16 - r], word, 16);
    total := total + Find(text, word);
  end;
  writeln(total);
end.
