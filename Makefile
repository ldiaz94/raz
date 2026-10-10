# Builds the compiler, jed, from src/ into the repository's root; the
# library it needs is lib/, beside it.

FPC = fpc
FPCFLAGS = -O2 -Mobjfpc -Sh- -vew -FUbuild

jed: src/*.pas | build
	$(FPC) $(FPCFLAGS) -ojed src/jed.pas

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

.PHONY: units tests clean
