#!/bin/sh
# Tests src/'s units against the seed's: each dumper reads the same
# files and must give the same standard output, standard error and
# status. Run from the repository root, after `make raz`; the seed's
# side is built by fpc from seed/.
set -e
b=build/self
mkdir -p $b
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/scandump.seed src/test/ScanDump.pas >/dev/null
./raz -Werror -I src -o $b/scandump.self src/test/ScanDump.raz
python3 src/test/genreals.py > $b/reals.raz
# one small file for each message the scanner makes, and the places
# diag shows them in: a tab, a long line, characters before the place
mkdir -p $b/lex
python3 src/test/genlex.py $b/lex
n=0; bad=0
for f in $b/lex/*.raz lib/*.raz examples/*.raz tools/*.raz src/*.raz src/test/*.raz test/run/*.raz test/err/*.raz \
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
    ./raz -Werror -I src -o $b/${l}dump.self src/test/${u}Dump.raz
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
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/linkdump.seed src/test/LinkDump.pas >/dev/null
./raz -Werror -I src -o $b/linkdump.self src/test/LinkDump.raz
for m in 0 1 2; do
    $b/linkdump.seed $m $b/link.seed
    $b/linkdump.self $m $b/link.self
    cmp $b/link.seed $b/link.self
done
echo "link and elf ok"

# X64: every encoder, then the assembler on a long run of instructions
# of every kind and a file for each error it makes; the bytes and the
# listing, or the message and status, must be the same
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/x64dump.seed src/test/X64Dump.pas >/dev/null
./raz -Werror -I src -o $b/x64dump.self src/test/X64Dump.raz
$b/x64dump.seed >$b/x64.seed
$b/x64dump.self >$b/x64.self
cmp $b/x64.seed $b/x64.self
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/asmdump.seed src/test/AsmDump.pas >/dev/null
./raz -Werror -I src -o $b/asmdump.self src/test/AsmDump.raz
mkdir -p $b/asm
python3 src/test/genasm.py $b/asm
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

# Gen: procedures made by a script of calls (expressions, statements,
# calls, frames, checks, defers, the entry point), whose bytes, fixups,
# line notes and listing must be the same; once with the static entry
# point and once with the dynamic one
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/gendump.seed src/test/GenDump.pas >/dev/null
./raz -Werror -I src -o $b/gendump.self src/test/GenDump.raz
for a in "" dyn; do
    $b/gendump.seed $a >$b/gen.seed
    $b/gendump.self $a >$b/gen.self
    cmp $b/gen.seed $b/gen.self
done
echo "gen ok"

# Item: operands and operations driven by a script with mistakes in it,
# which show their messages and go on; what each step gave, the code
# made and the messages must be the same. A run ends at the 20th error,
# as a compile does, so the script changes with each argument.
fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/itemdump.seed src/test/ItemDump.pas >/dev/null
./raz -Werror -I src -o $b/itemdump.self src/test/ItemDump.raz
n=0; bad=0
for a in $(seq 0 59); do
    s1=0; s2=0
    $b/itemdump.seed $a >$b/seed.out 2>$b/seed.err || s1=$?
    $b/itemdump.self $a >$b/self.out 2>$b/self.err || s2=$?
    n=$((n + 1))
    if [ $s1 != $s2 ] || ! cmp -s $b/seed.out $b/self.out || ! cmp -s $b/seed.err $b/self.err; then
        echo "differs: item script $a (status $s1 and $s2)"; bad=$((bad + 1))
    fi
done
echo "item: $n scripts, $bad differ"
test $bad = 0

# Parse and Raz: the compiler this makes, built by the seed, compiles
# what the seed compiles, to the same file, with the same messages and
# status: every example, test and tool, and the library, with each
# one's own options. Both sides run as build/cmp/raz, since a program
# holds the paths it was made from and the library is found beside the
# compiler.
printf 'module Version;\nconst Text* = "%s";\nend Version.\n' "$(tr -d "'" < build/version.inc)" >$b/Version.raz
./raz -Werror -I src -I $b -o $b/raz.self src/Raz.raz
c=build/cmp
mkdir -p $c
ln -sfn ../../lib $c/lib
# and the big program that times the compiler, 348,025 lines
mkdir -p $c/bench
python3 test/genbench.py 12000 >$c/bench/Bench.raz
files=
for f in $c/bench/Bench.raz lib/*.raz examples/*.raz tools/*.raz src/*.raz test/run/*.raz test/libc/*.raz test/bench/*.raz \
         conform/run/*.raz test/err/*.raz conform/err/*.raz; do
    files="$files $f"
done
for side in seed self; do
    rm -rf $c/$side
    mkdir -p $c/$side
    if [ $side = seed ]; then cp raz $c/raz; else cp $b/raz.self $c/raz; fi
    for f in $files; do
        dir=$(dirname $f); name=$(basename $f .raz); x=$(echo $dir | tr / _).$name
        flags=
        case $dir in
            examples|tools|lib|src) flags=-Werror ;;
        esac
        [ -f $dir/$name.args ] && [ $dir = test/err ] && flags="$flags $(cat $dir/$name.args)"
        case $dir in
            lib) opts= ;;
            src|tools) opts="-I src -I build/self" ;;
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
    for e in "" .out .err .status; do
        [ -f $c/seed/$x$e ] || [ -f $c/self/$x$e ] || continue
        if ! cmp -s $c/seed/$x$e $c/self/$x$e; then
            echo "differs: $f ($x$e)"; bad=$((bad + 1)); break
        fi
    done
done
echo "raz: $n files, $bad differ"
test $bad = 0
