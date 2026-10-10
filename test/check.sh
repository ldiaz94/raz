#!/bin/sh
# Compiles and runs every example and test, and compares what each
# prints, and its exit status, with what is expected:
#   X.raz     the program
#   X.expect  its standard output
#   X.args    its arguments, one per line (optional)
#   X.status  its exit status (optional; 0 if missing)
# A program without X.expect is compiled, not run. test/libc puts
# lib/Sys.raz, over the C library, before the system call one.
# Programs in test/err must not compile, and must print X.err. Then
# the version, tools/Doc.raz, the report's examples, tools/Pretty.raz,
# and the library's own tests.

raz=./raz
out=build/check
mkdir -p $out
pass=0
fail=0

run() {   # run dir name
    dir=$1; name=$2
    if ! $raz -I $dir/mods -o $out/$name $dir/$name.raz 2>$out/$name.cerr; then
        echo "FAIL $dir/$name: doesn't compile: $(cat $out/$name.cerr)"
        fail=$((fail + 1)); return
    fi
    if [ ! -f $dir/$name.expect ]; then pass=$((pass + 1)); return; fi
    set --
    if [ -f $dir/$name.args ]; then
        while IFS= read -r a; do set -- "$@" "$a"; done < $dir/$name.args
    fi
    $out/$name "$@" > $out/$name.out 2>/dev/null
    status=$?
    want=0
    [ -f $dir/$name.status ] && want=$(cat $dir/$name.status)
    if ! cmp -s $out/$name.out $dir/$name.expect; then
        echo "FAIL $dir/$name: output differs"
        diff $out/$name.out $dir/$name.expect | head -5
        fail=$((fail + 1))
    elif [ $status != $want ]; then
        echo "FAIL $dir/$name: status $status, not $want"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
}

for f in examples/*.raz test/run/*.raz test/libc/*.raz; do
    run $(dirname $f) $(basename $f .raz)
done

# raz run: a static program and one over C, from memory, with their
# arguments, output and status passed through
runs() {   # runs file status [arg]...
    f=$1; want=$2; shift 2
    $raz run -I $(dirname $f)/mods $f "$@" > $out/run.out 2>/dev/null
    status=$?
    if cmp -s $out/run.out ${f%.raz}.expect && [ $status = $want ]; then pass=$((pass + 1))
    else echo "FAIL raz run $f: status $status, not $want, or output differs"; fail=$((fail + 1)); fi
}
runs test/run/Args.raz 4 one 'two words' é
runs test/libc/Through.raz 2
for f in test/err/*.raz; do
    name=$(basename $f .raz)
    if $raz -I test/err/mods -I test/run/mods -o $out/$name $f 2>$out/$name.cerr; then
        echo "FAIL $f: compiles"
        fail=$((fail + 1))
    elif ! grep -qF "$(cat test/err/$name.err)" $out/$name.cerr; then
        echo "FAIL $f: says $(cat $out/$name.cerr)"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
done
# the report's version is the one the compiler says it follows
want=$(sed -n 's/^This is version \([0-9.-]*\) of the report.*/\1/p' doc/raz.md)
if ./raz --version | grep -qF "report $want"; then pass=$((pass + 1))
else echo "FAIL raz --version: not report $want"; fail=$((fail + 1)); fi

# tools/Doc.raz: on every library module, and as test/doc expects
if ./raz -o $out/Doc tools/Doc.raz 2>$out/Doc.cerr; then
    for f in lib/*.raz; do
        if ! $out/Doc $f > $out/doc.out; then echo "FAIL Doc $f"; fail=$((fail + 1)); fi
    done
    for f in test/doc/*.expect; do
        name=$(basename $f .expect)
        m=lib/$name.raz
        [ -f $m ] || m=lib/$name.linux-x86_64.raz
        if $out/Doc $m | cmp -s - $f; then pass=$((pass + 1))
        else echo "FAIL Doc $m: output differs"; fail=$((fail + 1)); fi
    done

    # the report's examples that are whole modules: each compiles, and
    # each with a main runs and ends with status 0
    rm -rf $out/report; mkdir -p $out/report
    for name in $($out/Doc examples doc/raz.md $out/report); do
        if ! $raz -o $out/report/$name $out/report/$name.raz 2>$out/report/$name.cerr; then
            echo "FAIL report example $name: $(cat $out/report/$name.cerr)"; fail=$((fail + 1))
        elif grep -q '^proc main\*' $out/report/$name.raz && ! $out/report/$name > /dev/null 2>&1; then
            echo "FAIL report example $name: status $?"; fail=$((fail + 1))
        else pass=$((pass + 1)); fi
    done
else
    echo "FAIL tools/Doc.raz: $(cat $out/Doc.cerr)"; fail=$((fail + 1))
fi

# tools/Pretty.raz: each test/pretty/X.raz comes out as X.expect, which
# comes out as it is; so do the library, the examples and the tools
if ./raz -o $out/Pretty tools/Pretty.raz 2>$out/Pretty.cerr; then
    for f in test/pretty/*.raz; do
        want=test/pretty/$(basename $f .raz).expect
        if $out/Pretty $f | cmp -s - $want && $out/Pretty $want | cmp -s - $want; then
            pass=$((pass + 1))
        else echo "FAIL Pretty $f: output differs"; fail=$((fail + 1)); fi
    done
    for f in lib/*.raz examples/*.raz tools/*.raz; do
        if ! $out/Pretty $f | cmp -s - $f; then
            echo "FAIL Pretty $f: not formatted"; fail=$((fail + 1))
        fi
    done
    pass=$((pass + 1))
else
    echo "FAIL tools/Pretty.raz: $(cat $out/Pretty.cerr)"; fail=$((fail + 1))
fi

# each library module's main is its test; Sys over C is tested in test/libc
for f in lib/*.raz; do
    [ $f = lib/Sys.raz ] && continue
    grep -q '^proc main\*' $f || continue
    name=lib_$(basename $f .raz)
    if ! $raz -o $out/$name $f 2>$out/$name.cerr; then
        echo "FAIL $f: doesn't compile: $(cat $out/$name.cerr)"; fail=$((fail + 1))
    elif ! $out/$name > $out/$name.out 2>&1; then
        echo "FAIL $f: its test says $(cat $out/$name.out)"; fail=$((fail + 1))
    else pass=$((pass + 1)); fi
done

# Thread's test again, with too little memory for all its threads:
# spawn must fail, with Thread.Failed
if (ulimit -v 60000; $out/lib_Thread.linux-x86_64 fail) > /dev/null 2>&1; then pass=$((pass + 1))
else echo "FAIL Thread under a memory limit"; fail=$((fail + 1)); fi

# the editors' support, headless, where the editors are installed
if test/editors.sh; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

echo "$pass passed, $fail failed"
[ $fail = 0 ]
