#!/bin/sh
# Tests src/'s units against the seed's: each dumper reads the same
# files and must give the same standard output, standard error and
# status. Run from the repository root, after `make raz`; the seed's
# side is built by fpc from seed/.
set -e
b=build/src
# The seed predates raw strings and match on a string (report
# 2026-10.25): the files that use them are the compiler's alone, and
# so are those whose message says what match takes. It predates, too,
# an INT widened in an expression and the rest (report 2026-10.26),
# the messages for an I64 that goes to an INT, and a help that
# converts the narrower of two integers; and views, v.(T),
# whose tests are conform/*/View*.raz, and which Math, examples/Elf.raz
# and, through Math, test/bench/NBody.raz use; and returning a slice of
# the frame as an error (report 2026-10.27); an array constant typed
# []T (report 2026-10.29); [] as the empty slice, seen through a view
# (report 2026-10.30); and U8, I8 and I16 widening to INT, and
# continue (report 2026-10.31).
newer="conform/run/RawStrings.raz conform/err/ScanRawOpen.raz conform/err/ScanRawIndent.raz
    conform/run/MatchStr.raz conform/err/MatchStrTwice.raz conform/err/MatchStrNoElse.raz
    conform/err/MatchStrVar.raz conform/err/MatchReal.raz conform/err/AtMatch.raz
    examples/Sh.raz examples/Settings.raz
    conform/run/IntWiden.raz conform/err/IntIncNarrow.raz conform/err/IntNarrow.raz conform/err/IntNarrowSum.raz
    conform/err/IntResultsNarrow.raz conform/err/GenIntTypes.raz
    lib/Math.raz examples/Elf.raz test/bench/NBody.raz
    conform/err/FrameSlice.raz
    conform/run/ArrayConstLen.raz conform/err/ArrayConstLenEmpty.raz conform/err/ArrayConstLenLiteral.raz
    conform/run/EmptySlice.raz
    conform/run/SmallWiden.raz conform/err/SmallWidenMade.raz conform/err/SmallWidenNeg.raz
    conform/err/SmallWidenI64.raz conform/err/SmallWidenMadeOp.raz
    conform/run/Continue.raz conform/err/ContinueOutside.raz conform/err/ContinueDefer.raz
    conform/err/ContinueName.raz"
