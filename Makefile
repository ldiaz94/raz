# Builds the compiler, jed, from src/ into the repository's root; the
# library it needs is lib/, beside it.

FPC = fpc
FPCFLAGS = -O2 -Mobjfpc -Sh- -vew -FUbuild

jed: src/*.pas | build
	$(FPC) $(FPCFLAGS) -FE. -ojed src/jed.pas

units: src/*.pas | build
	for u in scan sym x64 link elf; do $(FPC) $(FPCFLAGS) src/$$u.pas || exit 1; done

# tests of the parts below the parser, built from test/
tests: units
	$(FPC) $(FPCFLAGS) -Fusrc -obuild/scantest test/scantest.pas
	$(FPC) $(FPCFLAGS) -Fusrc -obuild/enctest test/enctest.pas
	$(FPC) $(FPCFLAGS) -Fusrc -obuild/handtest test/handtest.pas
	build/handtest build/hand && build/hand; test $$? = 42

build:
	mkdir -p build

clean:
	rm -rf build jed

# every example and test, against what it should print
check: jed
	test/check.sh

# line numbers: gdb stops at a line and names it
gdb: jed
	test/gdb.sh

# the compiler's speed, on a generated program of about 350,000 lines,
# the best of three runs; fails below 400,000 lines a second
bench: jed | build
	python3 test/genbench.py 12000 > build/Bench.jed
	@lines=$$(wc -l < build/Bench.jed); best=0; \
	for i in 1 2 3; do \
	    start=$$(date +%s%N); ./jed build/Bench.jed || exit 1; end=$$(date +%s%N); \
	    t=$$((end - start)); if [ $$best = 0 ] || [ $$t -lt $$best ]; then best=$$t; fi; \
	done; \
	rate=$$((lines * 1000000000 / best)); \
	echo "$$lines lines in $$((best / 1000000)) ms: $$rate lines a second"; \
	test $$rate -ge 400000

# native threads under load: 40,000 spawned and joined, 200 alive at a
# time, all waiting on one Mutex; then, with little memory, spawn must
# fail with Thread.Failed. make check runs a small version.
stress: jed | build
	./jed -o build/Stress lib/Thread.linux-x86_64.jed
	build/Stress 40000 200
	(ulimit -v 60000; build/Stress fail)

# the formatter, tools/Pretty.jed: the library, examples and tools are
# formatted already
fmt: jed | build
	./jed -o build/Pretty tools/Pretty.jed
	@fail=0; for f in lib/*.jed examples/*.jed tools/*.jed; do \
	    build/Pretty $$f | cmp -s - $$f || { echo "not formatted: $$f"; fail=1; }; \
	done; test $$fail = 0

# lines of the compiler: all of them, and those that aren't blank or comments
loc:
	@python3 test/loc.py src/*.pas

.PHONY: units tests check gdb bench stress fmt loc clean
