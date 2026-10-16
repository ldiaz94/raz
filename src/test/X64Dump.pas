{ Writes every instruction the encoder makes, with operands drawn by a
  fixed pseudo-random script, then prints the bytes, the fixups and the
  listing (raz -S) of what it made: the seed's side of a test of
  src/X64.raz, whose X64Dump.raz does the same and prints the same. }
program x64dump;
{$mode objfpc}{$H-}
uses diag, scan, seedcontinue, chunk, x64;
var
  seed: int64;
  i, k, op, a, b, c, d, lab1, lab2: longint;
  m: TMem;
  path: string;

function Rnd(n: longint): longint;
begin
  seed := (seed * 1103515245 + 12345) and $7FFFFFFF;
  Rnd := (seed shr 8) mod n;
end;

{ a register, with the stack and base pointers and the high ones often enough }
function Reg: longint;
begin
  Reg := Rnd(16);
end;

{ a size of 1, 2, 4 or 8 bytes }
function Size: longint;
begin
  Size := 1 shl Rnd(4);
end;

{ a value that fits size bytes, of 8 as 32 bits }
function Imm(sz: longint): longint;
var x: longint;
begin
  x := Rnd(1 shl 30);
  case Rnd(3) of
    0: Imm := x mod 100 - 50;
    1: Imm := x - (1 shl 29);
  else Imm := x mod 20000 - 10000;
  end;
  if sz = 1 then Imm := Imm mod 128
  else if sz = 2 then Imm := Imm mod 32768;
end;

function RandMem: TMem;
var kind, base, idx, sc, disp, x: longint;
begin
  kind := Rnd(6);
  base := Reg; idx := Reg; sc := 1 shl Rnd(4); x := Rnd(5);
  case x of
    0: disp := 0;
    1: disp := Rnd(250) - 125;
    2: disp := Rnd(1 shl 20) - (1 shl 19);
    3: disp := 127 + Rnd(3) - 1;
  else disp := -128 + Rnd(3) - 1;
  end;
  case kind of
    0, 1: RandMem := Mem(base, disp);
    2: RandMem := MemRip(Rnd(5), disp);
    3, 4: RandMem := MemIdx(base, idx, sc, disp);
  else RandMem := Mem(base, 0);
  end;
end;

