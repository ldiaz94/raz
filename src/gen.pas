{ gen.pas: the code generator, for x86-64.

  item.pas and parse.pas drive a stack machine: they push constants,
  addresses and the values of variables, operate on the values on top,
  store them and jump on them. Every value has a kind: a word, which
  is an integer as big as an address, a pointer, a BOOL, a set or a
  narrower integer; a long, a 64-bit integer on a machine whose word is
  smaller (never here); an F32; an F64. This unit makes the machine's
  code for those calls, and nothing above it knows the machine: a port
  is a new gen.pas, with an encoder of its own.

  Here the stack is the machine's: the value on top, once computed, is
  in rax, and the values under it are pushed when another is computed.
  A constant is only noted until something needs it in a register, so
  that it can be an instruction's operand.

  Calls use the System V convention. Arguments are computed left to
  right into frame slots, then loaded into registers just before the
  call, so that computing one argument can't disturb another. A record,
  array, slice or variant passed by value goes as the address of a copy
  the caller makes; one returned goes through a hidden pointer, as C's
  structs do, and so do several results.

  A procedure's frame holds its parameters, its variables, and the
  temporaries of the statement running. The variables are zeroed on
  entry.

  Depends on: scan and diag for errors, sym for types, chunk for code
  and data, x64 for instructions.
  Leaves out: what the program means, its types and their checks; that
  is item.pas. }

unit gen;

{$mode objfpc}{$H-}

interface

uses scan, diag, sym, chunk, x64;

const
  NoLabel = -1;
  WordSize = 8;   { the size of an address, and of INT }

