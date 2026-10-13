{ NBody.raz's twin: bodies under gravity. }
program nbody;
{$mode objfpc}
const
  N = 64;
  Steps = 8000;
  Dt = double(0.001);
var
  x, y, z, vx, vy, vz, m: array[0..N - 1] of double;
  i, s: int64;
  e: double;

procedure Step;
var i, j: int64; dx, dy, dz, d2, mag: double;
begin
  for i := 0 to N - 1 do
    for j := i + 1 to N - 1 do begin
      dx := x[i] - x[j];
      dy := y[i] - y[j];
      dz := z[i] - z[j];
      d2 := dx * dx + dy * dy + dz * dz + double(0.01);
      mag := Dt / (d2 * sqrt(d2));
      vx[i] := vx[i] - dx * m[j] * mag;
      vy[i] := vy[i] - dy * m[j] * mag;
      vz[i] := vz[i] - dz * m[j] * mag;
      vx[j] := vx[j] + dx * m[i] * mag;
      vy[j] := vy[j] + dy * m[i] * mag;
      vz[j] := vz[j] + dz * m[i] * mag;
    end;
  for i := 0 to N - 1 do begin
    x[i] := x[i] + Dt * vx[i];
    y[i] := y[i] + Dt * vy[i];
    z[i] := z[i] + Dt * vz[i];
  end;
end;

begin
  for i := 0 to N - 1 do begin
    x[i] := i mod 8;
    y[i] := i div 8;
    z[i] := (i mod 5) * 0.5;
    m[i] := 1.0 + (i mod 3);
  end;
  for s := 1 to Steps do Step;
  e := 0.0;
  for i := 0 to N - 1 do
    e := e + 0.5 * m[i] * (vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i]);
  writeln(trunc(e * 1000000.0));
end.
