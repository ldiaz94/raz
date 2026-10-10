#!/bin/sh
# Line numbers for gdb: stops a test program at a line of its source,
# by file and line, and checks that gdb names it, and the line of each
# caller.
out=build/check
mkdir -p $out
./raz -I test/run/mods -o $out/Procs test/run/Procs.raz || exit 1
gdb -batch -ex 'break test/run/Procs.raz:13' -ex run -ex bt $out/Procs > $out/gdb.out 2>&1
for want in 'Breakpoint 1, Procs.odd () at test/run/Procs.raz:13' \
            'in Procs.even () at test/run/Procs.raz:20' \
            'in Procs.main () at test/run/Procs.raz:'; do
    if ! grep -qF "$want" $out/gdb.out; then
        echo "FAIL gdb: no \"$want\""; cat $out/gdb.out; exit 1
    fi
done
echo "gdb finds the lines"
