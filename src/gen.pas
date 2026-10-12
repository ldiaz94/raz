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
  right onto the stack, and moved into their registers just before the
  call: a call in a later argument spills the earlier ones, as any call
  spills the values under it, so that it can't disturb them. A slice goes as its two words, as System V passes a
  16-byte struct of two integers; a record, array or variant passed by
  value goes as the address of a copy the caller makes; one returned goes through a hidden pointer, as C's
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

  { The code made so far, to go back to for a second try at a body }
  TCodeMark = record pc, fixups, lines, said: longint; end;

  TCall = record
    sig: PType;
    param: PObj;       { the parameter the next argument is for }
    obj: PObj;         { the procedure called, if it has a name }
    n: longint;                      { the arguments }
    isF: array[0..63] of boolean;    { ... goes in an xmm register }
    pair: array[0..63] of boolean;   { ... is a slice's first word, the next its second }
    target: int64;     { the frame slot of a procedure value, if chunk < 0 }
    chunk: longint;    { else the procedure's chunk }
    ext: boolean;      { C's: called through the chunk holding its address }
    ret: int64;        { set by Call: the temporary a slice or a record result is in }
  end;

const
  { the registers a procedure keeps its busiest variables in: System V's
    callee-saved ones, so they live through calls; a procedure saves
    those it uses, and Rt finds them there for the trap report }
  VarRegs: array[0..4] of longint = (RBX, R12, R13, R14, R15);

var
  rtFail, argcChunk, argvChunk: longint;
  { the stubs that Check's code calls, one for each kind of failure,
    made by EntryPoint for those used }
  failStubs: array[0..5] of longint = (-1, -1, -1, -1, -1, -1);
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

procedure Call(var c: TCall);

function AllocTemp(size, align: int64): int64;
function AllocPerm(size, align: int64): int64;
function TempMark: int64;
procedure ReleaseTemps(m: int64);
procedure KeepTemps;

procedure BeginProc(sig: PType; params: PObj);
procedure LocalsFromScratch;
procedure UseRegs(mask: longint);
procedure MarkCode(var m: TCodeMark);
procedure Redo(const m: TCodeMark);
procedure EnterBody(c, line: longint);
procedure ResultTo(off: int64; size: longint);
procedure CopyResult(off, size: int64);
procedure ReturnJump;
procedure EndProc(c: longint; open: boolean);
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
  StubNames: array[0..5] of string[6] = ('check0', 'check1', 'check2', 'check3', 'check4', 'check5');
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
  zeroTop: int64;               { the locals the prologue zeroes end here }
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
  { the checks of the procedure, whose failures EndFails makes }
  fails: array[0..4095] of record
    L, what, ra, name, at: longint;
    m: TMem;
    n: int64;
  end;
  numFails: longint;

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

{ The value i into register r, from wherever it is: a constant or an
  address is made there, a variable's register or the value's own
  register copied, a spilled value loaded. Unlike Loaded, it leaves the
  value where it was, so r is its only new copy. }
procedure ValueTo(i, r: longint);
begin
  case stack[i].loc of
    lConst: MovRI(r, stack[i].val);
    lHeld: MovRR(r, stack[i].val);
    lAdr: Lea(r, AdrMem(i, 0));
    lReg: if RegOf(i) <> r then MovRR(r, RegOf(i));
  else Load(r, Mem(RBP, stack[i].val), 8, false);
  end;
end;

{ The value on top, popped into register r }
procedure PopTo(r: longint);
begin
  ValueTo(depth - 1, r);
  Drop;
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

{ r times v, a size: by a shift where v is a power of two, as it
  mostly is, since a shift takes one cycle and imul three }
procedure MulI(r: longint; v: int64);
begin
  if Log2(v) > 0 then ShiftI(shShl, r, Log2(v))
  else if v <> 1 then ImulI(r, v);
end;

{ r compared with v, through rdx if v needs more than 32 bits; with
  zero by test, which sets the flags as cmp would and is shorter }
procedure CmpI(r: longint; v: int64);
begin
  if v = 0 then TestRR(r, r)
  else if Fits32(v) then AluI(aluCmp, r, v)
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
  { a constant on the left of an operation whose order doesn't matter
    goes right, where it can be an immediate or a shift }
  if (op in [sPlus, sTimes, sAmp, sBar, sXor]) and (stack[depth - 2].loc = lConst)
    and (stack[depth - 1].loc <> lConst) then Swap;
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
  PopTo(RAX);
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
  r := Peek(depth - 1);
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
  m.base is NoBase. The failing code is out of the way, at the
  procedure's end (EndFails), so that a check that holds costs a jump
  not taken; it has p for its place, never returns, and may use any
  register once it has read what it needs. }
procedure Check(cc, what: longint; const p: TPos; ra: longint; const m: TMem; n: int64; name: longint);
begin
  if numFails > High(fails) then Mark('more than ' + IntStr(High(fails) + 1) + ' checks in one procedure');
  fails[numFails].L := NoLabel;
  Jcc(cc xor 1, fails[numFails].L);   { x86's conditions come in pairs, the other one its last bit flipped }
  fails[numFails].what := what;
  fails[numFails].ra := ra;
  fails[numFails].m := m;
  fails[numFails].n := n;
  fails[numFails].name := name;
  fails[numFails].at := p.a;
  inc(numFails);
end;

{ The failures of the procedure's checks: each gives Rt.fail its values
  and the place of the offending expression, through a stub for its
  kind, which takes the place from where it was called }
procedure EndFails;
var i, line, col: longint;
begin
  for i := 0 to numFails - 1 do
    with fails[i] do begin
      FixLink(L);
      LineCol(at, line, col);
      NoteLine(line, col);
      if ra <> RSI then MovRR(RSI, ra);
      if m.base = NoBase then MovRI(RCX, n) else Load(RCX, m, 8, false);
      if name >= 0 then Lea(R9, MemRip(name, 0));
      if failStubs[what] < 0 then failStubs[what] := NewChunk(secText, Intern('Rt', 2), Intern(@StubNames[what][1], 6));
      CallChunk(failStubs[what]);
    end;
  numFails := 0;
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
  stack, and pushes the address of its element of size bytes: the
  index, checked against the length, times size, plus the pointer.
  It is worked out in the index's own register, which then holds the
  address; but if the slice's address is on the stack, under the
  index, the element's register is the one that holds that, still
  needed, so the work is done in rax. }
procedure IndexSlice(const a: TAdr; size: int64; checked: boolean; const p: TPos);
var m, ml: TMem; r: longint; inRax: boolean;
begin
  inRax := a.base = bStack;
  if inRax then begin r := RAX; PopTo(RAX) end
  else begin r := Top; Drop end;
  m := Place(a, RCX);
  ml := m; ml.disp := ml.disp + 8;
  if checked then begin
    AluM(aluCmp, r, ml);
    Check(ccB, 0, p, r, ml, 0, -1);
  end;
  MulI(r, size);
  AluM(aluAdd, r, m);
  if inRax then MovRR(Target, RAX)
  else Claim(depth);   { the index's register again, now for the address }
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
  MulI(RCX, size);
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
  MulI(RCX, size);
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
  PopTo(RDX);
  PopTo(RCX);
  PopTo(RDI);
  if checked then begin
    Alu(aluCmp, RCX, RDX);
    Check(ccLE, 3, p, RCX, NoMem, 0, -1);
  end;
  MovRR(RAX, RDX);
  Alu(aluSub, RAX, RCX);
  Store(Mem(RBP, tmp + 8), RAX, 8);
  MulI(RCX, size);
  Alu(aluAdd, RCX, RDI);
  Store(Mem(RBP, tmp), RCX, 8);
end;

{ Calls }

{ The call c, its arguments already in their frame slots: they go to
  registers or the stack, the procedure is called, and its result, if
  any, is pushed on the value stack. }

procedure Call(var c: TCall);
var
  res: PType; i, ni, nf, k, pad, r, first: longint;
  onStack: array[0..63] of boolean; late: array[4..5] of longint;
begin
  { the arguments are the c.n values on top, where computing them left
    them; the registers in use under them are saved around the call }
  first := depth - c.n;
  SpillBelow(first);
  res := c.sig^.base;
  c.ret := 0;
  ni := 0; nf := 0;
  if (res <> nil) and (BehindPointer(res) or (res^.form = fSlice)) then begin
    c.ret := AllocTemp(res^.size, res^.align);
    if BehindPointer(res) then ni := 1;
  end;
  { the System V classes: each argument in the next free register of
    its kind, or else on the stack }
  k := 0;
  for i := 0 to c.n - 1 do begin
    if c.isF[i] then begin onStack[i] := nf >= 8; if nf < 8 then inc(nf) end
    else begin
      { a slice's words both go in registers, or both on the stack }
      if (i > 0) and c.pair[i - 1] then onStack[i] := onStack[i - 1]
      else if c.pair[i] then onStack[i] := ni > 4
      else onStack[i] := ni >= 6;
      if not onStack[i] then inc(ni);
    end;
    if onStack[i] then inc(k);
  end;
  { System V wants rsp a multiple of 16 at the call: a quadword of
    padding makes the count pushed since the frame began even }
  pad := ord(odd(pushed + k));
  if pad <> 0 then AluI(aluSub, RSP, 8);
  for i := c.n - 1 downto 0 do
    if onStack[i] then begin
      ValueTo(first + i, RAX);
      Push(RAX);
    end;
  ni := 0; nf := 0;
  late[4] := -1; late[5] := -1;
  if (c.ret <> 0) and BehindPointer(res) then begin Lea(RDI, Mem(RBP, c.ret)); ni := 1 end;
  { rdi, rsi, rdx, rcx and the xmm registers first; r8 and r9 last, as
    they may hold arguments still }
  for i := 0 to c.n - 1 do
    if not onStack[i] then
      if c.isF[i] then begin
        if stack[first + i].loc = lFrame then MovsdXM(nf, Mem(RBP, stack[first + i].val))
        else begin ValueTo(first + i, RAX); MovqXR(nf, RAX) end;
        inc(nf);
      end else begin
        if ni < 4 then ValueTo(first + i, IntRegs[ni]) else late[ni] := first + i;
        inc(ni);
      end;
  if late[4] >= 0 then ValueTo(late[4], RAX);
  if late[5] >= 0 then ValueTo(late[5], R9);
  if late[4] >= 0 then MovRR(R8, RAX);
  for i := 1 to c.n do Drop;
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
  { the result: a slice in rax and rdx goes to the caller's temporary,
    two results on the stack, the first under the second, and a single
    value on top }
  if res = nil then
  else if res^.form = fSlice then begin
    Store(Mem(RBP, c.ret), RAX, 8);
    Store(Mem(RBP, c.ret + 8), RDX, 8);
  end else if InTwoRegs(res) then begin
    MovRR(Target, RAX); Computed(kWord);
    MovRR(Target, RDX); Computed(kWord);
  end else if c.ret = 0 then begin
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
var p: PObj; ni, nf, k: longint; stackOff: int64; f: boolean;
begin
  frameTop := 0; frameMax := 0; permTop := 0;
  ResetStack(0, 0);
  exitL := NoLabel;
  numIn := 0;
  resType := sig^.base;
  procParams := params;
  regMask := 0;
  ni := 0; nf := 0; stackOff := 16;
  if (resType <> nil) and BehindPointer(resType) then begin
    retSlot := AllocPerm(8, 8);
    inReg[0] := RDI; inSlot[0] := retSlot; inSize[0] := 8; inObj[0] := nil;
    numIn := 1; ni := 1;
  end;
  p := params;
  while p <> nil do begin
    p^.ind := p^.isVar or IsAggregate(p^.typ) and (p^.typ^.form <> fSlice);
    f := (p^.typ^.form = fReal) and not p^.isVar;
    if (p^.typ^.form = fSlice) and not p^.isVar then begin
      { its two words, in two registers or both on the stack }
      if ni <= 4 then begin
        p^.val := AllocPerm(16, 8);
        for k := 0 to 1 do begin
          inReg[numIn] := IntRegs[ni]; inSlot[numIn] := p^.val + 8 * k;
          inSize[numIn] := 8; inObj[numIn] := nil;
          inc(numIn); inc(ni);
        end;
      end else begin
        p^.val := stackOff;
        inc(stackOff, 16);
      end;
    end else if (f and (nf < 8)) or (not f and (ni < 6)) then begin
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

{ The frame as BeginProc left it, with the parameters' slots only: the
  locals are given theirs again once their registers are chosen. }
procedure LocalsFromScratch;
begin
  frameTop := paramTop; frameMax := paramTop; permTop := paramTop;
end;

{ The locals in memory have their slots: the prologue zeroes those and
  nothing below. The procedure keeps variables in the registers of
  mask, which are saved next, a quadword each, in slots that need no
  zeroing; the frame as it then stands is where a second try at the
  body starts. }
procedure UseRegs(mask: longint);
var i, k: longint;
begin
  zeroTop := permTop;
  regMask := mask;
  k := 0;
  for i := 0 to 4 do if mask and (1 shl i) <> 0 then inc(k);
  if k > 0 then saveAt := AllocPerm(8 * k, 8);
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
  numFails := 0;
  frameTop := frameAt[0]; frameMax := frameAt[1]; permTop := frameAt[2];
  exitL := NoLabel;
end;

{ The prologue, which is for the procedure's first line. Only the
  locals in memory are zeroed, from the parameters' slots down to
  zeroTop: the parameters are stored over their slots next, the
  registers of variables are zeroed in place, their save slots are
  written before they are read, and so is every temporary. }
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
  n := (AlignUp(zeroTop, 8) - paramTop) div 8;
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
  PopTo(RSI);
  Load(RDI, Mem(RBP, retSlot), 8, false);
  if off <> 0 then Lea(RDI, Mem(RDI, off));
  CopyBytes(size);
end;

{ return: the result, a value on top, goes in rax or xmm0; two words,
  the two values on top, in rax and rdx; one behind the hidden pointer
  goes back with that pointer in rax. }
procedure ReturnJump;
begin
  if resType <> nil then
    if BehindPointer(resType) then Load(RAX, Mem(RBP, retSlot), 8, false)
    else if InTwoRegs(resType) then begin
      PopTo(RDX);
      PopTo(RAX);
    end else begin
      if resType^.form = fReal then begin MovqXR(0, Top); Drop end
      else PopTo(RAX);
    end;
  Jmp(exitL);
end;

{ The end of the procedure in chunk c: the code that returns, and the
  frame's size, known only now, patched into its prologue. If it is
  open, running off its end, it returns zeros. }
procedure EndProc(c: longint; open: boolean);
var n: int64; i: longint;
begin
  codeChunk := -1;
  if (depth <> 0) or (pushed <> 0) then Fatal('internal error: stack depth');
  if open then
    if BehindPointer(resType) then begin
      Load(RDI, Mem(RBP, retSlot), 8, false);
      MovRI(RCX, resType^.size);
      MovRI(RAX, 0);
      RepStosb;
      Load(RAX, Mem(RBP, retSlot), 8, false);
    end else begin
      MovRI(RAX, 0);
      if InTwoRegs(resType) then MovRI(RDX, 0);
      MovqXR(0, RAX);
    end
  else DropJumpTo(exitL);
  FixLink(exitL);
  n := 0;
  for i := 0 to 4 do
    if regMask and (1 shl i) <> 0 then begin
      Load(VarRegs[i], Mem(RBP, saveAt + 8 * n), 8, false);
      inc(n);
    end;
  Leave;
  Ret;
  EndFails;
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
var entry, start, i: longint; m: PModule;
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
  { Rt.fail, for the failures of each kind: the place is where the
    check's call is, a byte before where it would return to }
  for i := 0 to High(failStubs) do
    if failStubs[i] >= 0 then begin
      BeginChunk(failStubs[i]);
      MovRI(RDI, i);
      Load(R8, Mem(RSP, 0), 8, false);
      AluI(aluSub, R8, 1);
      AluI(aluAnd, RSP, -16);
      CallChunk(rtFail);
      Ud2;
      EndChunk(failStubs[i]);
    end;
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
