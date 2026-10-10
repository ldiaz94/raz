{ Emits one of each instruction form into a chunk, for objdump: a test
  of the encoder in x64.pas. }
program enctest;
{$mode objfpc}{$H-}
uses scan, x64, link, elf;
var e, d: longint; L: longint;
begin
  d := NewChunk(secBss, -1, Intern('data', 4)); SetBss(d, 8, 8);
  e := NewChunk(secText, -1, Intern('start', 5));
  BeginChunk(e);
  MovRR(RAX, RCX); MovRR(R11, RDI); MovRR(RSI, R9);
  MovRI(RAX, 0); MovRI(RCX, 5); MovRI(RDX, -5); MovRI(R10, $FFFFFFFF); MovRI(RAX, $123456789A);
  Load(RAX, Mem(RBP, -8), 8, true); Load(RAX, Mem(RBP, -200), 4, true); Load(RCX, Mem(RAX, 0), 4, false);
  Load(RAX, Mem(RCX, 16), 2, true); Load(RAX, Mem(RAX, 3), 2, false); Load(RAX, Mem(RSP, 8), 1, true);
  Load(RAX, Mem(RBP, 0), 1, false); Load(R10, Mem(12, 0), 8, true); Load(RAX, Mem(13, 0), 8, true);
  Store(Mem(RBP, -16), RAX, 8); Store(Mem(RBP, -16), RSI, 1); Store(Mem(RCX, 0), RAX, 2); Store(Mem(RCX, 4), RDX, 4);
  Store(MemIdx(RBP, R10, 8, 0), RAX, 8); Store(MemRip(d, 0), RAX, 8); Lea(RAX, MemRip(d, 4));
  Alu(aluAdd, RAX, RCX); Alu(aluSub, RCX, RAX); Alu(aluCmp, RAX, RCX); Alu(aluXor, R8, R9);
  AluI(aluAdd, RAX, 1); AluI(aluAnd, RAX, 1000); AluI(aluCmp, RSP, 8); AluM(aluCmp, RAX, Mem(RCX, 8)); AluM(aluAdd, RAX, Mem(RCX, 0));
  Imul(RAX, RCX); ImulI(RAX, 24); Shift(shShl, RAX); Shift(shSar, RAX); ShiftI(shShr, RCX, 3);
  Unary(2, RAX); Unary(3, RAX); Unary(6, RCX); Unary(7, RCX); Cqo;
  Extend(RAX, 1, true); Extend(RAX, 1, false); Extend(RAX, 2, true); Extend(RAX, 2, false); Extend(RAX, 4, true); Extend(RAX, 4, false);
  SetCC(ccL, RAX); SetCC(ccA, RCX); TestRR(RAX, RAX);
  Push(RAX); Push(12); Pop(RCX); Pop(R11); CallR(R11); CallM(Mem(RCX, 8)); Ret; Leave; Syscall; Mfence; Ud2; RepMovsb; RepStosb;
  LockCmpxchg(Mem(RCX, 0), RDX); Xchg(Mem(RCX, 0), RAX); LockXadd(Mem(RCX, 0), RAX);
  MovqXR(0, RAX); MovqXR(1, RCX); MovqRX(RAX, 0); MovsdXM(2, Mem(RBP, -8)); MovsdMX(Mem(RBP, -8), 7);
  Sse($58, 0, 1, false); Sse($5E, 0, 1, true); Sse($5A, 0, 0, false); Sse($5A, 0, 0, true);
  Ucomis(0, 1, false); Ucomis(0, 1, true); Cvtsi2s(0, RAX, false); Cvtsi2s(0, RAX, true);
  Cvtts2si(RAX, 0, false); Cvtts2si(RAX, 0, true); Btc(RAX, 63);
  L := NoLabel; Jcc(ccE, L); Jmp(L); FixLink(L); JmpBack(chunks^[e].start); JccBack(ccNE, chunks^[e].start);
  EndChunk(e);
  WriteElf(ParamStr(1), e);
end.
