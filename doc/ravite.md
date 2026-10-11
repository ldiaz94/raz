# ravite

ravite (raz visual text editor) is a terminal editor written in raz,
with emacs's keys: buffers, the minibuffer, ido, a small dired, M-x and
settings. It colours raz through the scanner the formatter uses,
`tools/Scan.raz`. On Linux it is a static program, with no C; built
over `lib/Sys.raz`, the C one, it runs through the C library instead,
as it would on other systems:

    $ ./raz -I test/libc/mods -I tools -o ravite ravite/Ravite.raz

    $ make ravite                   # build/ravite
    $ build/ravite Module.raz       # or several files, or none for *scratch*
    $ make install                  # raz and ravite on PATH, through ~/.local

C- is Control, M- is Meta: Alt, or ESC and then the key.

## Keys

**Moving.** C-f C-b C-n C-p and the arrows; C-a C-e, Home and End;
M-f M-b by words; M-< M-> to the ends, setting the mark; M-{ M-} by
paragraphs; C-v M-v by screens, PageDown and PageUp; C-l puts the line
in the middle, then the top, then the bottom; M-g g goes to a line;
M-m to the first character of the line that isn't blank.

**Typing and deleting.** Typing inserts. RET starts a new line with the
indent of the one before; C-o opens a line after the point; TAB inserts
spaces to the next multiple of 4. DEL and C-d delete a character, or
DEL the region if it is shown; M-\ deletes the blanks around the point,
M-SPC leaves one; M-^ joins the line to the one before; C-t swaps two
characters; M-u M-l M-c change the case of a word.

**The mark and killing.** C-SPC sets the mark and shows the region; C-x
C-x swaps the point and the mark; C-x h marks the whole buffer. C-w
kills the region, M-w copies it, C-k kills to the end of the line or the
line break, M-d and M-DEL kill words. Kills in a row add up to one. C-y
yanks the last kill back; M-y right after it yanks an older one instead.

**Undo.** C-/, C-_ or C-x u undoes a command; typing is undone 20 keys
at a time. M-x undo-redo makes it again.

**Counts.** C-u 3 before a command does it 3 times; C-u alone is 4,
C-u C-u 16, M-3 is 3. C-u C-k kills whole lines.

**Search.** C-s and C-r search as you type, forward or back. Again for
the next match; at the end it fails, and once more it goes round. DEL
takes back a step, C-w adds the next word, RET stops there, C-g goes
back to where it started, and any other key stops and does its own
work. A search with no capital letters matches either case. M-%
replaces, asking at each match: y or SPC, n or DEL, ! for all the
rest, . for this one and stop, q or RET to stop. The replacement takes
the case of what it replaces, if that is all capitals or capitalized.

**Files and buffers.** C-x C-f finds a file, C-x C-s saves, C-x C-w
writes to another name, C-x s offers to save each changed file, C-x b
switches buffer, C-x k kills one, C-x C-b lists them, C-x C-c quits,
offering to save first. `*scratch*` is a buffer for notes that is no
file.

**The minibuffer** is edited with the same keys as any buffer; RET takes
it, C-g gives up. With ido, which is on, the choices that hold what you
typed follow it: `{first | second | ...}`. C-s and C-r turn them round,
TAB completes as far as they agree, RET takes the first, C-j takes just
what you typed. In C-x C-f, / goes into a directory and DEL out of it,
~/ goes home and // to the root, and C-d opens the directory.

**The list of buffers.** RET or f shows the buffer on the line, d or k
marks it to be killed and u unmarks it, x kills those marked, g lists
again, n and p move, q leaves.

**Dired.** C-x d, or finding a directory, lists it: each entry's kind,
size and name. RET or f opens an entry, ^ goes up, n and p move, g
lists again, + makes a directory, R renames, D deletes a file after a
yes, q leaves.

**M-x** runs any command by its name; C-h k says what a key runs, and
C-h b lists every binding.

## Settings

ravite reads `~/.ravite` when it starts:

    # my settings
    bind C-c f find-file     # keys as emacs writes them, then a command
    unbind C-z
    set indent 2             # columns TAB goes on by; 4 unless set
    set tab-width 4          # columns of a tab character; 8 unless set
    set colour off           # on unless set, or NO_COLOR is
    set ido off              # on unless set

A line that is wrong is named in the echo area, and the rest still
counts. M-x global-set-key, set-variable and load-init-file do the same
while ravite runs. C-c, C-x, C-h and M-g always start a sequence, so
`bind C-c x ...` works with nothing else under C-c.

## What it shows

