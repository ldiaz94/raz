#!/usr/bin/env python3
"""Builds the website into site/public/ from site/content/ and the repository.

    python3 site/build.py

The site is plain files: open public/index.html, or put the folder on
any web server. Nothing runs in the reader's browser; the code on the
tour's pages is run here, by ./raz, and the output shown is what it
printed, so a lesson that stops working fails the build.

Lessons are site/content/<tour>/NN-name.txt, one folder to a tour (see
TOURS below):

    title: Hello, world          (the first lines are "key: value")
    part: Raz                    (the lessons are grouped in parts)
    summary: a line for the contents page
    ---
    Paragraphs, separated by blank lines.  `code`, **bold**,
    [links](url) and "- " lists are understood, and nothing else.

    ```raz Name run
    ```

A fenced block "raz Name" is a module, written as Name.raz in a folder
of its own for the lesson.  "run" has the build run it and show what it
printed; "fail" runs it and shows the failure it ends in.  A block with
nothing in it is taken from doc/raz-tutorial.7, whose programs make
check already runs, by the module's name.

Two other blocks: "```text" is shown as written, and "```sh" is a shell
session: each line that starts with "$ " is run in the lesson's folder,
with raz on the path, and shown with what it printed.
"""
import html, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, "public")
RAZ = os.path.join(ROOT, "raz")
REPO = "https://github.com/ldiaz94/raz"

# folder in content/, folder in public/, name, the sentence under the name
TOURS = [
    ("tour", "tour", "Raz, Set, Go", "tour-intro.html"),
    ("advanced", "advanced", "Close to the Metal", "advanced-intro.html"),
]

KEYWORDS = set("""and begin break by code const defer div do else elsif end
extern for forward if import in link match mod module not of or packed proc
record repeat return set shl shr then to type until var variant VOLATILE
while xor""".split())
PREDECLARED = set("""INT UINT I8 I16 I32 I64 U8 U16 U32 U64 F32 F64 BOOL ERROR
true false nil LEN ADR NEW SIZE INC DEC MSG XADD CAS XCHG""".split())

# ---- highlighting ------------------------------------------------------

TOKEN = re.compile(r"""
    (?P<comment>\(\*.*?\*\)) |
    (?P<string>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*') |
    (?P<number>\b\d[0-9A-Fa-f]*(?:\.\d+)?(?:E[-+]?\d+)?H?\b) |
    (?P<word>[A-Za-z_][A-Za-z_0-9]*)
""", re.X | re.S)

def highlight(src):
    """src as HTML, its comments, strings, numbers and words in spans."""
    out, at = [], 0
    for m in TOKEN.finditer(src):
        out.append(html.escape(src[at:m.start()]))
        text, kind = m.group(), m.lastgroup
        if kind == "word":
            kind = ("kw" if text in KEYWORDS else
                    "ty" if text in PREDECLARED else None)
        if kind:
            out.append('<span class="%s">%s</span>' % (kind, html.escape(text)))
        else:
            out.append(html.escape(text))
        at = m.end()
    out.append(html.escape(src[at:]))
    return "".join(out)

# ---- the tutorial's programs -------------------------------------------

