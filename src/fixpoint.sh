#!/bin/sh
# The fixpoint: the previous release, BOOT's, builds src/ (stage 1),
# that builds src/ (stage 2), that builds it again (stage 3), and
# stages 2 and 3 must be the same file. A program holds the paths it was made from, so each
# stage is built by the same command in the same place, from the
# compiler before it copied to build/fix/raz, and is written as
# build/fix/out/raz before it is kept as stageN: a Mac's executable
# names itself in its signature, by the name it was written as. Run
# from the repository root, after `make raz`. Then stage 3 stands in for ./raz (messages name
# the library by its path from the compiler, so it must be at the root)
# while `make check` and `make bench` run on it; the one make built
# comes back.
#
# On a Mac with no Mac release in BOOT, stage 0 is the bootstrap's
# compiler (src/bootstrap.sh), made through the container; and make
# check isn't run there until test/ passes on the Mac (PLAN.md 5, step 8).
#
# A file is removed before another is copied to its name, never written
# in place: macOS kills a program whose signed file was written over.
set -e
d=build/fix
rm -rf $d
mkdir -p $d/v $d/out
ln -s ../../lib $d/lib
printf 'module Version;\nconst Text* = "%s";\nend Version.\n' "$(tr -d "'" < build/version.inc)" >$d/v/Version.raz
cp build/boot/raz $d/stage0
for n in 1 2 3; do
    rm -f $d/raz
    cp $d/stage$((n - 1)) $d/raz
    $d/raz -Werror -I src -I $d/v -o $d/out/raz src/Raz.raz
    mv $d/out/raz $d/stage$n
done
cmp $d/stage2 $d/stage3
echo "fixpoint: stages 2 and 3 are the same, $(wc -c <$d/stage3 | tr -d ' ') bytes"
cp raz $d/made
trap 'rm -f raz; cp $d/made raz' EXIT
rm -f raz
cp $d/stage3 raz
if [ "$(uname -s)" = Darwin ]; then
    echo "fixpoint: make check isn't run on the Mac until test/ passes there (PLAN.md 5, step 8)"
else
    make check
fi
make bench
