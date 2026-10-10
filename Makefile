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

# lines of the compiler: all of them, and those that aren't blank or comments
loc:
	@python3 test/loc.py src/*.pas

.PHONY: units tests check gdb bench loc clean
