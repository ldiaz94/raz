#!/bin/sh
# Runs test/libc on Alpine, whose C library is musl, in a docker
# container: raz, a static program, compiles each program there, so it
# links it against musl by default, having only musl's loader; then
# each runs, its output and status compared as test/check.sh compares
# them. Needs docker, and the network the first time, for the image.

image=${ALPINE:-alpine:3.20}
exec docker run --rm -v "$PWD":/raz:ro -w /raz "$image" sh -c '
pass=0; fail=0; out=/tmp/out; mkdir -p $out
for f in test/libc/*.raz; do
    name=$(basename $f .raz)
    if ! ./raz -Werror -I test/libc/mods -o $out/$name $f 2>$out/$name.cerr; then
        echo "FAIL $f: does not compile: $(cat $out/$name.cerr)"; fail=$((fail + 1)); continue
    fi
    if ! grep -q ld-musl $out/$name; then   # the loader it names
        echo "FAIL $f: not linked against musl"; fail=$((fail + 1)); continue
    fi
    [ -f test/libc/$name.expect ] || { pass=$((pass + 1)); continue; }
    status=$( { ( cd /tmp && exec $out/$name ) > $out/$name.out 2>$out/$name.err; echo $?; } 2>/dev/null )
    want=0; [ -f test/libc/$name.status ] && want=$(cat test/libc/$name.status)
    if ! cmp -s $out/$name.out test/libc/$name.expect; then
        echo "FAIL $f: output differs"; diff $out/$name.out test/libc/$name.expect | head -5; fail=$((fail + 1))
    elif [ $status != $want ]; then
        echo "FAIL $f: status $status, not $want"; cat $out/$name.err | head -5; fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
done
cat /etc/alpine-release | sed "s/^/Alpine /"
echo "$pass passed, $fail failed"
[ $fail = 0 ]'
