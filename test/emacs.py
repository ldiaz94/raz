"""Checks a session of ravite against emacs: plays the keys of
test/ravite/X.keys, written as emacs writes them, into emacs -Q -nw
on a 40 by 12 screen and into ravite -script, each on a copy of X.txt,
and says whether the buffer each ends in holds the same text.

    python3 test/emacs.py build/ravite test/ravite/X.keys [X.txt]

EXTRA="(ido-mode 1)" adds lisp to emacs's set-up. Emacs is set up as
ravite is: spaces for indenting, RET as newline-and-indent, TAB as
tab-to-tab-stop every 4 columns, no menu bar. Not run by make check:
it needs emacs, and waits for it."""
import os, pty, sys, time, select, subprocess, shutil, tempfile, fcntl, termios, struct
SPECIAL = {'RET': b'\r', 'SPC': b' ', 'TAB': b'\t', 'DEL': b'\x7f', 'ESC': b'\x1b', 'LFD': b'\n',
  '<up>': b'\x1b[A', '<down>': b'\x1b[B', '<right>': b'\x1b[C', '<left>': b'\x1b[D',
  '<home>': b'\x1bOH', '<end>': b'\x1bOF', '<prior>': b'\x1b[5~', '<next>': b'\x1b[6~', '<delete>': b'\x1b[3~'}
def ctrl(c):
    if c == '/': return 31
    if c == '?': return 127
    if c == 'SPC' or c == ' ': return 0
    return ord(c.upper()) & 31
def word(w):
    meta = ctrlf = False
    while len(w) > 2 and w[1] == '-' and w[0] in 'CM':
        if w[0] == 'C': ctrlf = True
        else: meta = True
        w = w[2:]
    if w in SPECIAL: b = SPECIAL[w]
    elif len(w) == 1: b = w.encode()
    else: return None
    if ctrlf: b = bytes([ctrl(w)]) if w != 'SPC' else b'\x00'
    if meta: b = b'\x1b' + b
    return b
def keys(text):
    out = []
    for w in text.split():
        b = word(w)
        if b is not None: out.append(b)
        else: out.extend(ch.encode() for ch in w)
    return out
def drain(fd, t):
    data = b''
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.01)
        if r:
            try: data += os.read(fd, 65536)
            except OSError: break
    return data
INIT = '(progn (setq-default indent-tabs-mode nil tab-width 4) (global-set-key (kbd "RET") (quote newline-and-indent)) (global-set-key (kbd "TAB") (quote tab-to-tab-stop)) (menu-bar-mode -1) (setq make-backup-files nil auto-save-default nil ring-bell-function (quote ignore)) %s)'
def emacs(path, ks, out, extra=''):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'xterm'
        os.execvp('emacs', ['emacs', '-Q', '-nw', '--eval', INIT % extra, path])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 12, 40, 0, 0))
    drain(fd, 2.5)
    os.write(fd, b'\x07'); drain(fd, 0.3)
    for k in ks:
        os.write(fd, k); drain(fd, 0.03)
    os.write(fd, b'\x07\x07\x07')
    drain(fd, 0.2)
    os.write(fd, b'\x1b:(progn (write-region nil nil "' + out.encode() + b'") (kill-emacs))\r')
    drain(fd, 1.0)
    os.waitpid(pid, 0)
    return open(out, 'rb').read()
args = [a for a in sys.argv[1:] if not a.startswith('-')]
ravite, kf = args[0], args[1]
txt = args[2] if len(args) > 2 else None
extra = os.environ.get('EXTRA', '')
d = tempfile.mkdtemp()
for who in ('e', 'r'):
    if txt: shutil.copy(txt, os.path.join(d, who + '.txt'))
ks = keys(open(kf).read())
e = emacs(os.path.join(d, 'e.txt'), ks, os.path.join(d, 'out'), extra)
r = subprocess.run([ravite, '-script', '40', '12', os.path.join(d, 'r.txt')], input=open(kf, 'rb').read(), capture_output=True).stdout
text = b'\n'.join(r.split(b'\n')[12:]).rstrip(b'\n')
e = e.rstrip(b'\n')
if e == text: print('same:', kf)
else:
    print('DIFFER:', kf); print('--- emacs'); print(e.decode()); print('--- ravite'); print(text.decode())
