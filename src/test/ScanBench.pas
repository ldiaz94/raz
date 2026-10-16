{ Counts the symbols of a file and nothing else, for timing scan.pas
  against src/Scan.raz (ScanBench.raz). }
program scanbench;
{$mode objfpc}{$H-}
uses diag, scan;
var n: longint;
begin
  if Open(ParamStr(1)) <> '' then Fatal('no file');
  n := 0;
  repeat Next; inc(n) until tok = sEof;
  writeln(n, ' symbols');
end.
