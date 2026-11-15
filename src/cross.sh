#!/bin/sh
# A compiler that runs here and compiles for TARGET (OS-ARCH, as
# darwin-arm64 or linux-x86_64): raz built by staging, for the target
# is whatever files the compiler was built from (doc/raz.md, 3).
#
#     src/cross.sh TARGET [OUT]        run from the repository root
#
# Stage build/cross/TARGET/src/ holds src/'s generic files and, under
# the plain names, the target's own: Gen.ARCH.raz as Gen.raz and
# Exe.OS.raz as Exe.raz; and the host's, Host.OS.raz as Host.raz, the
# host being the system the compiler will run on, which is this one.
# With only plain names there, module lookup has one choice each. BOOT's
# release builds the stage as the Makefile builds raz, from a directory
# where src/Raz.raz is again at src/, so the paths a program holds are
# the same. The compiler is OUT, build/cross/TARGET/raz if not said;
# its library is lib/, beside it.
set -e
target=$1
out=${2:-build/cross/$target/raz}
case $target in
*-*) ;;
*) echo "usage: src/cross.sh OS-ARCH [OUT]" >&2; exit 2;;
esac
os=${target%%-*}
arch=${target#*-}
host=$(uname -s | tr A-Z a-z)    # the OS that runs the compiler

# Each unit with files by target, and the file this build takes of it
missing=
for f in Gen.$arch.raz Exe.$os.raz Host.$host.raz; do
    [ -f src/$f ] || missing="$missing src/$f"
done
if [ -n "$missing" ]; then
    echo "cross.sh: no files for $target (host $host):$missing" >&2
    exit 1
fi
[ -f build/src/Version.raz ] || make build/src/Version.raz
[ -x build/boot/raz ] || make build/boot/raz

d=build/cross/$target
rm -rf $d
mkdir -p $d/src $d/v
for f in src/*.raz; do
    case $f in
    *.*.raz) ;;                 # a target's file, below
    *) cp $f $d/src/;;
    esac
done
cp src/Gen.$arch.raz $d/src/Gen.raz
cp src/Exe.$os.raz $d/src/Exe.raz
cp src/Host.$host.raz $d/src/Host.raz
cp build/src/Version.raz $d/v/
ln -s ../../../lib $d/lib
boot=$PWD/build/boot/raz
(cd $d && $boot -Werror -I src -I v -o raz src/Raz.raz)
case $out in
build/cross/$target/raz) ;;
*) cp $d/raz "$out";;
esac
