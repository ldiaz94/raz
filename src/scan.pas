{ scan.pas: the scanner.

  Reads a raz source file and hands the parser one symbol at a time:
  reserved words, identifiers, numbers, characters, strings and
  operators. Identifiers are interned, so that the rest of the compiler
  compares names as small integers. The scanner also says where the
  current symbol is, for messages.

  Depends on: BaseUnix, to read files; diag, to report errors.
  Leaves out: recovery from errors in the text itself, such as a string
  not closed: the first such error stops the compiler. The parser goes
  on after its own errors, through recovery below. }

unit scan;

{$mode objfpc}{$H-}

interface

uses diag;

type
  TSym = (sNull, sIdent, sInt, sReal, sChar, sString,
    sPlus, sMinus, sTimes, sSlash, sEql, sNeq, sLss, sLeq, sGtr, sGeq,
    sBecomes, sColon, sSemicolon, sComma, sPeriod, sUpto, sEllipsis,
    sLparen, sRparen, sLbrak, sRbrak, sLbrace, sRbrace, sArrow, sBar,
    { the reserved words, in the order of Words below }
    sAnd, sBegin, sBreak, sBy, sCode, sConst, sDefer, sDiv, sDo, sElse,
    sElsif, sEnd, sExtern, sFor, sForward, sIf, sImport, sIn, sLink,
    sMatch, sMod, sModule, sNot, sOf, sOr, sPacked, sProc, sRecord,
    sRepeat, sReturn, sSet, sShl, sShr, sThen, sTo, sType, sUntil, sVar,
    sVariant, sVolatile, sWhile, sXor,
    sEof);

  PBytes = ^TBytes;
  TBytes = array[0..MaxInt - 1] of byte;
  PLongs = ^TLongs;
  TLongs = array[0..MaxInt div 4 - 1] of longint;

  { Where the scanner is. Importing a module compiles it in the middle
    of another, so the parser saves this and restores it afterwards. }
  TScanState = record
    buf: PChar;
    len, pos, line, lineStart: longint;
    tokPos, tokLine, tokLineStart: longint;
    prevEnd: longint;   { where the symbol before this one ends }
    tok: TSym;
    ival: int64;
    rval: double;
    id: longint;
    f: longint;        { the file, as diag knows it }
    path: shortstring;
  end;

const
  MaxIdent = 63;
  MaxStr = 65536;

var
  tok: TSym;          { the current symbol }
  ival: int64;        { sInt, sChar: its value }
  rval: double;       { sReal: its value }
  id: longint;        { sIdent: its name }
  sbuf: array[0..MaxStr] of byte;   { sString: its bytes, then a zero }
  slen: longint;      { sString: how many bytes }

function Intern(p: PChar; n: longint): longint;
function NameOf(n: longint): shortstring;
function Open(const path: shortstring): boolean;
procedure Next;
procedure Mark(const msg: shortstring);
procedure MarkAt(const p: TPos; const msg: shortstring);
procedure MarkHelp(const p: TPos; const msg, hint: shortstring);
function AtLineStart: boolean;
function SymText(s: TSym): shortstring;
function Found: shortstring;