The buffer, its mode line, and the echo area, which the minibuffer
shares. The mode line is emacs's: `-UU-:**-  name   Top L12   (Raz)`,
`**` when changed, `%%` when it can't be changed. Long lines scroll
sideways; they don't wrap. A tab reaches to the next multiple of the
tab width, a control character shows as `^` and a letter, and every
other character takes one column. When the point leaves the window,
its line comes halfway down, as in emacs.

A `.raz` buffer is coloured: reserved words, basic types, built-ins,
`true` `false` `nil`, numbers, strings and characters, and comments, in
the 16 standard colours, so the terminal's theme decides how they look.

## Files

A file is read whole, exactly as it is. Saving writes `file.ravite~`
first and then renames it over the file, so that a failed write leaves
the file as it was. The new file is readable by all and writable by its
owner, whatever the old one's mode was.

## How it differs from emacs

Each session test, `test/ravite/X.keys`, leaves the text that `emacs -Q
-nw` leaves with the same keys, set up as `test/emacs.py` says, except
for what is below.

- RET indents as the line before, as newline-and-indent does; TAB is
  tab-to-tab-stop every 4 columns. There are no major modes.
- One window: C-x C-b shows the list in it, not beside it.
- No `*Messages*`, no Lisp, no recursive minibuffers, no minibuffer
  history, no undo in a tree.
- Search is for text, not patterns; ido matches by substring only.
- Dired shows kinds and sizes, not modes, owners or dates; it has no
  marks, and deletes files only.
- M-x reads with ido too.

## Not here

Several windows, the mouse, the system clipboard, wrapping, wide
characters (each takes one column), file:line on the command line,
keyboard macros, and colours for other languages. A crash by a signal
leaves the terminal raw: `reset` puts it right. Over C it needs a C
library whose `struct dirent` and `TIOCGWINSZ` are glibc's; FreeBSD's
aren't, so FreeBSD wants a `Sys` of its own (section 11 of the report).

## Inside

| Module | Lines | What |
|---|---|---|
| `Keys.raz` | 271 | a key from a terminal's bytes, Meta too; keys as emacs writes them |
| `Text.raz` | 337 | the text, a gap buffer of bytes, with undo and redo |
| `Colour.raz` | 109 | the colour of each byte on the screen |
| `View.raz` | 121 | the screen: the buffer, the mode line, the echo area |
| `Core.raz` | 375 | buffers, the echo area, settings, files; the hooks parts read and run keys through |
| `Edit.raz` | 558 | moving, typing, deleting, the mark, the kill ring, undo |
| `Mini.raz` | 269 | the minibuffer, ido, yes or no |
| `Search.raz` | 241 | incremental search, query-replace |
| `Dired.raz` | 336 | directories, and the list of buffers |
| `Commands.raz` | 799 | the commands' names, keymaps, counts, M-x, files, buffers, settings, help |
| `Ravite.raz` | 271 | the arguments, the screen, keys from the terminal or a script, the loop |

Lines are those of code, as `make loc` counts them; they are a
measure, not a limit: ravite is written to be read.

**Keys and commands.** Every key comes through `Commands.runKey`, which
reads the rest of its sequence while the keymaps say it is a prefix,
and runs the command bound to it, for the kind of buffer first, then
for all. A command is a procedure that takes its count. The minibuffer
is a buffer too: while it is open, the keys go through the same
keymaps, on it, but RET and C-g.

What ravite needs of the system, the terminal, files, directories and
the environment, is `Sys`'s (section 11 of the report).

**Core** holds what the parts share, and procedures the main module
sets, through which a part reads a key or runs one without importing
the part that does: raz modules can't import each other in a circle.

**Text.** The bytes lie in one block with a gap where the last change
was. Each change is logged with its bytes, so undo takes it back and
redo makes it again; a command starts a new step. Lines aren't kept in
a table: moving up and down walks from the point's line.

**Colour.** Only the screen is coloured. The one thing that carries
from line to line is a comment, so each buffer keeps the depth of
comment where its window starts, and counts on from there as it
scrolls down; after a jump back, or a change above it, it counts again
from the start of the buffer.

**Tests.** `ravite -script W H file... < keys` types keys written as
emacs writes them on a screen W by H, and at their end, or at C-x C-c,
prints the screen as plain text and then the buffer. `make check` runs
each `test/ravite/X.keys` on a copy of `X.txt`, or with `X.args`, in a
home of its own with a fresh copy of `test/ravite/tree` and `X.init` as
its `.ravite`, against `X.expect`; and the tests in `Keys`, `Text` and
`Colour`. Every session runs twice, over Linux's `Sys` and over the C
one.
