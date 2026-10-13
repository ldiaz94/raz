{ elf.pas: the executable file.

  Writes an ELF64 executable for x86-64 Linux: the ELF header, the
  program headers, the linked text and rodata, and section headers
  with a symbol table, so that objdump and gdb can name each procedure
  and variable. For gdb's line numbers there is DWARF 4: a line table
  (.debug_line), and the one compile unit that points to it
  (.debug_info, .debug_abbrev). There are no types or variables.

  A program that uses C is linked dynamically, in the least way the
  loader accepts: it names its loader and libraries, and each C symbol
  it uses is a quadword the loader fills in with the symbol's address
  (a GLOB_DAT relocation), which the code calls or reads through.
  There is no PLT and no lazy binding, and the program exports nothing.

  Depends on: link for the images and addresses, chunk for the chunks,
  scan for names and errors, BaseUnix to write the file.
  Leaves out: position independent executables, symbol versions, the
  rest of DWARF. }

unit elf;

{$mode objfpc}{$H-}

interface

uses scan, diag, chunk, link;

var
  needed: array[0..31] of longint;   { the libraries to load, names interned }
  numNeeded: longint;                { none: a static program }
  mainPath: shortstring;             { the main module's file, for gdb }
  stripped: boolean;   { -s: no symbols and no line numbers; the sections are there, empty }

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

const
  { the section names, in .shstrtab; a section header names its own }
  ShNames = #0'.text'#0'.rodata'#0'.bss'#0'.symtab'#0'.strtab'#0'.shstrtab'#0 +
    '.dynamic'#0'.dynstr'#0'.dynsym'#0'.debug_line'#0'.debug_info'#0'.debug_abbrev'#0;

{ A section header. Its name is given as a string and stored as its
  offset in ShNames: the #0 before it, counted from 1, is that offset
  counted from 0; the empty name, found nowhere, is 0. }
procedure Shdr(const name: shortstring; typ: longint; flags, adr, off, size: int64; lnk, info: longint; align, entsize: int64);
begin
  PutN(Pos(#0 + name + #0, ShNames), 4); PutN(typ, 4); PutN(flags, 8); PutN(adr, 8);
  PutN(off, 8); PutN(size, 8); PutN(lnk, 4); PutN(info, 4);
  PutN(align, 8); PutN(entsize, 8);
end;

procedure PutStr(const s: shortstring);
begin
  PutBytes(@s[1], length(s));
  PutN(0, 1);
end;

{ LEB128, unsigned }
procedure PutU(v: qword);
begin
  while v >= $80 do begin
    PutN(v and $7F or $80, 1);
    v := v shr 7;
  end;
  PutN(v, 1);
end;

{ The compile unit, which names the line table, and its abbreviation;
  the table itself is in the places, in rodata (link.pas). Section
  offsets go in off, sizes in size: line, info, abbrev. }
procedure PutDebug(var off, size: array of int64);
var cwd: array[0..255] of char;
begin
  off[0] := chunks^[placesChunk].adr - roAdr + roOff + linesOff;
  size[0] := linesSize;
  off[1] := len;
  PutN(0, 4); PutN(4, 2); PutN(0, 4); PutN(8, 1);   { length, version, abbrev, address size }
  PutU(1);
  PutStr(mainPath);
  if FpGetcwd(@cwd, SizeOf(cwd)) = nil then cwd[0] := #0;
  PutStr(PChar(@cwd));
  PutStr('raz');
  PutN(0, 4);                                 { the line table, at 0 }
  PutN(Base + textOff, 8); PutN(textSize, 8);  { the code, all of it }
  Patch(off[1], len - off[1] - 4, 4);
  size[1] := len - off[1];

  off[2] := len;
  PutU(1); PutU($11); PutN(0, 1);    { 1: a compile unit, no children }
  PutU($03); PutU($08);              { name, a string }
  PutU($1B); PutU($08);              { comp_dir, a string }
  PutU($25); PutU($08);              { producer, a string }
  PutU($10); PutU($17);              { stmt_list, a section offset }
  PutU($11); PutU($01);              { low_pc, an address }
  PutU($12); PutU($07);              { high_pc, a length in 8 bytes }
  PutN(0, 2); PutN(0, 1);
  size[2] := len - off[2];
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
  len := extraAdr - roAdr + roOff;
  PutStr(Interp);
  PadTo(extraAdr - roAdr + roOff + symAt);
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
  PadTo(bssOff);
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
var
  nph, nsh, c, nsyms, fd: longint;
  roExtra, dynSize, symOff, strOff, shstrOff, shOff, strsLen: int64;
  dbgOff, dbgSize: array[0..2] of int64;
  strs: PBytes;
  s, p: shortstring;
  sec: longint;
  dynamic: boolean;
begin
  cap := 1 shl 16;
  buf := GetMem(cap);
  len := 0;
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
  PutN($464C457F, 4);      { #127 'ELF' }
  PutN(2, 1); PutN(1, 1); PutN(1, 1); PutN(0, 9);   { 64-bit, little-endian, version 1 }
  PutN(2, 2);              { ET_EXEC }
  PutN(62, 2);             { EM_X86_64 }
  PutN(1, 4);
  PutN(chunks^[entry].adr, 8);
  PutN(64, 8);             { program headers follow }
  PutN(0, 8);              { section headers: patched below }
  PutN(0, 4);
  nsh := 10;
  if dynamic then nsh := 13;
  PutN(64, 2); PutN(56, 2); PutN(nph, 2);
  PutN(64, 2); PutN(nsh, 2); PutN(6, 2);   { .shstrtab is section 6 }

  { flags: 4 read, 5 read and run, 6 read and write }
  if dynamic then Phdr(PtInterp, 4, extraAdr - roAdr + roOff, extraAdr, length(Interp) + 1, length(Interp) + 1, 1);
  { the first segment maps the headers too, so text can follow them }
  Phdr(PtLoad, 5, 0, Base, textOff + textSize, textOff + textSize, Page);
  if roSize > 0 then Phdr(PtLoad, 4, roOff, roAdr, roSize, roSize, Page);
  if dynamic then begin
    Phdr(PtLoad, 6, bssOff, bssAdr, dynSize, bssSize, Page);
    Phdr(PtDynamic, 6, bssOff, bssAdr, dynSize, dynSize, 8);
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
    if not stripped and chunks^[c].live and (chunks^[c].name >= 0) and not chunks^[c].ext then begin
      s := ChunkName(c);
      if strsLen + length(s) + 1 > MemSize(strs) then strs := ReAllocMem(strs, strsLen * 2 + 256);
      Move(s[1], strs^[strsLen], length(s));
      strs^[strsLen + length(s)] := 0;
      case chunks^[c].sec of   { the section's index in the headers below }
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
  if stripped or (placesChunk < 0) then begin
    for c := 0 to 2 do begin dbgOff[c] := len; dbgSize[c] := 0 end;
  end else PutDebug(dbgOff, dbgSize);

  PadTo((len + 7) div 8 * 8);
  shOff := len;
  Patch(40, shOff, 8);
  { types: 1 PROGBITS, 2 SYMTAB, 3 STRTAB, 6 DYNAMIC, 8 NOBITS, 11 DYNSYM;
    flags: 2 ALLOC, 3 WRITE+ALLOC, 6 ALLOC+EXECINSTR. A symbol table's
    link is its string table's index: 5 .strtab, 8 .dynstr. The order
    here is the index the code above relies on. }
  Shdr('', 0, 0, 0, 0, 0, 0, 0, 0, 0);
  Shdr('.text', 1, 6, Base + textOff, textOff, textSize, 0, 0, 16, 0);
  Shdr('.rodata', 1, 2, roAdr, roOff, roSize, 0, 0, 16, 0);
  Shdr('.bss', 8, 3, bssAdr + dynSize, roOff + roSize, bssSize - dynSize, 0, 0, 16, 0);
  Shdr('.symtab', 2, 0, 0, symOff, nsyms * 24, 5, nsyms, 8, 24);
  Shdr('.strtab', 3, 0, 0, strOff, strsLen, 0, 0, 1, 0);
  Shdr('.shstrtab', 3, 0, 0, shstrOff, length(ShNames), 0, 0, 1, 0);
  if dynamic then begin   { the loader's tables, for readelf and objdump }
    Shdr('.dynamic', 6, 3, bssAdr, bssOff, dynSize, 8, 0, 8, 16);
    Shdr('.dynstr', 3, 2, extraAdr + strAt, extraAdr + strAt - roAdr + roOff, strLen, 0, 0, 1, 0);
    Shdr('.dynsym', 11, 2, extraAdr + symAt, extraAdr + symAt - roAdr + roOff, nsym * 24, 8, 1, 8, 24);
  end;
  Shdr('.debug_line', 1, 0, 0, dbgOff[0], dbgSize[0], 0, 0, 1, 0);
  Shdr('.debug_info', 1, 0, 0, dbgOff[1], dbgSize[1], 0, 0, 1, 0);
  Shdr('.debug_abbrev', 1, 0, 0, dbgOff[2], dbgSize[2], 0, 0, 1, 0);

  p := path + #0;
  fd := FpOpen(@p[1], O_WRONLY or O_CREAT or O_TRUNC, &755);
  if fd < 0 then Fatal('can''t write ' + path);
  if FpWrite(fd, buf^, len) <> len then Fatal('can''t write ' + path);
  FpClose(fd);
  FreeMem(strs);
  FreeMem(buf);
end;

end.