var
  { Where the parser goes on after an error: the innermost statement or
    declaration being read. nil stops the compiler at the first error. }
  recovery: ^jmp_buf;
  { The construct being read uses a name already reported as not
    declared: its errors follow from that one, and aren't reported. }
  quiet: boolean;
procedure SaveScan(var st: TScanState);
procedure RestoreScan(const st: TScanState);
function TokPos: TPos;
function AfterPrev: TPos;
function MissingPos: TPos;
function SpanFrom(const p: TPos): TPos;
function CurPath: shortstring;
function CurLine: longint;

implementation

uses BaseUnix;

const
  NumWords = ord(sXor) - ord(sAnd) + 1;
  Words: array[0..NumWords - 1] of string[8] = (
    'and', 'begin', 'break', 'by', 'code', 'const', 'defer', 'div', 'do',
    'else', 'elsif', 'end', 'extern', 'for', 'forward', 'if', 'import',
    'in', 'link', 'match', 'mod', 'module', 'not', 'of', 'or', 'packed',
    'proc', 'record', 'repeat', 'return', 'set', 'shl', 'shr', 'then',
    'to', 'type', 'until', 'var', 'variant', 'VOLATILE', 'while', 'xor');
  Ops: array[sPlus..sBar] of string[3] = (
    '+', '-', '*', '/', '=', '#', '<', '<=', '>', '>=',
    ':=', ':', ';', ',', '.', '..', '...',
    '(', ')', '[', ']', '{', '}', '^', '|');

var
  cur: TScanState;   { buf .. path; tok, ival, rval and id live above }

  { The name table: every distinct identifier once, in a pool of
    characters, found through an open-addressed hash table. }
  pool: PChar;
  poolLen, poolCap: longint;
  nameOff, nameLen, nameHash: PLongs;
  numNames, nameCap: longint;
  table: PLongs;     { name + 1, or 0 for an empty slot }
  tableMask: longint;

{ Names }

function Hash(p: PChar; n: longint): longint;
var h: longword; i: longint;
begin
  h := 2166136261;
  for i := 0 to n - 1 do h := (h xor byte(p[i])) * 16777619;
  Hash := longint(h and $7FFFFFFF);
end;

procedure Grow;
var i, j, n: longint;
begin
  FreeMem(table);
  tableMask := tableMask * 2 + 1;
  table := GetMem((tableMask + 1) * 4);
  FillChar(table^, (tableMask + 1) * 4, 0);
  for n := 0 to numNames - 1 do begin
    i := nameHash^[n] and tableMask;
    while table^[i] <> 0 do i := (i + 1) and tableMask;
    table^[i] := n + 1;
  end;
  j := nameCap * 2;
  nameOff := ReAllocMem(nameOff, j * 4);
  nameLen := ReAllocMem(nameLen, j * 4);
  nameHash := ReAllocMem(nameHash, j * 4);
  nameCap := j;
end;

function Intern(p: PChar; n: longint): longint;
var h, i, k: longint;
begin
  h := Hash(p, n);
  i := h and tableMask;
  while table^[i] <> 0 do begin
    k := table^[i] - 1;
    if (nameHash^[k] = h) and (nameLen^[k] = n)
      and (CompareByte(pool[nameOff^[k]], p^, n) = 0) then exit(k);
    i := (i + 1) and tableMask;
  end;
  if poolLen + n > poolCap then begin
    poolCap := poolCap * 2 + n;
    pool := ReAllocMem(pool, poolCap);
  end;
  Move(p^, pool[poolLen], n);
  k := numNames;
  nameOff^[k] := poolLen;
  nameLen^[k] := n;
  nameHash^[k] := h;
  inc(poolLen, n);
  inc(numNames);
  table^[i] := k + 1;
  if numNames * 2 > tableMask then Grow;
  Intern := k;
end;

function NameOf(n: longint): shortstring;
var s: shortstring;
begin
  SetLength(s, nameLen^[n]);
  Move(pool[nameOff^[n]], s[1], nameLen^[n]);
  NameOf := s;
end;

{ Errors }

{ The current symbol }
function TokPos: TPos;
begin
  TokPos.f := cur.f;
  TokPos.a := cur.tokPos;
  TokPos.b := cur.pos;
end;

{ The place just after the symbol before the current one, where a
  missing symbol belongs }
function AfterPrev: TPos;
begin
  AfterPrev.f := cur.f;
  AfterPrev.a := cur.prevEnd;
  AfterPrev.b := cur.prevEnd;
end;

{ Where to say a symbol is missing: at the current symbol, unless it
  starts a later line than the symbol before it, which is more likely
  where the missing one belongs }
function MissingPos: TPos;
var i: longint;
begin
  MissingPos := TokPos;
  for i := cur.prevEnd to cur.tokPos - 1 do
    if cur.buf[i] = #10 then MissingPos := AfterPrev;
end;

{ From the start of p to the end of the symbol before the current one:
  the whole of a construct that has just been read }
function SpanFrom(const p: TPos): TPos;
begin
  SpanFrom := p;
  SpanFrom.b := cur.prevEnd;
end;

function CurPath: shortstring;
begin
  CurPath := cur.path;
end;

function CurLine: longint;
begin
  CurLine := cur.tokLine;
end;

procedure Mark(const msg: shortstring);
begin
  MarkAt(TokPos, msg);
end;

{ An error in the parser's construct at p: reported, then the parser
  goes on from the recovery point. }
procedure MarkAt(const p: TPos; const msg: shortstring);
begin
  if not quiet then Error(p, msg);
  if recovery = nil then Finish;
  longjmp(recovery^, 1);
end;

{ MarkAt, with a line of help after the message. }
procedure MarkHelp(const p: TPos; const msg, hint: shortstring);
begin
  if not quiet then begin Error(p, msg); Help(hint) end;
  if recovery = nil then Finish;
  longjmp(recovery^, 1);
end;

{ An error in the text at bytes a to b of the file being read, which
  stops the compiler: past it, the symbols can't be trusted. }
procedure MarkBytes(a, b: longint; const msg: shortstring);
var p: TPos;
begin
  p.f := cur.f; p.a := a; p.b := b;
  Error(p, msg);
  Finish;
end;

procedure LexError(const msg: shortstring);
begin
  MarkBytes(cur.tokPos, cur.pos, msg);
end;

{ How an operator or reserved word is written, quoted, for messages. }
function SymText(s: TSym): shortstring;
begin
  if s in [sPlus..sBar] then SymText := '"' + Ops[s] + '"'
  else SymText := '"' + Words[ord(s) - ord(sAnd)] + '"';
end;

{ The current symbol, for "expected ..., found ...": a name as it is,
  a literal by its kind, an operator or reserved word quoted. }
function Found: shortstring;
begin
  case tok of
    sIdent: Found := NameOf(id);
    sInt, sReal: Found := 'a number';
    sChar: Found := 'a character';
    sString: Found := 'a string';
    sEof: Found := 'the end of the file';
  else Found := SymText(tok);
  end;
end;

{ The current symbol is the first on its line: at the top level of a
  module, by the usual layout, so where reading can start again. }
function AtLineStart: boolean;
begin
  AtLineStart := cur.tokPos = cur.tokLineStart;
end;

{ Files }

function Open(const path: shortstring): boolean;
var fd: cint; st: Stat; n, got, r: longint; p: shortstring;
begin
  p := path + #0;
  fd := FpOpen(@p[1], O_RDONLY);
  if fd < 0 then exit(false);
  if FpFStat(fd, st) <> 0 then begin FpClose(fd); exit(false) end;
  if (st.st_mode and S_IFMT) <> S_IFREG then begin FpClose(fd); exit(false) end;
  n := st.st_size;
  cur.buf := GetMem(n + 1);
  got := 0;
  while got < n do begin
    r := FpRead(fd, cur.buf[got], n - got);
    if r <= 0 then Fatal('can''t read ' + path);
    got := got + r;
  end;
  FpClose(fd);
  cur.buf[n] := #0;   { the sentinel that ends every scan }
  cur.len := n;
  cur.pos := 0;
  cur.line := 1;
  cur.lineStart := 0;
  cur.tokPos := 0;
  cur.tokLine := 1;
  cur.tokLineStart := 0;
  cur.path := path;
  cur.f := AddFile(path, cur.buf, n);
  Open := true;
end;

procedure SaveScan(var st: TScanState);
begin
  st := cur;
  st.tok := tok; st.ival := ival; st.rval := rval; st.id := id;
end;

procedure RestoreScan(const st: TScanState);
begin
  cur := st;
  tok := st.tok; ival := st.ival; rval := st.rval; id := st.id;
end;

{ UTF-8 }

{ Decodes the character at buf[pos], which is not ASCII, checking that
  it is well formed; returns its code point and moves pos past it. }
function Utf8(var pos: longint): longint;
var b0, b1, n, i, cp: longint; lo, hi: byte;
begin
  b0 := byte(cur.buf[pos]);
  lo := $80; hi := $BF;
  case b0 of
    $C2..$DF: begin n := 1; cp := b0 and $1F end;
    $E0: begin n := 2; cp := 0; lo := $A0 end;
    $E1..$EC, $EE, $EF: begin n := 2; cp := b0 and $0F end;
    $ED: begin n := 2; cp := $0D; hi := $9F end;   { no surrogates }
    $F0: begin n := 3; cp := 0; lo := $90 end;
    $F1..$F3: begin n := 3; cp := b0 and $07 end;
    $F4: begin n := 3; cp := 4; hi := $8F end;     { up to 10FFFFH }
  else
    cur.tokPos := pos;
    LexError('invalid UTF-8');
  end;
  for i := 1 to n do begin
    b1 := byte(cur.buf[pos + i]);
    if (b1 < lo) or (b1 > hi) or (pos + i >= cur.len) then begin
      cur.tokPos := pos;
      LexError('bad UTF-8');
    end;
    cp := cp shl 6 or (b1 and $3F);
    lo := $80; hi := $BF;
  end;
  pos := pos + n + 1;
  Utf8 := cp;
end;

procedure Put(b: longint);
begin
  if slen >= MaxStr then LexError('a string holds at most ' + IntStr(MaxStr) + ' bytes');
  sbuf[slen] := b;
  inc(slen);
end;

procedure PutUtf8(cp: longint);
begin
  if cp < $80 then Put(cp)
  else if cp < $800 then begin
    Put($C0 or cp shr 6); Put($80 or cp and $3F)
  end else if cp < $10000 then begin
    Put($E0 or cp shr 12); Put($80 or cp shr 6 and $3F); Put($80 or cp and $3F)
  end else begin
    Put($F0 or cp shr 18); Put($80 or cp shr 12 and $3F);
    Put($80 or cp shr 6 and $3F); Put($80 or cp and $3F)
  end;
end;

function HexVal(c: char): longint;
begin
  case c of
    '0'..'9': HexVal := ord(c) - ord('0');
    'A'..'F': HexVal := ord(c) - ord('A') + 10;
    'a'..'f': HexVal := ord(c) - ord('a') + 10;
  else HexVal := -1;
  end;
end;

{ The text of the file from byte a up to but not including b }
function Text(a, b: longint): shortstring;
var p: TPos;
begin
  p.f := cur.f; p.a := a; p.b := b;
  Text := Source(p);
end;

{ One character of a character or string literal, at buf[pos]: its code
  point, or for \xHH, minus one minus the byte. }
function LitChar(inString: boolean): longint;
var c: char; v, d, n, esc, digits: longint;
begin
  c := cur.buf[cur.pos];
  esc := cur.pos;
  if c = '\' then begin
    inc(cur.pos);
    c := cur.buf[cur.pos];
    inc(cur.pos);
    case c of
      'n': v := 10;
      't': v := 9;
      'r': v := 13;
      '0': v := 0;
      '\', '''', '"': v := ord(c);
      'x': begin
        if not inString then MarkBytes(esc, cur.pos, '\x is only for strings');
        d := HexVal(cur.buf[cur.pos]);
        n := HexVal(cur.buf[cur.pos + 1]);
        if (d < 0) or (n < 0) then MarkBytes(esc, cur.pos + 2, '\x needs two hex digits');
        inc(cur.pos, 2);
        v := -1 - (d * 16 + n);
      end;
      'u': begin
        if cur.buf[cur.pos] <> '{' then MarkBytes(esc, cur.pos, 'expected "{" after \u');
        inc(cur.pos);
        digits := cur.pos;
        v := 0; n := 0;
        while HexVal(cur.buf[cur.pos]) >= 0 do begin
          v := v * 16 + HexVal(cur.buf[cur.pos]);
          inc(n); inc(cur.pos);
          if n > 6 then MarkBytes(esc, cur.pos, 'a code point has at most 6 hex digits');
        end;
        if (n = 0) or (cur.buf[cur.pos] <> '}') then MarkBytes(esc, cur.pos, 'expected hex digits and "}" after \u{');
        inc(cur.pos);
        if (v > $10FFFF) or ((v >= $D800) and (v <= $DFFF)) then
          MarkBytes(esc, cur.pos, Text(digits, cur.pos - 1) + ' isn''t a code point');
      end;
    else MarkBytes(esc, cur.pos, 'unknown escape \' + c);
    end;
  end else if byte(c) >= $80 then
    v := Utf8(cur.pos)
  else if (c < ' ') or (c = #127) then
    if inString then LexError('string not closed')
    else LexError('character not closed')
  else begin
    v := ord(c);
    inc(cur.pos);
  end;
  LitChar := v;
end;

{ Symbols }

procedure Comment;
var depth, open: longint; c: char;
begin
  depth := 1;
  open := cur.pos;
  inc(cur.pos, 2);
  repeat
    c := cur.buf[cur.pos];
    if c = #0 then begin
      if cur.pos >= cur.len then MarkBytes(open, open + 2, 'comment not closed');
      inc(cur.pos);
    end else if (c = '(') and (cur.buf[cur.pos + 1] = '*') then begin
      inc(depth); inc(cur.pos, 2)
    end else if (c = '*') and (cur.buf[cur.pos + 1] = ')') then begin
      dec(depth); inc(cur.pos, 2)
    end else if c = #10 then begin
      inc(cur.pos); inc(cur.line); cur.lineStart := cur.pos
    end else if byte(c) >= $80 then
      Utf8(cur.pos)
    else
      inc(cur.pos);
  until depth = 0;
end;

procedure Number;
var start, i, d: longint; allDec: boolean; v: qword; s: shortstring; code: word;
begin
  start := cur.pos;
  allDec := true;
  while cur.buf[cur.pos] in ['0'..'9', 'A'..'F'] do begin
    if cur.buf[cur.pos] > '9' then allDec := false;
    inc(cur.pos);
  end;
  if cur.buf[cur.pos] = 'H' then begin
    v := 0;
    for i := start to cur.pos - 1 do begin
      if v shr 60 <> 0 then LexError(Text(start, cur.pos) + ' is too big for U64');
      v := v * 16 + qword(HexVal(cur.buf[i]));
    end;
    inc(cur.pos);
    tok := sInt;
    ival := int64(v);   { 16 digits are the bits of a 64-bit word }
  end else if (cur.buf[cur.pos] = '.') and (cur.buf[cur.pos + 1] in ['0'..'9']) then begin
    if not allDec then LexError('a decimal number has only the digits 0 to 9');
    inc(cur.pos);
    while cur.buf[cur.pos] in ['0'..'9'] do inc(cur.pos);
    if cur.buf[cur.pos] = 'E' then begin
      inc(cur.pos);
      if cur.buf[cur.pos] in ['+', '-'] then inc(cur.pos);
      if not (cur.buf[cur.pos] in ['0'..'9']) then LexError('expected a digit in the exponent');
      while cur.buf[cur.pos] in ['0'..'9'] do inc(cur.pos);
    end;
    if cur.pos - start > 255 then LexError('a number has at most 255 characters');
    SetLength(s, cur.pos - start);
    Move(cur.buf[start], s[1], cur.pos - start);
    Val(s, rval, code);
    if code <> 0 then LexError(Text(start, cur.pos) + ' is out of the range of F64');
    tok := sReal;
  end else begin
    if not allDec then LexError('a hex number ends with H');
    v := 0;
    for i := start to cur.pos - 1 do begin
      d := ord(cur.buf[i]) - ord('0');
      if v > (qword(high(int64)) - qword(d)) div 10 then LexError(Text(start, cur.pos) + ' is too big for I64');
      v := v * 10 + qword(d);
    end;
    tok := sInt;
    ival := int64(v);
  end;
  if cur.buf[cur.pos] in ['A'..'Z', 'a'..'z', '_', '0'..'9'] then
    LexError('a name can''t start with a digit');
end;

procedure Next;
var c: char; start, h, v: longint;
begin
  cur.prevEnd := cur.pos;
  repeat
    c := cur.buf[cur.pos];
    while c in [' ', #9, #13, #10] do begin
      if c = #10 then begin
        inc(cur.line); cur.lineStart := cur.pos + 1
      end;
      inc(cur.pos);
      c := cur.buf[cur.pos];
    end;
    if (c = '(') and (cur.buf[cur.pos + 1] = '*') then begin
      Comment; c := ' '
    end;
  until c <> ' ';
  cur.tokPos := cur.pos;
  cur.tokLine := cur.line;
  cur.tokLineStart := cur.lineStart;
  case c of
    'A'..'Z', 'a'..'z', '_': begin
      start := cur.pos;
      repeat inc(cur.pos)
      until not (cur.buf[cur.pos] in ['A'..'Z', 'a'..'z', '0'..'9', '_']);
      if cur.pos - start > MaxIdent then LexError('a name has at most ' + IntStr(MaxIdent) + ' characters');
      h := Intern(@cur.buf[start], cur.pos - start);
      if h < NumWords then tok := TSym(ord(sAnd) + h)
      else begin tok := sIdent; id := h end;
    end;
    '0'..'9': Number;
    '''': begin
      inc(cur.pos);
      if cur.buf[cur.pos] = '''' then LexError('empty character');
      v := LitChar(false);
      if cur.buf[cur.pos] <> '''' then LexError('character not closed');
      inc(cur.pos);
      tok := sChar;
      ival := v;
    end;
    '"': begin
      inc(cur.pos);
      slen := 0;
      while cur.buf[cur.pos] <> '"' do begin
        v := LitChar(true);
        if v < 0 then Put(-1 - v) else PutUtf8(v);
      end;
      inc(cur.pos);
      sbuf[slen] := 0;
      tok := sString;
    end;
    '+': begin inc(cur.pos); tok := sPlus end;
    '-': begin inc(cur.pos); tok := sMinus end;
    '*': begin inc(cur.pos); tok := sTimes end;
    '/': begin inc(cur.pos); tok := sSlash end;
    '=': begin inc(cur.pos); tok := sEql end;
    '#': begin inc(cur.pos); tok := sNeq end;
    '<': begin
      inc(cur.pos);
      if cur.buf[cur.pos] = '=' then begin inc(cur.pos); tok := sLeq end
      else tok := sLss;
    end;
    '>': begin
      inc(cur.pos);
      if cur.buf[cur.pos] = '=' then begin inc(cur.pos); tok := sGeq end
      else tok := sGtr;
    end;
    ':': begin
      inc(cur.pos);
      if cur.buf[cur.pos] = '=' then begin inc(cur.pos); tok := sBecomes end
      else tok := sColon;
    end;
    ';': begin inc(cur.pos); tok := sSemicolon end;
    ',': begin inc(cur.pos); tok := sComma end;
    '.': begin
      inc(cur.pos);
      if cur.buf[cur.pos] = '.' then begin
        inc(cur.pos);
        if cur.buf[cur.pos] = '.' then begin inc(cur.pos); tok := sEllipsis end
        else tok := sUpto;
      end else tok := sPeriod;
    end;
    '(': begin inc(cur.pos); tok := sLparen end;
    ')': begin inc(cur.pos); tok := sRparen end;
    '[': begin inc(cur.pos); tok := sLbrak end;
    ']': begin inc(cur.pos); tok := sRbrak end;
    '{': begin inc(cur.pos); tok := sLbrace end;
    '}': begin inc(cur.pos); tok := sRbrace end;
    '^': begin inc(cur.pos); tok := sArrow end;
    '|': begin inc(cur.pos); tok := sBar end;
    #0: begin
      if cur.pos < cur.len then MarkBytes(cur.pos, cur.pos + 1, 'NUL byte in the text');
      tok := sEof;
    end;
  else
    if byte(c) >= $80 then
      LexError('only ASCII outside strings, characters and comments');
    MarkBytes(cur.pos, cur.pos + 1, 'unexpected character "' + c + '"');
  end;
end;

var i: longint;

initialization
  poolCap := 1 shl 16;
  pool := GetMem(poolCap);
  nameCap := 1 shl 12;
  nameOff := GetMem(nameCap * 4);
  nameLen := GetMem(nameCap * 4);
  nameHash := GetMem(nameCap * 4);
  tableMask := 2 * nameCap - 1;
  table := GetMem((tableMask + 1) * 4);
  FillChar(table^, (tableMask + 1) * 4, 0);
  for i := 0 to NumWords - 1 do Intern(@Words[i][1], length(Words[i]));
end.
