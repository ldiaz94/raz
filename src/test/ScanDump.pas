{ Prints the symbols of a file, one per line: the seed's side of a test
  of src/Scan.raz, which prints the same. A real is shown by its bits,
  so that no formatting library decides what is the same. }
program scandump;
{$mode objfpc}{$H-}
uses diag, scan, seedcontinue;
var i: longint; bits: int64;
begin
  if Open(ParamStr(1)) <> '' then Fatal('no file');
  repeat
    Next;
    write(LineOf(TokPos), ':', TokPos.a, ':', TokPos.b, ' ', CurLine, ':', CurCol, ' ', ord(tok));
    case tok of
      sIdent: write(' ', NameOf(id), ' ', id);
      sInt, sChar: write(' ', ival);
      sReal: begin Move(rval, bits, 8); write(' ', HexStr(bits, 16)) end;
      sString: begin write(' "'); for i := 0 to slen - 1 do write(sbuf[i], ','); write('"') end;
    end;
    writeln;
  until tok = sEof;
end.
