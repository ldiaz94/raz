{ Builds a program by hand, chunk by chunk, links it and writes it:
  a test of x64.pas, link.pas and elf.pas. The program writes "hand"
  from rodata, adds one to a bss variable through a call, and exits
  with that variable plus 41: status 42. A chunk nothing reaches is
  left out. }
program handtest;
{$mode objfpc}{$H-}
uses scan, chunk, x64, link, elf;
var entry, msg, count, bump, unused: longint; s: shortstring;
begin
  s := 'hand'#10;
  msg := NewChunk(secRodata, -1, Intern('msg', 3));
  SetData(msg, @s[1], length(s), 1);
  count := NewChunk(secBss, -1, Intern('count', 5));
  SetBss(count, 8, 8);
  bump := NewChunk(secText, -1, Intern('bump', 4));
  unused := NewChunk(secText, -1, Intern('unused', 6));
  entry := NewChunk(secText, -1, Intern('start', 5));

  BeginChunk(bump);                      { count := count + 1 }
  Load(RAX, MemRip(count, 0), 8, true);
  AluI(aluAdd, RAX, 1);
  Store(MemRip(count, 0), RAX, 8);
  Ret;
  EndChunk(bump);

  BeginChunk(unused);
  Ud2;
  EndChunk(unused);

  BeginChunk(entry);
  MovRI(RAX, 1);                         { write(1, msg, 5) }
  MovRI(RDI, 1);
  Lea(RSI, MemRip(msg, 0));
  MovRI(RDX, length(s));
  Syscall;
  CallChunk(bump);
  Load(RDI, MemRip(count, 0), 8, true);
  AluI(aluAdd, RDI, 41);
  MovRI(RAX, 60);                        { exit(count + 41) }
  Syscall;
  EndChunk(entry);

  MarkLive(entry);
  WriteElf(ParamStr(1), entry);
end.
