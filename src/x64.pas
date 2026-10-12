{ x64.pas: machine code for x86-64.

  The encoder writes the instructions the code generator needs, and
  no others, into the text of chunk.pas. Registers are numbered as the
  hardware numbers them. Jumps within a procedure are patched here, as
  soon as their target is known.

  Depends on: scan, for errors; chunk, for the code buffer and fixups.
  Leaves out: choosing instructions; that is gen.pas. }

unit x64;

{$mode objfpc}{$H-}

interface

uses scan, diag, chunk;

const
  RAX = 0; RCX = 1; RDX = 2; RBX = 3; RSP = 4; RBP = 5; RSI = 6; RDI = 7;
  R8 = 8; R9 = 9; R10 = 10; R11 = 11;
  RIP = -1;      { a base meaning rip-relative, to a chunk }
  NoIndex = -1;

  { condition codes }
  ccB = 2; ccAE = 3; ccE = 4; ccNE = 5; ccBE = 6; ccA = 7; ccS = 8;
  ccP = 10; ccNP = 11; ccL = 12; ccGE = 13; ccLE = 14; ccG = 15;

  { group 1 operations, the /digit of 81 and 83 }
  aluAdd = 0; aluOr = 1; aluAnd = 4; aluSub = 5; aluXor = 6; aluCmp = 7;

  { the /digit of D3 and C1 }
  shShl = 4; shShr = 5; shSar = 7;

  NoLabel = -1;

type
  TMem = record
    base: longint;    { a register, or RIP }
    index: longint;   { a register, or NoIndex }
    scale: longint;   { 1, 2, 4 or 8 }
    disp: longint;
    chunk: longint;   { with RIP: the chunk addressed }
  end;

var
  labelAt: longint;   { the last place a jump was made to land }

function Here: TMem;
function Mem(base: longint; disp: int64): TMem;
function MemRip(chunk: longint; disp: longint): TMem;
function MemIdx(base, index, scale: longint; disp: int64): TMem;

procedure MovRR(dst, src: longint);
procedure MovRI(r: longint; v: int64);
procedure Load(r: longint; const m: TMem; size: longint; signed: boolean);
procedure Store(const m: TMem; r: longint; size: longint);
procedure Lea(r: longint; const m: TMem);
procedure Alu(op, dst, src: longint);
procedure AluI(op, r: longint; v: longint);
procedure AluM(op, r: longint; const m: TMem);
procedure Imul(dst, src: longint);
procedure ImulI(r: longint; v: longint);
procedure Shift(op, r: longint);
procedure ShiftI(op, r, n: longint);
procedure Unary(ext, r: longint);   { F7 /ext: 2 not, 3 neg, 6 div, 7 idiv }
procedure Cqo;
procedure Extend(r, size: longint; signed: boolean);
procedure SetCC(cc, r: longint);
procedure TestRR(a, b: longint);
procedure Push(r: longint);
procedure Pop(r: longint);
procedure CallChunk(c: longint);
procedure CallBack(target: longint);
procedure CallR(r: longint);
procedure CallM(const m: TMem);
procedure Ret;
procedure Leave;
procedure Syscall;
procedure Mfence;
procedure Ud2;
procedure RepMovsb;
procedure RepStosb;
procedure RepeCmpsb;
procedure LockCmpxchg(const m: TMem; r: longint);
procedure Xchg(const m: TMem; r: longint);
procedure LockXadd(const m: TMem; r: longint);
procedure MovqXR(x, r: longint);
procedure MovqRX(r, x: longint);
procedure MovsdXM(x: longint; const m: TMem);
procedure MovsdMX(const m: TMem; x: longint);
{ The real instructions take single: F32 (ss) rather than F64 (sd) }
procedure Sse(op, x, y: longint; single: boolean);   { 58 add, 59 mul, 5C sub, 5E div, 5A convert }
procedure Ucomis(x, y: longint; single: boolean);
procedure Cvtsi2s(x, r: longint; single: boolean);
procedure Cvtts2si(r, x: longint; single: boolean);
procedure Btc(r, bit: longint);

