#!/bin/sh
# Compiles and runs every example and test, and compares what each
# prints, and its exit status, with what is expected:
#   X.jed     the program
#   X.expect  its standard output
#   X.args    its arguments, one per line (optional)
#   X.status  its exit status (optional; 0 if missing)
# A program without X.expect is compiled, not run. test/libc puts
# lib/Sys.jed, over the C library, before the system call one.
# Programs in test/err must not compile, and must print X.err. Then
# the version, tools/Doc.jed, the report's examples, and the library's
# own tests.

jed=./jed
out=build/check
mkdir -p $out
pass=0
fail=0

run() {   # run dir name
    dir=$1; name=$2
    if ! $jed -I $dir/mods -o $out/$name $dir/$name.jed 2>$out/$name.cerr; then
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

for f in examples/*.jed test/run/*.jed test/libc/*.jed; do
    run $(dirname $f) $(basename $f .jed)
done
for f in test/err/*.jed; do
    name=$(basename $f .jed)
    if $jed -I test/err/mods -I test/run/mods -o $out/$name $f 2>$out/$name.cerr; then
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
want=$(sed -n 's/^This is version \([0-9.-]*\) of the report.*/\1/p' doc/jed.md)
if ./jed --version | grep -qF "report $want"; then pass=$((pass + 1))
else echo "FAIL jed --version: not report $want"; fail=$((fail + 1)); fi

# tools/Doc.jed: on every library module, and as test/doc expects
if ./jed -o $out/Doc tools/Doc.jed 2>$out/Doc.cerr; then
    for f in lib/*.jed; do
        if ! $out/Doc $f > $out/doc.out; then echo "FAIL Doc $f"; fail=$((fail + 1)); fi
    done
    for f in test/doc/*.expect; do
        name=$(basename $f .expect)
        m=lib/$name.jed
        [ -f $m ] || m=lib/$name.linux-x86_64.jed
        if $out/Doc $m | cmp -s - $f; then pass=$((pass + 1))
        else echo "FAIL Doc $m: output differs"; fail=$((fail + 1)); fi
    done

    # the report's examples that are whole modules: each compiles, and
    # each with a main runs and ends with status 0
    rm -rf $out/report; mkdir -p $out/report
    for name in $($out/Doc examples doc/jed.md $out/report); do
        if ! $jed -o $out/report/$name $out/report/$name.jed 2>$out/report/$name.cerr; then
            echo "FAIL report example $name: $(cat $out/report/$name.cerr)"; fail=$((fail + 1))
        elif grep -q '^proc main\*' $out/report/$name.jed && ! $out/report/$name > /dev/null 2>&1; then
            echo "FAIL report example $name: status $?"; fail=$((fail + 1))
        else pass=$((pass + 1)); fi
    done
else
    echo "FAIL tools/Doc.jed: $(cat $out/Doc.cerr)"; fail=$((fail + 1))
fi

# each library module's main is its test; Sys over C is tested in test/libc
for f in lib/*.jed; do
    [ $f = lib/Sys.jed ] && continue
    grep -q '^proc main\*' $f || continue
    name=lib_$(basename $f .jed)
    if ! $jed -o $out/$name $f 2>$out/$name.cerr; then
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
