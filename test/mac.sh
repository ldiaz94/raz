#!/bin/sh
# The Mac's tests, make mac-check on an Apple Silicon Mac (PLAN.md 5):
# test/mac/X.raz compiled for darwin-arm64 by the cross compiler, which
# src/cross.sh builds in the linux/amd64 container, into build/mac/X;
# then each run here, natively, and what it prints and its status
# compared, as test/check.sh compares a test's:
#   X.expect  its standard output (optional; empty if missing)
#   X.status  its exit status (optional; 0 if missing)
#
#     test/mac.sh build    in the container: the cross compiler, then the programs
#     test/mac.sh run      on the Mac: each program, run with a timeout
#
# build/mac is made anew each time: macOS keeps a file's code signature
# while the file is open or cached, and kills a program whose file was
# written again in place with another one.
set -e
out=build/mac
case $1 in
build)
    src/cross.sh darwin-arm64
    rm -rf $out
    mkdir -p $out
    for f in test/mac/*.raz; do
        name=$(basename $f .raz)
        build/cross/darwin-arm64/raz -o $out/$name $f 2>$out/$name.cerr || true
    done
    ;;
run)
    pass=0
    fail=0
    for f in test/mac/*.raz; do
        name=$(basename $f .raz)
        want=0
        [ -f test/mac/$name.status ] && want=$(cat test/mac/$name.status)
        if [ ! -x $out/$name ]; then
            echo "FAIL $f: doesn't compile: $(cat $out/$name.cerr 2>/dev/null)"; fail=$((fail + 1)); continue
        fi
        # perl's alarm, as macOS has no timeout
        status=0
        perl -e 'alarm 10; exec @ARGV' ./$out/$name > $out/$name.out 2>$out/$name.err || status=$?
        if [ -f test/mac/$name.expect ]; then exp=test/mac/$name.expect; else exp=/dev/null; fi
        if [ $status != $want ]; then
            echo "FAIL $f: status $status, not $want"; fail=$((fail + 1))
        elif ! cmp -s $out/$name.out $exp; then
            echo "FAIL $f: output differs"; fail=$((fail + 1))
        else
            pass=$((pass + 1))
        fi
    done
    echo "$pass passed, $fail failed"
    [ $fail = 0 ]
    ;;
*)
    echo "usage: test/mac.sh build|run" >&2
    exit 2
    ;;
esac
