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
