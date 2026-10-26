#!/bin/sh
# Builds the compiler with another host, test/host/Host.raz in place of
# src/Host.raz (the staging doc/compiler.md describes), and checks what
# that host changes: the library it names, a refused raz run, no C, and
# a refused write.
# Usage: test/compiler-host.sh path/to/raz

raz=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
top=$(mktemp -d "${TMPDIR:-/tmp}/raz-host-XXXXXX") || exit 1
trap 'rm -rf "$top"' EXIT
pass=0
fail=0
unset RAZ_PATH RAZ_PROFILE RAZ_TEST_WRITE
NO_COLOR=1
export NO_COLOR

# check NAME COMMAND... passes if the command succeeds.
check() {
    name=$1
    shift
    if "$@"; then pass=$((pass + 1)); else echo "FAIL $name"; fail=$((fail + 1)); fi
}

# says FILE TEXT: FILE holds TEXT.
says() { grep -q -F -- "$2" "$1"; }

# lacks FILE TEXT: FILE doesn't hold TEXT.
lacks() { ! grep -q -F -- "$2" "$1"; }

# The staged sources and the compiler built from them.
mkdir "$top/src" "$top/work"
cp src/*.raz "$top/src"
cp test/host/Host.raz "$top/src/Host.raz"
"$raz" -Werror -I "$top/src" -I build/src -o "$top/compiler" "$top/src/Raz.raz" 2>"$top/build.err" || {
    cat "$top/build.err"
    echo "FAIL the compiler with the test host doesn't build"
    exit 1
}

# A library of its own, which only this host's libraryDir finds.
cp -r lib "$top/library"
echo "module HostValue; const value* = 42; end HostValue." >"$top/library/HostValue.raz"
RAZ_TEST_LIBRARY=$top/library
export RAZ_TEST_LIBRARY

cd "$top/work" || exit 1
cat >Main.raz <<'END'
module Main;
import Out, HostValue;
proc main*;
begin Out.int(HostValue.value); Out.ln; end;
end Main.
END
cat >UsesC.raz <<'END'
module UsesC;
import SYSTEM;
extern proc getpid: I32;
proc main*;
begin _ := getpid(); end;
end UsesC.
END

# the library comes from the host, and the file is written
"$top/compiler" -Werror -o program Main.raz 2>err
check "builds with the host's library" test "$(./program)" = 42

# raz run is refused, before the source is read
"$top/compiler" run missing.raz 2>err
check "run is refused" says err "this test host cannot run programs"
check "run is refused before the source is read" lacks err "can't open"

# no C
"$top/compiler" -o cprogram UsesC.raz 2>err
check "C is refused" says err "cannot make a program that uses C"
check "C leaves no file" test ! -e cprogram

# a write the host refuses
rm -f program
RAZ_TEST_WRITE=refuse "$top/compiler" -o program Main.raz 2>err
check "a refused write is an error" says err "can't write"
check "a refused write leaves no file" test ! -e program

echo "$pass passed, $fail failed"
[ $fail = 0 ]
