{ Jacobi.raz's twin: a 2-D Jacobi sweep over open arrays. }
program jacobi;
{$mode objfpc}
const
  N = 512;
  Rounds = 200;
var
  a, b: array[0..N * N - 1] of double;
  i, r: int64;
  sum: double;

procedure Sweep(var d: array of double; const s: array of double);
var i, j: int64;
begin
  for i := 1 to N - 2 do
    for j := 1 to N - 2 do
      d[i * N + j] := 0.25 * (s[i * N + j - 1] + s[i * N + j + 1] + s[(i - 1) * N + j] + s[(i + 1) * N + j]);
end;

begin
  for i := 0 to N * N - 1 do begin
    a[i] := i mod 7;
    b[i] := a[i];
  end;
  for r := 1 to Rounds do begin
    Sweep(b, a);
    Sweep(a, b);
  end;
  sum := 0.0;
  for i := 0 to N * N - 1 do sum := sum + a[i];
  writeln(trunc(sum * 1000.0));
end.
