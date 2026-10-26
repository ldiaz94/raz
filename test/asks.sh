#!/bin/sh
# What the compiler asks of the library: every qualified name of lib/,
# Sys.write, Rt.exit and so on, that src/ uses in code (not in a comment,
# a string or a character) must be a row of the tables under "What the
# compiler asks of Sys, Rt and Files" in doc/compiler.md, and every row
# must be used. Prints the differences and exits 1 if there are any.
# Run from the repository's root.

doc=doc/compiler.md
tmp=${TMPDIR:-/tmp}/asks.$$
trap 'rm -f $tmp.*' EXIT

# src/*.raz with comments, strings and characters cut out, so that what
# is left is code. Comments (* ... *) don't nest and may span lines, and
# so may a `...` string; "..." and '...' end at the line's end at most.
code() {
    awk '
    BEGIN { state = "code" }
    {
        n = length($0); out = ""; i = 1
        while (i <= n) {
            c = substr($0, i, 1); d = substr($0, i, 2)
            if (state == "comment") {
                if (d == "*)") { state = "code"; i += 2 } else i++
            } else if (state == "raw") {
                if (c == "`") state = "code"
                i++
            } else if (state == "dq" || state == "sq") {
                if (c == "\\") i += 2
                else {
                    if ((state == "dq" && c == "\"") || (state == "sq" && c == "\047")) state = "code"
                    i++
                }
            } else if (d == "(*") { state = "comment"; i += 2 }
            else if (c == "`") { state = "raw"; i++ }
            else if (c == "\"") { state = "dq"; i++ }
            else if (c == "\047") { state = "sq"; i++ }
            else { out = out c; i++ }
        }
        if (state == "dq" || state == "sq") state = "code"
        print out
    }' src/*.raz
}

# the modules of lib/, as the names a program imports them by
libs=$(ls lib | sed 's/\..*//' | sort -u | tr '\n' '|' | sed 's/|$//')

code | grep -oE "\b($libs)\.[A-Za-z_][A-Za-z0-9_]*" | sort -u > $tmp.used
# the names in the first cell of a row of a table in the section:
# "| `Sys.close`, `Sys.Dir` | what for |"
sed -n '/^## What the compiler asks of Sys, Rt and Files/,/^## [^W]/p' $doc |
    sed -n 's/^| `\([^|]*\)|.*/`\1/p' |
    grep -oE '`[A-Za-z]+\.[A-Za-z_][A-Za-z0-9_]*`' | tr -d '`' | sort -u > $tmp.listed

status=0
if [ ! -s $tmp.listed ]; then echo "asks: $doc has no rows for the library names"; status=1; fi
if comm -23 $tmp.used $tmp.listed | sed "s|^|src/ uses it, $doc doesn't say: |" | grep .; then status=1; fi
if comm -13 $tmp.used $tmp.listed | sed "s|^|$doc lists it, src/ never uses it: |" | grep .; then status=1; fi
exit $status
