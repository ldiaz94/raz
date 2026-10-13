{ Grep.raz's twin. }
program grep;
{$mode objfpc}
const
  N = 16777216;
  Rounds = 16;
  Letters: string[16] = 'etaoinshrdlucmfw';
  Ones = qword($0101010101010101);
  Tops = qword($8080808080808080);
  Word: string[5] = 'error';
  A = 1;
  B = 3;
var
  text: array[0..N - 1] of byte;
  i, r, x, v, total, hits: int64;

function Zeros(v: qword): qword;
begin
  Zeros := (v - Ones) and not v and Tops;
end;

function Lowest(m: qword): int64;
begin
  Lowest := int64((((m and (0 - m)) - 1) and Ones) * Ones shr 56) - 1;
end;

function Holds(s: PByte): boolean;
var k: int64;
begin
  for k := 0 to Length(Word) - 1 do
    if s[k] <> ord(Word[k + 1]) then exit(false);
  Holds := true;
end;

function LineEnd(s: PByte; n: int64): int64;
var i: int64; m: qword;
begin
  i := 0;
  while i + 8 <= n do begin
    m := Zeros(PQWord(@s[i])^ xor qword($0A0A0A0A0A0A0A0A));
    if m <> 0 then exit(i + Lowest(m));
    i := i + 8;
  end;
  while (i < n) and (s[i] <> 10) do inc(i);
  LineEnd := i;
end;

function Find(s: PByte; n: int64): int64;
var i, j, last: int64; m, wa, wb: qword;
begin
  last := n - Length(Word);
  wa := qword(ord(Word[A + 1])) * Ones;
  wb := qword(ord(Word[B + 1])) * Ones;
  i := 0;
  while i + 7 <= last do begin
    m := Zeros(PQWord(@s[i + A])^ xor wa) and Zeros(PQWord(@s[i + B])^ xor wb);
    while m <> 0 do begin
      j := i + Lowest(m);
      if Holds(@s[j]) then exit(j);
      m := m and (m - 1);
    end;
    i := i + 8;
  end;
  while i <= last do begin
    if Holds(@s[i]) then exit(i);
    inc(i);
  end;
  Find := -1;
end;

function Lines(s: PByte; len: int64): int64;
var i, n: int64;
begin
  i := 0;
  n := 0;
  while i < len do begin
    i := i + LineEnd(@s[i], len - i) + 1;
    inc(n);
  end;
  Lines := n;
end;

function Matching(s: PByte; len: int64): int64;
var i, k, n: int64;
begin
  i := 0;
  n := 0;
  k := Find(s, len);
  while k >= 0 do begin
    inc(n);
    i := i + k;
    i := i + LineEnd(@s[i], len - i) + 1;
    if i >= len then exit(n);
    k := Find(@s[i], len - i);
  end;
  Matching := n;
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
  text[N - 1] := 10;
  i := 0;
  while i < N - 1000 do begin
    Move(Word[1], text[i], Length(Word));
    i := i + 997;
  end;
  total := 0;
  hits := 0;
  for r := 1 to Rounds do begin
    total := total + Lines(@text[0], N);
    hits := hits + Matching(@text[0], N);
  end;
  writeln(total, ' ', hits);
end.
