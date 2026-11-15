#!/bin/sh
# The Mac's tests, make mac-check on an Apple Silicon Mac (PLAN.md 5):
# test/mac/X.raz compiled for darwin-arm64 by the cross compiler, which
# src/cross.sh builds in the linux/amd64 container, into build/mac/X;
# then each run here, natively, and what it prints and its status
# compared, as test/check.sh compares a test's:
#   X.expect  its standard output (optional; empty if missing)
#   X.status  its exit status (optional; 0 if missing)
# Then conform/run's programs the same way, into build/mac/conform,
# with their arguments (X.args): until the port is whole some fail,
# which are counted and listed in build/mac/conform.fail, not failures
# of the run. A few of conform/run are not for this target, each named
# in notHere with the reason, and skipped.
#
#     test/mac.sh build    in the container: the cross compiler, then the programs
#     test/mac.sh run      on the Mac: each program, run with a timeout
#
# A test with a C file, test/mac/X.c, links the library that file makes:
# run builds it by cc into build/mac/libX.dylib, where the program finds
# it by @executable_path (Exe.darwin's libPath), and, built as a program
# with -DMAIN, it must print what X.expect holds, as C itself says it.
# Then lldb, if there is one, must find a line (test/lldb.sh).
#
# build/mac is made anew each time: macOS keeps a file's code signature
# while the file is open or cached, and kills a program whose file was
# written again in place with another one.
set -e
out=build/mac
# conform/run's programs that are not for darwin-arm64, and why
notHere='SystemImport: SYSTEM.SYSCALL is Linux'"'"'s only (report 6.8)'
case $1 in
build)
    src/cross.sh darwin-arm64
    rm -rf $out
    mkdir -p $out
    for f in test/mac/*.raz; do
        name=$(basename $f .raz)
        build/cross/darwin-arm64/raz -o $out/$name $f 2>$out/$name.cerr || true
    done
    mkdir -p $out/conform
    for f in conform/run/*.raz; do
        name=$(basename $f .raz)
        build/cross/darwin-arm64/raz -I conform/run/mods -o $out/conform/$name $f \
            2>$out/conform/$name.cerr || true
    done
    ;;
run)
    pass=0
    fail=0
    for f in test/mac/*.c; do
        name=$(basename $f .c)
        cc -dynamiclib -o $out/lib$name.dylib $f
        cc -DMAIN -o $out/$name.cmain $f
        if ! $out/$name.cmain | cmp -s - test/mac/$name.expect; then
            echo "FAIL $f: C's own output differs from $name.expect"; fail=$((fail + 1))
        fi
    done
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
    # conform/run, counted: why each fails goes to conform.fail
    c=$out/conform
    cpass=0
    cfail=0
    cskip=0
    : > $c.fail
    for f in conform/run/*.raz; do
        name=$(basename $f .raz)
        if echo "$notHere" | grep -q "^$name:"; then cskip=$((cskip + 1)); continue; fi
        want=0
        [ -f conform/run/$name.status ] && want=$(cat conform/run/$name.status)
        if [ ! -x $c/$name ]; then
            echo "$name: doesn't compile: $(grep -m1 error $c/$name.cerr)" >> $c.fail
            cfail=$((cfail + 1)); continue
        fi
        set --
        if [ -f conform/run/$name.args ]; then
            while IFS= read -r a; do set -- "$@" "$a"; done < conform/run/$name.args
        fi
        status=0
        perl -e 'alarm 10; exec @ARGV' ./$c/$name "$@" > $c/$name.out 2>$c/$name.err || status=$?
        if [ $status != $want ]; then
            echo "$name: status $status, not $want: $(head -1 $c/$name.err)" >> $c.fail
            cfail=$((cfail + 1))
        elif ! cmp -s $c/$name.out conform/run/$name.expect; then
            echo "$name: output differs" >> $c.fail
            cfail=$((cfail + 1))
        else
            cpass=$((cpass + 1))
        fi
    done
    echo "conform/run: $cpass of $((cpass + cfail)) passed, $cskip not for this target; the others in $c.fail"
    if command -v lldb > /dev/null; then test/lldb.sh || fail=$((fail + 1)); fi
    [ $fail = 0 ]
    ;;
*)
    echo "usage: test/mac.sh build|run" >&2
    exit 2
    ;;
esac
