{ elf.pas: the executable file.

  Writes a static ELF64 executable for x86-64 Linux: the ELF header,
  one program header per section that has anything in it, the linked
  text and rodata, and section headers with a symbol table, so that
  objdump and gdb can name each procedure and variable.

  Depends on: link for the images and addresses, x64 for the chunks,
  scan for names and errors, BaseUnix to write the file.
  Leaves out: dynamic linking, for now. }

unit elf;

{$mode objfpc}{$H-}

interface

uses scan, x64, link;

const
  HeaderSize = 64 + 3 * 56;   { the ELF header and up to three program headers }

procedure WriteElf(const path: shortstring; entry: longint);

implementation

uses BaseUnix;

var
  buf: PBytes;
  len, cap: int64;

procedure Room(n: int64);
begin
  if len + n > cap then begin
    cap := cap * 2 + n;
    buf := ReAllocMem(buf, cap);
  end;
end;

procedure PutN(v: qword; n: longint);
var i: longint;
begin
  Room(n);
  for i := 0 to n - 1 do begin
    buf^[len] := byte(v);
    v := v shr 8;
    inc(len);
  end;
end;

procedure PutBytes(p: PBytes; n: int64);
begin
  Room(n);
  if n > 0 then Move(p^, buf^[len], n);
  len := len + n;
end;

procedure PadTo(off: int64);
begin
  while len < off do PutN(0, 1);
end;

procedure Patch(at: int64; v: qword; n: longint);
var i: longint;
begin
  for i := 0 to n - 1 do begin
    buf^[at + i] := byte(v);
    v := v shr 8;
  end;
end;

procedure Phdr(flags: longint; off, adr, filesz, memsz: int64);
begin
  PutN(1, 4);          { PT_LOAD }
  PutN(flags, 4);
  PutN(off, 8);
  PutN(adr, 8);
  PutN(adr, 8);
  PutN(filesz, 8);
  PutN(memsz, 8);
  PutN(Page, 8);
end;

procedure Shdr(name, typ: longint; flags, adr, off, size: int64; lnk, info: longint; align, entsize: int64);
begin
  PutN(name, 4); PutN(typ, 4); PutN(flags, 8); PutN(adr, 8);
  PutN(off, 8); PutN(size, 8); PutN(lnk, 4); PutN(info, 4);
  PutN(align, 8); PutN(entsize, 8);
end;

procedure WriteElf(const path: shortstring; entry: longint);
const
  ShNames = #0'.text'#0'.rodata'#0'.bss'#0'.symtab'#0'.strtab'#0'.shstrtab'#0;
var
  nph, c, nsym, fd: longint;
  symOff, strOff, shstrOff, shOff, strLen: int64;
  strs: PBytes;
  s, p: shortstring;
  sec: longint;
begin
  cap := 1 shl 16;
  buf := GetMem(cap);
  len := 0;
  nph := 1;
  if roSize > 0 then inc(nph);
  if bssSize > 0 then inc(nph);

  { ELF header }
  PutN($464C457F, 4); PutN(2, 1); PutN(1, 1); PutN(1, 1); PutN(0, 9);
  PutN(2, 2);              { ET_EXEC }
  PutN(62, 2);             { EM_X86_64 }
  PutN(1, 4);
  PutN(chunks^[entry].adr, 8);
  PutN(64, 8);             { program headers follow }
  PutN(0, 8);              { section headers: patched below }
  PutN(0, 4);
  PutN(64, 2); PutN(56, 2); PutN(nph, 2);
  PutN(64, 2); PutN(7, 2); PutN(6, 2);

  { the first segment maps the headers too, so text can follow them }
  Phdr(5, 0, Base, textOff + textSize, textOff + textSize);
  if roSize > 0 then Phdr(4, roOff, Base + roOff, roSize, roSize);
  if bssSize > 0 then Phdr(6, 0, bssAdr, 0, bssSize);

  PadTo(textOff);
  PutBytes(textImg, textSize);
  PadTo(roOff);   { even when empty, so that every section lies in the file }
  PutBytes(roImg, roSize);

  { the symbol table: one local symbol for each named live chunk }
  PadTo((len + 7) div 8 * 8);
  symOff := len;
  strs := GetMem(1 shl 16);
  strLen := 1;
  strs^[0] := 0;
  PutN(0, 24);
  nsym := 1;
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and (chunks^[c].name >= 0) then begin
      s := ChunkName(c);
      if strLen + length(s) + 1 > MemSize(strs) then strs := ReAllocMem(strs, strLen * 2 + 256);
      Move(s[1], strs^[strLen], length(s));
      strs^[strLen + length(s)] := 0;
      case chunks^[c].sec of
        secText: sec := 1;
        secRodata: sec := 2;
      else sec := 3;
      end;
      PutN(strLen, 4);
      if sec = 1 then PutN(2, 1) else PutN(1, 1);   { STT_FUNC, STT_OBJECT }
      PutN(0, 1);
      PutN(sec, 2);
      PutN(chunks^[c].adr, 8);
      PutN(chunks^[c].size, 8);
      strLen := strLen + length(s) + 1;
      inc(nsym);
    end;
  strOff := len;
  PutBytes(strs, strLen);
  shstrOff := len;
  s := ShNames;
  PutBytes(@s[1], length(s));

  PadTo((len + 7) div 8 * 8);
  shOff := len;
  Patch(40, shOff, 8);
  Shdr(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  Shdr(1, 1, 6, Base + textOff, textOff, textSize, 0, 0, 16, 0);
  Shdr(7, 1, 2, Base + roOff, roOff, roSize, 0, 0, 16, 0);
  Shdr(15, 8, 3, bssAdr, roOff + roSize, bssSize, 0, 0, 16, 0);
  Shdr(20, 2, 0, 0, symOff, nsym * 24, 5, nsym, 8, 24);
  Shdr(28, 3, 0, 0, strOff, strLen, 0, 0, 1, 0);
  Shdr(36, 3, 0, 0, shstrOff, length(ShNames), 0, 0, 1, 0);

  p := path + #0;
  fd := FpOpen(@p[1], O_WRONLY or O_CREAT or O_TRUNC, &755);
  if fd < 0 then Fatal('can''t write ' + path);
  if FpWrite(fd, buf^, len) <> len then Fatal('can''t write ' + path);
  FpClose(fd);
  FreeMem(strs);
  FreeMem(buf);
end;

end.
