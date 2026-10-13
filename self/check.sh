#!/bin/sh
# Tests self/'s units against the seed's: each dumper reads the same
# files and must give the same standard output, standard error and
# status. Run from the repository root, after `make raz`; the seed's
# side is built by fpc from src/.
set -e
b=build/self
mkdir -p $b
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fusrc -o$b/scandump.seed self/test/ScanDump.pas >/dev/null
./raz -Werror -I self -o $b/scandump.self self/test/ScanDump.raz
python3 self/test/genreals.py > $b/reals.raz
# one small file for each message the scanner makes, and the places
# diag shows them in: a tab, a long line, characters before the place
mkdir -p $b/lex
python3 self/test/genlex.py $b/lex
n=0; bad=0
for f in $b/lex/*.raz lib/*.raz examples/*.raz tools/*.raz self/*.raz self/test/*.raz test/run/*.raz test/err/*.raz \
         conform/*/*.raz $b/reals.raz; do
    [ -f "$f" ] || continue
    s1=0; s2=0
    $b/scandump.seed $f >$b/seed.out 2>$b/seed.err || s1=$?
    $b/scandump.self $f >$b/self.out 2>$b/self.err || s2=$?
    n=$((n + 1))
    if [ $s1 != $s2 ] || ! cmp -s $b/seed.out $b/self.out || ! cmp -s $b/seed.err $b/self.err; then
        echo "differs: $f (status $s1 and $s2)"; bad=$((bad + 1))
    fi
done
echo "$n files, $bad differ"
test $bad = 0

# Jump: a parser's way of going on after an error
./raz -Werror -I self -o $b/recover self/test/Recover.raz
printf 'a bad b bad bad c\nd bad\n' >$b/rec.raz
r=$($b/recover $b/rec.raz 2>/dev/null) || test $? = 1
test "$r" = "8 names, 4 failed, 4 errors" && echo "recover ok"

# Chunk and Sym: a fixed pseudo-random script each, run by both sides,
# which print all they have made or answered; Sym also ends, as the
# argument says, in an error, whose message and status must agree
for u in Chunk Sym; do
    l=$(echo $u | tr A-Z a-z)
    fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fusrc -o$b/${l}dump.seed self/test/${u}Dump.pas >/dev/null
    ./raz -Werror -I self -o $b/${l}dump.self self/test/${u}Dump.raz
done
for a in "" dup deep; do
    for s in seed self; do
        t=0; $b/chunkdump.$s >$b/chunk.$s 2>/dev/null || t=$?
        t2=0; $b/symdump.$s $a >$b/sym.$s.out 2>$b/sym.$s.err || t2=$?
        echo "$t $t2" >$b/status.$s
    done
    cmp $b/status.seed $b/status.self
    cmp $b/chunk.seed $b/chunk.self
    cmp $b/sym.seed.out $b/sym.self.out
    cmp $b/sym.seed.err $b/sym.self.err
done
echo "chunk and sym ok"

# Link and Elf: a program of chunks made by a script, linked and written
# as a static, a dynamic and a stripped executable, which must be the
# same file from both sides
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fusrc -o$b/linkdump.seed self/test/LinkDump.pas >/dev/null
./raz -Werror -I self -o $b/linkdump.self self/test/LinkDump.raz
for m in 0 1 2; do
    $b/linkdump.seed $m $b/link.seed
    $b/linkdump.self $m $b/link.self
    cmp $b/link.seed $b/link.self
done
echo "link and elf ok"

# X64: every encoder, then the assembler on a long run of instructions
# of every kind and a file for each error it makes; the bytes and the
# listing, or the message and status, must be the same
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fusrc -o$b/x64dump.seed self/test/X64Dump.pas >/dev/null
./raz -Werror -I self -o $b/x64dump.self self/test/X64Dump.raz
$b/x64dump.seed >$b/x64.seed
$b/x64dump.self >$b/x64.self
cmp $b/x64.seed $b/x64.self
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fusrc -o$b/asmdump.seed self/test/AsmDump.pas >/dev/null
./raz -Werror -I self -o $b/asmdump.self self/test/AsmDump.raz
mkdir -p $b/asm
python3 self/test/genasm.py $b/asm
n=0; bad=0
for f in $b/asm/*.raz; do
    s1=0; s2=0
    $b/asmdump.seed $f >$b/seed.out 2>$b/seed.err || s1=$?
    $b/asmdump.self $f >$b/self.out 2>$b/self.err || s2=$?
    n=$((n + 1))
    if [ $s1 != $s2 ] || ! cmp -s $b/seed.out $b/self.out || ! cmp -s $b/seed.err $b/self.err; then
        echo "differs: $f (status $s1 and $s2)"; bad=$((bad + 1))
    fi
done
echo "x64: $n assembler files, $bad differ"
test $bad = 0