procedure Jmp(var L: longint);
procedure Jcc(cc: longint; var L: longint);
procedure JmpBack(target: longint);
procedure JccBack(cc, target: longint);
procedure FixLink(L: longint);
procedure FixLinkTo(L, target: longint);

implementation

{ Operands }

function Mem(base: longint; disp: int64): TMem;
begin
  if (disp < low(longint)) or (disp > high(longint)) then Mark('an offset beyond 32 bits');
  Mem.base := base; Mem.index := NoIndex; Mem.scale := 1;
  Mem.disp := disp; Mem.chunk := -1;
end;

function MemRip(chunk: longint; disp: longint): TMem;
begin
  MemRip.base := RIP; MemRip.index := NoIndex; MemRip.scale := 1;
  MemRip.disp := disp; MemRip.chunk := chunk;
end;

function MemIdx(base, index, scale: longint; disp: int64): TMem;
begin
  MemIdx := Mem(base, disp);
  MemIdx.index := index;
  MemIdx.scale := scale;
end;

{ The address of the code about to be written, as an operand }
function Here: TMem;
begin
  Here := MemRip(curChunk, pc - chunks^[curChunk].start);
end;

{ Encoding. An instruction is: a legacy prefix, REX, the opcode, ModRM,
  SIB and displacement. Opcodes of more than one byte are given with
  their first byte in the low eight bits. }

procedure Opcode(op: longint);
begin
  repeat
    Put1(op and $FF);
    op := op shr 8;
  until op = 0;
end;

procedure Prefix(pfx: longint; w: boolean; reg, index, base: longint; byteReg: boolean);
var rex: longint;
begin
  if pfx <> 0 then Put1(pfx);
  rex := 0;
  if w then rex := rex or 8;
  if reg >= 8 then rex := rex or 4;
  if index >= 8 then rex := rex or 2;
  if base >= 8 then rex := rex or 1;
  { sil and dil exist only with a REX prefix }
  if (rex <> 0) or (byteReg and (reg >= 4) and (reg <= 7)) then Put1($40 or rex);
end;

{ op reg, [mem] }
procedure OpM(pfx: longint; w: boolean; op, reg: longint; const m: TMem; byteReg: boolean = false);
var md, b, sc: longint;
begin
  if m.base = RIP then Prefix(pfx, w, reg, NoIndex, 0, byteReg)
  else Prefix(pfx, w, reg, m.index, m.base, byteReg);
  Opcode(op);
  reg := reg and 7;
  if m.base = RIP then begin
    Put1(reg shl 3 or 5);
    { the rip-relative displacement counts from the end of the
      instruction, which these instructions end with }
    AddFixup(pc, m.chunk, m.disp);
    Put4(0);
    exit;
  end;
  b := m.base and 7;
  if (m.disp = 0) and (b <> RBP) then md := 0
  else if (m.disp >= -128) and (m.disp <= 127) then md := 1
  else md := 2;
  if (m.index <> NoIndex) or (b = RSP) then begin
    Put1(md shl 6 or reg shl 3 or 4);
    case m.scale of 1: sc := 0; 2: sc := 1; 4: sc := 2; else sc := 3; end;
    if m.index = NoIndex then Put1(sc shl 6 or 4 shl 3 or b)
    else Put1(sc shl 6 or (m.index and 7) shl 3 or b);
  end else
    Put1(md shl 6 or reg shl 3 or b);
  if md = 1 then Put1(m.disp)
  else if md = 2 then Put4(m.disp);
end;

{ op reg, rm (both registers) }
procedure OpR(pfx: longint; w: boolean; op, reg, rm: longint);
begin
  Prefix(pfx, w, reg, NoIndex, rm, false);
  Opcode(op);
  Put1($C0 or (reg and 7) shl 3 or (rm and 7));
