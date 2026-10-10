{ Prints the symbols of a file, one per line: a test of scan.pas. }
program scantest;
{$mode objfpc}{$H-}
uses scan;
var i: longint;
begin
  if not Open(ParamStr(1)) then Fatal('no file');
  repeat
    Next;
    write(Where, ' ', ord(sym));
    case sym of
      sIdent: write(' ', NameOf(id));
      sInt, sChar: write(' ', ival);
      sReal: write(' ', rval:0:6);
      sString: begin write(' "'); for i := 0 to slen - 1 do write(sbuf[i], ','); write('"') end;
    end;
    writeln;
  until sym = sEof;
end.
