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
  R8 = 8; R9 = 9; R10 = 10; R11 = 11; R12 = 12; R13 = 13; R14 = 14; R15 = 15;
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
  listing: boolean;   { -S: each instruction's text is kept, for List }

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
procedure AluMI(op: longint; m: TMem; v, size: longint);
procedure StoreI(m: TMem; v, size: longint);
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
procedure Align(n: longint);
procedure RepMovsb;
procedure Std;
procedure Cld;
procedure RepStosb;
procedure RepeCmpsb;
procedure LockCmpxchg(const m: TMem; r: longint);
procedure Xchg(const m: TMem; r: longint);
procedure LockXadd(const m: TMem; r: longint);
procedure MovqXR(x, r: longint);
procedure MovqRX(r, x: longint);
procedure MovX(x, y: longint);
{ The real instructions take single: F32 (ss) rather than F64 (sd) }
procedure MovsXM(x: longint; const m: TMem; single: boolean);
procedure MovsMX(const m: TMem; x: longint; single: boolean);
procedure Sse(op, x, y: longint; single: boolean);   { 58 add, 59 mul, 5C sub, 5E div, 5A convert }
procedure SseM(op, x: longint; const m: TMem; single: boolean);
procedure Ucomis(x, y: longint; single: boolean);
procedure Cvtsi2s(x, r: longint; single: boolean);
procedure Cvtts2si(r, x: longint; single: boolean);
procedure Btc(r, bit: longint);

procedure Jmp(var L: longint);
procedure Jcc(cc: longint; var L: longint);
procedure JmpBack(target: longint);
procedure JccBack(cc, target: longint);
procedure FixLink(L: longint);
procedure DropJumpTo(var L: longint);
procedure FixLinkTo(L, target: longint);
function JoinLinks(L1, L2: longint): longint;

type
  { The parser's reader of an integer constant in a code procedure: a
    whole expression, or, when whole is false, a single factor }
  TConstFn = function(whole: boolean): int64;

const
  RegNames: array[0..3, 0..15] of string[5] = (
    ('rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
     'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'),
    ('eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi',
     'r8d', 'r9d', 'r10d', 'r11d', 'r12d', 'r13d', 'r14d', 'r15d'),
    ('ax', 'cx', 'dx', 'bx', 'sp', 'bp', 'si', 'di',
     'r8w', 'r9w', 'r10w', 'r11w', 'r12w', 'r13w', 'r14w', 'r15w'),
    ('al', 'cl', 'dl', 'bl', 'spl', 'bpl', 'sil', 'dil',
     'r8b', 'r9b', 'r10b', 'r11b', 'r12b', 'r13b', 'r14b', 'r15b'));
  CondNames: array[0..15] of string[3] = ('o', 'no', 'b', 'ae', 'e', 'ne',
    'be', 'a', 's', 'ns', 'p', 'np', 'l', 'ge', 'le', 'g');

procedure Assemble(constExpr: TConstFn);
procedure Say(const s: shortstring);
function SaidCount: longint;
procedure Unsay(n: longint);
procedure Restate(at: longint; const s: shortstring);
procedure List(module: longint);

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

{ The legacy prefix pfx, if any, and REX: wide is REX.W; byte4 says
  a byte register of 4 to 7 is used, spl to dil, which exist only with
  a REX prefix. }
procedure Prefix(pfx: longint; w: boolean; reg, index, base: longint; byte4: boolean);
var rex: longint;
begin
  if pfx <> 0 then Put1(pfx);
  rex := 0;
  if w then rex := rex or 8;
  if reg >= 8 then rex := rex or 4;
  if index >= 8 then rex := rex or 2;
  if base >= 8 then rex := rex or 1;
  if (rex <> 0) or byte4 then Put1($40 or rex);
end;

{ op reg, [mem] }
procedure OpM(pfx: longint; w: boolean; op, reg: longint; const m: TMem; byteReg: boolean = false);
var md, b, sc: longint;
begin
  byteReg := byteReg and (reg >= 4) and (reg <= 7);
  if m.base = RIP then Prefix(pfx, w, reg, NoIndex, 0, byteReg)
  else Prefix(pfx, w, reg, m.index, m.base, byteReg);
  Opcode(op);
  reg := reg and 7;
  if m.base = RIP then begin
    Put1(reg shl 3 or 5);
    { mod 00 with r/m 101 is rip + disp32. The displacement counts
      from the end of the instruction, and the fixup takes it to end
      with these four bytes: an instruction with an immediate after
      them, AluMI's or StoreI's, takes the immediate's size off disp
      first (the assembler can't name a chunk). }
    AddFixup(pc, m.chunk, m.disp);
    Put4(0);
    exit;
  end;
  b := m.base and 7;
  { mod 00 takes no displacement, but with r/m 101 (RBP or R13) it means
    rip-relative, or disp32 under a SIB byte, so those bases take a
    zero disp8 }
  if (m.disp = 0) and (b <> RBP) then md := 0
  else if (m.disp >= -128) and (m.disp <= 127) then md := 1
  else md := 2;
  { r/m 100 (RSP or R12) means a SIB byte follows, so those bases need
    one, with index 100 meaning none }
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
procedure OpR(pfx: longint; w: boolean; op, reg, rm: longint; byteReg: boolean = false);
begin
  Prefix(pfx, w, reg, NoIndex, rm, byteReg and ((reg in [4..7]) or (rm in [4..7])));
  Opcode(op);
  Put1($C0 or (reg and 7) shl 3 or (rm and 7));
end;

{ The listing: the text of each instruction, as it is made }

type
  TSaid = record
    at: longint;          { where the instruction starts in code }
    text: string[63];
  end;

var
  said: ^TSaid;
  numSaid, saidCap: longint;

{ How many instructions the listing has, and back to n of them, for
  code made again }
function SaidCount: longint;
begin
  SaidCount := numSaid;
end;

procedure Unsay(n: longint);
begin
  numSaid := n;
end;

procedure SayAt(at: longint; const s: shortstring);
begin
  if not listing then exit;
  if numSaid = saidCap then begin
    saidCap := saidCap * 2 + 1024;
    said := ReAllocMem(said, saidCap * SizeOf(TSaid));
  end;
  said[numSaid].at := at;
  said[numSaid].text := s;
  inc(numSaid);
end;

{ The text of the instruction about to be written }
procedure Say(const s: shortstring);
begin
  SayAt(pc, s);
end;

{ The text of the instruction at at, said again, as when its operand is
  patched }
procedure Restate(at: longint; const s: shortstring);
var i: longint;
begin
  i := numSaid - 1;
  while (i >= 0) and (said[i].at <> at) do dec(i);
  if i >= 0 then said[i].text := s;
end;

function RN(r: longint; size: longint = 8): shortstring;
begin
  case size of
    1: RN := RegNames[3, r];
    2: RN := RegNames[2, r];
    4: RN := RegNames[1, r];
  else RN := RegNames[0, r];
  end;
end;

function XN(x: longint): shortstring;
begin
  XN := 'xmm' + IntStr(x);
end;

{ A memory operand, with the size of what it holds, as the assembler
  reads it }
function MN(const m: TMem; size: longint = 0): shortstring;
var s: shortstring;
begin
  case size of
    1: s := 'byte ';
    2: s := 'word ';
    4: s := 'dword ';
    8: s := 'qword ';
  else s := '';
  end;
  if m.base = RIP then s := s + '[' + ChunkName(m.chunk)
  else s := s + '[' + RN(m.base);
  if m.index <> NoIndex then s := s + ' + ' + RN(m.index) + ' * ' + IntStr(m.scale);
  if m.disp > 0 then s := s + ' + ' + IntStr(m.disp)
  else if m.disp < 0 then s := s + ' - ' + IntStr(-m.disp);
  MN := s + ']';
end;

const
  AluNames: array[0..7] of string[3] = ('add', 'or', 'adc', 'sbb', 'and', 'sub', 'xor', 'cmp');
  ShiftNames: array[0..7] of string[3] = ('rol', 'ror', 'rcl', 'rcr', 'shl', 'shr', 'sal', 'sar');
  UnaryNames: array[2..7] of string[4] = ('not', 'neg', 'mul', 'imul', 'div', 'idiv');

procedure MovRR(dst, src: longint);
begin
  if listing then Say('mov ' + RN(dst) + ', ' + RN(src));
  OpR(0, true, $89, src, dst);
end;

{ The immediate of n bytes that ends an instruction }
procedure PutImm(v, n: longint);
begin
  if n = 4 then Put4(v)
  else begin
    Put1(v and $FF);
    if n = 2 then Put1((v shr 8) and $FF);
  end;
end;

{ op [m], v, on size bytes; v fits in them, or in 32 bits for 8 }
procedure AluMI(op: longint; m: TMem; v, size: longint);
var n: longint;
begin
  if listing then Say(AluNames[op] + ' ' + MN(m, size) + ', ' + IntStr(v));
  if (size = 1) or (v >= -128) and (v <= 127) then n := 1
  else if size = 2 then n := 2
  else n := 4;
  if m.base = RIP then dec(m.disp, n);
  if size = 1 then OpM(0, false, $80, op, m)
  else if n = 1 then OpM(ord(size = 2) * $66, size = 8, $83, op, m)
  else OpM(ord(size = 2) * $66, size = 8, $81, op, m);
  PutImm(v, n);
end;

{ mov [m], v, of size bytes; v fits in them, or in 32 bits for 8 }
procedure StoreI(m: TMem; v, size: longint);
var n: longint;
begin
  if listing then Say('mov ' + MN(m, size) + ', ' + IntStr(v));
  n := size;
  if n > 4 then n := 4;
  if m.base = RIP then dec(m.disp, n);
  if size = 1 then OpM(0, false, $C6, 0, m)
  else OpM(ord(size = 2) * $66, size = 8, $C7, 0, m);
  PutImm(v, n);
end;

procedure MovRI(r: longint; v: int64);
begin
  if not listing then
  else if v = 0 then Say('xor ' + RN(r, 4) + ', ' + RN(r, 4))
  else Say('mov ' + RN(r) + ', ' + IntStr(v));
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
  if not listing then
  else if size = 8 then Say('mov ' + RN(r) + ', ' + MN(m))
  else if (size = 4) and not signed then Say('mov ' + RN(r, 4) + ', ' + MN(m))
  else if size = 4 then Say('movsxd ' + RN(r) + ', ' + MN(m, 4))
  else if signed then Say('movsx ' + RN(r) + ', ' + MN(m, size))
  else Say('movzx ' + RN(r, 4) + ', ' + MN(m, size));
  case size of
    1: if signed then OpM(0, true, $BE0F, r, m) else OpM(0, false, $B60F, r, m);
    2: if signed then OpM(0, true, $BF0F, r, m) else OpM(0, false, $B70F, r, m);
    4: if signed then OpM(0, true, $63, r, m) else OpM(0, false, $8B, r, m);
  else OpM(0, true, $8B, r, m);
  end;
end;

procedure Store(const m: TMem; r: longint; size: longint);
begin
  if listing then Say('mov ' + MN(m) + ', ' + RN(r, size));
  case size of
    1: OpM(0, false, $88, r, m, true);
    2: OpM($66, false, $89, r, m);
    4: OpM(0, false, $89, r, m);
  else OpM(0, true, $89, r, m);
  end;
end;

procedure Lea(r: longint; const m: TMem);
begin
  if listing then Say('lea ' + RN(r) + ', ' + MN(m));
  OpM(0, true, $8D, r, m);
end;

procedure Alu(op, dst, src: longint);
begin
  if listing then Say(AluNames[op] + ' ' + RN(dst) + ', ' + RN(src));
  OpR(0, true, op shl 3 or 1, src, dst);
end;

procedure AluI(op, r: longint; v: longint);
begin
  if listing then Say(AluNames[op] + ' ' + RN(r) + ', ' + IntStr(v));
  if (v >= -128) and (v <= 127) then begin
    OpR(0, true, $83, op, r); Put1(v)
  end else begin
    OpR(0, true, $81, op, r); Put4(v)
  end;
end;

{ op r, [m] }
procedure AluM(op, r: longint; const m: TMem);
begin
  if listing then Say(AluNames[op] + ' ' + RN(r) + ', ' + MN(m));
  OpM(0, true, op shl 3 or 3, r, m);
end;

procedure Imul(dst, src: longint);
begin
  if listing then Say('imul ' + RN(dst) + ', ' + RN(src));
  OpR(0, true, $AF0F, dst, src);
end;

procedure ImulI(r: longint; v: longint);
begin
  if listing then Say('imul ' + RN(r) + ', ' + RN(r) + ', ' + IntStr(v));
  OpR(0, true, $69, r, r);
  Put4(v);
end;

procedure Shift(op, r: longint);
begin
  if listing then Say(ShiftNames[op] + ' ' + RN(r) + ', cl');
  OpR(0, true, $D3, op, r);
end;

procedure ShiftI(op, r, n: longint);
begin
  if listing then Say(ShiftNames[op] + ' ' + RN(r) + ', ' + IntStr(n));
  OpR(0, true, $C1, op, r);
  Put1(n);
end;

procedure Unary(ext, r: longint);
begin
  if listing then Say(UnaryNames[ext] + ' ' + RN(r));
  OpR(0, true, $F7, ext, r);
end;

procedure Cqo;
begin
  if listing then Say('cqo');
  Put1($48); Put1($99);
end;

{ Brings a value of size bytes in r to 64 bits, by its sign or zeros. }
procedure Extend(r, size: longint; signed: boolean);
begin
  if not listing then
  else if size = 4 then begin
    if signed then Say('movsxd ' + RN(r) + ', ' + RN(r, 4)) else Say('mov ' + RN(r, 4) + ', ' + RN(r, 4))
  end else if signed then Say('movsx ' + RN(r) + ', ' + RN(r, size))
  else Say('movzx ' + RN(r, 4) + ', ' + RN(r, size));
  case size of
    1: if signed then OpR(0, true, $BE0F, r, r, true) else OpR(0, false, $B60F, r, r, true);
    2: if signed then OpR(0, true, $BF0F, r, r) else OpR(0, false, $B70F, r, r);
    4: if signed then OpR(0, true, $63, r, r) else OpR(0, false, $89, r, r);
  end;
end;

{ r := 1 if the condition holds, else 0 }
procedure SetCC(cc, r: longint);
begin
  if listing then Say('set' + CondNames[cc] + ' ' + RN(r, 1));
  OpR(0, false, $900F + cc shl 8, 0, r, true);
  if listing then Say('movzx ' + RN(r, 4) + ', ' + RN(r, 1));
  OpR(0, false, $B60F, r, r, true);
end;

procedure TestRR(a, b: longint);
begin
  if listing then Say('test ' + RN(a) + ', ' + RN(b));
  OpR(0, true, $85, b, a);
end;

procedure Push(r: longint);
begin
  if listing then Say('push ' + RN(r));
  if r >= 8 then Put1($41);
  Put1($50 + r and 7);
end;

procedure Pop(r: longint);
begin
  if listing then Say('pop ' + RN(r));
  if r >= 8 then Put1($41);
  Put1($58 + r and 7);
end;

procedure CallChunk(c: longint);
begin
  if listing then Say('call ' + ChunkName(c));
  Put1($E8);
  AddFixup(pc, c, 0);
  Put4(0);
end;

procedure CallBack(target: longint);
begin
  if listing then Say('call');
  Put1($E8);
  Put4(target - (pc + 4));
end;

procedure CallR(r: longint);
begin
  if listing then Say('call ' + RN(r));
  OpR(0, false, $FF, 2, r);
end;

procedure CallM(const m: TMem);
begin
  if listing then Say('call ' + MN(m));
  OpM(0, false, $FF, 2, m);
end;

procedure Ret; begin if listing then Say('ret'); Put1($C3) end;
procedure Leave; begin Say('leave'); Put1($C9) end;
procedure Syscall; begin Say('syscall'); Put1($0F); Put1($05) end;
procedure Mfence; begin Say('mfence'); Put1($0F); Put1($AE); Put1($F0) end;
procedure Ud2; begin Say('ud2'); Put1($0F); Put1($0B) end;

{ Code made up to a multiple of n bytes with no-ops, the fewest: the
  long forms of nop, of up to 8 bytes, that x86 decodes as one }
procedure Align(n: longint);
const
  Nops: array[1..8] of string[8] = (#$90, #$66#$90, #$0F#$1F#$00, #$0F#$1F#$40#$00,
    #$0F#$1F#$44#$00#$00, #$66#$0F#$1F#$44#$00#$00, #$0F#$1F#$80#$00#$00#$00#$00,
    #$0F#$1F#$84#$00#$00#$00#$00#$00);
var k, i: longint;
begin
  while pc mod n <> 0 do begin
    k := n - pc mod n;
    if k > 8 then k := 8;
    Say('nop');
    for i := 1 to k do Put1(ord(Nops[k][i]));
  end;
end;
procedure RepMovsb; begin Say('rep movsb'); Put1($F3); Put1($A4) end;
{ the direction flag, which has rep movsb go down, and back up }
procedure Std; begin Say('std'); Put1($FD) end;
procedure Cld; begin Say('cld'); Put1($FC) end;
procedure RepStosb; begin Say('rep stosb'); Put1($F3); Put1($AA) end;
procedure RepeCmpsb; begin Say('repe cmpsb'); Put1($F3); Put1($A6) end;

procedure LockCmpxchg(const m: TMem; r: longint);
begin
  if listing then Say('lock cmpxchg ' + MN(m) + ', ' + RN(r));
  Put1($F0);
  OpM(0, true, $B10F, r, m);
end;

procedure Xchg(const m: TMem; r: longint);
begin
  if listing then Say('xchg ' + MN(m) + ', ' + RN(r));
  OpM(0, true, $87, r, m);
end;

procedure LockXadd(const m: TMem; r: longint);
begin
  if listing then Say('lock xadd ' + MN(m) + ', ' + RN(r));
  Put1($F0);
  OpM(0, true, $C10F, r, m);
end;

procedure MovqXR(x, r: longint);
begin
  if listing then Say('movq ' + XN(x) + ', ' + RN(r));
  OpR($66, true, $6E0F, x, r);
end;

procedure MovqRX(r, x: longint);
begin
  if listing then Say('movq ' + RN(r) + ', ' + XN(x));
  OpR($66, true, $7E0F, x, r);
end;

{ movaps: all of xmm y to xmm x, the shortest move between two }
procedure MovX(x, y: longint);
begin
  if listing then Say('movaps ' + XN(x) + ', ' + XN(y));
  OpR(0, false, $280F, x, y);
end;

const
  RealPfx: array[boolean] of longint = ($F2, $F3);
  RealEnd: array[boolean] of string[2] = ('sd', 'ss');

procedure MovsXM(x: longint; const m: TMem; single: boolean);
begin
  if listing then Say('movs' + RealEnd[single][2] + ' ' + XN(x) + ', ' + MN(m));
  OpM(RealPfx[single], false, $100F, x, m);
end;

procedure MovsMX(const m: TMem; x: longint; single: boolean);
begin
  if listing then Say('movs' + RealEnd[single][2] + ' ' + MN(m) + ', ' + XN(x));
  OpM(RealPfx[single], false, $110F, x, m);
end;

function SseName(op: longint; single: boolean): shortstring;
begin
  case op of
    $58: SseName := 'add' + RealEnd[single];
    $59: SseName := 'mul' + RealEnd[single];
    $5C: SseName := 'sub' + RealEnd[single];
    $5E: SseName := 'div' + RealEnd[single];
  else SseName := 'cvt' + RealEnd[single] + '2' + RealEnd[not single];
  end;
end;

procedure Sse(op, x, y: longint; single: boolean);
begin
  if listing then Say(SseName(op, single) + ' ' + XN(x) + ', ' + XN(y));
  OpR(RealPfx[single], false, $0F or op shl 8, x, y);
end;

{ The same, its right operand in memory: addsd x, [m] }
procedure SseM(op, x: longint; const m: TMem; single: boolean);
begin
  if listing then Say(SseName(op, single) + ' ' + XN(x) + ', ' + MN(m));
  OpM(RealPfx[single], false, $0F or op shl 8, x, m);
end;

procedure Ucomis(x, y: longint; single: boolean);
begin
  if listing then Say('ucomi' + RealEnd[single] + ' ' + XN(x) + ', ' + XN(y));
  if single then OpR(0, false, $2E0F, x, y) else OpR($66, false, $2E0F, x, y);
end;

procedure Cvtsi2s(x, r: longint; single: boolean);
begin
  if listing then Say('cvtsi2' + RealEnd[single] + ' ' + XN(x) + ', ' + RN(r));
  OpR(RealPfx[single], true, $2A0F, x, r);
end;

procedure Cvtts2si(r, x: longint; single: boolean);
begin
  if listing then Say('cvtt' + RealEnd[single] + '2si ' + RN(r) + ', ' + XN(x));
  OpR(RealPfx[single], true, $2C0F, r, x);
end;

procedure Btc(r, bit: longint);
begin
  if listing then Say('btc ' + RN(r) + ', ' + IntStr(bit));
  OpR(0, true, $BA0F, 7, r);
  Put1(bit);
end;

{ Jumps. A label not yet placed is the chain of the jumps to it, each
  rel32 field holding the position of the one before, NoLabel ending
  it. Placing the label walks the chain and patches each. }

procedure Jmp(var L: longint);
begin
  if listing then Say('jmp');
  Put1($E9);
  Put4(L);
  L := pc - 4;
end;

procedure Jcc(cc: longint; var L: longint);
begin
  if listing then Say('j' + CondNames[cc]);
  Put1($0F); Put1($80 + cc);
  Put4(L);
  L := pc - 4;
end;

procedure JmpBack(target: longint);
begin
  if listing then Say('jmp');
  Put1($E9);
  Put4(target - (pc + 4));
end;

procedure JccBack(cc, target: longint);
begin
  if listing then Say('j' + CondNames[cc]);
  Put1($0F); Put1($80 + cc);
  Put4(target - (pc + 4));
end;

procedure FixLinkTo(L, target: longint);
var next: longint;
begin
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

{ If the last instruction made is a jmp to L, it is taken back, since L
  is to be placed just after it: a return at the end of a procedure
  needn't jump to the code that returns. L is the place of the latest
  jump's 4-byte field, so the last instruction is that jump when L is
  4 bytes back and an E9 byte (jmp) is before it; a jcc's field follows
  the bytes 0F 8x, never E9. L then becomes the next jump on the chain,
  which the field held. The caller must place L next, before anything
  can have noted where the jmp ended. }
procedure DropJumpTo(var L: longint);
begin
  if (L = NoLabel) or (L <> pc - 4) or (code^[L - 1] <> $E9) then exit;
  L := Get4At(L);
  TakeBack(5);
  if listing and (numSaid > 0) and (said[numSaid - 1].at = pc) then dec(numSaid);
end;

{ The jumps of chains L1 and L2, as one chain: each jump's field holds
  the next one's place until it is fixed, the last NoLabel }
function JoinLinks(L1, L2: longint): longint;
var L: longint;
begin
  if L2 = NoLabel then exit(L1);
  if L1 <> NoLabel then begin
    L := L2;
    while Get4At(L) <> NoLabel do L := Get4At(L);
    Put4At(L, L1);
  end;
  JoinLinks := L2;
end;


{ The assembler, for code procedures: x86-64 in Intel's syntax as NASM
  writes it (report, appendix A). It reads instructions with the
  scanner up to end, and encodes them with OpM and OpR; constants are
  read by the parser's constExpr. }

const
  NoBase = -3;   { a memory operand's base, not yet read }

type
  TOpKind = (oReg, oXmm, oMem, oImm);
  TOpd = record
    kind: TOpKind;
    r, size: longint;   { oReg, oXmm: the register and its size; oMem: its size, or 0 }
    m: TMem;
    v: int64;           { oImm }
  end;

{ The current symbol as a word: an identifier, or a reserved word that
  is also an instruction }
function AsmWord: shortstring;
begin
  case tok of
    sIdent: AsmWord := NameOf(id);
    sAnd: AsmWord := 'and';
    sOr: AsmWord := 'or';
    sXor: AsmWord := 'xor';
    sNot: AsmWord := 'not';
    sDiv: AsmWord := 'div';
    sShl: AsmWord := 'shl';
    sShr: AsmWord := 'shr';
  else AsmWord := '';
  end;
end;

{ Whether w names a register: rax, eax, ax, al and so on, or xmm0 to
  xmm15 (size 16) }
function IsReg(const w: shortstring; var r, size: longint): boolean;
const Sizes: array[0..3] of longint = (8, 4, 2, 1);
var i, j, e: longint;
begin
  IsReg := true;
  for i := 0 to 3 do
    for j := 0 to 15 do
      if RegNames[i, j] = w then begin r := j; size := Sizes[i]; exit end;
  size := 16;
  Val(copy(w, 4, 2), r, e);
  IsReg := (copy(w, 1, 3) = 'xmm') and (length(w) > 3) and (e = 0) and (r in [0..15]);
end;

{ Which word of list, a list of words each with a space either side,
  w is, from 0; -1 if none }
function WordIndex(const w, list: shortstring): longint;
var i, k: longint;
begin
  k := pos(' ' + w + ' ', list);
  WordIndex := -1;
  if k = 0 then exit;
  WordIndex := 0;
  for i := 2 to k do if list[i] = ' ' then inc(WordIndex);
end;

{ The condition a name ends in: e of je, nz of jnz }
function Cond(const w: shortstring): longint;
const
  Alias: array[0..11] of string[3] = ('c', 'nae', 'nc', 'nb', 'z', 'nz', 'na', 'nbe', 'nge', 'nl', 'ng', 'nle');
  AliasCc: array[0..11] of longint = (2, 2, 3, 3, 4, 5, 6, 7, 12, 13, 14, 15);
var i: longint;
begin
  for i := 0 to 15 do if CondNames[i] = w then exit(i);
  for i := 0 to 11 do if Alias[i] = w then exit(AliasCc[i]);
  Cond := -1;
end;

procedure Operand(var o: TOpd; constExpr: TConstFn);
var w: shortstring; r, size, sz: longint; st: TScanState;
begin
  FillChar(o, SizeOf(o), 0);
  w := AsmWord;
  sz := 0;
  if w = 'byte' then sz := 1 else if w = 'word' then sz := 2
  else if w = 'dword' then sz := 4 else if w = 'qword' then sz := 8;
  if sz <> 0 then begin Next; w := AsmWord end;
  if tok = sLbrak then begin
    { [base + index * scale + disp], the displacement last }
    Next;
    o.kind := oMem; o.size := sz;
    o.m := Mem(NoBase, 0);
    repeat
      if IsReg(AsmWord, r, size) and (size = 8) then begin
        Next;
        { the scale is a single number or constant: a whole expression
          would take in the displacement after it, as 4 + 16 in
          [rdi + rsi * 4 + 16] }
        if tok = sTimes then begin
          Next;
          o.m.index := r;
          o.m.scale := constExpr(false);
        end
        else if o.m.base = NoBase then o.m.base := r
        else begin o.m.index := r; o.m.scale := 1 end;
      end else o.m.disp := o.m.disp + constExpr(true);
      if not (tok in [sPlus, sMinus]) then break;
      SaveScan(st);
      Next;
      if not IsReg(AsmWord, r, size) and (st.tok = sMinus) then RestoreScan(st);
    until false;
    if (tok <> sRbrak) or (o.m.base = NoBase) or not (o.m.scale in [1, 2, 4, 8]) then
      Mark('expected a memory operand, [base + index * scale + disp]');
    Next;
  end else if IsReg(w, o.r, o.size) then begin
    if o.size = 16 then o.kind := oXmm else o.kind := oReg;
    Next;
  end else begin
    o.kind := oImm;
    o.v := constExpr(true);
  end;
end;

{ op with register reg and the register or memory operand o }
procedure RM(pfx: longint; w: boolean; op, reg: longint; const o: TOpd; byteReg: boolean = false);
begin
  if o.kind = oMem then OpM(pfx, w, op, reg, o.m, byteReg)
  else OpR(pfx, w, op, reg, o.r, byteReg);
end;

procedure PutImm(v: int64; size: longint);
begin
  case size of
    1: Put1(v);
    2: begin Put1(v); Put1(v shr 8) end;
  else Put4(v);
  end;
end;

procedure Assemble(constExpr: TConstFn);
const
  Alus = ' add or adc sbb and sub xor cmp ';
  Unaries = ' not neg mul imul div idiv ';
  Shifts = ' rol ror rcl rcr shl shr sal sar ';
  SseOps = ' sqrt add mul sub min div max ';
  SseCodes: array[0..6] of longint = ($51, $58, $59, $5C, $5D, $5E, $5F);
  { SSE2 integer instructions that work on 16 bytes at a time: 66 0F code,
    xmm and xmm or memory (pshufd also takes a byte) }
  PackedOps = ' punpcklbw punpcklwd pcmpeqb pshufd pand pandn por pxor paddb psubb ';
  PackedCodes: array[0..9] of longint = ($60, $61, $74, $70, $DB, $DF, $EB, $EF, $FC, $F8);
  { bit scans and counts: reg, reg or memory, with the prefix and code that tell them }
  BitOps = ' bsf bsr tzcnt lzcnt popcnt ';
  BitPfx: array[0..4] of longint = (0, 0, $F3, $F3, $F3);
  BitCodes: array[0..4] of longint = ($BC0F, $BD0F, $BC0F, $BD0F, $B80F);
  Plain: array[0..14] of string[7] = ('ret', 'leave', 'syscall', 'cpuid', 'rdtsc',
    'pause', 'nop', 'ud2', 'int3', 'hlt', 'cqo', 'cdq', 'mfence', 'lfence', 'sfence');
  PlainOp: array[0..14] of longint = ($C3, $C9, $050F, $A20F, $310F,
    $90F3, $90, $0B0F, $CC, $F4, $9948, $99, $F0AE0F, $E8AE0F, $F8AE0F);
var
  w: shortstring; o: array[0..2] of TOpd; n, i, k, size, pfx, cc: longint;
  wide, byteOp, wasListing: boolean; at, start: TPos; v: int64; first: longint;
  names, places, chains: array[0..63] of longint; numLabels: longint;
  usedAt: array[0..63] of TPos;

  { the label called n, entered if new }
  function Lab(n: longint): longint;
  var i: longint;
  begin
    for i := 0 to numLabels - 1 do if names[i] = n then exit(i);
    if numLabels > High(names) then Mark('more than 64 labels');
    names[numLabels] := n; places[numLabels] := -1; chains[numLabels] := NoLabel;
    usedAt[numLabels] := TokPos;
    Lab := numLabels;
    inc(numLabels);
  end;

  procedure Bad;
  begin
    MarkAt(at, 'can''t assemble ' + w + ' with these operands');
  end;

  { an instruction of two operands: a register or memory, and a
    register (opcode toRM), the other way (fromRM), or an immediate
    (opImm /digit, or none if opImm < 0) }
  procedure Two(toRM, fromRM, opImm, digit: longint);
  begin
    if n <> 2 then Bad;
    if o[1].kind = oImm then begin
      if (o[0].kind = oImm) or (opImm < 0) then Bad;
      if (opImm = $81) and not byteOp and (o[1].v >= -128) and (o[1].v <= 127) then begin
        RM(pfx, wide, $83, digit, o[0]);   { a byte, sign-extended }
        Put1(o[1].v);
      end else begin
        RM(pfx, wide, opImm - ord(byteOp), digit, o[0]);
        PutImm(o[1].v, size);
      end;
    end else if (o[1].kind = oReg) and (o[0].kind in [oReg, oMem]) then
      RM(pfx, wide, toRM - ord(byteOp), o[1].r, o[0], byteOp)
    else if (o[0].kind = oReg) and (o[1].kind = oMem) then
      RM(pfx, wide, fromRM - ord(byteOp), o[0].r, o[1], byteOp)
    else Bad;
  end;

begin
  numLabels := 0;
  while not (tok in [sEnd, sEof]) do begin
    at := TokPos;
    w := AsmWord;
    if tok = sSemicolon then begin Next; continue end;
    if w = '' then Mark('expected an instruction');
    Next;
    if tok = sColon then begin
      SayAt(pc, w + ':');
      k := Lab(Intern(@w[1], length(w)));
      if places[k] >= 0 then MarkAt(at, 'label ' + w + ' is defined twice');
      places[k] := pc;
      FixLink(chains[k]);
      Next;
      continue;
    end;
    first := pc;
    wasListing := listing;
    listing := false;   { the instruction is said as it is written }
    if w = 'lock' then begin
      Put1($F0);
      w := AsmWord;
      Next;
    end;
    cc := -1;
    if w = 'db' then
      repeat
        start := TokPos;
        v := constExpr(true);
        if (v < -128) or (v > 255) then MarkAt(SpanFrom(start), 'expected a byte from 0 to 255, found ' + IntStr(v));
        Put1(v);
        if tok <> sComma then break;
        Next;
      until false
    else if (w[1] = 'j') and ((w = 'jmp') or (Cond(copy(w, 2, 3)) >= 0)) and (tok = sIdent) then begin
      { a jump to a label }
      k := Lab(id);
      Next;
      if w <> 'jmp' then cc := Cond(copy(w, 2, 3));
      if places[k] >= 0 then begin
        if cc < 0 then JmpBack(places[k]) else JccBack(cc, places[k])
      end else if cc < 0 then Jmp(chains[k]) else Jcc(cc, chains[k]);
    end else begin
      n := 0;
      if tok <> sSemicolon then
        repeat
          if n > High(o) then Mark('too many operands');
          Operand(o[n], constExpr);
          inc(n);
          if tok <> sComma then break;
          Next;
        until false;
      { the size: a register's, or what the memory operand says }
      size := 8;
      for i := n - 1 downto 0 do
        if (o[i].kind = oReg) or (o[i].kind = oMem) and (o[i].size <> 0) then size := o[i].size;
      if n > 0 then
        if (o[0].kind = oReg) or (o[0].kind = oMem) and (o[0].size <> 0) then size := o[0].size;
      wide := size = 8;
      byteOp := size = 1;
      if size = 2 then pfx := $66 else pfx := 0;
      if WordIndex(w, Alus) >= 0 then begin
        k := WordIndex(w, Alus);
        Two(k * 8 + 1, k * 8 + 3, $81, k)
      end
      else if w = 'mov' then begin
        if (n = 2) and (o[0].kind = oReg) and (o[1].kind = oImm) and (size >= 4) then begin
          if wide then MovRI(o[0].r, o[1].v)
          else begin Prefix(0, false, 0, NoIndex, o[0].r, false); Put1($B8 + o[0].r and 7); Put4(o[1].v) end;
        end else Two($89, $8B, $C7, 0);
      end else if w = 'test' then Two($85, $85, $F7, 0)
      else if w = 'xchg' then Two($87, $87, -1, 0)
      else if (w = 'cmpxchg') or (w = 'xadd') then begin
        if (n <> 2) or (o[1].kind <> oReg) then Bad;
        if w = 'xadd' then k := $C10F else k := $B10F;
        RM(pfx, wide, k - ord(byteOp) shl 8, o[1].r, o[0], byteOp);
      end else if w = 'lea' then begin
        if (n <> 2) or (o[0].kind <> oReg) or (o[1].kind <> oMem) then Bad;
        RM(pfx, wide, $8D, o[0].r, o[1]);
      end else if (w = 'movzx') or (w = 'movsx') or (w = 'movsxd') then begin
        if (n <> 2) or (o[0].kind <> oReg) or (o[1].kind = oImm) then Bad;
        if w = 'movsxd' then k := $63
        else if o[1].size = 1 then k := $B60F
        else if o[1].size = 2 then k := $B70F
        else Bad;
        if w = 'movsx' then k := k + $0800;
        RM(pfx, wide, k, o[0].r, o[1], o[1].size = 1);
      end else if ((WordIndex(w, Unaries) >= 0) and (n = 1)) or (w = 'inc') or (w = 'dec') then begin
        if o[0].kind = oImm then Bad;
        if w = 'inc' then RM(pfx, wide, $FF - ord(byteOp), 0, o[0], byteOp)
        else if w = 'dec' then RM(pfx, wide, $FF - ord(byteOp), 1, o[0], byteOp)
        else RM(pfx, wide, $F7 - ord(byteOp), WordIndex(w, Unaries) + 2, o[0], byteOp);
      end else if w = 'imul' then begin
        if (n < 2) or (o[0].kind <> oReg) or (o[1].kind = oImm) then Bad;
        if n = 2 then RM(pfx, wide, $AF0F, o[0].r, o[1])
        else begin RM(pfx, wide, $69, o[0].r, o[1]); PutImm(o[2].v, size) end;
      end else if WordIndex(w, Shifts) >= 0 then begin
        k := WordIndex(w, Shifts);
        if k = 6 then k := 4;   { sal is shl }
        if (n <> 2) or (o[0].kind = oImm) then Bad;
        if o[1].kind = oImm then begin RM(pfx, wide, $C1 - ord(byteOp), k, o[0], byteOp); Put1(o[1].v) end
        else if (o[1].kind = oReg) and (o[1].r = RCX) and (o[1].size = 1) then RM(pfx, wide, $D3 - ord(byteOp), k, o[0], byteOp)
        else Bad;
      end else if (w = 'push') or (w = 'pop') then begin
        if (n <> 1) or (o[0].kind <> oReg) or not wide then Bad;
        if w = 'push' then Push(o[0].r) else Pop(o[0].r);
      end else if (w = 'call') or (w = 'jmp') then begin
        if (n <> 1) or (o[0].kind = oImm) then Bad;
        if w = 'call' then RM(0, false, $FF, 2, o[0]) else RM(0, false, $FF, 4, o[0]);
      end else if (copy(w, 1, 3) = 'set') and (Cond(copy(w, 4, 3)) >= 0) then begin
        if (n <> 1) or (o[0].kind = oImm) or (size <> 1) then Bad;
        RM(0, false, $900F + Cond(copy(w, 4, 3)) shl 8, 0, o[0], true);
      end else if (copy(w, 1, 4) = 'cmov') and (Cond(copy(w, 5, 3)) >= 0) then begin
        if (n <> 2) or (o[0].kind <> oReg) or (o[1].kind = oImm) then Bad;
        RM(pfx, wide, $400F + Cond(copy(w, 5, 3)) shl 8, o[0].r, o[1]);
      end else if (length(w) > 2) and (WordIndex(copy(w, 1, length(w) - 2), SseOps) >= 0)
        and ((copy(w, length(w) - 1, 2) = 'sd') or (copy(w, length(w) - 1, 2) = 'ss')) then begin
        { sqrtsd, addss and the like: xmm, xmm or memory }
        if (n <> 2) or (o[0].kind <> oXmm) or not (o[1].kind in [oXmm, oMem]) then Bad;
        k := $0F or SseCodes[WordIndex(copy(w, 1, length(w) - 2), SseOps)] shl 8;
        RM(RealPfx[w[length(w)] = 's'], false, k, o[0].r, o[1]);
      end else if WordIndex(w, PackedOps) >= 0 then begin
        if (n < 2) or (o[0].kind <> oXmm) or not (o[1].kind in [oXmm, oMem]) then Bad;
        k := WordIndex(w, PackedOps);
        RM($66, false, $0F or PackedCodes[k] shl 8, o[0].r, o[1]);
        if w = 'pshufd' then begin
          if (n <> 3) or (o[2].kind <> oImm) then Bad;
          Put1(o[2].v);
        end else if n <> 2 then Bad;
      end else if (w = 'movdqu') or (w = 'movdqa') then begin
        { the load is 6F and the store 7F; movdqu is F3, movdqa 66 }
        if w = 'movdqu' then k := $F3 else k := $66;
        if (n = 2) and (o[0].kind = oXmm) and (o[1].kind in [oXmm, oMem]) then RM(k, false, $6F0F, o[0].r, o[1])
        else if (n = 2) and (o[0].kind = oMem) and (o[1].kind = oXmm) then RM(k, false, $7F0F, o[1].r, o[0])
        else Bad;
      end else if w = 'pmovmskb' then begin
        if (n <> 2) or (o[0].kind <> oReg) or (o[1].kind <> oXmm) then Bad;
        RM($66, false, $D70F, o[0].r, o[1]);
      end else if WordIndex(w, BitOps) >= 0 then begin
        if (n <> 2) or (o[0].kind <> oReg) or (o[1].kind = oImm) or (size < 4) then Bad;
        k := WordIndex(w, BitOps);
        RM(BitPfx[k], wide, BitCodes[k], o[0].r, o[1]);
      end else if (w = 'movsd') or (w = 'movss') then begin
        if w = 'movsd' then k := $F2 else k := $F3;
        if (n = 2) and (o[0].kind = oXmm) and (o[1].kind in [oXmm, oMem]) then RM(k, false, $100F, o[0].r, o[1])
        else if (n = 2) and (o[0].kind = oMem) and (o[1].kind = oXmm) then RM(k, false, $110F, o[1].r, o[0])
        else Bad;
      end else if (w = 'movq') or (w = 'movd') then begin
        if (n = 2) and (o[0].kind = oXmm) and (o[1].kind in [oReg, oMem]) then RM($66, w = 'movq', $6E0F, o[0].r, o[1])
        else if (n = 2) and (o[1].kind = oXmm) and (o[0].kind in [oReg, oMem]) then RM($66, w = 'movq', $7E0F, o[1].r, o[0])
        else Bad;
      end else if (w = 'ucomisd') or (w = 'ucomiss') then begin
        if (n <> 2) or (o[0].kind <> oXmm) or not (o[1].kind in [oXmm, oMem]) then Bad;
        if w = 'ucomisd' then RM($66, false, $2E0F, o[0].r, o[1]) else RM(0, false, $2E0F, o[0].r, o[1]);
      end else if (w = 'cvtsi2sd') or (w = 'cvtsi2ss') then begin
        if (n <> 2) or (o[0].kind <> oXmm) or not (o[1].kind in [oReg, oMem]) then Bad;
        RM(RealPfx[w = 'cvtsi2ss'], o[1].size <> 4, $2A0F, o[0].r, o[1]);
      end else if (w = 'cvttsd2si') or (w = 'cvttss2si') then begin
        if (n <> 2) or (o[0].kind <> oReg) or not (o[1].kind in [oXmm, oMem]) then Bad;
        RM(RealPfx[w = 'cvttss2si'], wide, $2C0F, o[0].r, o[1]);
      end else if (w = 'cvtsd2ss') or (w = 'cvtss2sd') then begin
        if (n <> 2) or (o[0].kind <> oXmm) or not (o[1].kind in [oXmm, oMem]) then Bad;
        RM(RealPfx[w = 'cvtss2sd'], false, $5A0F, o[0].r, o[1]);
      end else begin
        k := 0;
        while (k <= High(Plain)) and (Plain[k] <> w) do inc(k);
        if (k > High(Plain)) or (n <> 0) then MarkAt(at, 'unknown instruction ' + w);
        Opcode(PlainOp[k]);
      end;
    end;
    if tok <> sSemicolon then Mark('expected ";"');
    listing := wasListing;
    SayAt(first, Source(SpanFrom(at)));
    Next;
  end;
  for k := 0 to numLabels - 1 do
    if places[k] < 0 then MarkAt(usedAt[k], 'label ' + NameOf(names[k]) + ' isn''t defined');
end;

{ The listing, raz -S: each live procedure of the module in the order
  it was made, each line of source it comes from, and under it the
  instructions made for it, at their offsets in the procedure; a jump
  within it says where to by its offset too. }
procedure List(module: longint);
var order: ^longint; n, i, j, k, c, t, line: longint; text: shortstring;
begin
  order := GetMem(numChunks * SizeOf(longint));
  n := 0;
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and (chunks^[c].sec = secText) and (chunks^[c].module = module) then begin
      i := n;
      while (i > 0) and (chunks^[order[i - 1]].start > chunks^[c].start) do begin
        order[i] := order[i - 1];
        dec(i);
      end;
      order[i] := c;
      inc(n);
    end;
  i := 0; j := 0;
  for k := 0 to n - 1 do begin
    c := order[k];
    writeln;
    writeln(ChunkName(c), ':');
    line := -1;
    while (i < numSaid) and (said[i].at < chunks^[c].start) do inc(i);
    while (i < numSaid) and (said[i].at < chunks^[c].start + chunks^[c].size) do begin
      while (j < numLines) and (lines^[j].at <= said[i].at) do begin
        if (lines^[j].chunk = c) and (lines^[j].line <> line) then begin
          line := lines^[j].line;
          writeln(line: 6, '  ', LineText(NameOf(lines^[j].path), line));
        end;
        inc(j);
      end;
      text := said[i].text;
      t := said[i].at;
      if (text = 'jmp') or (text = 'call') then text := text + ' ' + IntStr(t + 5 + Get4At(t + 1) - chunks^[c].start)
      else if (text[1] = 'j') and (pos(' ', text) = 0) then text := text + ' ' + IntStr(t + 6 + Get4At(t + 2) - chunks^[c].start);
      writeln(t - chunks^[c].start: 14, '  ', text);
      inc(i);
    end;
  end;
  FreeMem(order);
end;

end.
