#!/bin/sh
# The conformance suite: programs whose behaviour the report defines,
# which every implementation of raz must give, whatever its target.
#
#   conform/check.sh COMPILER [MESSAGES]
#
# run from the directory above conform/. COMPILER is run as
#   COMPILER -I DIR -o EXE FILE
# to compile FILE, finding the modules it imports, besides the
# library's, in DIR, into the executable EXE; an implementation run
# otherwise is given a script that runs it so.
#
#   run/X.raz     a program; run/mods holds the modules it imports
#   run/X.expect  its standard output
#   run/X.args    its arguments, one per line (optional)
#   run/X.status  its exit status (optional; 0 if missing)
#   err/X.raz     a program the report says is an error, which must not
#                 compile; err/mods holds the modules it imports
#
# What a program says on standard error, the compiler's messages
# included, is the implementation's own (appendix A). One that keeps
# its text may give MESSAGES, a directory of X.stderr and X.err, the
# standard error of run/X and of compiling err/X, compared when there.
#
# Programs that use reals are among the rest, until a target may leave
# them out.

raz=$1
msg=${2:-/nonexistent}
out=build/conform
mkdir -p $out
pass=0
fail=0

for f in conform/run/*.raz; do
    name=$(basename $f .raz)
    if ! $raz -I conform/run/mods -o $out/$name $f 2>$out/$name.cerr; then
        echo "FAIL $f: doesn't compile: $(cat $out/$name.cerr)"
        fail=$((fail + 1)); continue
    fi
    set --
    if [ -f conform/run/$name.args ]; then
        while IFS= read -r a; do set -- "$@" "$a"; done < conform/run/$name.args
    fi
    # in $(...), so that what the shell says of a signal goes nowhere
    status=$( { ( exec $out/$name "$@" ) > $out/$name.out 2>$out/$name.err; echo $?; } 2>/dev/null )
    want=0
    [ -f conform/run/$name.status ] && want=$(cat conform/run/$name.status)
    if ! cmp -s $out/$name.out conform/run/$name.expect; then
        echo "FAIL $f: output differs"
        diff $out/$name.out conform/run/$name.expect | head -5
        fail=$((fail + 1))
    elif [ $status != $want ]; then
        echo "FAIL $f: status $status, not $want"
        fail=$((fail + 1))
    elif [ -f $msg/$name.stderr ] && ! cmp -s $out/$name.err $msg/$name.stderr; then
        echo "FAIL $f: standard error differs"
        diff $out/$name.err $msg/$name.stderr | head -5
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
done

for f in conform/err/*.raz; do
    name=$(basename $f .raz)
    if $raz -I conform/err/mods -o $out/$name $f 2>$out/$name.cerr; then
        echo "FAIL $f: compiles"
        fail=$((fail + 1))
    elif [ -f $msg/$name.err ] && ! cmp -s $msg/$name.err $out/$name.cerr; then
        echo "FAIL $f: says"; diff $msg/$name.err $out/$name.cerr
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
done

echo "$pass passed, $fail failed"
[ $fail = 0 ]
