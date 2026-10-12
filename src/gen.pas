{ gen.pas: the code generator, for x86-64.

  item.pas and parse.pas drive a stack machine: they push constants,
  addresses and the values of variables, operate on the values on top,
  store them and jump on them. Every value has a kind: a word, which
  is an integer as big as an address, a pointer, a BOOL, a set or a
  narrower integer; a long, a 64-bit integer on a machine whose word is
  smaller (never here); an F32; an F64. This unit makes the machine's
  code for those calls, and nothing above it knows the machine: a port
  is a new gen.pas, with an encoder of its own.

  The stack is kept in registers, as in Wirth's compilers: the value at
  depth d in r8 to r11, register d mod 4, a deeper one's register taken
  by spilling the shallower value it held to the frame. A constant, or
  an address in the frame or of a chunk, is only noted until something
  needs it in a register, so that it can be an instruction's operand.

  Calls use the System V convention. Arguments are computed left to
  right into frame slots, then loaded into registers just before the
  call, so that computing one argument can't disturb another; a
  constant or an address, which nothing can disturb, goes straight to
  its register. A record,
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
  { What the machine catches by itself, which the code needn't test for
    (report section 10): on x86-64 Linux, a division by zero, a stack
    overflow (at the guard page under the stack), a call to nil, and
    a load or store within NilPage bytes of address 0, which is never
    mapped. }
  NilPage = 4096;

type
  TKind = (kWord, kLong, kF32, kF64);

  { Where a variable is: its address is relative to the frame, to a
    chunk, to an address on the stack, or to one held in a frame slot }
  TBase = (bFrame, bGlobal, bStack, bSlot, bReg);
  TAdr = record
    base: TBase;
    chunk: longint;   { bGlobal: the chunk; bSlot: the frame slot; bReg: the register }
    off: int64;       { added to the address }
  end;

  { How an argument waits for its call: in a frame slot, or noted, as a
    constant or as the address of the frame or a chunk plus an offset }
  TArgHow = (argSlot, argConst, argAdr, argHeld);

  { The code made so far, to go back to for a second try at a body }
  TCodeMark = record pc, fixups, lines, said: longint; end;

  TCall = record
    sig: PType;
    param: PObj;       { the parameter the next argument is for }
    obj: PObj;         { the procedure called, if it has a name }
    n: longint;                      { the arguments }
    slots: array[0..63] of int64;    { each one's frame slot, constant or offset }
    how: array[0..63] of TArgHow;
    adrChunk: array[0..63] of longint;   { argAdr: the chunk, or -1 for the frame }
    isF: array[0..63] of boolean;    { ... goes in an xmm register }
    target: int64;     { the frame slot of a procedure value, if chunk < 0 }
    chunk: longint;    { else the procedure's chunk }
    code: boolean;     { a code procedure: two results come in rax and rdx }
    ext: boolean;      { C's: called through the chunk holding its address }
    ret: int64;        { set by Call: the temporary an aggregate result is in }
  end;

const
  { the registers a procedure keeps its busiest variables in: System V's
    callee-saved ones, so they live through calls; a procedure saves
    those it uses, and Rt finds them there for the trap report }
  VarRegs: array[0..4] of longint = (RBX, R12, R13, R14, R15);

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
procedure IncDecReg(r, size: longint; signed, dec: boolean);
procedure ZeroNew(size: int64);
procedure Atomic(which: longint);
procedure SysCall(n: longint);
procedure Fence;

procedure Jump(var L: longint);
procedure JumpIf(var L: longint; when: boolean);
procedure JumpCmp(op: TSym; signed: boolean; var L: longint);
procedure JumpOut(op: TSym; signed: boolean; var L: longint);
procedure CondValue(notOp: TSym; signed: boolean; fj, tj: longint);
procedure JumpBack(top: longint);
procedure Fix(L: longint);
procedure FixTo(L, top: longint);
function JoinJumps(L1, L2: longint): longint;

procedure CheckIndex(n: int64; const p: TPos);
procedure CheckEnum(n: int64; name: longint; const p: TPos);
procedure CheckNil(reach: int64; const p: TPos);
procedure IndexSlice(const a: TAdr; size: int64; checked: boolean; const p: TPos);
procedure Slice(const a: TAdr; isArray: boolean; n, size, tmp: int64; checked: boolean; const p: TPos);
procedure SlicePtr(size, tmp: int64; checked: boolean; const p: TPos);
procedure CopySlice(dOff, sOff, size: int64; checked: boolean; const p: TPos);

procedure PopArg(var c: TCall);
procedure Call(var c: TCall);

function AllocTemp(size, align: int64): int64;
function AllocPerm(size, align: int64): int64;
function TempMark: int64;
procedure ReleaseTemps(m: int64);
procedure KeepTemps;

procedure BeginProc(sig: PType; params: PObj);
procedure UseRegs(mask: longint; at: int64);
procedure MarkCode(var m: TCodeMark);
procedure Redo(const m: TCodeMark);
procedure EnterBody(c, line: longint);
procedure ResultTo(off: int64; size: longint);
procedure CopyResult(off, size: int64);
procedure ReturnJump;
procedure EndProc(c: longint);
function DeferBegin(var L, saved: longint): longint;
procedure DeferEnd(L, saved: longint);
procedure RunDefer(at: longint);

function EntryPoint(dynamic: boolean; first: PModule; main: PObj; cExit, places, placesVar, exitProc: longint): longint;
procedure CodeProc(c: longint; constExpr: TConstFn);

implementation

type
  { where a value on the stack is }
  TLoc = (lConst,     { not loaded: val is the value }
          lHeld,      { not loaded: in register val, a variable's own,
                        which nothing in an expression can change }
          lAdr,       { not loaded: the address of chunk, or of the frame
                        if chunk is -1, plus val }
          lReg,       { in its register }
          lFrame);    { spilled: in the frame slot val }

  TEntry = record
    loc: TLoc;
    val: int64;
    chunk: longint;
    k: TKind;
  end;

const
  { the registers of the stack: the value at depth d is in Regs[d mod
    NumRegs]. rax, rdx and rcx, which division and shifts need, and rsi
    and rdi, which copying needs, aren't among them. }
  NumRegs = 4;
  Regs: array[0..NumRegs - 1] of longint = (R8, R9, R10, R11);
  IntRegs: array[0..5] of longint = (RDI, RSI, RDX, RCX, R8, R9);

var
  stack: array[0..255] of TEntry;
  owner: array[0..NumRegs - 1] of longint;   { the value in each register, or -1 }
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
  inObj: array[0..13] of PObj;
  numIn: longint;
  procParams: PObj;             { the parameters, for EnterBody }
  regMask: longint;             { the registers of variables, as bits of VarRegs }
  saveAt: int64;                { where they are saved, a quadword each }
  frameAt: array[0..2] of int64;   { frameTop, frameMax, permTop after the declarations }

function KindOf(t: PType): TKind;
begin
  if t^.form = fReal then begin
    if t^.size = 4 then KindOf := kF32 else KindOf := kF64
  end else if t^.size > WordSize then KindOf := kLong
  else KindOf := kWord;
end;

{ The stack, as in Wirth's compilers: the value at depth d is held in
  register d, for as many registers as there are. A value deeper than
  that, when its register is wanted, and every value in a register
  when a call would clobber them, is spilled to a frame slot, and loaded
  again where it is used. A constant is only noted. }

function RegOf(i: longint): longint;
begin
  RegOf := Regs[i mod NumRegs];
end;

{ The value i, in a register, goes to a frame slot }
procedure Spill(i: longint);
var s: int64;
begin
  s := AllocTemp(8, 8);
  Store(Mem(RBP, s), RegOf(i), 8);
  stack[i].loc := lFrame;
  stack[i].val := s;
  owner[i mod NumRegs] := -1;
end;

{ Every value below depth d in a register, spilled }
procedure SpillBelow(d: longint);
var r: longint;
begin
  for r := 0 to NumRegs - 1 do
    if (owner[r] >= 0) and (owner[r] < d) then Spill(owner[r]);
end;

{ The register of value i, for it to hold: a deeper value in it is
  spilled. }
function Claim(i: longint): longint;
var r: longint;
begin
  r := i mod NumRegs;
  if (owner[r] >= 0) and (owner[r] <> i) then Spill(owner[r]);
  owner[r] := i;
  Claim := Regs[r];
end;

{ The memory at the noted address i, plus off }
function AdrMem(i: longint; off: int64): TMem;
begin
  if stack[i].chunk < 0 then AdrMem := Mem(RBP, stack[i].val + off)
  else AdrMem := MemRip(stack[i].chunk, stack[i].val + off);
end;

{ The value i, in its register }
function Loaded(i: longint): longint;
var r: longint;
begin
  if stack[i].loc <> lReg then begin
    r := Claim(i);
    if stack[i].loc = lConst then MovRI(r, stack[i].val)
    else if stack[i].loc = lHeld then MovRR(r, stack[i].val)
    else if stack[i].loc = lAdr then Lea(r, AdrMem(i, 0))
    else Load(r, Mem(RBP, stack[i].val), 8, false);
    stack[i].loc := lReg;
  end;
  Loaded := RegOf(i);
end;

{ The register value i is in, only to be read: a variable's own, or
  its register }
function Peek(i: longint): longint;
begin
  if stack[i].loc = lHeld then Peek := stack[i].val else Peek := Loaded(i);
end;

function Top: longint;
begin
  if depth = 0 then Fatal('internal error: the stack is empty');
  Top := Loaded(depth - 1);
end;

procedure NewEntry(k: TKind; loc: TLoc; v: int64);
begin
  if depth > High(stack) then Mark('the expression is too deep');
  stack[depth].k := k;
  stack[depth].loc := loc;
  stack[depth].val := v;
  stack[depth].chunk := -1;
  inc(depth);
end;

{ The register a new value on top is to be computed in }
function Target: longint;
begin
  Target := Claim(depth);
end;

{ The value just computed in Target goes on top }
procedure Computed(k: TKind);
begin
  NewEntry(k, lReg, 0);
end;

procedure Drop;
begin
  dec(depth);
  if stack[depth].loc = lReg then owner[depth mod NumRegs] := -1;
end;

{ Whether the value on top is a constant, and if so, which }
function TopConst(var v: int64): boolean;
begin
  TopConst := stack[depth - 1].loc = lConst;
  v := stack[depth - 1].val;
end;

procedure ResetStack(d, p: longint);
var r: longint;
begin
  depth := d;
  pushed := p;
  for r := 0 to NumRegs - 1 do owner[r] := -1;
end;

procedure PushConst(k: TKind; v: int64);
begin
  NewEntry(k, lConst, v);
end;

function Fits32(v: int64): boolean;
begin
  Fits32 := (v >= low(longint)) and (v <= high(longint));
end;

{ The memory a names. An address on the stack is popped, and is in its
  register still; one in a slot is loaded into r. }
function Place(const a: TAdr; r: longint): TMem;
var ra: longint;
begin
  if a.base = bReg then Fatal('internal error: a register has no address');
  case a.base of
    bFrame: Place := Mem(RBP, a.off);
    bGlobal: Place := MemRip(a.chunk, a.off);
    bStack:
      if stack[depth - 1].loc = lAdr then begin
        Place := AdrMem(depth - 1, a.off);
        Drop;
      end else begin
        ra := Peek(depth - 1);
        Drop;
        Place := Mem(ra, a.off)
      end;
  else
    Load(r, Mem(RBP, a.chunk), 8, false);
    Place := Mem(r, a.off);
  end;
end;

procedure PushAdr(const a: TAdr);
var m: TMem; r: longint;
begin
  if (a.base = bStack) and (a.off = 0) then exit;
  if a.base in [bFrame, bGlobal] then begin
    NewEntry(kWord, lAdr, a.off);
    if a.base = bGlobal then stack[depth - 1].chunk := a.chunk;
    exit;
  end;
  if a.base = bStack then begin m := Place(a, -1); r := Target end
  else begin r := Target; m := Place(a, r) end;
  Lea(r, m);
  Computed(kWord);
end;

procedure PushVar(const a: TAdr; size: longint; signed: boolean; k: TKind);
var m: TMem; r: longint;
begin
  if a.base = bReg then begin
    NewEntry(k, lHeld, a.chunk);
    exit;
  end;
  if a.base = bStack then begin m := Place(a, -1); r := Target end
  else begin r := Target; m := Place(a, r) end;
  Load(r, m, size, signed);
  Computed(k);
end;

procedure PushProc(c: longint; ext: boolean);
var r: longint;
begin
  r := Target;
  if ext then Load(r, MemRip(c, 0), 8, false)
  else Lea(r, MemRip(c, 0));
  Computed(kWord);
end;

{ Pops a value into the variable at a; an address on the stack is under
  the value. }
procedure PopVar(const a: TAdr; size: longint);
var r: longint; v: int64;
begin
  if a.base = bReg then begin
    if TopConst(v) then MovRI(a.chunk, v) else MovRR(a.chunk, Peek(depth - 1));
    Drop;
    exit;
  end;
  if TopConst(v) and Fits32(v) then begin
    Drop;
    StoreI(Place(a, RCX), v, size);
    exit;
  end;
  if TopConst(v) then begin r := RAX; MovRI(RAX, v) end
  else r := Peek(depth - 1);
  Drop;
  Store(Place(a, RCX), r, size);
end;

{ The two values on top change places. }
procedure Swap;
var e: TEntry; x, y: longint; rx, ry: boolean;
begin
  x := depth - 2; y := depth - 1;
  rx := stack[x].loc = lReg;
  ry := stack[y].loc = lReg;
  if rx and ry then begin
    MovRR(RAX, RegOf(x));
    MovRR(RegOf(x), RegOf(y));
    MovRR(RegOf(y), RAX);
  end else if rx then begin
    owner[x mod NumRegs] := -1;
    MovRR(Claim(y), RegOf(x));
  end else if ry then begin
    owner[y mod NumRegs] := -1;
    MovRR(Claim(x), RegOf(y));
  end;
  e := stack[x]; stack[x] := stack[y]; stack[y] := e;
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
  MovRR(RSI, Top);
  Drop;
  MovRR(RDI, Top);
  Drop;
  if off <> 0 then Lea(RDI, Mem(RDI, off));
  CopyBytes(size);
end;

{ Pops a source's address, and copies size bytes to a. }
procedure CopyTo(const a: TAdr; size: int64);
begin
  MovRR(RSI, Top);
  Drop;
  Lea(RDI, Place(a, RDI));
  CopyBytes(size);
end;

procedure ZeroVar(const a: TAdr; size: int64);
begin
  Lea(RDI, Place(a, RDI));
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

{ r compared with v, through rdx if v needs more than 32 bits }
procedure CmpI(r: longint; v: int64);
begin
  if Fits32(v) then AluI(aluCmp, r, v)
  else begin MovRI(RDX, v); Alu(aluCmp, r, RDX) end;
end;

{ r div or mod 2^k, 1 <= k <= 62, with shifts: div truncates towards
  zero, so a negative dividend first gets 2^k - 1 added (the bias). }
procedure DivPow2(op: TSym; r, k: longint; unsign: boolean);
begin
  if unsign then begin
    if op = sDiv then ShiftI(shShr, r, k)
    else begin ShiftI(shShl, r, 64 - k); ShiftI(shShr, r, 64 - k) end;
    exit;
  end;
  MovRR(RCX, r);
  ShiftI(shSar, RCX, 63);
  ShiftI(shShr, RCX, 64 - k);
  Alu(aluAdd, RCX, r);
  ShiftI(shSar, RCX, k);
  if op = sDiv then MovRR(r, RCX)
  else begin ShiftI(shShl, RCX, k); Alu(aluSub, r, RCX) end;
end;

{ Before rax div y, of a signed type of bits < 64: its smallest value
  divided by -1 overflows it, which must stop the program as it does for
  an I64 (report section 6.1). idiv on the 64-bit values wouldn't fault,
  so then rax is made the smallest I64, and it does. }
procedure DivTrap(bits, y: longint);
var L: longint;
begin
  L := NoLabel;
  CmpI(y, -1);
  Jcc(ccNE, L);
  CmpI(RAX, int64(-1) shl (bits - 1));
  Jcc(ccNE, L);
  ShiftI(shShl, RAX, 64 - bits);
  FixLink(L);
end;

{ The right operand of the two values on top, popped, in register y:
  its own, or rcx for a constant; the left one stays, in its register,
  which is returned. }
function Operands(var y: longint): longint;
var v: int64;
begin
  if TopConst(v) then begin MovRI(RCX, v); y := RCX end else y := Peek(depth - 1);
  Drop;
  Operands := Top;
end;

procedure RealOp(op: TSym; k: TKind);
var f: boolean; r, y: longint;
begin
  f := k = kF32;
  r := Operands(y);
  MovqXR(0, r);
  MovqXR(1, y);
  case op of
    sPlus: Sse($58, 0, 1, f);
    sMinus: Sse($5C, 0, 1, f);
    sTimes: Sse($59, 0, 1, f);
    sSlash: Sse($5E, 0, 1, f);
  end;
  MovqRX(r, 0);
end;

{ The group 1 operation of +, -, &, | and xor }
function AluOf(op: TSym): longint;
begin
  case op of
    sPlus: AluOf := aluAdd;
    sMinus: AluOf := aluSub;
    sAmp: AluOf := aluAnd;
    sBar: AluOf := aluOr;
  else AluOf := aluXor;
  end;
end;

{ The two values on top, the left op the right, an integer of size
  bytes, signed or not, brought back to its width. }
procedure Op(op: TSym; k: TKind; size: longint; signed: boolean);
var v: int64; r, y, sh, bits: longint; c: boolean;
begin
  if k in [kF32, kF64] then begin RealOp(op, k); exit end;
  bits := size * 8;
  c := TopConst(v);
  sh := -1;
  if c and (op in [sTimes, sDiv, sMod]) then sh := Log2(v);
  if c and (sh >= 1) then begin
    Drop;
    r := Top;
    if op = sTimes then ShiftI(shShl, r, sh) else DivPow2(op, r, sh, not signed);
  end else if c and Fits32(v) and (op in [sPlus, sMinus, sBar, sXor, sAmp, sTimes, sShl, sShr]) then begin
    Drop;
    r := Top;
    case op of
      sTimes: ImulI(r, v);
      sShl: ShiftI(shShl, r, v and (bits - 1));
      sShr: if signed then ShiftI(shSar, r, v and (bits - 1)) else ShiftI(shShr, r, v and (bits - 1));
    else AluI(AluOf(op), r, v);
    end;
  end else begin
    r := Operands(y);
    case op of
      sPlus, sMinus, sAmp, sBar, sXor: Alu(AluOf(op), r, y);
      sTimes: Imul(r, y);
      sDiv, sMod: begin
        MovRR(RAX, r);
        if not signed then begin MovRI(RDX, 0); Unary(6, y) end
        else begin
          if (bits < 64) and (not c or (v = -1)) then DivTrap(bits, y);
          Cqo; Unary(7, y)
        end;
        if op = sDiv then MovRR(r, RAX) else MovRR(r, RDX);
      end;
      sShl, sShr: begin
        { the count modulo the width: the machine takes it modulo 64 }
        if y <> RCX then MovRR(RCX, y);
        if bits < 64 then AluI(aluAnd, RCX, bits - 1);
        if op = sShl then Shift(shShl, r)
        else if signed then Shift(shSar, r) else Shift(shShr, r);
      end;
    end;
  end;
  if bits < 64 then Extend(r, size, signed);
  stack[depth - 1].k := k;
end;

{ The left op the right of the two values on top, as a BOOL }
procedure Compare(op: TSym; k: TKind; signed: boolean);
const
  CcSigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccL, ccLE, ccG, ccGE);
  CcUnsigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccB, ccBE, ccA, ccAE);
var f: boolean; r, y: longint; v: int64;
begin
  if k in [kF32, kF64] then begin
    f := k = kF32;
    r := Operands(y);
    MovqXR(0, r);
    MovqXR(1, y);
    case op of
      sEql: begin Ucomis(0, 1, f); SetCC(ccE, r); SetCC(ccNP, RCX); Alu(aluAnd, r, RCX) end;
      sNeq: begin Ucomis(0, 1, f); SetCC(ccNE, r); SetCC(ccP, RCX); Alu(aluOr, r, RCX) end;
      sLss: begin Ucomis(1, 0, f); SetCC(ccA, r) end;
      sLeq: begin Ucomis(1, 0, f); SetCC(ccAE, r) end;
      sGtr: begin Ucomis(0, 1, f); SetCC(ccA, r) end;
      sGeq: begin Ucomis(0, 1, f); SetCC(ccAE, r) end;
    end;
  end else begin
    if TopConst(v) then begin Drop; r := Top; CmpI(r, v) end
    else begin r := Operands(y); Alu(aluCmp, r, y) end;
    if signed then SetCC(CcSigned[op], r) else SetCC(CcUnsigned[op], r);
  end;
  stack[depth - 1].k := kWord;
end;

procedure Neg(k: TKind; size: longint; signed: boolean);
var r: longint;
begin
  r := Top;
  case k of
    kF32: Btc(r, 31);
    kF64: Btc(r, 63);
  else
    Unary(3, r);
    if size < 8 then Extend(r, size, signed);
  end;
end;

procedure Complement(size: longint; signed: boolean);
var r: longint;
begin
  r := Top;
  Unary(2, r);
  if size < 8 then Extend(r, size, signed);
end;

procedure NotBool;
begin
  AluI(aluXor, Top, 1);
end;

{ The integer on top, brought to size bytes }
procedure Narrow(size: longint; signed: boolean);
var r: longint;
begin
  r := Top;
  if size < 8 then Extend(r, size, signed);
  stack[depth - 1].k := kWord;
end;

{ The integer on top, as a real of kind k; big if it may be a U64 above
  high(I64), which the machine would take as negative }
procedure IntToReal(k: TKind; big: boolean);
var L1, L2, r: longint; f: boolean;
begin
  f := k = kF32;
  r := Top;
  if big then begin
    { above high(I64): halve, keeping the low bit, and double }
    L1 := NoLabel; L2 := NoLabel;
    TestRR(r, r);
    Jcc(ccS, L1);
    Cvtsi2s(0, r, f);
    Jmp(L2);
    FixLink(L1);
    MovRR(RCX, r);
    ShiftI(shShr, RCX, 1);
    AluI(aluAnd, r, 1);
    Alu(aluOr, RCX, r);
    Cvtsi2s(0, RCX, f);
    Sse($58, 0, 0, f);
    FixLink(L2);
  end else Cvtsi2s(0, r, f);
  MovqRX(r, 0);
  stack[depth - 1].k := k;
end;

{ The real of kind k on top, truncated to an integer }
procedure RealToInt(k: TKind);
var r: longint;
begin
  r := Top;
  MovqXR(0, r);
  Cvtts2si(r, 0, k = kF32);
  stack[depth - 1].k := kWord;
end;

{ The real of kind k on top, as the other kind }
procedure RealToReal(k: TKind);
var r: longint;
begin
  r := Top;
  MovqXR(0, r);
  Sse($5A, 0, 0, k = kF32);
  MovqRX(r, 0);
  if k = kF32 then stack[depth - 1].k := kF64 else stack[depth - 1].k := kF32;
end;

{ Whether the slices in the frame at a and b are equal (or not, if not
  eq): the lengths, then the bytes, len shl shift of them, compared
  right where the comparison stands. }
procedure CompareSeq(a, b: int64; shift: longint; eq: boolean);
var differ, r: longint;
begin
  r := Target;
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
  if eq then SetCC(ccE, r) else SetCC(ccNE, r);
  Computed(kWord);
end;

{ An error is the address of its length, followed by its message: pops
  one, and makes the slice of its message at tmp, empty for nil. }
procedure ErrorText(tmp: int64);
var L: longint;
begin
  MovRR(RAX, Top);
  Drop;
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
var r, y, op: longint; v: int64; a: TAdr;
begin
  if TopConst(v) and Fits32(v) then begin
    Drop;
    a.base := bStack; a.off := 0;
    if dec then op := aluSub else op := aluAdd;
    AluMI(op, Place(a, RCX), v, size);
    exit;
  end;
  r := Operands(y);
  Drop;
  Load(RAX, Mem(r, 0), size, signed);
  if dec then Alu(aluSub, RAX, y) else Alu(aluAdd, RAX, y);
  Store(Mem(r, 0), RAX, size);
end;

{ INC or DEC of the variable in register r, by the value on top; a
  narrow one wraps at its width }
procedure IncDecReg(r, size: longint; signed, dec: boolean);
var y, op: longint; v: int64;
begin
  if dec then op := aluSub else op := aluAdd;
  if TopConst(v) and Fits32(v) then AluI(op, r, v)
  else begin y := Top; Alu(op, r, y) end;
  Drop;
  if size < 8 then Extend(r, size, signed);
end;

{ The pointer on top, which NEW got, to size zero bytes unless nil }
procedure ZeroNew(size: int64);
var L, r: longint;
begin
  r := Top;
  L := NoLabel;
  TestRR(r, r);
  Jcc(ccE, L);
  MovRR(RDI, r);
  MovRI(RCX, size);
  MovRI(RAX, 0);
  RepStosb;
  FixLink(L);
end;

{ CAS(p, old, new), XCHG(p, v) or XADD(p, v), from the stack: the
  result where p was }
procedure Atomic(which: longint);
var r, n: longint;
begin
  if which = bCas then begin n := Top; Drop end;
  MovRR(RAX, Top);
  Drop;
  r := Top;
  case which of
    bCas: begin LockCmpxchg(Mem(r, 0), n); SetCC(ccE, r) end;
    bXchg: begin Xchg(Mem(r, 0), RAX); MovRR(r, RAX) end;
    bXadd: begin LockXadd(Mem(r, 0), RAX); MovRR(r, RAX) end;
  end;
  stack[depth - 1].k := kWord;
end;

{ The system call and its arguments, n values on the stack; every value
  in a register is spilled first, as the arguments go in its registers }
procedure SysCall(n: longint);
const SysRegs: array[0..6] of longint = (RAX, RDI, RSI, RDX, R10, R8, R9);
var i: longint;
begin
  SpillBelow(depth);
  for i := 0 to n - 1 do
    with stack[depth - n + i] do
      if loc = lConst then MovRI(SysRegs[i], val)
      else if loc = lHeld then MovRR(SysRegs[i], val)
      else if loc = lAdr then Lea(SysRegs[i], AdrMem(depth - n + i, 0))
      else Load(SysRegs[i], Mem(RBP, val), 8, false);
  for i := 1 to n do Drop;
  x64.Syscall;
  MovRR(Target, RAX);
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
var r: longint;
begin
  r := Top;
  Drop;
  TestRR(r, r);
  if when then Jcc(ccNE, L) else Jcc(ccE, L);
end;

{ Pops two integers, and jumps if the left op the right }
procedure JumpCmp(op: TSym; signed: boolean; var L: longint);
const
  CcSigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccL, ccLE, ccG, ccGE);
  CcUnsigned: array[sEql..sGeq] of longint = (ccE, ccNE, ccB, ccBE, ccA, ccAE);
var r, y: longint; v: int64;
begin
  { a comparison changes neither: a variable's register will do }
  if TopConst(v) then begin Drop; r := Peek(depth - 1); CmpI(r, v) end
  else begin y := Peek(depth - 1); Drop; r := Peek(depth - 1); Alu(aluCmp, r, y) end;
  Drop;
  if signed then Jcc(CcSigned[op], L) else Jcc(CcUnsigned[op], L);
end;

{ JumpCmp out of an expression, past code that may spill: the values
  under the two compared are spilled first, so that they are where the
  code after the landing place expects them, whichever way it came. }
procedure JumpOut(op: TSym; signed: boolean; var L: longint);
begin
  SpillBelow(depth - 2);
  JumpCmp(op, signed, L);
end;

{ The comparison of the two values on top, unless notOp holds, as a
  BOOL; jumps on its false path (fj) and its true one (tj) land as well }
procedure CondValue(notOp: TSym; signed: boolean; fj, tj: longint);
var r, e: longint;
begin
  JumpOut(notOp, signed, fj);
  FixLink(tj);
  r := Target;
  MovRI(r, 1);
  e := NoLabel;
  Jmp(e);
  FixLink(fj);
  MovRI(r, 0);
  FixLink(e);
  Computed(kWord);
end;

procedure JumpBack(top: longint);
begin
  JmpBack(top);
end;

procedure Fix(L: longint);
begin
  FixLink(L);
end;

function JoinJumps(L1, L2: longint): longint;
begin
  JoinJumps := JoinLinks(L1, L2);
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
  after it the place before it again; it never returns, and may use
  any register once it has read what it needs. }
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
var r: longint;
begin
  r := Top;
  CmpI(r, n);
  Check(ccB, 0, p, r, NoMem, n, -1);
end;

{ The integer on top is a position of an enumeration of n names }
procedure CheckEnum(n: int64; name: longint; const p: TPos);
var r: longint;
begin
  r := Top;
  CmpI(r, n);
  Check(ccB, 2, p, r, NoMem, n, name);
end;

{ The address on top, from a pointer, which is to be used reach bytes
  past: the program stops if it is nil, unless the machine would stop
  it, as for a reach within NilPage. }
procedure CheckNil(reach: int64; const p: TPos);
var r: longint;
begin
  if reach <= NilPage then exit;
  r := Top;
  TestRR(r, r);
  Check(ccNE, 4, p, r, NoMem, 0, -1);
end;

{ Pops an index, and the address of the slice at a if it is on the
  stack, and pushes the address of its element of size bytes. }
procedure IndexSlice(const a: TAdr; size: int64; checked: boolean; const p: TPos);
var m, ml: TMem;
begin
  MovRR(RAX, Top);
  Drop;
  m := Place(a, RCX);
  ml := m; ml.disp := ml.disp + 8;
  if checked then begin
    AluM(aluCmp, RAX, ml);
    Check(ccB, 0, p, RAX, ml, 0, -1);
  end;
  if size <> 1 then ImulI(RAX, size);
  AluM(aluAdd, RAX, m);
  MovRR(Target, RAX);
  Computed(kWord);
end;

{ Pops lo and hi, and the address of the array or slice at a if it is
  on the stack, and makes the slice lo..hi of it, with elements of size
  bytes, in the frame at tmp; the array has n elements. }
procedure Slice(const a: TAdr; isArray: boolean; n, size, tmp: int64; checked: boolean; const p: TPos);
var m, ml: TMem;
begin
  MovRR(RDX, Top);
  Drop;
  MovRR(RCX, Top);
  Drop;
  m := Place(a, RDI);
  ml := m; ml.disp := ml.disp + 8;
  if checked then begin
    if isArray then begin CmpI(RDX, n); ml := NoMem end
    else AluM(aluCmp, RDX, ml);
    Check(ccBE, 1, p, RCX, ml, n, -1);
    Alu(aluCmp, RCX, RDX);
    Check(ccBE, 1, p, RCX, ml, n, -1);
  end;
  MovRR(RAX, RDX);
  Alu(aluSub, RAX, RCX);
  Store(Mem(RBP, tmp + 8), RAX, 8);
  if size <> 1 then ImulI(RCX, size);
  if isArray then Lea(RAX, m) else Load(RAX, m, 8, false);
  Alu(aluAdd, RAX, RCX);
  Store(Mem(RBP, tmp), RAX, 8);
end;

{ COPY: the elements of the slice in the frame at sOff, of size bytes
  each, to the start of the one at dOff, which must be as long, as one
  block; backwards when the destination is above the source, so that
  an overlap comes out right. }
procedure CopySlice(dOff, sOff, size: int64; checked: boolean; const p: TPos);
var ml: TMem; L, E: longint;
begin
  Load(RDX, Mem(RBP, sOff + 8), 8, false);
  if checked then begin
    ml := Mem(RBP, dOff + 8);
    MovRI(RAX, 0);
    AluM(aluCmp, RDX, ml);
    Check(ccBE, 1, p, RAX, ml, 0, -1);
  end;
  MovRR(RCX, RDX);
  if size <> 1 then ImulI(RCX, size);
  Load(RSI, Mem(RBP, sOff), 8, false);
  Load(RDI, Mem(RBP, dOff), 8, false);
  Alu(aluCmp, RDI, RSI);
  L := NoLabel;
  Jcc(ccBE, L);
  Lea(RSI, MemIdx(RSI, RCX, 1, -1));
  Lea(RDI, MemIdx(RDI, RCX, 1, -1));
  Std;
  RepMovsb;
  Cld;
  E := NoLabel;
  Jmp(E);
  FixLink(L);
  RepMovsb;
  FixLink(E);
end;

{ Pops a pointer, lo and hi, and makes the slice p[lo..hi] at tmp. Its
  bounds can't be known, but it can't run backwards. }
procedure SlicePtr(size, tmp: int64; checked: boolean; const p: TPos);
begin
  MovRR(RDX, Top);
  Drop;
  MovRR(RCX, Top);
  Drop;
  MovRR(RDI, Top);
  Drop;
  if checked then begin
    Alu(aluCmp, RCX, RDX);
    Check(ccLE, 3, p, RCX, NoMem, 0, -1);
  end;
  MovRR(RAX, RDX);
  Alu(aluSub, RAX, RCX);
  Store(Mem(RBP, tmp + 8), RAX, 8);
  if size <> 1 then ImulI(RCX, size);
  Alu(aluAdd, RCX, RDI);
  Store(Mem(RBP, tmp), RCX, 8);
end;

{ Calls }

{ The call c, its arguments already in their frame slots: they go to
  registers or the stack, the procedure is called, and its result, if
  any, is pushed on the value stack. }
{ The value on top is argument c.n of c, which waits for the call: a
  constant or an address is noted, a real or anything else goes to a
  frame slot. }
procedure PopArg(var c: TCall);
var i: longint;
begin
  i := depth - 1;
  c.how[c.n] := argSlot;
  if not c.isF[c.n] and (stack[i].loc = lConst) then c.how[c.n] := argConst
  else if stack[i].loc = lAdr then c.how[c.n] := argAdr
  else if stack[i].loc = lHeld then c.how[c.n] := argHeld;
  if c.how[c.n] = argSlot then begin
    c.slots[c.n] := AllocTemp(8, 8);
    Store(Mem(RBP, c.slots[c.n]), Top, 8);
  end else begin
    c.slots[c.n] := stack[i].val;
    c.adrChunk[c.n] := stack[i].chunk;
  end;
  Drop;
end;

{ Argument i of c into register r }
procedure LoadArg(const c: TCall; i, r: longint);
begin
  case c.how[i] of
    argConst: MovRI(r, c.slots[i]);
    argHeld: MovRR(r, c.slots[i]);
    argAdr:
      if c.adrChunk[i] < 0 then Lea(r, Mem(RBP, c.slots[i]))
      else Lea(r, MemRip(c.adrChunk[i], c.slots[i]));
  else Load(r, Mem(RBP, c.slots[i]), 8, false);
  end;
end;

procedure Call(var c: TCall);
var
  res: PType; i, ni, nf, k, pad, r: longint;
  onStack: array[0..63] of boolean;
begin
  SpillBelow(depth);   { the registers in use, saved around the call }
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
  { System V wants rsp a multiple of 16 at the call: a quadword of
    padding makes the count pushed since the frame began even }
  pad := ord(odd(pushed + k));
  if pad <> 0 then AluI(aluSub, RSP, 8);
  for i := c.n - 1 downto 0 do
    if onStack[i] then begin
      LoadArg(c, i, RAX);
      Push(RAX);
    end;
  ni := 0; nf := 0;
  if (c.ret <> 0) and not c.code then begin Lea(RDI, Mem(RBP, c.ret)); ni := 1 end;
  for i := 0 to c.n - 1 do
    if not onStack[i] then
      if c.isF[i] then begin MovsdXM(nf, Mem(RBP, c.slots[i])); inc(nf) end
      else begin LoadArg(c, i, IntRegs[ni]); inc(ni) end;
  { a procedure taking ... is told in al how many xmm registers it got }
  if c.sig^.variadic then MovRI(RAX, nf);
  if c.ext then CallM(MemRip(c.chunk, 0))
  else if c.chunk >= 0 then CallChunk(c.chunk)
  else begin
    { r11 is scratch: caller-saved, carrying no argument, and free,
      as the value stack was spilled above }
    Load(R11, Mem(RBP, c.target), 8, false);
    CallR(R11);
  end;
  if k + pad > 0 then AluI(aluAdd, RSP, 8 * (k + pad));
  if (c.ret <> 0) and c.code then begin
    Store(Mem(RBP, c.ret), RAX, 8);
    Store(Mem(RBP, c.ret + 8), RDX, 8);
  end;
  if (res <> nil) and (c.ret = 0) then begin
    r := Target;
    if res^.form = fReal then MovqRX(r, 0)
    else begin
      MovRR(r, RAX);
      if res^.form = fBool then Extend(r, 1, false)
      else if (res^.form = fInt) and (res^.size < 8) then Extend(r, res^.size, res^.signed);
    end;
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
  procParams := params;
  regMask := 0;
  ni := 0; nf := 0; stackOff := 16;
  if (resType <> nil) and IsAggregate(resType) then begin
    retSlot := AllocPerm(8, 8);
    inReg[0] := RDI; inSlot[0] := retSlot; inSize[0] := 8; inObj[0] := nil;
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
      inObj[numIn] := p;
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

{ The procedure keeps variables in the registers of mask, saved at at;
  the frame as it stands is where a second try at its body starts. }
procedure UseRegs(mask: longint; at: int64);
begin
  regMask := mask;
  saveAt := at;
  frameAt[0] := frameTop; frameAt[1] := frameMax; frameAt[2] := permTop;
end;

procedure MarkCode(var m: TCodeMark);
begin
  m.pc := pc; m.fixups := numFixups; m.lines := numLines; m.said := SaidCount;
end;

{ For a second try at the body: the code as it was at m, and the frame
  as UseRegs found it }
procedure Redo(const m: TCodeMark);
begin
  pc := m.pc; numFixups := m.fixups; numLines := m.lines; Unsay(m.said);
  frameTop := frameAt[0]; frameMax := frameAt[1]; permTop := frameAt[2];
  exitL := NoLabel;
end;

{ The prologue, which is for the procedure's first line. Only the
  locals are zeroed: the parameters are stored over their slots next,
  and every temporary is written before it is read. The locals are all
  declared by now, below the parameters' slots. }
procedure EnterBody(c, line: longint);
var i, top: longint; n: int64; p: PObj;
begin
  BeginChunk(c);
  codeChunk := c;
  NoteLine(line, 1);   { a declaration starts a line }
  Push(RBP);
  MovRR(RBP, RSP);
  Say('sub rsp, frame');
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
  { the registers of variables: saved, as a variable starts at zero,
    a parameter taken from where it came }
  chunks^[c].saveMask := regMask;
  chunks^[c].saveAt := saveAt;
  n := 0;
  for i := 0 to 4 do
    if regMask and (1 shl i) <> 0 then begin
      Store(Mem(RBP, saveAt + 8 * n), VarRegs[i], 8);
      MovRI(VarRegs[i], 0);
      inc(n);
    end;
  for i := 0 to numIn - 1 do
    if inReg[i] < 0 then MovsdMX(Mem(RBP, inSlot[i]), -1 - inReg[i])
    else if (inObj[i] <> nil) and (inObj[i]^.reg <> 0) then begin
      MovRR(inObj[i]^.reg, inReg[i]);
      if inSize[i] < 8 then Extend(inObj[i]^.reg, inSize[i], inObj[i]^.typ^.signed);
    end else Store(Mem(RBP, inSlot[i]), inReg[i], inSize[i]);
  p := procParams;
  while p <> nil do begin
    if (p^.reg <> 0) and (p^.val > 0) then
      if p^.typ^.form in [fInt, fBool, fEnum, fSet] then
        Load(p^.reg, Mem(RBP, p^.val), p^.typ^.size, p^.typ^.signed)
      else Load(p^.reg, Mem(RBP, p^.val), 8, false);
    p := p^.next;
  end;
end;

{ Pops one of several results, a value of size bytes, into its place
  off bytes into the caller's, behind the hidden pointer. }
procedure ResultTo(off: int64; size: longint);
var r: longint;
begin
  r := Top;
  Drop;
  Load(RCX, Mem(RBP, retSlot), 8, false);
  Store(Mem(RCX, off), r, size);
end;

{ Pops an address, and copies size bytes from it to the result, off
  bytes into it. }
procedure CopyResult(off, size: int64);
begin
  MovRR(RSI, Top);
  Drop;
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
      if resType^.form = fReal then MovqXR(0, Top) else MovRR(RAX, Top);
      Drop;
    end;
  Jmp(exitL);
end;

{ The end of the procedure in chunk c: the code that returns, and the
  frame's size, known only now, patched into its prologue. }
procedure EndProc(c: longint);
var n: int64; i: longint;
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
  n := 0;
  for i := 0 to 4 do
    if regMask and (1 shl i) <> 0 then begin
      Load(VarRegs[i], Mem(RBP, saveAt + 8 * n), 8, false);
      inc(n);
    end;
  Leave;
  Ret;
  n := AlignUp(frameMax, 16);
  if n < 16 then n := 16;
  if n > high(longint) then Mark('frame too big');
  Put4At(frameFix, n);
  { the listing's text for the sub, which starts 3 bytes (REX.W, opcode,
    ModRM) before its immediate }
  Restate(frameFix - 3, 'sub rsp, ' + IntStr(n));
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

{ A code procedure: its instructions, read by the assembler (x64.pas),
  are the whole of chunk c }
procedure CodeProc(c: longint; constExpr: TConstFn);
begin
  BeginChunk(c);
  Assemble(constExpr);
  EndChunk(c);
end;

initialization
  ResetStack(0, 0);
  rtFail := NewChunk(secText, Intern('Rt', 2), Intern('fail', 4));
  argcChunk := NewChunk(secBss, -1, Intern('argc', 4));
  SetBss(argcChunk, 8, 8);
  argvChunk := NewChunk(secBss, -1, Intern('argv', 4));
  SetBss(argvChunk, 8, 8);
end.
