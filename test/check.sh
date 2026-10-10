#!/bin/sh
# Compiles and runs every example and test, and compares what each
# prints, and its exit status, with what is expected:
#   X.jed     the program
#   X.expect  its standard output
#   X.args    its arguments, one per line (optional)
#   X.status  its exit status (optional; 0 if missing)
# Programs in test/err must not compile, and must print X.err.

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

for f in examples/*.jed test/run/*.jed; do
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
echo "$pass passed, $fail failed"
[ $fail = 0 ]
