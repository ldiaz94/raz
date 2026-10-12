# Builds the compiler, raz, from src/ into the repository's root; the
# library it needs is lib/, beside it.

FPC = fpc
FPCFLAGS = -O2 -Mobjfpc -Sh- -vew -FUbuild

raz: src/*.pas build/version.inc | build
	$(FPC) $(FPCFLAGS) -Fibuild -FE. -oraz src/raz.pas

# The version is git's name for the commit; the file changes only when
# that does, so raz isn't rebuilt for nothing.
build/version.inc: FORCE | build
	@v=$$(git describe --tags --dirty 2>/dev/null || echo unknown); \
	v="'$${v#v}'"; echo "$$v" | cmp -s - $@ || echo "$$v" >$@

FORCE:

units: src/*.pas | build
	for u in diag scan sym chunk x64 link elf; do $(FPC) $(FPCFLAGS) src/$$u.pas || exit 1; done

# tests of the parts below the parser, built from test/
tests: units
	$(FPC) $(FPCFLAGS) -Fusrc -obuild/scantest test/scantest.pas
	$(FPC) $(FPCFLAGS) -Fusrc -obuild/enctest test/enctest.pas
	$(FPC) $(FPCFLAGS) -Fusrc -obuild/handtest test/handtest.pas
	build/handtest build/hand && build/hand; test $$? = 42

build:
	mkdir -p build

clean:
	rm -rf build raz

# every example and test, against what it should print
check: raz build/raz-lib.3
	test/check.sh

# line numbers: gdb stops at a line and names it
gdb: raz
	test/gdb.sh

# the compiler's speed, on a generated program of about 350,000 lines,
# the best of three runs; fails below 400,000 lines a second
bench: raz | build
	python3 test/genbench.py 12000 > build/Bench.raz
	@lines=$$(wc -l < build/Bench.raz); best=0; \
	for i in 1 2 3; do \
	    start=$$(date +%s%N); ./raz build/Bench.raz || exit 1; end=$$(date +%s%N); \
	    t=$$((end - start)); if [ $$best = 0 ] || [ $$t -lt $$best ]; then best=$$t; fi; \
	done; \
	rate=$$((lines * 1000000000 / best)); \
	echo "$$lines lines in $$((best / 1000000)) ms: $$rate lines a second"; \
	test $$rate -ge 400000

# the code's speed: the kernels of test/bench, which say check off,
# against their twins in Pascal built by FPC -O2
kernels: raz
	test/bench/run.sh

# native threads under load: 40,000 spawned and joined, 200 alive at a
# time, all waiting on one Mutex; then, with little memory, spawn must
# fail with Thread.Failed. make check runs a small version.
stress: raz | build
	./raz -o build/Stress lib/Thread.linux-x86_64.raz
	build/Stress 40000 200
	(ulimit -v 60000; build/Stress fail)

# the formatter, tools/Pretty.raz: the library, examples and tools are
# formatted already
fmt: raz | build
	./raz -o build/Pretty tools/Pretty.raz
	@fail=0; for f in lib/*.raz examples/*.raz tools/*.raz; do \
	    build/Pretty $$f | cmp -s - $$f || { echo "not formatted: $$f"; fail=1; }; \
	done; test $$fail = 0

# lines of the compiler, by rloc: each file's blank, comment and code,
# then the lines of code in all
loc:
	@rloc -f src/*.pas
	@rloc -c src/*.pas

# raz-lib(3), the library's manual page, made by tools/Doc.raz from
# its sources, in the order of the report's section 11
LIBDOC = Rt Mem Heap Arena Lock Thread.linux-x86_64 Out Sys.linux-x86_64 \
	Str Buf Fmt List Map Sort Math Files Opt C

man: build/raz-lib.3

build/raz-lib.3: raz tools/Doc.raz tools/Scan.raz lib/*.raz | build
	./raz -Werror -o build/Doc tools/Doc.raz
	build/Doc man $(LIBDOC:%=lib/%.raz) > $@

# the report as a PDF, by pandoc and Chromium; not part of check, as
# CI has neither
pdf: build/raz.pdf

build/raz.pdf: doc/raz.md doc/report.css | build
	pandoc doc/raz.md -s --toc --toc-depth=1 --shift-heading-level-by=-1 \
	    --syntax-highlighting=none -c ../doc/report.css \
	    -o build/raz.html
	chromium --headless --no-pdf-header-footer --print-to-pdf=$@ build/raz.html 2>/dev/null

# raz and its library go together under $(PREFIX)/lib/raz; the link
# on PATH works since raz finds lib/ beside its real path. The manual
# pages go where man looks, beside bin.
PREFIX = $(HOME)/.local
MAN = $(PREFIX)/share/man

install: raz build/raz-lib.3
	rm -rf $(PREFIX)/lib/raz
	mkdir -p $(PREFIX)/lib/raz $(PREFIX)/bin $(MAN)/man1 $(MAN)/man3 $(MAN)/man7
	cp -r raz lib $(PREFIX)/lib/raz
	ln -sf $(PREFIX)/lib/raz/raz $(PREFIX)/bin/raz
	cp doc/raz.1 $(MAN)/man1/raz.1
	cp build/raz-lib.3 $(MAN)/man3/raz-lib.3
	cp doc/raz.7 doc/raz-tutorial.7 $(MAN)/man7

uninstall:
	rm -rf $(PREFIX)/lib/raz $(PREFIX)/bin/raz $(MAN)/man1/raz.1 $(MAN)/man3/raz-lib.3 \
	    $(MAN)/man7/raz.7 $(MAN)/man7/raz-tutorial.7

# The website, plain files in site/public/: its home page, the tour
# "Raz, Set, Go" (whose programs are run here, so the output shown is
# real) and the report. site/build.py says how; it needs ./raz and pandoc.
site: raz
	python3 site/build.py

.PHONY: units tests check gdb bench kernels stress fmt loc man pdf site clean install uninstall
