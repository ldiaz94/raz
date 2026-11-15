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
# Then the library: each module's own main, its test, as the target
# takes its file (Name.darwin-arm64.raz, Name.darwin.raz, Name.arm64.raz
# or Name.raz), built with -Werror into build/mac/lib and run there,
# passing if it ends with status 0, as raztest has it; and test/libc's
# programs, over Sys, the C one, into build/mac/libc, compared as
# test/check.sh compares them (X.expect, X.status, and X.stderr with
# each address 0x?). These count as test/mac's do, but those named in
# libNotHere, with the reason, which are skipped.
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
# the library's tests and test/libc's programs that are not for it, and why
libNotHere='test/libc/ExecveC: reads what signals sh ignores and catches in /proc/self/status, which is Linux'"'"'s'

# The file of module $1 the target takes, as the compiler looks for it
libFile() {
    for f in lib/$1.darwin-arm64.raz lib/$1.darwin.raz lib/$1.arm64.raz lib/$1.raz; do
        [ -f $f ] && { echo $f; return; }
    done
}

# The library's modules that have a test, by the files the target takes
libTests() {
    for m in $(ls lib/*.raz | sed 's|lib/||; s|\..*||' | sort -u); do
        f=$(libFile $m)
        [ -n "$f" ] && grep -q '^proc main\*' $f && echo $f
    done
}

# Runs $out/$1/$2 with a timeout, in its directory, from the arguments
# on: its status, its output in $2.out and $2.err
runIn() {
    dir=$1; prog=$2; shift 2
    (cd $out/$dir && perl -e 'alarm 60; exec @ARGV' ./$prog "$@" > $prog.out 2>$prog.err) || return $?
}
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
    mkdir -p $out/lib $out/libc
    for f in $(libTests); do
        name=$(basename $f .raz); name=${name%%.*}
        build/cross/darwin-arm64/raz -Werror -o $out/lib/$name $f 2>$out/lib/$name.cerr || true
    done
    for f in test/libc/*.raz; do
        name=$(basename $f .raz)
        build/cross/darwin-arm64/raz -Werror -I test/libc/mods -o $out/libc/$name $f \
            2>$out/libc/$name.cerr || true
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
    # the library's tests, and test/libc's programs
    lpass=0
    lfail=0
    lskip=0
    for f in $(libTests); do
        name=$(basename $f .raz); name=${name%%.*}
        if echo "$libNotHere" | grep -q "^lib/$name:"; then lskip=$((lskip + 1)); continue; fi
        if [ ! -x $out/lib/$name ]; then
            echo "FAIL $f: doesn't compile: $(head -3 $out/lib/$name.cerr)"; lfail=$((lfail + 1)); continue
        fi
        status=0
        runIn lib $name || status=$?
        if [ $status != 0 ]; then
            echo "FAIL $f: status $status"; tail -5 $out/lib/$name.err; lfail=$((lfail + 1))
        else
            lpass=$((lpass + 1))
        fi
    done
    for f in test/libc/*.raz; do
        name=$(basename $f .raz)
        if echo "$libNotHere" | grep -q "^test/libc/$name:"; then lskip=$((lskip + 1)); continue; fi
        if [ ! -x $out/libc/$name ]; then
            echo "FAIL $f: doesn't compile: $(head -3 $out/libc/$name.cerr)"; lfail=$((lfail + 1)); continue
        fi
        want=0
        [ -f test/libc/$name.status ] && want=$(cat test/libc/$name.status)
        # from the repository's root, as a message names the file so
        status=0
        perl -e 'alarm 60; exec @ARGV' ./$out/libc/$name > $out/libc/$name.out 2>$out/libc/$name.err || status=$?
        if [ -f test/libc/$name.expect ]; then exp=test/libc/$name.expect; else exp=/dev/null; fi
        if [ $status != $want ]; then
            echo "FAIL $f: status $status, not $want"; head -3 $out/libc/$name.err; lfail=$((lfail + 1))
        elif ! cmp -s $out/libc/$name.out $exp; then
            echo "FAIL $f: output differs"; diff $out/libc/$name.out $exp | head -5; lfail=$((lfail + 1))
        elif [ -f test/libc/$name.stderr ] && ! sed 's/0x[0-9a-f]*/0x?/g' $out/libc/$name.err |
                cmp -s - test/libc/$name.stderr; then
            echo "FAIL $f: standard error differs"; diff $out/libc/$name.err test/libc/$name.stderr | head -5
            lfail=$((lfail + 1))
        else
            lpass=$((lpass + 1))
        fi
    done
    echo "the library and test/libc: $lpass passed, $lfail failed, $lskip not for this target"
    if command -v lldb > /dev/null; then test/lldb.sh || fail=$((fail + 1)); fi
    [ $fail = 0 ] && [ $lfail = 0 ]
    ;;
*)
    echo "usage: test/mac.sh build|run" >&2
    exit 2
    ;;
esac
