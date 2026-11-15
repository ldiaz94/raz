#!/bin/sh
# Line numbers for lldb, as gdb.sh's for gdb, on a Mac: stops a test
# program at a line of its source, by file and line, and checks that
# lldb names it, and the line of each caller. The program is conform's
# Procs, which test/mac.sh build made for darwin-arm64 in build/mac.
prog=build/mac/conform/Procs
out=build/mac
if [ ! -x $prog ]; then echo "FAIL lldb: no $prog; make mac-build first"; exit 1; fi
lldb --batch -o 'b Procs.raz:13' -o run -o bt $prog > $out/lldb.out 2>&1
for want in 'Procs.odd at Procs.raz:13' \
            'Procs.even at Procs.raz:20' \
            'Procs.main at Procs.raz:'; do
    if ! grep -qF "$want" $out/lldb.out; then
        echo "FAIL lldb: no \"$want\""; cat $out/lldb.out; exit 1
    fi
done
echo "lldb finds the lines"
