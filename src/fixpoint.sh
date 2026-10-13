#!/bin/sh
# The fixpoint: the seed builds src/ (stage 1), that builds src/
# (stage 2), that builds it again (stage 3), and stages 2 and 3 must
# be the same file. A program holds the paths it was made from, so each
# stage is built by the same command in the same place, from the
# compiler before it copied to build/fix/raz. Run from the repository
# root, after `make raz`. Then stage 3 stands in for ./raz (messages name
# the library by its path from the compiler, so it must be at the root)
# while `make check` and `make bench` run on it; the seed's comes back.
set -e
d=build/fix
rm -rf $d
mkdir -p $d/v
ln -s ../../lib $d/lib
printf 'module Version;\nconst Text* = "%s";\nend Version.\n' "$(tr -d "'" < build/version.inc)" >$d/v/Version.raz
cp build/seed/raz $d/stage0
for n in 1 2 3; do
    cp $d/stage$((n - 1)) $d/raz
    $d/raz -Werror -I src -I $d/v -o $d/stage$n src/Raz.raz
done
cmp $d/stage2 $d/stage3
echo "fixpoint: stages 2 and 3 are the same, $(wc -c <$d/stage3) bytes"
cp raz $d/seed
trap 'cp $d/seed raz' EXIT
cp $d/stage3 raz
make check
make bench
