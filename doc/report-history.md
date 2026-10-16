# The versions of the report

What each version of the report, `doc/raz.md`, changed. A version is named
by the month it was made in and a count: `2026-10.0`, then `2026-10.1`
for the next change that month. Section numbers are those of the report
at the time.

- **2026-10.0.** The first numbered version: the language of compiler
  0.3.0.
- **2026-10.1.** Messages: every error in a run, warnings of what is
  never used and `-Werror` (section 10); failed checks say what failed,
  and signals say where (sections 6.5 and 10).
- **2026-10.2.** `Sys` gains files and directories, the terminal, and
  the environment (section 11).
- **2026-10.3.** `return f(x);` passes on the several results of `f`
  (sections 7.3 and 8). `and`, `or` and `not` are for `BOOL`s, and
  bind below the relations; `&`, `|` and `~` are the operators on bits,
  and `xor` is for integers only (sections 2 and 6). Arrays and slices
  of integers, `BOOL`s, enumerations, sets and pointers compare with
  `=`, by code where the comparison stands, not by a call into `Rt`
  (section 6.5). A generic module's instance is made where it is first
  used, so its arguments may name types declared after the imports
  (section 3).
- **2026-10.4.** `Sys` gains a connection to a Unix socket, waiting on
  several files at once, pseudo-terminals, and starting, waiting for
  and stopping programs (section 11).
- **2026-10.5.** A module with files in more than one of the
  directories searched is an error, unless the first is a link to one
  of the others (section 3).
- **2026-10.6.** `Sys.Info` says whether the path is a regular file,
  and whether it is a symbolic link (section 11).
- **2026-10.7.** `Sys.send` writes to a socket without SIGPIPE
  (section 11).
- **2026-10.8.** `Sys.workDir` returns the directory, with no `var`
  parameter (section 11).
- **2026-10.9.** The language is frozen (the start of the report).
  `Sys` gains opening a file for any use, seeking,
  links, permissions and times; pipes, process groups and the
  terminal's foreground; signals caught on a file descriptor; clocks,
  sleeping and random bytes; and network sockets. `Sys.spawn` takes a
  `Program`, and `Sys.wait` says which program changed and how. `Str`
  gains UTF-8 and reading a number, `Map` removing and walking, `Fmt`
  reals; `Sort`, `Math`, `Files` and `Opt` are new (section 11).
- **2026-10.10.** Said at last: what the compiler did and the report
  didn't say, all through; what an implementation chooses, and the
  core every target has (appendix A); the whole grammar (appendix B);
  the library's module names are kept for it (section 3); a record,
  variant or enumeration is a type of its own wherever it is written
  (section 5.10); a `nil` pointer, a division by zero and a stack
  overflow stop the program on every target (section 10); byte order
  is the target's, and `Str` reads and writes a fixed one (sections
  5.5 and 11); `Out`'s buffer is `Sys.outSize` bytes (section 11).
  Changed: a field of a packed record that may be misaligned has no
  address and no volatile access (section 5.5). Mended:
  arithmetic on untyped constants that overflows is an error (section
  2); a slice of a pointer can't run backwards (section 6.4). Ordinary
  accesses are no longer promised to be made exactly as written, only
  volatile and atomic ones (section 7.6).
- **2026-10.11.** `INT` and `UINT`, as big as an
  address, are the integers of lengths, slices, pointer differences,
  pointer conversions, `SYSCALL` and `ARGC`; `SIZE` and a constant
  `LEN` are untyped; `INT` widens silently to `I64` and `UINT` to
  `U64`, but neither mixes with them in an expression or a `for`
  (sections 5, 6.1 and 7.2); `Mem.Allocator` takes `INT` sizes.
  Pointers, procedures, `ERROR`s, slices and variants' tags are sized
  by the address, and basic types aligned as the target's C aligns
  them (section 5). Reals are a target's to have or not (section
  5.1). An exported variable can't be changed, passed by `var` or
  addressed outside its module, nor an array in it sliced (section 3). `check off;`
  leaves a module's index and slice checks out (sections 3, 6.4 and
  6.5). An index of any integer type is checked by its value (6.5). A
  shift counts modulo its operand's width, and the smallest value of
  every signed type divided by -1 stops the program (6.1). Writing a
  string's bytes isn't defined (5.10). The atomic built-ins work on
  `INT`, `UINT` and pointers (6.8). An integer constant past an
  extern's parameters goes as an `INT` (9). An importer depends only
  on a module's interface, so a module can be compiled on its own;
  whether it is, and into what, is the implementation's (sections 3
  and 10; appendix A). The library takes and gives
  `INT` for lengths, counts, descriptors, process ids and statuses,
  `main`'s and `Rt.exit`'s among them, and `I32` for a character;
  `I64` stays for what may pass an `INT` on a small target: a file's
  size and position, times, and numbers read from text (section
  11). An array constant has a type and is used as a variable that
  can't be changed; `+` joins string constants (section 4). `match`
  takes an integer, with constants and ranges as labels (7.4).
- **2026-10.12.** A code procedure is written in the target's assembly
  language, not as bytes (section 8; appendix A). A program that stops
  says the calls under way and their variables, and `Rt.trace` says
  them on demand (sections 10 and 11).
- **2026-10.13.** `Sys` gains writing without waiting, and waiting for
  room to write (section 11).
- **2026-10.14.** The blank, `_`, drops a value or one of several
  results (section 7.1); a call that drops a result is a lint
  (section 10).
