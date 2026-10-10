{ x64.pas: machine code.

  The code of a program is a set of chunks: one per procedure, module
  variable and string. A chunk's bytes go in one of three sections:
  text (code), rodata (strings), bss (variables, which are all zero).
  A reference from code to another chunk (a call, or a rip-relative
  address) is a fixup, patched once the linker has placed every chunk.
  Jumps within a procedure are patched here, as soon as their target
  is known.

  The encoder writes the instructions the code generator needs, and
  no others. Registers are numbered as the hardware numbers them.

  Depends on: scan, for errors.
  Leaves out: choosing instructions; that is gen.pas. }

unit x64;

{$mode objfpc}{$H-}

interface

uses scan;

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
  TSection = (secText, secRodata, secBss);

  TMem = record
    base: longint;    { a register, or RIP }
    index: longint;   { a register, or NoIndex }
    scale: longint;   { 1, 2, 4 or 8 }
    disp: longint;
    chunk: longint;   { with RIP: the chunk addressed }
  end;

  TChunk = record
    sec: TSection;
    start, size, align: longint;   { in its section's buffer }
    firstFix, numFix: longint;     { its fixups, text chunks only }
    module, name: longint;         { for the symbol table; -1 if none }
    adr: int64;                    { its address, set by the linker }
    live: boolean;                 { reached from the entry point }
    ext: boolean;                  { bss: the address of a C symbol, its name }
  end;

  { A source line whose code starts at a place in text, for gdb }
  TLine = record
    at, chunk: longint;   { the place in text, and its chunk }
    path, line: longint;  { the file's path, interned, and the line }
  end;

  TFixup = record
    at: longint;      { the rel32 field, as an offset in text }
    chunk: longint;   { the chunk it refers to }
    addend: longint;  { added to the chunk's address }
  end;

  PChunks = ^TChunkArray;
  TChunkArray = array[0..MaxInt div SizeOf(TChunk) - 1] of TChunk;
  PLines = ^TLineArray;
  TLineArray = array[0..MaxInt div SizeOf(TLine) - 1] of TLine;
  PFixups = ^TFixupArray;
  TFixupArray = array[0..MaxInt div SizeOf(TFixup) - 1] of TFixup;

var
  code: PBytes;      { text }
  pc: longint;       { its length }
  rodata: PBytes;
  rolen: longint;
  chunks: PChunks;
  numChunks: longint;
  fixups: PFixups;
  numFixups: longint;
  lines: PLines;
  numLines: longint;
  curFile: longint;   { the file being compiled, for NoteLine }
  labelAt: longint;   { the last place a jump was made to land }

function NewChunk(sec: TSection; module, name: longint): longint;
procedure BeginChunk(c: longint);
procedure EndChunk(c: longint);
procedure SetData(c: longint; p: PBytes; n, align: longint);
procedure SetBss(c: longint; size, align: longint);
function ExternChunk(name: longint): longint;
procedure NoteLine(line: longint);

procedure Put1(b: longint);
procedure Put4(v: longint);
procedure Put4At(at, v: longint);
function Get4At(at: longint): longint;

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

var
  codeCap, roCap, chunkCap, fixCap, lineCap: longint;
  curChunk: longint;

{ Buffers and chunks }

procedure Room(n: longint);
begin
  if pc + n > codeCap then begin
    codeCap := codeCap * 2 + n;
    code := ReAllocMem(code, codeCap);
  end;
end;

procedure Put1(b: longint);
begin
  if pc + 16 > codeCap then Room(16);
  code^[pc] := byte(b);
  inc(pc);
end;

procedure Put4(v: longint);
begin
  if pc + 16 > codeCap then Room(16);
  PLongint(@code^[pc])^ := v;
  inc(pc, 4);
end;

procedure Put4At(at, v: longint);
begin
  PLongint(@code^[at])^ := v;
end;

function Get4At(at: longint): longint;
begin
  Get4At := PLongint(@code^[at])^;
end;

procedure Put8(v: int64);
begin
  Put4(longint(v and $FFFFFFFF));
  Put4(longint(v shr 32));
end;

function NewChunk(sec: TSection; module, name: longint): longint;
begin
  if numChunks = chunkCap then begin
    chunkCap := chunkCap * 2;
    chunks := ReAllocMem(chunks, chunkCap * SizeOf(TChunk));
  end;
  FillChar(chunks^[numChunks], SizeOf(TChunk), 0);
  chunks^[numChunks].sec := sec;
  chunks^[numChunks].module := module;
  chunks^[numChunks].name := name;
  chunks^[numChunks].align := 1;
  chunks^[numChunks].size := -1;   { not yet defined }
  NewChunk := numChunks;
  inc(numChunks);
end;

procedure BeginChunk(c: longint);
begin
  { code is aligned to 16 bytes, padded with int3 }
  while pc and 15 <> 0 do Put1($CC);
  curChunk := c;
  chunks^[c].start := pc;
  chunks^[c].align := 16;
  chunks^[c].firstFix := numFixups;
end;

procedure EndChunk(c: longint);
begin
  chunks^[c].size := pc - chunks^[c].start;
  chunks^[c].numFix := numFixups - chunks^[c].firstFix;
end;

procedure SetData(c: longint; p: PBytes; n, align: longint);
begin
  if rolen + n > roCap then begin
    roCap := roCap * 2 + n;
    rodata := ReAllocMem(rodata, roCap);
  end;
  Move(p^, rodata^[rolen], n);
  chunks^[c].start := rolen;
  chunks^[c].size := n;
  chunks^[c].align := align;
  inc(rolen, n);
end;

procedure SetBss(c: longint; size, align: longint);
begin
  chunks^[c].size := size;
  chunks^[c].align := align;
end;

{ The code from here on is for line of the current file. A line with
  no code of its own gives way to the next. }
procedure NoteLine(line: longint);
begin
  if (numLines > 0) and (lines^[numLines - 1].at = pc) then dec(numLines);
  if (numLines > 0) and (lines^[numLines - 1].chunk = curChunk)
    and (lines^[numLines - 1].line = line) and (lines^[numLines - 1].path = curFile) then exit;
  if numLines = lineCap then begin
    lineCap := lineCap * 2;
    lines := ReAllocMem(lines, lineCap * SizeOf(TLine));
  end;
  lines^[numLines].at := pc;
  lines^[numLines].chunk := curChunk;
  lines^[numLines].path := curFile;
  lines^[numLines].line := line;
  inc(numLines);
end;

{ The quadword that holds the address of C's symbol name, filled in
  when the program starts; one for each name. }
function ExternChunk(name: longint): longint;
var c: longint;
begin
  for c := 0 to numChunks - 1 do
    if chunks^[c].ext and (chunks^[c].name = name) then exit(c);
  c := NewChunk(secBss, -1, name);
  SetBss(c, 8, 8);
  chunks^[c].ext := true;
  ExternChunk := c;
end;

procedure AddFixup(at, chunk, addend: longint);
begin
  if numFixups = fixCap then begin
    fixCap := fixCap * 2;
    fixups := ReAllocMem(fixups, fixCap * SizeOf(TFixup));
  end;
  fixups^[numFixups].at := at;
  fixups^[numFixups].chunk := chunk;
  fixups^[numFixups].addend := addend;
  inc(numFixups);
end;

{ Operands }

function Mem(base: longint; disp: int64): TMem;
begin
  if (disp < low(longint)) or (disp > high(longint)) then Mark('offset too big');
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

initialization
  codeCap := 1 shl 20;
  code := GetMem(codeCap);
  pc := 0;
  roCap := 1 shl 16;
  rodata := GetMem(roCap);
  rolen := 0;
  chunkCap := 1 shl 10;
  chunks := GetMem(chunkCap * SizeOf(TChunk));
  numChunks := 0;
  fixCap := 1 shl 12;
  fixups := GetMem(fixCap * SizeOf(TFixup));
  numFixups := 0;
  lineCap := 1 shl 12;
  lines := GetMem(lineCap * SizeOf(TLine));
  numLines := 0;
end.
