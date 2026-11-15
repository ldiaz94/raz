#!/bin/sh
# The compiler's speed against the previous release's, the one BOOT
# names (build/boot/raz), on the same generated program: the best of
# five runs of each, as build/cmp/raz, which finds the library beside
# it. A regression test: it fails if this compiler takes more than a
# tenth longer. Run from the repository root, after make raz.
#
# On a Mac while BOOT names no Mac release, build/boot/raz is the
# bootstrap's compiler (src/bootstrap.sh), made from src/ through the
# container, and that is what this one is compared with, as it says.
# A file is removed before another is copied to its name: macOS kills a
# program whose signed file was written over in place.
set -e
tag=$(sed -n 1p BOOT)
prev="the previous release, $tag"
if [ "$(uname -s)" = Darwin ] && [ -d build/boot/bootstrap-${tag#v} ]; then
    prev="the bootstrap's compiler, build/boot/raz ($tag has no darwin-arm64 tarball)"
    echo "prev is $prev"
fi
mkdir -p build/cmp/bench
ln -sfn ../../lib build/cmp/lib
sh test/genbench.sh 12000 >build/cmp/bench/Bench.raz
echo "$(($(wc -l <build/cmp/bench/Bench.raz))) lines"
for t in prev this; do
    rm -f build/cmp/raz
    if [ $t = prev ]; then cp build/boot/raz build/cmp/raz; else cp raz build/cmp/raz; fi
    best=0
    for i in 1 2 3 4 5; do
        s=$(sh test/nanos.sh); build/cmp/raz -o build/cmp/bench/Bench.$t build/cmp/bench/Bench.raz; e=$(sh test/nanos.sh)
        d=$(( (e - s) / 1000000 )); if [ $best = 0 ] || [ $d -lt $best ]; then best=$d; fi
    done
    echo "$t: $best ms"
    eval "ms_$t=$best"
done
if [ $((ms_this * 10)) -gt $((ms_prev * 11)) ]; then
    echo "slower than $prev, by more than a tenth"
    exit 1
fi
