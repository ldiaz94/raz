{ diag.pas: messages.

  The one place the compiler's messages are made. A message is an
  error or a warning at a position, which it shows as the file, line
  and column, then the line of source with the position underlined;
  notes, each at a position of its own, and help, a line of advice,
  may follow it. Colour is used when standard error is a terminal and
  NO_COLOR isn't set. diag keeps every source file it is given, so
  that a note can show a line of a module compiled earlier.

  Depends on: BaseUnix and termio, to write and to ask about the
  terminal.
  Leaves out: wording. The callers say what is wrong; a message is at
  most 255 characters, which every message so far keeps well within. }

unit diag;

{$mode objfpc}{$H-}

interface

type
  { A stretch of a source file: bytes a up to but not including b.
    a = b marks the place between two characters. }
  TPos = record
    f, a, b: longint;
  end;

const
  MaxErrors = 20;

var
  errors, warnings: longint;
  werror: boolean;     { -Werror: a warning counts as an error }
  { The construct being read uses a name already reported as not
    declared: its errors follow from that one, and aren't shown. }
  quiet: boolean;

function AddFile(const path: shortstring; buf: PChar; len: longint): longint;
function ShownPath(const path: shortstring): shortstring;
function PathOf(f: longint): shortstring;
function LineOf(const p: TPos): longint;
function Join(const p, q: TPos): TPos;
function Source(const p: TPos): shortstring;
function LineText(const path: shortstring; line: longint): shortstring;
procedure Error(const p: TPos; const msg: shortstring);
procedure Warning(const p: TPos; const msg: shortstring);
procedure Note(const p: TPos; const msg: shortstring);
function IntStr(n: int64): shortstring;
procedure Help(const msg: shortstring);
procedure Fatal(const msg: shortstring);
procedure Finish;

implementation

uses BaseUnix, termio;

type
  TFile = record
    path: shortstring;
    buf: PChar;
    len: longint;
  end;

var
  files: ^TFile;      { numFiles of them, in room for cap }
  numFiles, cap: longint;
  colour, colourKnown, cwdKnown: boolean;
  cwd: shortstring;    { the working directory and a /, or '' if unknown }
  lastError: TPos;     { where the last error was }
  shown: boolean;      { whether it was shown: its notes and help are only then }

{ Paths are shown from the working directory where they are under it,
  so messages read the same wherever the compiler or its library is. }
function ShownPath(const path: shortstring): shortstring;
var d: array[0..255] of char;
begin
  if not cwdKnown then begin
    if FpGetcwd(@d[0], SizeOf(d)) <> nil then cwd := StrPas(@d[0]) + '/';
    cwdKnown := true;
  end;
  if (cwd <> '') and (copy(path, 1, length(cwd)) = cwd) then ShownPath := copy(path, length(cwd) + 1, 255)
  else ShownPath := path;
end;

function AddFile(const path: shortstring; buf: PChar; len: longint): longint;
begin
  if numFiles = cap then begin
    cap := 2 * cap + 8;
    ReallocMem(files, cap * SizeOf(TFile));
  end;
  files[numFiles].path := ShownPath(path);
  files[numFiles].buf := buf;
  files[numFiles].len := len;
  AddFile := numFiles;
  inc(numFiles);
end;

function PathOf(f: longint): shortstring;
begin
  PathOf := files[f].path;
end;

{ Writing }

const
  Bold = #27'[1m'; Red = #27'[1;31m'; Yellow = #27'[1;33m';
  Cyan = #27'[1;36m'; Green = #27'[1;32m'; Blue = #27'[1;34m';
  Plain = #27'[0m';

{ Whether NO_COLOR is set, to anything }
function NoColour: boolean;
var e: PPChar;
begin
  e := envp;
  while (e^ <> nil) and (CompareByte(e^^, PChar('NO_COLOR=')^, 9) <> 0) do inc(e);
  NoColour := e^ <> nil;
end;

{ s in colour c, when colour is on }
function Paint(const c, s: shortstring): shortstring;
begin
  if not colourKnown then begin
    colour := (IsATTY(2) = 1) and not NoColour;
    colourKnown := true;
  end;
  if colour then Paint := c + s + Plain else Paint := s;
end;

function IntStr(n: int64): shortstring;
var s: shortstring;
begin
  Str(n, s);
  IntStr := s;
end;

{ Positions }

{ The line of p, and the byte where it starts. Lines are counted from
  the start of the file, which is slow only next to compiling it. }
procedure Locate(const p: TPos; out line, start: longint);
var i: longint; buf: PChar;
begin
  buf := files[p.f].buf;
  line := 1; start := 0;
  for i := 0 to p.a - 1 do
    if buf[i] = #10 then begin inc(line); start := i + 1 end;
end;

function LineOf(const p: TPos): longint;
var line, start: longint;
begin
  Locate(p, line, start);
  LineOf := line;
end;

{ Characters from byte i to byte j of buf: every byte but a UTF-8
  continuation byte. }
function Chars(buf: PChar; i, j: longint): longint;
var n: longint;
begin
  n := 0;
  for i := i to j - 1 do
    if (byte(buf[i]) and $C0) <> $80 then inc(n);
  Chars := n;
end;

{ "file:line:col: kind: msg", then the line with p underlined. A tab
  before p is copied into the underline, so that the two line up
  whatever the terminal makes of tabs. }
{ A long line is shown cut to this many bytes around the place, its
  cut ends marked ... }
const ShownBytes = 100;

procedure Show(const p: TPos; const kind, kindColour, msg: shortstring);
var line, start, stop, lo, hi, i, n: longint; buf: PChar; num, gutter: shortstring;
begin
  if p.f >= numFiles then begin
    { about no place in a file, as for Rt, which the compiler imports
      before it reads one }
    writeln(StdErr, Paint(Bold, 'raz:'), ' ', Paint(kindColour, kind + ':'), ' ', Paint(Bold, msg));
    exit;
  end;
  Locate(p, line, start);
  buf := files[p.f].buf;
  writeln(StdErr, Paint(Bold, files[p.f].path + ':' + IntStr(line) + ':'
    + IntStr(Chars(buf, start, p.a) + 1) + ':'), ' ', Paint(kindColour, kind + ':'),
    ' ', Paint(Bold, msg));
  stop := start;
  while (stop < files[p.f].len) and (buf[stop] <> #10) do inc(stop);
  num := IntStr(line);
  while length(num) < 5 do num := ' ' + num;
  gutter := Paint(Blue, num + ' |');
  lo := start; hi := stop;
  if hi - lo > ShownBytes then begin
    if p.a - lo > ShownBytes div 2 then lo := p.a - ShownBytes div 2;
    while (byte(buf[lo]) and $C0) = $80 do inc(lo);
    if hi - lo > ShownBytes then hi := lo + ShownBytes;
    while (hi < stop) and ((byte(buf[hi]) and $C0) = $80) do inc(hi);
  end;
  write(StdErr, gutter, ' ');
  if lo > start then write(StdErr, '...');
  for i := lo to hi - 1 do write(StdErr, buf[i]);
  if hi < stop then write(StdErr, '...');
  writeln(StdErr);
  write(StdErr, Paint(Blue, '      |'), ' ');
  if lo > start then write(StdErr, '   ');
  for i := lo to p.a - 1 do
    if buf[i] = #9 then write(StdErr, #9)
    else if (byte(buf[i]) and $C0) <> $80 then write(StdErr, ' ');
  if p.b < hi then n := Chars(buf, p.a, p.b) else n := Chars(buf, p.a, hi);
  if n < 1 then n := 1;
  writeln(StdErr, Paint(kindColour, StringOfChar('^', n)));
end;

{ From the start of p to the end of q }
function Join(const p, q: TPos): TPos;
begin
  Join := p;
  Join.b := q.b;
end;

{ The text at p, at most the 255 bytes a shortstring holds }
function Source(const p: TPos): shortstring;
var n: longint;
begin
  n := p.b - p.a;
  if n > 255 then n := 255;
  SetLength(Source, n);
  Move(files[p.f].buf[p.a], Source[1], n);
end;

{ Messages }

{ Line line of the file at path, as written }
function LineText(const path: shortstring; line: longint): shortstring;
var i, k, n: longint; s: shortstring;
begin
  s := '';
  for i := 0 to numFiles - 1 do
    if files[i].path = ShownPath(path) then begin
      k := 0; n := 1;
      while (n < line) and (k < files[i].len) do begin
        if files[i].buf[k] = #10 then inc(n);
        inc(k);
      end;
      while (k < files[i].len) and (files[i].buf[k] <> #10) and (length(s) < 255) do begin
        s := s + files[i].buf[k];
        inc(k);
      end;
      break;
    end;
  LineText := s;
end;

procedure Error(const p: TPos; const msg: shortstring);
begin
  { a second error at one place follows from the first: when a symbol
    ends a construct with an error, the one around it may stop there too }
  shown := not quiet and not ((errors > 0) and (p.f = lastError.f) and (p.a = lastError.a));
  if not shown then exit;
  lastError := p;
  Show(p, 'error', Red, msg);
  inc(errors);
  if errors >= MaxErrors then begin
    writeln(StdErr, 'raz: stopping after ', MaxErrors, ' errors');
    Halt(1);
  end;
end;

procedure Warning(const p: TPos; const msg: shortstring);
begin
  if werror then Error(p, msg)
  else begin
    Show(p, 'warning', Yellow, msg);
    shown := true;
    inc(warnings);
  end;
end;

{ Notes and help follow an error or a warning, and are shown with it }
procedure Note(const p: TPos; const msg: shortstring);
begin
  if shown then Show(p, 'note', Cyan, msg);
end;

procedure Help(const msg: shortstring);
begin
  if shown then writeln(StdErr, Paint(Green, 'help:'), ' ', msg);
end;

{ An error with no place in the source, such as a file that can't be
  read: it stops the compiler at once. }
procedure Fatal(const msg: shortstring);
begin
  writeln(StdErr, 'raz: ', msg);
  Halt(1);
end;

function Count(n: longint; const what: shortstring): shortstring;
begin
  if n = 1 then Count := '1 ' + what else Count := IntStr(n) + ' ' + what + 's';
end;

{ Says how many errors and warnings there were, and stops the compiler
  if there were errors. }
procedure Finish;
begin
  if (errors > 0) and (warnings > 0) then
    writeln(StdErr, 'raz: ', Count(errors, 'error'), ', ', Count(warnings, 'warning'))
  else if errors > 0 then writeln(StdErr, 'raz: ', Count(errors, 'error'))
  else if warnings > 0 then writeln(StdErr, 'raz: ', Count(warnings, 'warning'));
  if errors > 0 then Halt(1);
end;

end.
