{ elf.pas: the executable file.

  Writes an ELF64 executable for x86-64 Linux: the ELF header, the
  program headers, the linked text and rodata, and section headers
  with a symbol table, so that objdump and gdb can name each procedure
  and variable.

  A program that uses C is linked dynamically, in the least way the
  loader accepts: it names its loader and libraries, and each C symbol
  it uses is a quadword the loader fills in with the symbol's address
  (a GLOB_DAT relocation), which the code calls or reads through.
  There is no PLT and no lazy binding, and the program exports nothing.

  Depends on: link for the images and addresses, x64 for the chunks,
  scan for names and errors, BaseUnix to write the file.
  Leaves out: position independent executables, symbol versions. }

unit elf;

{$mode objfpc}{$H-}

interface

uses scan, x64, link;

var
  needed: array[0..31] of longint;   { the libraries to load, names interned }
  numNeeded: longint;                { none: a static program }

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

procedure Phdr(typ, flags: longint; off, adr, filesz, memsz, align: int64);
begin
  PutN(typ, 4);
  PutN(flags, 4);
  PutN(off, 8);
  PutN(adr, 8);
  PutN(adr, 8);
  PutN(filesz, 8);
  PutN(memsz, 8);
  PutN(align, 8);
end;

procedure Shdr(name, typ: longint; flags, adr, off, size: int64; lnk, info: longint; align, entsize: int64);
begin
  PutN(name, 4); PutN(typ, 4); PutN(flags, 8); PutN(adr, 8);
  PutN(off, 8); PutN(size, 8); PutN(lnk, 4); PutN(info, 4);
  PutN(align, 8); PutN(entsize, 8);
end;

procedure PutStr(const s: shortstring);
begin
  PutBytes(@s[1], length(s));
  PutN(0, 1);
end;

const
  Interp = '/lib64/ld-linux-x86-64.so.2';
  { program header types }
  PtLoad = 1; PtDynamic = 2; PtInterp = 3; PtGnuStack = $6474E551;

var
  { in the room at the end of rodata: where each of the loader's
    tables starts, from extraAdr }
  symAt, relaAt, hashAt, strAt: int64;
  nsym, strLen: longint;

