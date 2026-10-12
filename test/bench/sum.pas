{ Sum.raz's twin: a sum over an open array, its slice. }
program sum;
{$mode objfpc}
const
  N = 1000000;
  Rounds = 300;
var
  a: array[0..N - 1] of int64;
  i, r, total: int64;

function Sum(const s: array of int64): int64;
var i, t: int64;
begin
  t := 0;
  for i := 0 to High(s) do t := t + s[i];
  Sum := t;
end;

begin
  for i := 0 to N - 1 do a[i] := i;
  total := 0;
  for r := 1 to Rounds do total := total + Sum(a);
  writeln(total);
end.