end;

procedure MovRR(dst, src: longint);
begin
  OpR(0, true, $89, src, dst);
end;

procedure MovRI(r: longint; v: int64);
begin
  if (v >= low(longint)) and (v <= high(longint)) then begin
    if v = 0 then OpR(0, false, $31, r, r)        { xor r32, r32 }
    else if v > 0 then begin                      { mov r32, imm32 }
      Prefix(0, false, 0, NoIndex, r, false); Put1($B8 + r and 7); Put4(v)
    end else begin
      OpR(0, true, $C7, 0, r); Put4(v)            { sign-extended imm32 }
    end;
  end else if (v > 0) and (v <= $FFFFFFFF) then begin
    Prefix(0, false, 0, NoIndex, r, false); Put1($B8 + r and 7); Put4(longint(v))
  end else begin
    Prefix(0, true, 0, NoIndex, r, false); Put1($B8 + r and 7); Put8(v)
  end;
end;

procedure Load(r: longint; const m: TMem; size: longint; signed: boolean);
begin
  case size of
    1: if signed then OpM(0, true, $BE0F, r, m) else OpM(0, false, $B60F, r, m);
    2: if signed then OpM(0, true, $BF0F, r, m) else OpM(0, false, $B70F, r, m);
    4: if signed then OpM(0, true, $63, r, m) else OpM(0, false, $8B, r, m);
  else OpM(0, true, $8B, r, m);
  end;
end;

procedure Store(const m: TMem; r: longint; size: longint);
begin
  case size of
    1: OpM(0, false, $88, r, m, true);
    2: OpM($66, false, $89, r, m);
    4: OpM(0, false, $89, r, m);
  else OpM(0, true, $89, r, m);
  end;
end;

procedure Lea(r: longint; const m: TMem);
begin
  OpM(0, true, $8D, r, m);
end;

procedure Alu(op, dst, src: longint);
begin
  OpR(0, true, op shl 3 or 1, src, dst);
end;

procedure AluI(op, r: longint; v: longint);
begin
  if (v >= -128) and (v <= 127) then begin
    OpR(0, true, $83, op, r); Put1(v)
  end else begin
    OpR(0, true, $81, op, r); Put4(v)
  end;
end;

{ op r, [m] }
procedure AluM(op, r: longint; const m: TMem);
begin
  OpM(0, true, op shl 3 or 3, r, m);
end;

procedure Imul(dst, src: longint);
begin
  OpR(0, true, $AF0F, dst, src);
end;

procedure ImulI(r: longint; v: longint);
begin
  OpR(0, true, $69, r, r);
  Put4(v);
end;

procedure Shift(op, r: longint);
begin
  OpR(0, true, $D3, op, r);
end;

procedure ShiftI(op, r, n: longint);
begin
  OpR(0, true, $C1, op, r);
  Put1(n);
end;

procedure Unary(ext, r: longint);
begin
  OpR(0, true, $F7, ext, r);
end;

procedure Cqo;
begin
  Put1($48); Put1($99);
end;

{ Brings a value of size bytes in r to 64 bits, by its sign or zeros. }
procedure Extend(r, size: longint; signed: boolean);
begin
  case size of
    1: if signed then OpR(0, true, $BE0F, r, r) else OpR(0, false, $B60F, r, r);
    2: if signed then OpR(0, true, $BF0F, r, r) else OpR(0, false, $B70F, r, r);
    4: if signed then OpR(0, true, $63, r, r) else OpR(0, false, $89, r, r);
  end;
end;

{ r := 1 if the condition holds, else 0 }
procedure SetCC(cc, r: longint);
begin
  OpR(0, false, $900F + cc shl 8, 0, r);
  OpR(0, false, $B60F, r, r);
end;

procedure TestRR(a, b: longint);
begin
  OpR(0, true, $85, b, a);
end;

procedure Push(r: longint);
begin
  if r >= 8 then Put1($41);
  Put1($50 + r and 7);
