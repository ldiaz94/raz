{ Lines.raz's twin. }
program lines;
{$mode objfpc}
const
  N = 16777216;
  Rounds = 32;
  Letters = 'etaoinshrdlucmfw';
var
  text: array[0..N - 1] of byte;
  i, r, x, v, k, total, walked: int64;

function Count(p: pbyte; n: int64): int64;
var i, c: int64;
begin
  c := 0;
  for i := 0 to n - 1 do
    if p[i] = 10 then inc(c);
  Count := c;
end;

begin
  x := 1;
  for i := 0 to N - 1 do begin
    x := (x * 1103515245 + 12345) and $7FFFFFFF;
    v := (x shr 16) and 63;
    if v = 0 then text[i] := 10
    else if v < 10 then text[i] := ord(' ')
    else text[i] := ord(Letters[(v and 15) + 1]);
  end;
  total := 0;
  walked := 0;
  for r := 1 to Rounds do begin
    total := total + Count(@text[0], N);
    i := 0;
    k := IndexByte(text[0], N, 10);
    while k >= 0 do begin
      inc(walked);
      i := i + k + 1;
      if i >= N then break;
      k := IndexByte(text[i], N - i, 10);
    end;
  end;
  writeln(total, ' ', walked);
end.