{ The sizes of the loader's tables: what LinkAll must leave room for. }
procedure SizeTables(var roExtra, dynSize: int64);
var c, i: longint;
begin
  nsym := 1;
  strLen := 1;
  for i := 0 to numNeeded - 1 do strLen := strLen + length(NameOf(needed[i])) + 1;
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and chunks^[c].ext then begin
      inc(nsym);
      strLen := strLen + length(NameOf(chunks^[c].name)) + 1;
    end;
  symAt := (length(Interp) + 1 + 7) div 8 * 8;
  relaAt := symAt + nsym * 24;
  hashAt := relaAt + (nsym - 1) * 24;
  strAt := hashAt + 4 * (3 + nsym);
  roExtra := strAt + strLen;
  dynSize := (numNeeded + 10) * 16;
end;

{ The loader's tables in the room at the end of rodata, which the
  buffer already holds as zeros: the loader's name; the symbols, one
  for each C symbol used; a GLOB_DAT relocation for each, at its
  quadword; a hash table of one bucket; and their names. }
procedure PutTables;
var c, k, i, at, name: longint;
begin
  len := extraAdr - Base;
  PutStr(Interp);
  PadTo(extraAdr - Base + symAt);
  PutN(0, 24);
  name := strLen;
  for c := numChunks - 1 downto 0 do   { names go last in the string table }
    if chunks^[c].live and chunks^[c].ext then name := name - length(NameOf(chunks^[c].name)) - 1;
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and chunks^[c].ext then begin
      PutN(name, 4); PutN($10, 1); PutN(0, 1); PutN(0, 2);   { global, undefined }
      PutN(0, 8); PutN(0, 8);
      name := name + length(NameOf(chunks^[c].name)) + 1;
    end;
  k := 1;
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and chunks^[c].ext then begin
      PutN(chunks^[c].adr, 8);
      PutN(qword(k) shl 32 or 6, 8);   { R_X86_64_GLOB_DAT }
      PutN(0, 8);
      inc(k);
    end;
  PutN(1, 4); PutN(nsym, 4); PutN(nsym - 1, 4);   { the bucket chains every symbol }
  PutN(0, 4);
  for i := 1 to nsym - 1 do PutN(i - 1, 4);
  PutN(0, 1);
  for i := 0 to numNeeded - 1 do PutStr(NameOf(needed[i]));
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and chunks^[c].ext then PutStr(NameOf(chunks^[c].name));
  len := roOff + roSize;

  { the dynamic table, at the start of the writable segment }
  PadTo(bssAdr - Base);
  at := 1;
  for i := 0 to numNeeded - 1 do begin
    PutN(1, 8); PutN(at, 8);   { DT_NEEDED }
    at := at + length(NameOf(needed[i])) + 1;
  end;
  PutN(4, 8); PutN(extraAdr + hashAt, 8);     { DT_HASH }
  PutN(5, 8); PutN(extraAdr + strAt, 8);      { DT_STRTAB }
  PutN(6, 8); PutN(extraAdr + symAt, 8);      { DT_SYMTAB }
  PutN(10, 8); PutN(strLen, 8);               { DT_STRSZ }
  PutN(11, 8); PutN(24, 8);                   { DT_SYMENT }
  PutN(7, 8); PutN(extraAdr + relaAt, 8);     { DT_RELA }
  PutN(8, 8); PutN((nsym - 1) * 24, 8);       { DT_RELASZ }
  PutN(9, 8); PutN(24, 8);                    { DT_RELAENT }
  PutN(21, 8); PutN(0, 8);                    { DT_DEBUG, for gdb }
  PutN(0, 16);                                { DT_NULL }
end;

procedure WriteElf(const path: shortstring; entry: longint);
const
  ShNames = #0'.text'#0'.rodata'#0'.bss'#0'.symtab'#0'.strtab'#0'.shstrtab'#0 +
    '.dynamic'#0'.dynstr'#0'.dynsym'#0;
var
  nph, nsh, c, nsyms, fd: longint;
  roExtra, dynSize, symOff, strOff, shstrOff, shOff, strsLen: int64;
  strs: PBytes;
  s, p: shortstring;
  sec: longint;
  dynamic: boolean;
begin
  cap := 1 shl 16;
  buf := GetMem(cap);
  len := 0;
  MarkLive(entry);
  dynamic := numNeeded > 0;
  roExtra := 0; dynSize := 0;
  if dynamic then SizeTables(roExtra, dynSize);
  { room for the most program headers either kind of program has }
  LinkAll(64 + 6 * 56, roExtra, dynSize);
  if dynamic then nph := 6
  else begin
    nph := 2;
    if roSize > 0 then inc(nph);
    if bssSize > 0 then inc(nph);
  end;

  { ELF header }
  PutN($464C457F, 4); PutN(2, 1); PutN(1, 1); PutN(1, 1); PutN(0, 9);
  PutN(2, 2);              { ET_EXEC }
  PutN(62, 2);             { EM_X86_64 }
  PutN(1, 4);
  PutN(chunks^[entry].adr, 8);
  PutN(64, 8);             { program headers follow }
  PutN(0, 8);              { section headers: patched below }
  PutN(0, 4);
  nsh := 7;
  if dynamic then nsh := 10;
  PutN(64, 2); PutN(56, 2); PutN(nph, 2);
  PutN(64, 2); PutN(nsh, 2); PutN(6, 2);

  if dynamic then Phdr(PtInterp, 4, extraAdr - Base, extraAdr, length(Interp) + 1, length(Interp) + 1, 1);
  { the first segment maps the headers too, so text can follow them }
  Phdr(PtLoad, 5, 0, Base, textOff + textSize, textOff + textSize, Page);
  if roSize > 0 then Phdr(PtLoad, 4, roOff, Base + roOff, roSize, roSize, Page);
  if dynamic then begin
    Phdr(PtLoad, 6, bssAdr - Base, bssAdr, dynSize, bssSize, Page);
    Phdr(PtDynamic, 6, bssAdr - Base, bssAdr, dynSize, dynSize, 8);
  end else if bssSize > 0 then Phdr(PtLoad, 6, 0, bssAdr, 0, bssSize, Page);
  Phdr(PtGnuStack, 6, 0, 0, 0, 0, 16);   { a stack that can't run code }

  PadTo(textOff);
  PutBytes(textImg, textSize);
  PadTo(roOff);   { even when empty, so that every section lies in the file }
  PutBytes(roImg, roSize);
  if dynamic then PutTables;

  { the symbol table: one local symbol for each named live chunk }
  PadTo((len + 7) div 8 * 8);
  symOff := len;
  strs := GetMem(1 shl 16);
  strsLen := 1;
  strs^[0] := 0;
  PutN(0, 24);
  nsyms := 1;
  for c := 0 to numChunks - 1 do
    if chunks^[c].live and (chunks^[c].name >= 0) and not chunks^[c].ext then begin
      s := ChunkName(c);
      if strsLen + length(s) + 1 > MemSize(strs) then strs := ReAllocMem(strs, strsLen * 2 + 256);
      Move(s[1], strs^[strsLen], length(s));
      strs^[strsLen + length(s)] := 0;
      case chunks^[c].sec of
        secText: sec := 1;
        secRodata: sec := 2;
      else sec := 3;
      end;
      PutN(strsLen, 4);
      if sec = 1 then PutN(2, 1) else PutN(1, 1);   { STT_FUNC, STT_OBJECT }
      PutN(0, 1);
      PutN(sec, 2);
      PutN(chunks^[c].adr, 8);
      PutN(chunks^[c].size, 8);
      strsLen := strsLen + length(s) + 1;
      inc(nsyms);
    end;
  strOff := len;
  PutBytes(strs, strsLen);
  shstrOff := len;
  s := ShNames;
  PutBytes(@s[1], length(s));

  PadTo((len + 7) div 8 * 8);
  shOff := len;
  Patch(40, shOff, 8);
  Shdr(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
  Shdr(1, 1, 6, Base + textOff, textOff, textSize, 0, 0, 16, 0);
  Shdr(7, 1, 2, Base + roOff, roOff, roSize, 0, 0, 16, 0);
  Shdr(15, 8, 3, bssAdr + dynSize, roOff + roSize, bssSize - dynSize, 0, 0, 16, 0);
  Shdr(20, 2, 0, 0, symOff, nsyms * 24, 5, nsyms, 8, 24);
  Shdr(28, 3, 0, 0, strOff, strsLen, 0, 0, 1, 0);
  Shdr(36, 3, 0, 0, shstrOff, length(ShNames), 0, 0, 1, 0);
  if dynamic then begin   { the loader's tables, for readelf and objdump }
    Shdr(46, 6, 3, bssAdr, bssAdr - Base, dynSize, 8, 0, 8, 16);
    Shdr(55, 3, 2, extraAdr + strAt, extraAdr + strAt - Base, strLen, 0, 0, 1, 0);
    Shdr(63, 11, 2, extraAdr + symAt, extraAdr + symAt - Base, nsym * 24, 8, 1, 8, 24);
  end;

  p := path + #0;
  fd := FpOpen(@p[1], O_WRONLY or O_CREAT or O_TRUNC, &755);
  if fd < 0 then Fatal('can''t write ' + path);
  if FpWrite(fd, buf^, len) <> len then Fatal('can''t write ' + path);
  FpClose(fd);
  FreeMem(strs);
  FreeMem(buf);
end;

end.