end;

procedure Pop(r: longint);
begin
  if r >= 8 then Put1($41);
  Put1($58 + r and 7);
end;

procedure CallChunk(c: longint);
begin
  Put1($E8);
  AddFixup(pc, c, 0);
  Put4(0);
end;

procedure CallBack(target: longint);
begin
  Put1($E8);
  Put4(target - (pc + 4));
end;

procedure CallR(r: longint);
begin
  OpR(0, false, $FF, 2, r);
end;

procedure CallM(const m: TMem);
begin
  OpM(0, false, $FF, 2, m);
end;

procedure Ret; begin Put1($C3) end;
procedure Leave; begin Put1($C9) end;
procedure Syscall; begin Put1($0F); Put1($05) end;
procedure Mfence; begin Put1($0F); Put1($AE); Put1($F0) end;
procedure Ud2; begin Put1($0F); Put1($0B) end;
procedure RepMovsb; begin Put1($F3); Put1($A4) end;
procedure RepStosb; begin Put1($F3); Put1($AA) end;
procedure RepeCmpsb; begin Put1($F3); Put1($A6) end;

procedure LockCmpxchg(const m: TMem; r: longint);
begin
  Put1($F0);
  OpM(0, true, $B10F, r, m);
end;

procedure Xchg(const m: TMem; r: longint);
begin
  OpM(0, true, $87, r, m);
end;

procedure LockXadd(const m: TMem; r: longint);
begin
  Put1($F0);
  OpM(0, true, $C10F, r, m);
end;

procedure MovqXR(x, r: longint);
begin
  OpR($66, true, $6E0F, x, r);
end;

procedure MovqRX(r, x: longint);
begin
  OpR($66, true, $7E0F, x, r);
end;

procedure MovsdXM(x: longint; const m: TMem);
begin
  OpM($F2, false, $100F, x, m);
end;

procedure MovsdMX(const m: TMem; x: longint);
begin
  OpM($F2, false, $110F, x, m);
end;

const
  RealPfx: array[boolean] of longint = ($F2, $F3);

procedure Sse(op, x, y: longint; single: boolean);
begin
  OpR(RealPfx[single], false, $0F or op shl 8, x, y);
end;

procedure Ucomis(x, y: longint; single: boolean);
begin
  if single then OpR(0, false, $2E0F, x, y) else OpR($66, false, $2E0F, x, y);
end;

procedure Cvtsi2s(x, r: longint; single: boolean);
begin
  OpR(RealPfx[single], true, $2A0F, x, r);
end;

procedure Cvtts2si(r, x: longint; single: boolean);
begin
  OpR(RealPfx[single], true, $2C0F, r, x);
end;

procedure Btc(r, bit: longint);
begin
  OpR(0, true, $BA0F, 7, r);
  Put1(bit);
end;

{ Jumps. A label not yet placed is the chain of the jumps to it, each
  rel32 field holding the position of the one before, NoLabel ending
  it. Placing the label walks the chain and patches each. }

procedure Jmp(var L: longint);
begin
  Put1($E9);
  Put4(L);
  L := pc - 4;
end;

procedure Jcc(cc: longint; var L: longint);
begin
  Put1($0F); Put1($80 + cc);
  Put4(L);
  L := pc - 4;
end;

procedure JmpBack(target: longint);
begin
  Put1($E9);
  Put4(target - (pc + 4));
end;

procedure JccBack(cc, target: longint);
begin
  Put1($0F); Put1($80 + cc);
  Put4(target - (pc + 4));
end;

procedure FixLinkTo(L, target: longint);
var next: longint;
begin
  if L <> NoLabel then labelAt := target;
  while L <> NoLabel do begin
    next := Get4At(L);
    Put4At(L, target - (L + 4));
    L := next;
  end;
end;

procedure FixLink(L: longint);
begin
  FixLinkTo(L, pc);
end;

end.
