#!/bin/sh
# The kernels: each raz program here, which says check off, against its
# twin in Pascal, built by FPC -O2; each run five times, the fastest
# kept. Run from the directory above test/:
#   test/bench/run.sh [compiler]
raz=${1:-./raz}
out=build/bench
mkdir -p $out

best() {   # best program: the fewest milliseconds of five runs
    b=0
    for i in 1 2 3 4 5; do
        s=$(date +%s%N); $1 > /dev/null; e=$(date +%s%N)
        t=$(( (e - s) / 1000000 ))
        if [ $b = 0 ] || [ $t -lt $b ]; then b=$t; fi
    done
    echo $b
}

for f in test/bench/*.raz; do
    n=$(basename $f .raz)
    $raz -o $out/$n $f || exit 1
    fpc -O2 -v0 -FE$out -o$out/$n.fpc test/bench/$(echo $n | tr A-Z a-z).pas > /dev/null || exit 1
    if [ "$($out/$n)" != "$($out/$n.fpc)" ]; then echo "$n: the two print differently"; exit 1; fi
    r=$(best $out/$n); p=$(best $out/$n.fpc)
    echo "$n $r $p" | awk '{ printf "%-10s raz %5d ms   fpc -O2 %5d ms   %.2f times\n", $1, $2, $3, $2 / $3 }'
done
