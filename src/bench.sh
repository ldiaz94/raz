#!/bin/sh
# The compiler's speed against the previous release's, the one BOOT
# names (build/boot/raz), on the same generated program: the best of
# five runs of each, as build/cmp/raz, which finds the library beside
# it. A regression test: it fails if this compiler takes more than a
# tenth longer. Run from the repository root, after make raz.
set -e
mkdir -p build/cmp/bench
ln -sfn ../../lib build/cmp/lib
sh test/genbench.sh 12000 >build/cmp/bench/Bench.raz
echo "$(($(wc -l <build/cmp/bench/Bench.raz))) lines"
for t in prev this; do
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
    echo "slower than the previous release, $(cut -d" " -f1 BOOT), by more than a tenth"
    exit 1
fi