def tutorial_blocks():
    """Every literal block of the manual page, as raz source."""
    blocks, cur = [], None
    for line in open(os.path.join(ROOT, "doc", "raz-tutorial.7"), encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith(".Bd -literal"):
            cur = []
        elif line == ".Ed" and cur is not None:
            blocks.append("\n".join(cur) + "\n")
            cur = None
        elif cur is not None:
            # roff writes a backslash as \e and a dot at a line's start as \&.
            cur.append(line.replace("\\&", "").replace("\\e", "\\"))
    return blocks

def tutorial_module(name):
    for b in tutorial_blocks():
        if re.search(r"^module %s\b" % re.escape(name), b, re.M):
            return b
    sys.exit("no program %s in the tutorial" % name)

# ---- running -----------------------------------------------------------

def run(directory, name):
    """(stdout, stderr, status) of the module name, compiled and run."""
    p = subprocess.run([RAZ, "run", "-Werror", name + ".raz"], cwd=directory,
                       capture_output=True, text=True, timeout=60)
    return p.stdout, p.stderr, p.returncode

def shell_html(directory, script):
    """A session: each "$ command" line run in directory, with its output."""
    bin = os.path.join(directory, ".bin")
    os.makedirs(bin, exist_ok=True)
    if not os.path.exists(os.path.join(bin, "raz")):
        os.symlink(RAZ, os.path.join(bin, "raz"))   # raz finds lib/ by its real path
    env = dict(os.environ, PATH=bin + ":" + os.environ["PATH"],
               RAZLIB=os.path.join(ROOT, "lib"))
    out = []
    for line in script.rstrip("\n").split("\n"):
        if not line.startswith("$ "):
            out.append(html.escape(line))
            continue
        out.append('<span class="cmd">%s</span>' % html.escape(line))
        p = subprocess.run(line[2:], shell=True, cwd=directory, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=60)
        text = p.stdout.rstrip("\n")
        if text:
            out.append(html.escape(text))
    return '<pre class="output term"><code>%s</code></pre>' % "\n".join(out)

def output_html(stdout, stderr):
    out = html.escape(stdout)
    if stderr:
        out += '<span class="err">%s</span>' % html.escape(stderr)
    return '<pre class="output"><code>%s</code></pre>' % out

# ---- a little markup -----------------------------------------------------

def inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    return s

def prose(text):
    out = []
    for para in re.split(r"\n\s*\n", text.strip()):
        lines = para.split("\n")
        if para.startswith("## "):
            out.append("<h2>%s</h2>" % inline(para[3:]))
        elif all(l.startswith("- ") for l in lines):
            out.append("<ul>%s</ul>" % "".join(
                "<li>%s</li>" % inline(l[2:]) for l in lines))
        else:
            out.append("<p>%s</p>" % inline(" ".join(lines)))
    return "\n".join(out)

# ---- lessons -------------------------------------------------------------

def read_lesson(path):
    head, _, body = open(path, encoding="utf-8").read().partition("\n---\n")
    meta = dict(l.split(": ", 1) for l in head.strip().split("\n"))
    meta["slug"] = re.sub(r"^\d+-|\.txt$", "", os.path.basename(path))
    meta["body"] = body
    return meta

def lesson_body(lesson):
    """The lesson's page content; runs its programs."""
    parts, tmp = [], tempfile.mkdtemp()
    try:
        chunks = re.split(r"^```(raz [^\n]*|text|sh)\n(.*?)^```$", lesson["body"],
                          flags=re.M | re.S)
        # chunks: text, info, code, text, info, code, ..., text
        for i in range(0, len(chunks), 3):
            if chunks[i].strip():
                parts.append(prose(chunks[i]))
            if i + 1 >= len(chunks):
                break
            kind, code = chunks[i + 1], chunks[i + 2]
            if kind == "text":
                parts.append('<pre class="code"><code>%s</code></pre>'
                             % html.escape(code.rstrip("\n")))
                continue
            if kind == "sh":
                parts.append(shell_html(tmp, code))
                continue
            info = kind.split()[1:]
            name, flags = info[0], info[1:]
            if not code.strip():
                code = tutorial_module(name)
            with open(os.path.join(tmp, name + ".raz"), "w", encoding="utf-8") as f:
                f.write(code)
            parts.append('<div class="file"><span>%s.raz</span></div>'
                         '<pre class="code"><code>%s</code></pre>'
                         % (name, highlight(code.rstrip("\n"))))
            if "run" in flags or "fail" in flags:
                stdout, stderr, status = run(tmp, name)
                if ("fail" in flags) == (status == 0):
                    sys.exit("%s: %s ended with status %d\n%s%s" % (
                        lesson["slug"], name, status, stdout, stderr))
                parts.append(output_html(stdout, stderr))
    finally:
        shutil.rmtree(tmp)
    return "\n".join(parts)

# ---- pages ---------------------------------------------------------------

def page(title, body, depth=0, current=""):
    up = "../" * depth
    nav = "".join('<a href="%s%s"%s>%s</a>' % (
        up, href, ' aria-current="page"' if key == current else "", label)
        for key, href, label in [
            ("home", "index.html", "raz"),
            ("tour", "tour/index.html", "Raz, Set, Go"),
            ("advanced", "advanced/index.html", "Close to the Metal"),
            ("spec", "spec.html", "Report"),
            ("get", "index.html#download", "Download")])
    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s</title>
<link rel="stylesheet" href="%sstyle.css">
</head>
<body>
<header><nav>%s<a class="repo" href="%s">GitHub</a></nav></header>
<main>
%s
</main>
<footer>raz is under the ISC license. <a href="%s">Source</a>.</footer>
</body>
</html>
""" % (html.escape(title), up, nav, REPO, body, REPO)

def write(path, text):
    path = os.path.join(OUT, path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

def build_tour(tour, lessons, next_page):
    """One tour's pages: a contents page and a page to each lesson.
    next_page is (href, label) for what follows its last lesson."""
    folder, outdir, name, intro_file = tour
    parts = []
    for l in lessons:
        if l["part"] not in parts:
            parts.append(l["part"])
    first = lambda p: 1 + next(i for i, x in enumerate(lessons) if x["part"] == p)
    for n, l in enumerate(lessons):
        toc = []
        for p in parts:
            toc.append("<h3>%s</h3><ol start='%d'>" % (p, first(p)))
            for i, x in enumerate(lessons):
                if x["part"] == p:
                    cur = ' aria-current="page"' if i == n else ""
                    toc.append('<li><a href="%s.html"%s>%s</a></li>' % (
                        x["slug"], cur, html.escape(x["title"])))
            toc.append("</ol>")
        pager = '<a href="index.html">Contents</a>'
        if n > 0:
            pager = '<a href="%s.html">&larr; %s</a>' % (
                lessons[n - 1]["slug"], html.escape(lessons[n - 1]["title"])) + pager
        if n + 1 < len(lessons):
            pager += '<a class="next" href="%s.html">%s &rarr;</a>' % (
                lessons[n + 1]["slug"], html.escape(lessons[n + 1]["title"]))
        else:
            pager += '<a class="next" href="%s">%s &rarr;</a>' % next_page
        body = ('<div class="tour"><aside><h2>%s</h2>%s</aside><article>'
                '<p class="kicker">%s &middot; lesson %d of %d</p><h1>%s</h1>\n%s'
                '<p class="tryit">Save a program under its module&rsquo;s name and run '
                'it with <code>raz run Name.raz</code>.</p>'
                '<div class="pager">%s</div></article></div>') % (
            name, "\n".join(toc), l["part"], n + 1, len(lessons),
            html.escape(l["title"]), lesson_body(l), pager)
        write("%s/%s.html" % (outdir, l["slug"]), page(
            "%s - %s" % (l["title"], name), body, 1, folder))
    cards = []
    for p in parts:
        cards.append("<h2>%s</h2><ol start='%d'>" % (p, first(p)))
        for x in lessons:
            if x["part"] == p:
                cards.append('<li><a href="%s.html">%s</a> <span>%s</span></li>' % (
                    x["slug"], html.escape(x["title"]), html.escape(x["summary"])))
        cards.append("</ol>")
    intro = open(os.path.join(HERE, "content", intro_file), encoding="utf-8").read()
    write("%s/index.html" % outdir, page(name,
          '<div class="contents">%s%s</div>' % (intro, "\n".join(cards)), 1, folder))

def build_spec():
    if not shutil.which("pandoc"):
        sys.exit("pandoc makes the report's page: apt-get install pandoc")
    p = subprocess.run(
        ["pandoc", os.path.join(ROOT, "doc", "raz.md"), "-s", "--template",
         os.path.join(HERE, "content", "spec.tmpl"), "--toc", "--toc-depth=1",
         "--shift-heading-level-by=-1", "--no-highlight", "-t", "html"],
        capture_output=True, text=True, check=True)
    body = '<div class="spec">%s</div>' % p.stdout
    write("spec.html", page("The raz report", body, 0, "spec"))

def build_home():
    snippet = open(os.path.join(HERE, "content", "home.raz"), encoding="utf-8").read()
    tmp = tempfile.mkdtemp()
    try:
        with open(os.path.join(tmp, "Taste.raz"), "w", encoding="utf-8") as f:
            f.write(snippet)
        stdout, stderr, status = run(tmp, "Taste")
        if status != 0:
            sys.exit("Taste failed:\n" + stderr)
    finally:
        shutil.rmtree(tmp)
    text = open(os.path.join(HERE, "content", "home.html"), encoding="utf-8").read()
    text = text.replace("@SNIPPET@", highlight(snippet.rstrip("\n")))
    text = text.replace("@OUTPUT@", html.escape(stdout.rstrip("\n")))
    write("index.html", page("raz: a small systems language", text, 0, "home"))

def main():
    if not os.path.exists(RAZ):
        sys.exit("make raz first")
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    shutil.copy(os.path.join(HERE, "style.css"), OUT)
    names = sorted(f for f in os.listdir(os.path.join(HERE, "content"))
                   if re.match(r"\d+-.*\.txt$", f))
    counts = []
    for i, tour in enumerate(TOURS):
        folder = os.path.join(HERE, "content", tour[0])
        lessons = [read_lesson(os.path.join(folder, f))
                   for f in sorted(os.listdir(folder)) if re.match(r"\d+-.*\.txt$", f)]
        if i + 1 < len(TOURS):
            nxt = ("../%s/index.html" % TOURS[i + 1][1], TOURS[i + 1][2])
        else:
            nxt = ("../spec.html", "The report")
        build_tour(tour, lessons, nxt)
        counts.append(len(lessons))
    build_spec()
    build_home()
    print("site/public: %s lessons" % " + ".join(map(str, counts)))

main()
