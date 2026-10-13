#!/bin/sh
# The scanner's speed against the seed's, on the compiler's own
# benchmark program: the best of seven runs of each. Run from the
# repository root, after self/check.sh has built the tests.
set -e
b=build/self
python3 test/genbench.py 12000 >$b/Bench.raz
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fusrc -o$b/scanbench.seed self/test/ScanBench.pas >/dev/null
./raz -Werror -I self -o $b/scanbench.self self/test/ScanBench.raz
echo "$(wc -l <$b/Bench.raz) lines"
for t in seed self; do
    best=0
    for i in 1 2 3 4 5 6 7; do
        s=$(date +%s%N); $b/scanbench.$t $b/Bench.raz >/dev/null; e=$(date +%s%N)
        d=$(( (e - s) / 1000000 )); if [ $best = 0 ] || [ $d -lt $best ]; then best=$d; fi
    done
    echo "$t: $best ms"
done
