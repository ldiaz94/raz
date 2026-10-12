{ Heapsort.raz's twin. }
program heapsort;
{$mode objfpc}
const
  N = 200000;
  Rounds = 8;
var
  a: array[0..N - 1] of int64;
  i, r, x, total: int64;

procedure Sift(var s: array of int64; lo, hi: int64);
var root, child, t: int64;
begin
  root := lo;
  child := 2 * root + 1;
  while child < hi do begin
    if (child + 1 < hi) and (s[child] < s[child + 1]) then inc(child);
    if s[root] >= s[child] then exit;
    t := s[root];
    s[root] := s[child];
    s[child] := t;
    root := child;
    child := 2 * root + 1;
  end;
end;

procedure Sort(var s: array of int64);
var i, t: int64;
begin
  for i := Length(s) div 2 - 1 downto 0 do Sift(s, i, Length(s));
  for i := High(s) downto 1 do begin
    t := s[0];
    s[0] := s[i];
    s[i] := t;
    Sift(s, 0, i);
  end;
end;

begin
  x := 1;
  total := 0;
  for r := 1 to Rounds do begin
    for i := 0 to N - 1 do begin
      x := (x * 1103515245 + 12345) and $7FFFFFFF;
      a[i] := x;
    end;
    Sort(a);
    for i := 1 to N - 1 do
      if a[i - 1] > a[i] then writeln('not sorted');
    total := total + a[N div 2];
  end;
  writeln(total);
end.