newer() {
    case $1 in conform/*/View*.raz) return 0 ;; esac
    for g in $newer; do [ $g = $1 ] && return 0; done
    return 1
}
mkdir -p $b
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/scandump.seed src/test/ScanDump.pas >/dev/null
./raz -Werror -I src -o $b/scandump.src src/test/ScanDump.raz
python3 src/test/genreals.py > $b/reals.raz
# one small file for each message the scanner makes, and the places
# diag shows them in: a tab, a long line, characters before the place
mkdir -p $b/lex
python3 src/test/genlex.py $b/lex
n=0; bad=0
for f in $b/lex/*.raz lib/*.raz examples/*.raz tools/*.raz src/*.raz src/test/*.raz test/run/*.raz test/err/*.raz \
         conform/*/*.raz $b/reals.raz; do
    [ -f "$f" ] || continue
    newer $f && continue
    s1=0; s2=0
    $b/scandump.seed $f >$b/seed.out 2>$b/seed.err || s1=$?
    $b/scandump.src $f >$b/src.out 2>$b/src.err || s2=$?
    n=$((n + 1))
    if [ $s1 != $s2 ] || ! cmp -s $b/seed.out $b/src.out || ! cmp -s $b/seed.err $b/src.err; then
        echo "differs: $f (status $s1 and $s2)"; bad=$((bad + 1))
    fi
done
echo "$n files, $bad differ"
test $bad = 0

# Jump: a parser's way of going on after an error
./raz -Werror -I src -o $b/recover src/test/Recover.raz
printf 'a bad b bad bad c\nd bad\n' >$b/rec.raz
r=$($b/recover $b/rec.raz 2>/dev/null) || test $? = 1
test "$r" = "8 names, 4 failed, 4 errors" && echo "recover ok"

# Chunk and Sym: a fixed pseudo-random script each, run by both sides,
# which print all they have made or answered; Sym also ends, as the
# argument says, in an error, whose message and status must agree
for u in Chunk Sym; do
    l=$(echo $u | tr A-Z a-z)
    fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/${l}dump.seed src/test/${u}Dump.pas >/dev/null
    ./raz -Werror -I src -o $b/${l}dump.src src/test/${u}Dump.raz
done
for a in "" dup deep; do
    for s in seed src; do
        t=0; $b/chunkdump.$s >$b/chunk.$s 2>/dev/null || t=$?
        t2=0; $b/symdump.$s $a >$b/sym.$s.out 2>$b/sym.$s.err || t2=$?
        echo "$t $t2" >$b/status.$s
    done
    cmp $b/status.seed $b/status.src
    cmp $b/chunk.seed $b/chunk.src
    cmp $b/sym.seed.out $b/sym.src.out
    cmp $b/sym.seed.err $b/sym.src.err
done
echo "chunk and sym ok"

# Link and Elf: a program of chunks made by a script, linked and written
# as a static, a dynamic and a stripped executable, which must be the
# same file from both sides
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/linkdump.seed src/test/LinkDump.pas >/dev/null
./raz -Werror -I src -o $b/linkdump.src src/test/LinkDump.raz
for m in 0 1 2; do
    $b/linkdump.seed $m $b/link.seed
    $b/linkdump.src $m $b/link.src
    cmp $b/link.seed $b/link.src
done
echo "link and elf ok"

# X64: every encoder, then the assembler on a long run of instructions
# of every kind and a file for each error it makes; the bytes and the
# listing, or the message and status, must be the same
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/x64dump.seed src/test/X64Dump.pas >/dev/null
./raz -Werror -I src -o $b/x64dump.src src/test/X64Dump.raz
$b/x64dump.seed >$b/x64.seed
$b/x64dump.src >$b/x64.src
cmp $b/x64.seed $b/x64.src
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/asmdump.seed src/test/AsmDump.pas >/dev/null
./raz -Werror -I src -o $b/asmdump.src src/test/AsmDump.raz
mkdir -p $b/asm
python3 src/test/genasm.py $b/asm
n=0; bad=0
for f in $b/asm/*.raz; do
    s1=0; s2=0
    $b/asmdump.seed $f >$b/seed.out 2>$b/seed.err || s1=$?
    $b/asmdump.src $f >$b/src.out 2>$b/src.err || s2=$?
    n=$((n + 1))
    if [ $s1 != $s2 ] || ! cmp -s $b/seed.out $b/src.out || ! cmp -s $b/seed.err $b/src.err; then
        echo "differs: $f (status $s1 and $s2)"; bad=$((bad + 1))
    fi
done
echo "x64: $n assembler files, $bad differ"
test $bad = 0

# Gen and Item were tested here against the seed's while they were ported,
# by the code they made: the same bytes, listings and line notes. Since the
# compiler's own code was improved (v0.10.1) that code is no longer the
# seed's, so they are tested by what the seed can still check, the
# messages and statuses of Parse and Raz below, and by the fixpoint and
# the tests of `make check`, on the compiler they make.

# Parse and Raz: the compiler this makes, built by the seed, compiles
# what the seed compiles, with the same messages and status (the files
# are no longer the same, as it makes better code): every example, test and tool, and the library, with each
# one's own options. Both sides run as build/cmp/raz, since a program
# holds the paths it was made from and the library is found beside the
# compiler.
printf 'module Version;\nconst Text* = "%s";\nend Version.\n' "$(tr -d "'" < build/version.inc)" >$b/Version.raz
./raz -Werror -I src -I $b -o $b/raz.src src/Raz.raz
c=build/cmp
mkdir -p $c
ln -sfn ../../lib $c/lib
# and the big program that times the compiler, 348,025 lines
mkdir -p $c/bench
python3 test/genbench.py 12000 >$c/bench/Bench.raz
files=
for f in $c/bench/Bench.raz lib/*.raz examples/*.raz tools/*.raz src/*.raz test/run/*.raz test/libc/*.raz test/bench/*.raz \
         conform/run/*.raz test/err/*.raz conform/err/*.raz; do
    newer $f || files="$files $f"
done
for side in seed src; do
    rm -rf $c/$side
    mkdir -p $c/$side
    if [ $side = seed ]; then cp build/seed/raz $c/raz; else cp $b/raz.src $c/raz; fi
    for f in $files; do
        dir=$(dirname $f); name=$(basename $f .raz); x=$(echo $dir | tr / _).$name
        flags=
        case $dir in
            examples|tools|lib|src) flags=-Werror ;;
        esac
        [ -f $dir/$name.args ] && [ $dir = test/err ] && flags="$flags $(cat $dir/$name.args)"
        case $dir in
            lib) opts= ;;
            src|tools) opts="-I src -I build/src" ;;
            test/err) opts="-I test/err/mods -I test/run/mods" ;;
            *) opts="-I $dir/mods" ;;
        esac
        s=0
        $c/raz $flags $opts -o $c/$side/$x $f >$c/$side/$x.out 2>$c/$side/$x.err || s=$?
        echo $s >$c/$side/$x.status
    done
done
n=0; bad=0
for f in $files; do
    x=$(dirname $f | tr / _).$(basename $f .raz)
    n=$((n + 1))
    for e in .out .err .status; do
        [ -f $c/seed/$x$e ] || [ -f $c/src/$x$e ] || continue
        if ! cmp -s $c/seed/$x$e $c/src/$x$e; then
            echo "differs: $f ($x$e)"; bad=$((bad + 1)); break
        fi
    done
done
echo "raz: $n files, $bad differ"
test $bad = 0
