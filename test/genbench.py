"""Writes a large raz program to standard output, for timing the
compiler: n procedures of loops, conditions, records, slices and calls,
each calling the one before, so that none is left out."""
import sys

n = int(sys.argv[1])
print("""module Bench;
import Out;

type
    Pair = record x, y: I64; end;
    Shape = variant circle(r: I64); rect(w, h: I64); dot; end;

var
    g: [16]I64;
    data: [64]I64;
""")
print("""proc p0(a, b: I64; s: []I64): I64;
begin
    return a + b;
end;
""")
for i in range(1, n + 1):
    print(f"""(* procedure {i} *)
proc p{i}(a, b: I64; s: []I64): I64;
var i, t: I64; r: Pair; sh: Shape;
begin
    t := 0;
    for i := 0 to LEN(s) - 1 do
        if s[i] > a then
            t := t + s[i] * b;
        elsif s[i] = b then
            t := t - 1;
        else
            t := t xor i;
        end;
    end;
    r.x := t;
    r.y := a + b * {i};
    while r.x > 100 do
        r.x := r.x div 2;
    end;
    sh := rect(r.x, r.y);
    match sh of
    | circle(c): t := t + c;
    | rect(w, h): t := t + w * h;
    | dot: t := t - 1;
    end;
    g[a and 15] := r.x + r.y;
    return p{i - 1}(t and 1023, b, s[0..LEN(s) div 2]) + r.x;
end;
""")
print(f"""proc main*;
var i: I64;
begin
    for i := 0 to 63 do data[i] := i; end;
    Out.int(p{n}(1, 2, data[0..4]));
    Out.ln;
end;

end Bench.""")