- **2026-10.15.** `Math` gains `pow`, `ceil`, `round`, `log2`,
  `log10`, `tan`, `asin`, `acos` and `atan`; `Sys` gains `space`
  (section 11).
- **2026-10.16.** Record constants, and array and record constants of
  records, strings, procedures and more (section 4); `Str` gains
  `copy` (section 11).
- **2026-10.17.** `COPY` copies the elements of one array or slice to
  another as a block (section 6.8).
- **2026-10.18.** A code procedure takes and returns slices (section
  8).
- **2026-10.19.** The library gains `Bytes` (section 11).
- **2026-10.20.** `try`: a call of a procedure whose last result is an
  `ERROR`, which makes the procedure it stands in return that error
  when it isn't `nil` (sections 2, 5.8, 6, 7.8 and appendix B). `try`
  becomes a reserved word, which breaks a program with a name `try`.
- **2026-10.21.** An arm of a `match` on an enumeration may name
  several of its names (section 7.4).
- **2026-10.22.** Mends and trims, from an audit of the report against its
  tests. What is an error is stated once (section 10), by meaning; the
  words of messages, the number of them and the warnings are an
  implementation's. Every stop of a running program, a nil pointer, a
  division by zero, a stack overflow, a failed check, ends with status 2,
  after the `Rt.atExit` procedures (section 10). Readings the compiler
  had taken are in the report: `check` and `off` aren't reserved, an
  untyped constant converts to a pointer as an `INT` does, a shift of an
  untyped constant, which types `match` takes, `lo` above `hi`, a `defer`
  in a `defer`, where an `INT` widens, a real above the largest `F64`, a
  code point above 10FFFFH, a NUL byte, a volatile variable passed by
  `var`, and a `forward` with no body. The core of the library is what
  `conform/` tests (appendix A); the rest of the library is the standard
  library. The report is in two volumes, `doc/raz.md` and `doc/raz-lib.md`,
  and its history is here.
- **2026-10.23.** `Math` gains `bits` and `fromBits`, an `F64`'s bits
  and back, and `mul`, the 128-bit product of two `U64`s, for reading
  and writing reals exactly (volume 2).
- **2026-10.24.** `Sys` gains serving datagrams, `listenUdp`,
  `receive` and `reply`; a socket's own port, `localPort`; connecting
  with a timeout, `connectTcpWithin`; passing files over a Unix socket,
  `sendFds` and `receiveFds`; and memory shared through a file,
  `memFile` and `mapFile`. `Thread` works in a program that uses C,
  and no longer says `link static` (volume 2).
- **2026-10.25.** A thaw, for strings. A raw string, between
  backquotes, has no escapes and may run over lines, indented with
  the code around it (section 2 and appendix B); `match` takes a string, with string constants as labels
  (section 7.4). It breaks no program. `Str` gains `eqFold`,
  `findLast`, `hasSuffix`, `trim`, `trimLeft`, `trimRight`, `cut`,
  `field`, `lower`, `upper`, `join`, `replace`, `decodeLast`,
  `next`, `valid`, `chars`, `toHex` and `fromInt`; `Math` gains
  `toReal` (volume 2).
- **2026-10.26.** A thaw, for `INT` and `I64`, and for views. An `INT` widens to an
  `I64`, and a `UINT` to a `U64`, wherever its value goes to one: in an
  expression, where it meets one, and in `a, b := f(x)`, `return
  f(x)`, a `for`'s bounds and the step of `INC` and `DEC` (sections
  5.10, 6.1 and 7.2). A view, `v.(T)`, reads and writes the bytes of
  the variable `v` as a `T`, checked to lie within it (section 6.9 and
  appendix B). It breaks no program. `Sys` gains `position`,
  `truncate`, `sync` and `infoOf`; `Opt` gains `at`, where the
  operands are (volume 2).
- **2026-10.27.** A defect mended: returning, as a slice, a local
  array, a value parameter that is an array, an array literal, or a
  slice, field or element of one, is an error, since the frame it
  points into is gone once the procedure returns (section 7.3); what
  isn't caught is named among the exceptions of section 10. `Sys`
  gains `openMode`, `syncAll`, `lock`, `linkInfo` and `Info.ino`;
  `Buf` gains `spare`, and its `add` and `str` stop the program when
  memory runs out rather than dropping bytes; the standard library
  gains `Vec`, a growable array (volume 2).
- **2026-10.28.** A defect mended: an array a call returns lives to the
  end of the statement the call is in, and a slice of it kept past
  that is undefined, among the exceptions of section 10 (section 8).
  `Sys` gains `entryKind` and `Info.dev`; `spawn` finds a name without
  a `/` along `PATH`; over the C library, `syncAll` of a file that
  isn't open is -9 (EBADF), as on Linux (volume 2).
- **2026-10.29.** A thaw, for tables. An array constant typed `[]T`
  takes its length from its literal, and is an array constant of that
  length in all else (section 4). It breaks no program. `Sys` gains
  what a shell needs: `dup`, `dupTo`, `keepOnExec`, `Program.more`,
  `exec`, `access` and `Access`'s `executing`, `umask`, `envAt`,
  `getMode` and `setMode`, `cpuTime`, `limit` and `setLimit`, `uid`,
  `euid`, `hostName`, and `sigUsr1`, `sigUsr2` and `sigAlrm`; `Map`
  gains `done`, `Str` gains `free`, and `Files` gains `load` (volume
  2).
