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

# the compiler's speed, on a generated program of about 350,000 lines;
# fails below 400,000 lines a second
bench: jed | build
	python3 test/genbench.py 12000 > build/Bench.jed
	@lines=$$(wc -l < build/Bench.jed); \
	start=$$(date +%s%N); ./jed build/Bench.jed || exit 1; end=$$(date +%s%N); \
	rate=$$((lines * 1000000000 / (end - start))); \
	echo "$$lines lines in $$(((end - start) / 1000000)) ms: $$rate lines a second"; \
	test $$rate -ge 400000

# lines of the compiler: all of them, and those that aren't blank or comments
loc:
	@python3 test/loc.py src/*.pas

.PHONY: units tests check bench loc clean
