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
	for u in diag scan sym x64 link elf; do $(FPC) $(FPCFLAGS) src/$$u.pas || exit 1; done

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
check: raz
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

# native threads under load: 40,000 spawned and joined, 200 alive at a
# time, all waiting on one Mutex; then, with little memory, spawn must
# fail with Thread.Failed. make check runs a small version.
stress: raz | build
	./raz -o build/Stress lib/Thread.linux-x86_64.raz
	build/Stress 40000 200
	(ulimit -v 60000; build/Stress fail)

# the formatter, tools/Pretty.raz: the library, examples, tools and
# ravite are formatted already
fmt: raz | build
	./raz -o build/Pretty tools/Pretty.raz
	@fail=0; for f in lib/*.raz examples/*.raz tools/*.raz ravite/*.raz; do \
	    build/Pretty $$f | cmp -s - $$f || { echo "not formatted: $$f"; fail=1; }; \
	done; test $$fail = 0

# lines of the compiler: all of them, and those that aren't blank or comments
loc:
	@python3 test/loc.py src/*.pas

# raz and its library go together under $(PREFIX)/lib/raz; the link
# on PATH works since raz finds lib/ beside its real path.
PREFIX = $(HOME)/.local

install: raz
	rm -rf $(PREFIX)/lib/raz
	mkdir -p $(PREFIX)/lib/raz $(PREFIX)/bin
	cp -r raz lib $(PREFIX)/lib/raz
	ln -sf $(PREFIX)/lib/raz/raz $(PREFIX)/bin/raz

uninstall:
	rm -rf $(PREFIX)/lib/raz $(PREFIX)/bin/raz

.PHONY: units tests check gdb bench stress fmt loc clean install uninstall
