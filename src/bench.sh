#!/bin/sh
# The scanner's speed against the seed's, on the compiler's own
# benchmark program: the best of seven runs of each. Run from the
# repository root, after make raz.
set -e
b=build/src
mkdir -p $b
python3 test/genbench.py 12000 >$b/Bench.raz
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/scanbench.seed src/test/ScanBench.pas >/dev/null
./raz -Werror -I src -o $b/scanbench.src src/test/ScanBench.raz
echo "$(wc -l <$b/Bench.raz) lines"
for t in seed src; do
    best=0
    for i in 1 2 3 4 5 6 7; do
        s=$(date +%s%N); $b/scanbench.$t $b/Bench.raz >/dev/null; e=$(date +%s%N)
        d=$(( (e - s) / 1000000 )); if [ $best = 0 ] || [ $d -lt $best ]; then best=$d; fi
    done
    echo "$t: $best ms"
done

# The whole compiler's speed, the seed's and this one's, on the same
# program: the best of five runs of each, as build/cmp/raz, which finds
# the library beside it.
mkdir -p build/cmp/bench
ln -sfn ../../lib build/cmp/lib
cp $b/Bench.raz build/cmp/bench/Bench.raz
for t in seed src; do
    if [ $t = seed ]; then cp build/seed/raz build/cmp/raz; else cp $b/raz.src build/cmp/raz; fi
    best=0
    for i in 1 2 3 4 5; do
        s=$(date +%s%N); build/cmp/raz -o build/cmp/bench/Bench.$t build/cmp/bench/Bench.raz; e=$(date +%s%N)
        d=$(( (e - s) / 1000000 )); if [ $best = 0 ] || [ $d -lt $best ]; then best=$d; fi
    done
    echo "compile, $t: $best ms"
done
