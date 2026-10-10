# Builds the compiler, jed, from src/ into the repository's root; the
# library it needs is lib/, beside it.

FPC = fpc
FPCFLAGS = -O2 -Mobjfpc -Sh- -vew -FUbuild

jed: src/*.pas | build
	$(FPC) $(FPCFLAGS) -ojed src/jed.pas

units: src/*.pas | build
	$(FPC) $(FPCFLAGS) src/scan.pas
	$(FPC) $(FPCFLAGS) src/sym.pas

build:
	mkdir -p build

clean:
	rm -rf build jed

.PHONY: units clean
