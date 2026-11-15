#!/bin/sh
# Makes test/a64/Encode.expect, what Encode.raz must print, from Apple's
# assembler: Asm.txt, A64's assembler's part, turned into Apple's syntax
# (raz's comments dropped, 10H as 0x10, `adr x0, v` as the adrp and add
# it stands for, a name as its symbol, _v, db and dd as .byte and .long,
# and ; between instructions as a new line, since ; begins a comment
# there), then Api.s, the instructions of Encode.raz's calls of A64.
# Each word of the object's code, a run of nop as one line, then its
# relocations, sorted, as Encode.raz prints its fixups.
# Run on an arm64 Mac, from the repository's root: sh test/a64/expect.sh
set -e
d=test/a64
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
{
    echo Lstart:
    sed -E -e '/^\(\*/,/\*\)/d' -e '/^end$/d' \
        -e 's/([0-9][0-9A-F]*)H/0x\1/g' \
        -e 's/adr (x[0-9]+), (glob|proc1)/adrp \1, _\2@PAGE; add \1, \1, _\2@PAGEOFF/g' \
        -e 's/(b|bl) proc1/\1 _proc1/g' \
        -e 's/(fcmp [ds][0-9]+, #0);/\1.0;/g' \
        -e 's/^db /.byte /; s/; dd /; .long /' $d/Asm.txt
    cat $d/Api.s
} | tr ';' '\n' > $t/all.s
cc -c -arch arm64 $t/all.s -o $t/all.o
objdump -d $t/all.o | awk '
    /^ *[0-9a-f]+:/ {
        if ($2 == "d503201f") { nops++; next }
        if (nops) { print "nop * " nops; nops = 0 }
        print $2
    }
    END { if (nops) print "nop * " nops }' > $d/Encode.expect
objdump -r $t/all.o | awk '/ARM64_RELOC/ { print "reloc", $1, $2, $3 }' | sort >> $d/Encode.expect