type
  TKind = (kWord, kLong, kF32, kF64);

  { Where a variable is: its address is relative to the frame, to a
    chunk, to an address on the stack, or to one held in a frame slot }
  TBase = (bFrame, bGlobal, bStack, bSlot);
  TAdr = record
    base: TBase;
    chunk: longint;   { bGlobal: the chunk; bSlot: the frame slot }
    off: int64;       { added to the address }
  end;

  TCall = record
    sig: PType;
    param: PObj;       { the parameter the next argument is for }
    obj: PObj;         { the procedure called, if it has a name }
    n: longint;                      { the arguments }
    slots: array[0..63] of int64;    { each one's frame slot }
    isF: array[0..63] of boolean;    { ... goes in an xmm register }
    target: int64;     { the frame slot of a procedure value, if chunk < 0 }
    chunk: longint;    { else the procedure's chunk }
    code: boolean;     { a code procedure: two results come in rax and rdx }
    ext: boolean;      { C's: called through the chunk holding its address }
    ret: int64;        { set by Call: the temporary an aggregate result is in }
  end;

var
  rtFail, argcChunk, argvChunk: longint;
  depth: longint;      { the values on the stack }
  pushed: longint;     { quadwords pushed on the machine's stack }
  codeChunk: longint = -1;   { the procedure or body being compiled, or -1 }

function KindOf(t: PType): TKind;

procedure PushConst(k: TKind; v: int64);
procedure PushAdr(const a: TAdr);
procedure PushVar(const a: TAdr; size: longint; signed: boolean; k: TKind);
procedure PushProc(c: longint; ext: boolean);
procedure PopVar(const a: TAdr; size: longint);
procedure Drop;
procedure Swap;
procedure ResetStack(d, p: longint);

procedure CopyBlock(size, off: int64);
procedure CopyTo(const a: TAdr; size: int64);
procedure ZeroVar(const a: TAdr; size: int64);

procedure Op(op: TSym; k: TKind; size: longint; signed: boolean);
procedure Compare(op: TSym; k: TKind; signed: boolean);
procedure Neg(k: TKind; size: longint; signed: boolean);
procedure Complement(size: longint; signed: boolean);
procedure NotBool;
procedure Narrow(size: longint; signed: boolean);
procedure IntToReal(k: TKind; big: boolean);
procedure RealToInt(k: TKind);
procedure RealToReal(k: TKind);
procedure CompareSeq(a, b: int64; shift: longint; eq: boolean);
procedure ErrorText(tmp: int64);
procedure IncDec(size: longint; signed, dec: boolean);
procedure ZeroNew(size: int64);
procedure Atomic(which: longint);
procedure SysCall(n: longint);
procedure Fence;

procedure Jump(var L: longint);
procedure JumpIf(var L: longint; when: boolean);
procedure JumpKeep(var L: longint; when: boolean);
procedure FixKeep(L: longint);
procedure JumpCmp(op: TSym; signed: boolean; var L: longint);
procedure JumpBack(top: longint);
procedure Fix(L: longint);
procedure FixTo(L, top: longint);

procedure CheckIndex(n: int64; const p: TPos);
procedure CheckEnum(n: int64; name: longint; const p: TPos);
procedure IndexSlice(const a: TAdr; size: int64; checked: boolean; const p: TPos);
procedure Slice(const a: TAdr; isArray: boolean; n, size, tmp: int64; checked: boolean; const p: TPos);
procedure SlicePtr(size, tmp: int64; checked: boolean; const p: TPos);

procedure Call(var c: TCall);

function AllocTemp(size, align: int64): int64;
function AllocPerm(size, align: int64): int64;
function TempMark: int64;
procedure ReleaseTemps(m: int64);
procedure KeepTemps;

procedure BeginProc(sig: PType; params: PObj);
procedure EnterBody(c, line: longint);
procedure ResultTo(off: int64; size: longint);
procedure CopyResult(off, size: int64);
procedure ReturnJump;
procedure EndProc(c: longint);
function DeferBegin(var L, saved: longint): longint;
procedure DeferEnd(L, saved: longint);
procedure RunDefer(at: longint);

function EntryPoint(dynamic: boolean; first: PModule; main: PObj; cExit, places, placesVar, exitProc: longint): longint;

implementation

type
  TEntry = record
    isConst: boolean;   { not loaded: val is the value }
    val: int64;
    k: TKind;
  end;

var
  stack: array[0..255] of TEntry;
  inRax: longint;               { the entry whose value is in rax, or -1 }
  frameTop, frameMax, permTop: int64;
  frameFix: longint;            { where the frame size is patched in }
  paramTop: int64;              { the parameters' slots end here }
  retSlot: int64;               { holds the hidden result pointer }
  resType: PType;               { the procedure's result, or nil }
  exitL: longint;
  { parameters arriving in registers: where each is stored on entry }
  inReg: array[0..13] of longint;
  inSlot: array[0..13] of int64;
  inSize: array[0..13] of longint;
  numIn: longint;

const
  IntRegs: array[0..5] of longint = (RDI, RSI, RDX, RCX, R8, R9);

function KindOf(t: PType): TKind;
begin
  if t^.form = fReal then begin
    if t^.size = 4 then KindOf := kF32 else KindOf := kF64
  end else if t^.size > WordSize then KindOf := kLong
  else KindOf := kWord;
end;

{ The stack }

{ rax is wanted for a new value: the one in it is pushed }
procedure Spill;
begin
  if inRax >= 0 then begin
    Push(RAX);
    inc(pushed);
    inRax := -1;
  end;
end;

procedure NewEntry(k: TKind; isConst: boolean; v: int64);
begin
  if depth > High(stack) then Mark('the expression is too deep');
  stack[depth].k := k;
  stack[depth].isConst := isConst;
  stack[depth].val := v;
  inc(depth);
end;

{ The value just computed in rax goes on top }
procedure Computed(k: TKind);
begin
  NewEntry(k, false, 0);
  inRax := depth - 1;
end;

{ The value on top, popped into register r }
procedure PopTo(r: longint);
var e: TEntry;
begin
  if depth = 0 then Fatal('internal error: the stack is empty');
  dec(depth);
  e := stack[depth];
  if e.isConst then begin
    if r = RAX then Spill;
    MovRI(r, e.val);
  end else if inRax = depth then begin
    if r <> RAX then MovRR(r, RAX);
    inRax := -1;
  end else begin
    Pop(r);
    dec(pushed);
  end;
end;

{ The value on top, into rax, and on top still }
procedure TopToRax;
var k: TKind;
begin
  k := stack[depth - 1].k;
  PopTo(RAX);
  Computed(k);
end;

procedure ResetStack(d, p: longint);
begin
  depth := d;
  pushed := p;
  inRax := -1;
end;

procedure PushConst(k: TKind; v: int64);
begin
  NewEntry(k, true, v);
end;

{ The memory a names: an address on the stack is popped into r, one in
  a slot loaded into r }
function Place(const a: TAdr; r: longint): TMem;
begin
  case a.base of
    bFrame: Place := Mem(RBP, a.off);
    bGlobal: Place := MemRip(a.chunk, a.off);
    bStack: begin PopTo(r); Place := Mem(r, a.off) end;
  else
    if r = RAX then Spill;
    Load(r, Mem(RBP, a.chunk), 8, false);
    Place := Mem(r, a.off);
  end;
end;

procedure PushAdr(const a: TAdr);
var m: TMem;
begin
  if (a.base = bStack) and (a.off = 0) then exit;
  m := Place(a, RAX);
  Spill;
  Lea(RAX, m);
  Computed(kWord);
end;

procedure PushVar(const a: TAdr; size: longint; signed: boolean; k: TKind);
var m: TMem;
begin
  m := Place(a, RAX);
  Spill;
  Load(RAX, m, size, signed);
  Computed(k);
end;

procedure PushProc(c: longint; ext: boolean);
begin
  Spill;
  if ext then Load(RAX, MemRip(c, 0), 8, false)
  else Lea(RAX, MemRip(c, 0));
  Computed(kWord);
end;

{ Pops a value into the variable at a; an address on the stack is under
  the value. }
procedure PopVar(const a: TAdr; size: longint);
var m: TMem;
begin
  if a.base in [bFrame, bGlobal] then begin
    PopTo(RAX);
    Store(Place(a, RAX), RAX, size);
  end else begin
    PopTo(RCX);
    m := Place(a, RAX);
    Store(m, RCX, size);
  end;
end;

procedure Drop;
begin
  dec(depth);
  if stack[depth].isConst then exit;
  if inRax = depth then inRax := -1
  else begin
    AluI(aluAdd, RSP, 8);
    dec(pushed);
  end;
end;

{ The two values on top change places. }
procedure Swap;
var e: TEntry; a, b: boolean;
begin
  a := stack[depth - 2].isConst;
  b := stack[depth - 1].isConst;
  if not a and not b then begin
    { the one on top is in rax, or pushed over the other }
    if inRax <> depth - 1 then begin Pop(RAX); dec(pushed) end;
    Xchg(Mem(RSP, 0), RAX);
    inRax := depth - 1;
  end else if inRax = depth - 1 then inRax := depth - 2
  else if inRax = depth - 2 then inRax := depth - 1;
  e := stack[depth - 1];
  stack[depth - 1] := stack[depth - 2];
  stack[depth - 2] := e;
end;

{ Copying }

{ size bytes from [rsi] to [rdi], through rcx; rsi and rdi are left
  as they fall. Up to 64 bytes, as a record or a small array mostly
  is, they go as moves of 8, 4, 2 and 1 bytes: rep movsb takes some
  twenty cycles to start, longer than the few moves take. }
procedure CopyBytes(size: int64);
var o, n: int64;
begin
  if size > 64 then begin
    MovRI(RCX, size);
    RepMovsb;
    exit;
  end;
  o := 0;
  while o < size do begin
    n := 8;
    while n > size - o do n := n div 2;
    Load(RCX, Mem(RSI, o), n, false);
    Store(Mem(RDI, o), RCX, n);
    Inc(o, n);
  end;
end;

{ Pops a source's address, and a destination's under it, and copies
  size bytes to off bytes past the destination. }
procedure CopyBlock(size, off: int64);
begin
  PopTo(RSI);
  PopTo(RDI);
  if off <> 0 then Lea(RDI, Mem(RDI, off));
  CopyBytes(size);
end;

{ Pops a source's address, and copies size bytes to a. }
procedure CopyTo(const a: TAdr; size: int64);
begin
  PopTo(RSI);
  Lea(RDI, Place(a, RDI));
  CopyBytes(size);
end;

procedure ZeroVar(const a: TAdr; size: int64);
begin
  Lea(RDI, Place(a, RDI));
  Spill;
  MovRI(RCX, size);
  MovRI(RAX, 0);
  RepStosb;
end;

{ Operations }

function Log2(v: int64): longint;
var n: longint;
begin
  n := 0;
  while (v > 1) and (v and 1 = 0) do begin v := v shr 1; inc(n) end;
  if v <> 1 then n := -1;
  Log2 := n;
end;

{ rax div or mod 2^k, 1 <= k <= 62, with shifts: div truncates towards
  zero, so a negative dividend first gets 2^k - 1 added (the bias). }
procedure DivPow2(op: TSym; k: longint; unsign: boolean);
begin
  if unsign then begin
    if op = sDiv then ShiftI(shShr, RAX, k)
    else begin ShiftI(shShl, RAX, 64 - k); ShiftI(shShr, RAX, 64 - k) end;
    exit;
  end;
  MovRR(RCX, RAX);
  ShiftI(shSar, RCX, 63);
  ShiftI(shShr, RCX, 64 - k);
  Alu(aluAdd, RCX, RAX);
  ShiftI(shSar, RCX, k);
  if op = sDiv then MovRR(RAX, RCX)
  else begin ShiftI(shShl, RCX, k); Alu(aluSub, RAX, RCX) end;
end;

procedure CmpI(r: longint; v: int64);
begin
  if (v >= low(longint)) and (v <= high(longint)) then AluI(aluCmp, r, v)
  else begin MovRI(R11, v); Alu(aluCmp, r, R11) end;
end;

{ Before rax div rcx, of a signed type of bits < 64: its smallest value
  divided by -1 overflows it, which must stop the program as it does for
  an I64 (report section 6.1). idiv on the 64-bit values wouldn't fault,
  so then rax is made the smallest I64, and it does. }
procedure DivTrap(bits: longint);
var L: longint;
begin
  L := NoLabel;
  CmpI(RCX, -1);
  Jcc(ccNE, L);
  CmpI(RAX, int64(-1) shl (bits - 1));
  Jcc(ccNE, L);
  ShiftI(shShl, RAX, 64 - bits);
  FixLink(L);
end;

{ The two values on top, the left one into rax and the right into rcx }
procedure Operands;
begin
  PopTo(RCX);
  PopTo(RAX);
end;

procedure RealOp(op: TSym; k: TKind);
var f: boolean;
begin
  f := k = kF32;
  Operands;
  MovqXR(0, RAX);
  MovqXR(1, RCX);
  case op of
    sPlus: Sse($58, 0, 1, f);
    sMinus: Sse($5C, 0, 1, f);
    sTimes: Sse($59, 0, 1, f);
    sSlash: Sse($5E, 0, 1, f);
  end;
  MovqRX(RAX, 0);
  Computed(k);
end;

{ The two values on top, the left op the right, an integer of size
  bytes, signed or not, brought back to its width. }
procedure Op(op: TSym; k: TKind; size: longint; signed: boolean);
var y: TEntry; sh, bits: longint;
begin
  if k in [kF32, kF64] then begin RealOp(op, k); exit end;
  bits := size * 8;
  y := stack[depth - 1];
  sh := -1;
  if y.isConst and (op in [sTimes, sDiv, sMod]) then sh := Log2(y.val);
  if y.isConst then begin
    dec(depth);
    PopTo(RAX);
    if sh < 1 then MovRI(RCX, y.val);
  end else Operands;
  case op of
    sPlus: Alu(aluAdd, RAX, RCX);
    sMinus: Alu(aluSub, RAX, RCX);
    sTimes: if sh >= 1 then ShiftI(shShl, RAX, sh) else Imul(RAX, RCX);
    sDiv, sMod: if sh >= 1 then DivPow2(op, sh, not signed) else begin
      if not signed then begin MovRI(RDX, 0); Unary(6, RCX) end
      else begin
        if (bits < 64) and (not y.isConst or (y.val = -1)) then DivTrap(bits);
        Cqo; Unary(7, RCX)
      end;
      if op = sMod then MovRR(RAX, RDX);
    end;
    sAmp: Alu(aluAnd, RAX, RCX);
    sBar: Alu(aluOr, RAX, RCX);
    sXor: Alu(aluXor, RAX, RCX);
    sShl, sShr: begin
      { the count modulo the width: the machine takes it modulo 64 }
      if bits < 64 then AluI(aluAnd, RCX, bits - 1);
      if op = sShl then Shift(shShl, RAX)
      else if signed then Shift(shSar, RAX) else Shift(shShr, RAX);
    end;
  end;
  if bits < 64 then Extend(RAX, size, signed);
  Computed(k);
end;

{ The left op the right of the two values on top, as a BOOL }
procedure Compare(op: TSym; k: TKind; signed: boolean);
const
  CcSigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccL, ccLE, ccG, ccGE);
  CcUnsigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccB, ccBE, ccA, ccAE);
var y: TEntry; f: boolean;
begin
  if k in [kF32, kF64] then begin
    f := k = kF32;
    Operands;
    MovqXR(0, RAX);
    MovqXR(1, RCX);
    case op of
      sEql: begin Ucomis(0, 1, f); SetCC(ccE, RAX); SetCC(ccNP, RCX); Alu(aluAnd, RAX, RCX) end;
      sNeq: begin Ucomis(0, 1, f); SetCC(ccNE, RAX); SetCC(ccP, RCX); Alu(aluOr, RAX, RCX) end;
      sLss: begin Ucomis(1, 0, f); SetCC(ccA, RAX) end;
      sLeq: begin Ucomis(1, 0, f); SetCC(ccAE, RAX) end;
      sGtr: begin Ucomis(0, 1, f); SetCC(ccA, RAX) end;
      sGeq: begin Ucomis(0, 1, f); SetCC(ccAE, RAX) end;
    end;
  end else begin
    y := stack[depth - 1];
    if y.isConst then begin
      dec(depth);
      PopTo(RAX);
      CmpI(RAX, y.val);
    end else begin
      Operands;
      Alu(aluCmp, RAX, RCX);
    end;
    if signed then SetCC(CcSigned[op], RAX) else SetCC(CcUnsigned[op], RAX);
  end;
  Computed(kWord);
end;

procedure Neg(k: TKind; size: longint; signed: boolean);
begin
  PopTo(RAX);
  case k of
    kF32: Btc(RAX, 31);
    kF64: Btc(RAX, 63);
  else
    Unary(3, RAX);
    if size < 8 then Extend(RAX, size, signed);
  end;
  Computed(k);
end;

procedure Complement(size: longint; signed: boolean);
begin
  PopTo(RAX);
  Unary(2, RAX);
  if size < 8 then Extend(RAX, size, signed);
  Computed(kWord);
end;

procedure NotBool;
begin
  PopTo(RAX);
  AluI(aluXor, RAX, 1);
  Computed(kWord);
end;

{ The integer on top, brought to size bytes }
procedure Narrow(size: longint; signed: boolean);
begin
  PopTo(RAX);
  if size < 8 then Extend(RAX, size, signed);
  Computed(kWord);
end;

{ The integer on top, as a real of kind k; big if it may be a U64 above
  high(I64), which the machine would take as negative }
procedure IntToReal(k: TKind; big: boolean);
var L1, L2: longint; f: boolean;
begin
  f := k = kF32;
  PopTo(RAX);
  if big then begin
    { above high(I64): halve, keeping the low bit, and double }
    L1 := NoLabel; L2 := NoLabel;
    TestRR(RAX, RAX);
    Jcc(ccS, L1);
    Cvtsi2s(0, RAX, f);
    Jmp(L2);
    FixLink(L1);
    MovRR(RCX, RAX);
    ShiftI(shShr, RCX, 1);
    AluI(aluAnd, RAX, 1);
    Alu(aluOr, RCX, RAX);
    Cvtsi2s(0, RCX, f);
    Sse($58, 0, 0, f);
    FixLink(L2);
  end else Cvtsi2s(0, RAX, f);
  MovqRX(RAX, 0);
  Computed(k);
end;

{ The real of kind k on top, truncated to an integer }
procedure RealToInt(k: TKind);
begin
  PopTo(RAX);
  MovqXR(0, RAX);
  Cvtts2si(RAX, 0, k = kF32);
  Computed(kWord);
end;

{ The real of kind k on top, as the other kind }
procedure RealToReal(k: TKind);
begin
  PopTo(RAX);
  MovqXR(0, RAX);
  Sse($5A, 0, 0, k = kF32);
  MovqRX(RAX, 0);
  if k = kF32 then Computed(kF64) else Computed(kF32);
end;

{ Whether the slices in the frame at a and b are equal (or not, if not
  eq): the lengths, then the bytes, len shl shift of them, compared
  right where the comparison stands. }
procedure CompareSeq(a, b: int64; shift: longint; eq: boolean);
var differ: longint;
begin
  Spill;
  Load(RCX, Mem(RBP, b + 8), 8, false);
  AluM(aluCmp, RCX, Mem(RBP, a + 8));
  differ := NoLabel;
  Jcc(ccNE, differ);
  Load(RSI, Mem(RBP, b), 8, false);
  Load(RDI, Mem(RBP, a), 8, false);
  if shift > 0 then ShiftI(shShl, RCX, shift);
  Alu(aluCmp, RCX, RCX);   { equal, if there are no bytes }
  RepeCmpsb;
  FixLink(differ);
  if eq then SetCC(ccE, RAX) else SetCC(ccNE, RAX);
  Computed(kWord);
end;

{ An error is the address of its length, followed by its message: pops
  one, and makes the slice of its message at tmp, empty for nil. }
procedure ErrorText(tmp: int64);
var L: longint;
begin
  PopTo(RAX);
  MovRI(RCX, 0);
  L := NoLabel;
  TestRR(RAX, RAX);
  Jcc(ccE, L);
  Load(RCX, Mem(RAX, 0), 8, false);
  Lea(RAX, Mem(RAX, 8));
  FixLink(L);
  Store(Mem(RBP, tmp), RAX, 8);
  Store(Mem(RBP, tmp + 8), RCX, 8);
end;

{ Pops a step and an integer variable's address, and adds the step to
  it, or takes it away. }
procedure IncDec(size: longint; signed, dec: boolean);
begin
  PopTo(RCX);
  PopTo(RDX);
  Spill;
  Load(RAX, Mem(RDX, 0), size, signed);
  if dec then Alu(aluSub, RAX, RCX) else Alu(aluAdd, RAX, RCX);
  Store(Mem(RDX, 0), RAX, size);
end;

{ The pointer on top, which NEW got, to size zero bytes unless nil }
procedure ZeroNew(size: int64);
var L: longint;
begin
  PopTo(RAX);
  L := NoLabel;
  TestRR(RAX, RAX);
  Jcc(ccE, L);
  MovRR(RDX, RAX);
  MovRR(RDI, RAX);
  MovRI(RCX, size);
  MovRI(RAX, 0);
  RepStosb;
  MovRR(RAX, RDX);
  FixLink(L);
  Computed(kWord);
end;

{ CAS(p, old, new), XCHG(p, v) or XADD(p, v), from the stack }
procedure Atomic(which: longint);
begin
  if which = bCas then PopTo(RDX);
  PopTo(RAX);
  PopTo(RCX);
  case which of
    bCas: begin LockCmpxchg(Mem(RCX, 0), RDX); SetCC(ccE, RAX) end;
    bXchg: Xchg(Mem(RCX, 0), RAX);
    bXadd: LockXadd(Mem(RCX, 0), RAX);
  end;
  Computed(kWord);
end;

{ The system call and its arguments, n values on the stack }
procedure SysCall(n: longint);
const Regs: array[0..6] of longint = (RAX, RDI, RSI, RDX, R10, R8, R9);
var i: longint;
begin
  for i := n - 1 downto 0 do PopTo(Regs[i]);
  x64.Syscall;
  Computed(kWord);
end;

procedure Fence;
begin
  Mfence;
end;

{ Jumps. A label is the chain of the jumps to it, until it is placed. }

procedure Jump(var L: longint);
begin
  Jmp(L);
end;

{ Pops a BOOL, and jumps if it is when }
procedure JumpIf(var L: longint; when: boolean);
begin
  PopTo(RAX);
  TestRR(RAX, RAX);
  if when then Jcc(ccNE, L) else Jcc(ccE, L);
end;

{ For and and or: jumps if the BOOL on top is when, keeping it for
  where the jump goes, and drops it if not. }
procedure JumpKeep(var L: longint; when: boolean);
begin
  JumpIf(L, when);
end;

{ Where JumpKeep went: the BOOL on top is there, as it was there. }
procedure FixKeep(L: longint);
begin
  TopToRax;
  FixLink(L);
end;

{ Pops two integers, and jumps if the left op the right }
procedure JumpCmp(op: TSym; signed: boolean; var L: longint);
const
  CcSigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccL, ccLE, ccG, ccGE);
  CcUnsigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccB, ccBE, ccA, ccAE);
var y: TEntry;
begin
  y := stack[depth - 1];
  if y.isConst then begin
    dec(depth);
    PopTo(RAX);
    CmpI(RAX, y.val);
  end else begin
    Operands;
    Alu(aluCmp, RAX, RCX);
  end;
  if signed then Jcc(CcSigned[op], L) else Jcc(CcUnsigned[op], L);
end;

procedure JumpBack(top: longint);
begin
  JmpBack(top);
end;

procedure Fix(L: longint);
begin
  FixLink(L);
end;

procedure FixTo(L, top: longint);
begin
  FixLinkTo(L, top);
end;

{ Checks }

const
  NoBase = -2;   { a TMem that is no memory }

{ The program goes on if the condition cc holds, and otherwise stops
  in Rt.fail(what, a, b, len, at, name), which says what failed at p,
  found by at, the address of the call: an index a (what = 0), a slice
  a..b (1), each for a length len, a position a of the enumeration
  called name (2), or a slice of a pointer a..b that runs backwards
  (3). a is in register ra, b in RDX; len is in memory at m, or n if
  m.base is NoBase. The failing code has p for its place, and the code
  after it the place before it again. }
procedure Check(cc, what: longint; const p: TPos; ra: longint; const m: TMem; n: int64; name: longint);
var L, line, col: longint; before: TLine;
begin
  L := NoLabel;
  Jcc(cc, L);
  before := lines^[numLines - 1];
  LineCol(p.a, line, col);
  NoteLine(line, col);
  MovRR(RSI, ra);
  if m.base = NoBase then MovRI(RCX, n) else Load(RCX, m, 8, false);
  Lea(R8, Here);
  MovRI(RDI, what);
  if name >= 0 then Lea(R9, MemRip(name, 0));
  AluI(aluAnd, RSP, -16);
  CallChunk(rtFail);
  Ud2;
  FixLink(L);
  NoteLine(before.line, before.col);
end;

{ For Check: a length known here, not in memory }
function NoMem: TMem;
begin
  NoMem := Mem(NoBase, 0);
end;

{ The index on top is below n, unsigned }
procedure CheckIndex(n: int64; const p: TPos);
begin
  TopToRax;
  CmpI(RAX, n);
  Check(ccB, 0, p, RAX, NoMem, n, -1);
end;

{ The integer on top is a position of an enumeration of n names }
procedure CheckEnum(n: int64; name: longint; const p: TPos);
begin
  TopToRax;
  CmpI(RAX, n);
  Check(ccB, 2, p, RAX, NoMem, n, name);
end;

{ Pops an index, and the address of the slice at a if it is on the
  stack, and pushes the address of its element of size bytes. }
procedure IndexSlice(const a: TAdr; size: int64; checked: boolean; const p: TPos);
var m, ml: TMem;
begin
  PopTo(RAX);
  m := Place(a, RCX);
  ml := m; ml.disp := ml.disp + 8;
  if checked then begin
    AluM(aluCmp, RAX, ml);
    Check(ccB, 0, p, RAX, ml, 0, -1);
  end;
  if size <> 1 then ImulI(RAX, size);
  AluM(aluAdd, RAX, m);
  Computed(kWord);
end;

{ Pops lo and hi, and the address of the array or slice at a if it is
  on the stack, and makes the slice lo..hi of it, with elements of size
  bytes, in the frame at tmp; the array has n elements. }
procedure Slice(const a: TAdr; isArray: boolean; n, size, tmp: int64; checked: boolean; const p: TPos);
var m, ml: TMem;
begin
  PopTo(RDX);
  PopTo(RCX);
  m := Place(a, R8);
  ml := m; ml.disp := ml.disp + 8;
  if checked then begin
    if isArray then begin CmpI(RDX, n); ml := NoMem end
    else AluM(aluCmp, RDX, ml);
    Check(ccBE, 1, p, RCX, ml, n, -1);
    Alu(aluCmp, RCX, RDX);
    Check(ccBE, 1, p, RCX, ml, n, -1);
  end;
  Spill;
  MovRR(RAX, RDX);
  Alu(aluSub, RAX, RCX);
  Store(Mem(RBP, tmp + 8), RAX, 8);
  if size <> 1 then ImulI(RCX, size);
  if isArray then Lea(RAX, m) else Load(RAX, m, 8, false);
  Alu(aluAdd, RAX, RCX);
  Store(Mem(RBP, tmp), RAX, 8);
end;

{ Pops a pointer, lo and hi, and makes the slice p[lo..hi] at tmp. Its
  bounds can't be known, but it can't run backwards. }
procedure SlicePtr(size, tmp: int64; checked: boolean; const p: TPos);
begin
  PopTo(RDX);
  PopTo(RCX);
  PopTo(R8);
  if checked then begin
    Alu(aluCmp, RCX, RDX);
    Check(ccLE, 3, p, RCX, NoMem, 0, -1);
  end;
  Spill;
  MovRR(RAX, RDX);
  Alu(aluSub, RAX, RCX);
  Store(Mem(RBP, tmp + 8), RAX, 8);
  if size <> 1 then ImulI(RCX, size);
  MovRR(RAX, R8);
  Alu(aluAdd, RAX, RCX);
  Store(Mem(RBP, tmp), RAX, 8);
end;

{ Calls }

procedure Call(var c: TCall);
var
  res: PType; i, ni, nf, k, pad: longint;
  onStack: array[0..63] of boolean;
begin
  Spill;   { the value in rax waits on the stack, past the call }
  res := c.sig^.base;
  c.ret := 0;
  ni := 0; nf := 0;
  if (res <> nil) and IsAggregate(res) then begin
    c.ret := AllocTemp(res^.size, res^.align);
    if not c.code then ni := 1;
  end;
  { the System V classes: each argument in the next free register of
    its kind, or else on the stack }
  k := 0;
  for i := 0 to c.n - 1 do begin
    if c.isF[i] then begin onStack[i] := nf >= 8; if nf < 8 then inc(nf) end
    else begin onStack[i] := ni >= 6; if ni < 6 then inc(ni) end;
    if onStack[i] then inc(k);
  end;
  pad := ord(odd(pushed + k));
  if pad <> 0 then AluI(aluSub, RSP, 8);
  for i := c.n - 1 downto 0 do
    if onStack[i] then begin
      Load(RAX, Mem(RBP, c.slots[i]), 8, false);
      Push(RAX);
    end;
  ni := 0; nf := 0;
  if (c.ret <> 0) and not c.code then begin Lea(RDI, Mem(RBP, c.ret)); ni := 1 end;
  for i := 0 to c.n - 1 do
    if not onStack[i] then
      if c.isF[i] then begin MovsdXM(nf, Mem(RBP, c.slots[i])); inc(nf) end
      else begin Load(IntRegs[ni], Mem(RBP, c.slots[i]), 8, false); inc(ni) end;
  { a procedure taking ... is told in al how many xmm registers it got }
  if c.sig^.variadic then MovRI(RAX, nf);
  if c.ext then CallM(MemRip(c.chunk, 0))
  else if c.chunk >= 0 then CallChunk(c.chunk)
  else begin
    Load(R11, Mem(RBP, c.target), 8, false);
    CallR(R11);
  end;
  if k + pad > 0 then AluI(aluAdd, RSP, 8 * (k + pad));
  if (c.ret <> 0) and c.code then begin
    Store(Mem(RBP, c.ret), RAX, 8);
    Store(Mem(RBP, c.ret + 8), RDX, 8);
  end;
  if (res <> nil) and (c.ret = 0) then begin
    if res^.form = fReal then MovqRX(RAX, 0)
    else if res^.form = fBool then Extend(RAX, 1, false)
    else if (res^.form = fInt) and (res^.size < 8) then Extend(RAX, res^.size, res^.signed);
    Computed(KindOf(res));
  end;
end;

{ Frames }

function AllocTemp(size, align: int64): int64;
begin
  if align < 1 then align := 1;
  frameTop := AlignUp(frameTop + size, align);
  if frameTop > frameMax then frameMax := frameTop;
  AllocTemp := -frameTop;
end;

function AllocPerm(size, align: int64): int64;
begin
  AllocPerm := AllocTemp(size, align);
  permTop := frameTop;
end;

function TempMark: int64;
begin
  TempMark := frameTop;
end;

procedure ReleaseTemps(m: int64);
begin
  if m < permTop then m := permTop;
  frameTop := m;
end;

{ Every slot used so far stays reserved for the rest of the procedure:
  a deferred statement's temporaries live until it runs. }
procedure KeepTemps;
begin
  frameTop := frameMax;
  permTop := frameMax;
end;

{ The parameters' places: each in a frame slot of its own, stored there
  from its register on entry, or above the frame where the caller
  pushed it. A var parameter, and a record or array passed by value,
  holds an address (ind). }
procedure BeginProc(sig: PType; params: PObj);
var p: PObj; ni, nf: longint; stackOff: int64; f: boolean;
begin
  frameTop := 0; frameMax := 0; permTop := 0;
  ResetStack(0, 0);
  exitL := NoLabel;
  numIn := 0;
  resType := sig^.base;
  ni := 0; nf := 0; stackOff := 16;
  if (resType <> nil) and IsAggregate(resType) then begin
    retSlot := AllocPerm(8, 8);
    inReg[0] := RDI; inSlot[0] := retSlot; inSize[0] := 8;
    numIn := 1; ni := 1;
  end;
  p := params;
  while p <> nil do begin
    p^.ind := p^.isVar or IsAggregate(p^.typ);
    f := (p^.typ^.form = fReal) and not p^.isVar;
    if (f and (nf < 8)) or (not f and (ni < 6)) then begin
      p^.val := AllocPerm(8, 8);
      if f then begin inReg[numIn] := -1 - nf; inc(nf) end
      else begin inReg[numIn] := IntRegs[ni]; inc(ni) end;
      inSlot[numIn] := p^.val;
      if p^.ind then inSize[numIn] := 8
      else if p^.typ^.form in [fInt, fBool, fEnum, fSet, fReal] then inSize[numIn] := p^.typ^.size
      else inSize[numIn] := 8;
      inc(numIn);
    end else begin
      p^.val := stackOff;
      inc(stackOff, 8);
    end;
    p := p^.next;
  end;
  paramTop := frameTop;
end;

{ The prologue, which is for the procedure's first line. Only the
  locals are zeroed: the parameters are stored over their slots next,
  and every temporary is written before it is read. The locals are all
  declared by now, below the parameters' slots. }
procedure EnterBody(c, line: longint);
var i, top: longint; n: int64;
begin
  BeginChunk(c);
  codeChunk := c;
  NoteLine(line, 1);   { a declaration starts a line }
  Push(RBP);
  MovRR(RBP, RSP);
  Put1($48); Put1($81); Put1($EC);           { sub rsp, imm32 }
  frameFix := pc; Put4(0);
  n := (AlignUp(frameMax, 8) - paramTop) div 8;
  if n > 0 then MovRI(RAX, 0);
  if n <= 4 then
    for i := 1 to n do Store(Mem(RBP, -paramTop - 8 * i), RAX, 8)
  else begin
    { a quadword at a time: r10 counts up to zero }
    MovRI(R10, -n);
    top := pc;
    Store(MemIdx(RBP, R10, 8, -paramTop), RAX, 8);
    AluI(aluAdd, R10, 1);
    JccBack(ccNE, top);
  end;
  for i := 0 to numIn - 1 do
    if inReg[i] < 0 then MovsdMX(Mem(RBP, inSlot[i]), -1 - inReg[i])
    else Store(Mem(RBP, inSlot[i]), inReg[i], inSize[i]);
end;

{ Pops one of several results, a value of size bytes, into its place
  off bytes into the caller's, behind the hidden pointer. }
procedure ResultTo(off: int64; size: longint);
begin
  PopTo(RAX);
  Load(RCX, Mem(RBP, retSlot), 8, false);
  Store(Mem(RCX, off), RAX, size);
end;

{ Pops an address, and copies size bytes from it to the result, off
  bytes into it. }
procedure CopyResult(off, size: int64);
begin
  PopTo(RSI);
  Load(RDI, Mem(RBP, retSlot), 8, false);
  if off <> 0 then Lea(RDI, Mem(RDI, off));
  CopyBytes(size);
end;

{ return: the result, a value on top, goes in rax or xmm0; one behind
  the hidden pointer goes back with that pointer in rax. }
procedure ReturnJump;
begin
  if resType <> nil then
    if IsAggregate(resType) then Load(RAX, Mem(RBP, retSlot), 8, false)
    else begin
      PopTo(RAX);
      if resType^.form = fReal then MovqXR(0, RAX);
    end;
  Jmp(exitL);
end;

procedure EndProc(c: longint);
var n: int64;
begin
  codeChunk := -1;
  if (depth <> 0) or (pushed <> 0) then Fatal('internal error: stack depth');
  { running off the end returns zeros }
  if resType <> nil then
    if IsAggregate(resType) then begin
      Load(RDI, Mem(RBP, retSlot), 8, false);
      MovRI(RCX, resType^.size);
      MovRI(RAX, 0);
      RepStosb;
      Load(RAX, Mem(RBP, retSlot), 8, false);
    end else begin
      MovRI(RAX, 0);
      MovqXR(0, RAX);
    end;
  FixLink(exitL);
  Leave;
  Ret;
  n := AlignUp(frameMax, 16);
  if n < 16 then n := 16;
  if n > high(longint) then Mark('frame too big');
  Put4At(frameFix, n);
  EndChunk(c);
end;

{ A deferred statement is compiled where it stands, as a subroutine of
  its procedure that the code jumps over; DeferBegin gives its address
  and starts it, with the return address pushed. The stack is empty
  where it is called, and where it begins. }
function DeferBegin(var L, saved: longint): longint;
begin
  Jmp(L);
  saved := pushed;
  pushed := 1;
  DeferBegin := pc;
end;

procedure DeferEnd(L, saved: longint);
begin
  KeepTemps;
  Ret;
  FixLink(L);
  pushed := saved;
end;

procedure RunDefer(at: longint);
begin
  CallBack(at);
end;

{ The entry point, _start, and its chunk: it saves argc and argv, and
  the address of the places for Rt; runs every used module's body, then
  main; and ends with Rt.exit, its status main's or 0. A dynamic program
  starts as C's crt1 does, through __libc_start_main(main, argc, argv,
  nil, nil, rtld_fini, stack_end), with rsp aligned; its main first
  gives Rt C's exit, in cExit. }
function EntryPoint(dynamic: boolean; first: PModule; main: PObj; cExit, places, placesVar, exitProc: longint): longint;
var entry, start: longint; m: PModule;
begin
  entry := NewChunk(secText, -1, Intern('_start', 6));
  if dynamic then begin
    start := NewChunk(secText, -1, Intern('main', 4));
    BeginChunk(entry);
    MovRI(RBP, 0);
    MovRR(R9, RDX);
    Pop(RSI);
    MovRR(RDX, RSP);
    AluI(aluAnd, RSP, -16);
    Push(RAX);
    Push(RSP);
    MovRI(R8, 0);
    MovRI(RCX, 0);
    Lea(RDI, MemRip(start, 0));
    CallM(MemRip(ExternChunk(Intern('__libc_start_main', 17)), 0));
    Ud2;
    EndChunk(entry);
    BeginChunk(start);
    Push(RBP);   { aligns the stack again }
    Store(MemRip(argcChunk, 0), RDI, 8);
    Store(MemRip(argvChunk, 0), RSI, 8);
    Load(RAX, MemRip(ExternChunk(Intern('exit', 4)), 0), 8, false);
    Store(MemRip(cExit, 0), RAX, 8);
  end else begin
    start := entry;
    BeginChunk(entry);
    Load(RAX, Mem(RSP, 0), 8, false);
    Store(MemRip(argcChunk, 0), RAX, 8);
    Lea(RAX, Mem(RSP, 8));
    Store(MemRip(argvChunk, 0), RAX, 8);
  end;
  Lea(RAX, MemRip(places, 0));
  Store(MemRip(placesVar, 0), RAX, 8);
  m := first;
  while m <> nil do begin
    if m^.used and (m^.body >= 0) then CallChunk(m^.body);
    m := m^.next;
  end;
  if main <> nil then CallChunk(main^.chunk);
  if (main <> nil) and (main^.typ^.base <> nil) then MovRR(RDI, RAX) else MovRI(RDI, 0);
  CallChunk(exitProc);
  Ud2;
  EndChunk(start);
  EntryPoint := entry;
end;

initialization
  inRax := -1;
  rtFail := NewChunk(secText, Intern('Rt', 2), Intern('fail', 4));
  argcChunk := NewChunk(secBss, -1, Intern('argc', 4));
  SetBss(argcChunk, 8, 8);
  argvChunk := NewChunk(secBss, -1, Intern('argv', 4));
  SetBss(argvChunk, 8, 8);
end.
