# ravite

ravite (raz visual text editor) is a small terminal editor written in
raz, with vim's keys. It colours raz as `editor/vim` does, through the
same scanner as the formatter, `tools/Scan.raz`. It is a static
program of about 2,000 lines, with no C.

    $ make ravite               # build/ravite
    $ build/ravite Module.raz
    $ build/ravite T.raz:5:10   # at line 5, column 10, as raz's messages say
    $ make install              # raz and ravite on PATH, through ~/.local

## Keys

A count before a command repeats it, or names a line. An operator
takes a motion, or itself for whole lines: `dw`, `d3w`, `3dd`, `y$`,
`>}`, `c/end<Enter>`.

**Motions.**

| Keys | To |
|---|---|
| `h j k l`, the arrows | a character left or right on the line, a line down or up |
| `0` `^` `$`, Home and End | the line's start, its first character that isn't blank, its end |
| `w` `b` `e` | the next word's start, this word's or the last one's, this word's end or the next one's |
| `gg` `G`, `5G` | the first line, the last, line 5 |
| `{` `}` | the empty line before, or after |
| `+` `-`, Enter | the first character of the next line, or of the last |
| `%` | the bracket that matches the next of `( ) [ ] { }` on the line |
| `f` `F` `t` `T` and a character | that character on the line, forward or back; `t` and `T` stop just before it |
| `;` `,` | the last `f F t T` again, the same way or the other |
| `/text` `?text` | the next place of text, or the last one, round the end of the file |
| `n` `N`, `*` | the last search again, the same way or the other; the word under the cursor |

**Commands.**

| Keys | What |
|---|---|
| `d` `c` `y` `>` `<` | delete, change, yank, shift right or left by 4 spaces |
| `x` `X`, `D` `C`, `s` `S`, `Y` | `dl` `dh`, `d$` `c$`, `cl` `cc`, `yy` |
| `i` `a` `I` `A` `o` `O` | insert mode: before, after, at the line's start, at its end, on a new line below or above |
| `p` `P` | put what the register holds after the cursor, or before; lines go below or above |
| `r` and a character | replace the character under the cursor |
| `J` | join the line and the next, with one space |
| `u`, Ctrl-R | undo, redo |
| `.` | repeat the last change |
| `v` `V` | visual mode, by characters or by lines |
| Ctrl-D Ctrl-U, Ctrl-F Ctrl-B | scroll half a screen, a screen |
| `ZZ` | write if changed, and quit |

**Insert mode.** Typing inserts. Backspace and Delete remove a
character; Ctrl-W removes a word. Enter keeps the indent of the line;
Tab inserts spaces to the next multiple of 4. Escape, or Ctrl-C, goes
back to normal mode.

**Visual mode.** Motions move the cursor, while the other end stays;
`o` swaps them. `d` `x` `y` `c` `>` `<` act on what is selected;
Escape leaves it.

**The command line.** `:w` writes, `:q` quits, `:q!` quits without
writing, `:wq` writes and quits, `:x` writes if changed and quits,
`:12` goes to line 12, `:$` to the last.

There is one register, which every delete and yank fills. Undo has no
limit; a command, with all it types in insert mode, is one step.

## What it shows

The text, `~` past its end, and a last line: the mode, a message or
the command line on the left, the file, `[+]` when it has changed, and
the cursor's line and column on the right. Long lines scroll sideways;
they don't wrap. A tab reaches to the next multiple of 8 columns, a
control character shows as `^` and a letter, and every other character
takes one column.

A `.raz` file is coloured: reserved words, basic types, built-ins,
`true` `false` `nil`, numbers, strings and characters, and comments, in
the 16 standard colours, so the terminal's theme decides how they look.
`NO_COLOR` turns colour off.

## Files

A file is read whole into memory, without its last line break, and
written with one. Writing goes to `file.ravite~` first, then renames it
over the file, so that a failed write leaves the file as it was. The
new file is readable by all and writable by its owner, whatever the
old one's mode was.

## Not here

The mouse, the system clipboard, several files or windows, wrapping,
wide characters (each character takes one column), settings, patterns
(`/` looks for text), marks, macros, text objects, other registers,
counts on `.`, and colours for other languages. A crash by a signal
leaves the terminal raw: `reset` puts it right. It runs on Linux for
x86-64; FreeBSD needs a `Tty` of its own, over the C library.

## Inside

| Module | Lines | What |
|---|---|---|
| `ravite/Tty.linux-x86_64.raz` | 73 | raw mode and back, the screen's size, waiting for a key, renaming, by system calls |
| `ravite/Keys.raz` | 184 | a key from the bytes a terminal sends; vim's notation for keys, for the tests |
| `ravite/Text.raz` | 330 | the text, a gap buffer of bytes, with undo and redo |
| `ravite/Colour.raz` | 109 | the colour of each byte on the screen |
| `ravite/View.raz` | 154 | the screen, drawn into one buffer and written at once |
| `ravite/Ravite.raz` | 1,305 | the modes, motions, operators, commands, search and the command line |

Lines are those of code, as `make loc` counts them.

**Text.** The bytes lie in one block with a gap where the last change
was; a change moves the gap there first. Each change is logged with
its bytes, so undo takes it back and redo makes it again. A command
starts a new step, and undo takes back a step at a time. Lines aren't
kept in a table: moving up or down walks from the cursor's line, and
going to line N counts from the start, which is fast enough below some
megabytes.

**Keys and `.`.** Every key comes through one procedure, which keeps
the keys of the command under way. A command that changed the text
keeps them as the last change, and `.` plays them again as if typed.
A count on `i` or `o` types the same keys again the same way.

**Colour.** Only the screen is coloured. The one thing that carries
from line to line is a comment, so ravite keeps the depth of comment
where the screen starts, and counts on from there as the screen
scrolls down; after a jump back, or a change above it, it counts again
from the start of the file. `Scan` then reads the symbols on the
screen, and a table gives each word its colour.

**Tests.** `ravite -script W H file` reads keys in vim's notation
(`<esc>`, `<cr>`, `<c-r>`) from standard input, as if typed on a screen
W columns by H rows, and at their end, or at `:q`, prints the screen
as plain text and then the text. Each `test/ravite/X.keys` is typed on
a copy of `X.txt`, or on `X.args` as the file named, and must print
`X.expect`. Each session was checked against what vim does with the
same keys when it was written. `make check` runs them, and the tests
in `Keys`, `Text` and `Colour`.