begin
  seed := 3;
  path := 'lib/Rt.raz';
  if Open(path) <> '' then Fatal('no file');
  listing := true;
  for i := 0 to 4 do NewChunk(secText, i - 1, i);
  curFile := Intern(@path[1], length(path));
  BeginChunk(0);
  lab1 := NoLabel; lab2 := NoLabel;
  for k := 1 to 3000 do begin
    if k mod 7 = 0 then begin a := Rnd(300); b := Rnd(60); NoteLine(1 + a, b) end;
    op := Rnd(50);
    case op of
      0: begin a := Reg; b := Reg; MovRR(a, b) end;
      1: begin
        a := Reg; b := Rnd(6); c := Rnd(1 shl 30);
        case b of
          0: MovRI(a, 0);
          1: MovRI(a, c);
          2: MovRI(a, -c);
          3: MovRI(a, int64(c) * 8 + 5);
          4: MovRI(a, int64(c) * 4096 * 4096 * 9 - 7);
        else MovRI(a, 0);
        end;
      end;
      2: begin a := Rnd(8); m := RandMem; b := Size; c := Imm(b); AluMI(a, m, c, b) end;
      3: begin m := RandMem; b := Size; c := Imm(b); StoreI(m, c, b) end;
      4: begin a := Reg; m := RandMem; b := Size; c := Rnd(2); Load(a, m, b, c = 0) end;
      5: begin m := RandMem; a := Reg; b := Size; Store(m, a, b) end;
      6: begin a := Reg; m := RandMem; Lea(a, m) end;
      7: begin a := Rnd(8); b := Reg; c := Reg; Alu(a, b, c) end;
      8: begin a := Rnd(8); b := Reg; c := Imm(8); AluI(a, b, c) end;
      9: begin a := Rnd(8); b := Reg; m := RandMem; AluM(a, b, m) end;
      10: begin a := Reg; b := Reg; Imul(a, b) end;
      11: begin a := Reg; c := Imm(8); ImulI(a, c) end;
      12: begin a := Rnd(3); b := Reg; if a = 0 then a := shShl else if a = 1 then a := shShr else a := shSar; Shift(a, b) end;
      13: begin a := Rnd(3); b := Reg; c := Rnd(64); if a = 0 then a := shShl else if a = 1 then a := shShr else a := shSar; ShiftI(a, b, c) end;
      14: begin a := Rnd(4); b := Reg; if a < 2 then a := a + 2 else a := a + 4; Unary(a, b) end;
      15: Cqo;
      16: begin a := Reg; b := 1 shl Rnd(3); c := Rnd(2); Extend(a, b, c = 0) end;
      17: begin a := Rnd(16); b := Reg; SetCC(a, b) end;
      18: begin a := Reg; b := Reg; TestRR(a, b) end;
      19: begin a := Reg; Push(a) end;
      20: begin a := Reg; Pop(a) end;
      21: begin a := Rnd(5); CallChunk(a) end;
      22: begin a := Rnd(1000); CallBack(a) end;
      23: begin a := Reg; CallR(a) end;
      24: begin a := Reg; JmpR(a) end;
      25: begin m := RandMem; CallM(m) end;
      26: begin a := Rnd(5); case a of 0: Ret; 1: Leave; 2: Syscall; 3: Mfence; else Ud2 end end;
      27: begin a := 8 shl Rnd(3); Align(a) end;
      28: begin a := Rnd(5); case a of 0: RepMovsb; 1: Std; 2: Cld; 3: RepStosb; else RepeCmpsb end end;
      29: begin m := RandMem; a := Reg; LockCmpxchg(m, a) end;
      30: begin m := RandMem; a := Reg; Xchg(m, a) end;
      31: begin m := RandMem; a := Reg; LockXadd(m, a) end;
      32: begin a := Reg; b := Reg; MovqXR(a, b) end;
      33: begin a := Reg; b := Reg; MovqRX(a, b) end;
      34: begin a := Reg; b := Reg; MovX(a, b) end;
      35: begin a := Reg; m := RandMem; b := Rnd(2); MovsXM(a, m, b = 0) end;
      36: begin m := RandMem; a := Reg; b := Rnd(2); MovsMX(m, a, b = 0) end;
      37: begin
        d := Rnd(5); a := Reg; b := Reg; c := Rnd(2);
        case d of 0: d := $58; 1: d := $59; 2: d := $5C; 3: d := $5E; else d := $5A end;
        Sse(d, a, b, c = 0);
      end;
      38: begin
        d := Rnd(5); a := Reg; m := RandMem; c := Rnd(2);
        case d of 0: d := $58; 1: d := $59; 2: d := $5C; 3: d := $5E; else d := $5A end;
        SseM(d, a, m, c = 0);
      end;
      39: begin a := Reg; b := Reg; c := Rnd(2); Ucomis(a, b, c = 0) end;
      40: begin a := Reg; b := Reg; c := Rnd(2); Cvtsi2s(a, b, c = 0) end;
      41: begin a := Reg; b := Reg; c := Rnd(2); Cvtts2si(a, b, c = 0) end;
      42: begin a := Reg; b := Rnd(64); Btc(a, b) end;
      43: begin
        a := Rnd(16); b := Rnd(2);
        if b = 0 then Jmp(lab1) else Jcc(a, lab2);
      end;
      44: begin a := Rnd(16); b := Rnd(2); c := pc - Rnd(200); if b = 0 then JmpBack(c) else JccBack(a, c) end;
      45: if Rnd(3) = 0 then begin FixLink(lab1); lab1 := NoLabel end
          else begin FixLinkTo(lab2, pc - 20); lab2 := NoLabel end;
      46: begin Jmp(lab1); DropJumpTo(lab1) end;
      47: begin a := JoinLinks(lab1, lab2); lab1 := a; lab2 := NoLabel end;
    else begin a := Rnd(256); Put1(a) end;
    end;
  end;
  FixLink(lab1); FixLink(lab2);
  EndChunk(0);
  chunks^[0].live := true;
  writeln('pc ', pc, ' fixups ', numFixups, ' lines ', numLines, ' said ', SaidCount);
  for i := 0 to pc - 1 do write(HexStr(code^[i], 2));
  writeln;
  for i := 0 to numFixups - 1 do writeln('F ', fixups^[i].at, ' ', fixups^[i].chunk, ' ', fixups^[i].addend);
  List(-1);
end.
