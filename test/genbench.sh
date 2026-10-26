#!/bin/sh
# Writes a large raz program to standard output, for timing the
# compiler: n procedures of loops, conditions, records, slices and
# calls, each calling the one before, so that none is left out.
#     sh test/genbench.sh n > build/Bench.raz
n=$1
cat <<'END'
module Bench;
import Out;

type
    Pair = record x, y: INT; end;
    Shape = variant circle(r: INT); rect(w, h: INT); dot; end;

var
    g: [16]INT;
    data: [64]INT;

proc p0(a, b: INT; _s: []INT): INT;
begin
    return a + b;
end;

END
# awk, not a loop of the shell, so that 12,000 procedures take a moment
awk -v n="$n" 'BEGIN {
    for (i = 1; i <= n; i++) {
        printf "(* procedure %d *)\n", i
        printf "proc p%d(a, b: INT; s: []INT): INT;\n", i
        print "var i, t: INT; r: Pair; sh: Shape;"
        print "begin"
        print "    t := 0;"
        print "    for i := 0 to LEN(s) - 1 do"
        print "        if s[i] > a then"
        print "            t := t + s[i] * b;"
        print "        elsif s[i] = b then"
        print "            t := t - 1;"
        print "        else"
        print "            t := t xor i;"
        print "        end;"
        print "    end;"
        print "    r.x := t;"
        printf "    r.y := a + b * %d;\n", i
        print "    while r.x > 100 do"
        print "        r.x := r.x div 2;"
        print "    end;"
        print "    sh := rect(r.x, r.y);"
        print "    match sh of"
        print "    | circle(c): t := t + c;"
        print "    | rect(w, h): t := t + w * h;"
        print "    | dot: t := t - 1;"
        print "    end;"
        print "    g[a & 15] := r.x + r.y;"
        printf "    return p%d(t & 1023, b, s[0..LEN(s) div 2]) + r.x;\n", i - 1
        print "end;"
        print ""
    }
}'
cat <<END
proc main*;
var i: INT;
begin
    for i := 0 to 63 do data[i] := i; end;
    Out.int(p$n(1, 2, data[0..4]));
    Out.ln;
end;

end Bench.
END
