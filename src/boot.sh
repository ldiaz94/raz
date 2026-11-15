#!/bin/sh
# The compiler that builds src/: the release BOOT names, by its tag and
# its tarball's SHA-256. A release's tarball is the same, byte for byte,
# wherever it is made (the Makefile's dist), so the sum pins the very
# compiler; and since that release was built by the one before it, back
# to v0.19.0, which the Pascal seed built (git has it at that tag),
# raz can always be built again from source alone.
#
# The tarball is taken from build/boot/ if it is there; else from the
# website's downloads in this checkout, site/public/download/, where
# every release is kept; else from the GitHub release, by curl, or by
# gh's REST API where the repository is private and gh has a token; else
# from the website, which serves the same bytes. A machine with no
# network and no site/public has it put there by hand. The sum is
# checked whichever it came from. Its raz goes to build/boot/raz, with
# this repository's lib/ beside it, since src/ is built against today's
# library. Run from the repository root, by make.
set -e
read tag sum < BOOT
v=${tag#v}
t=raz-$v-linux-x86_64.tar.gz
d=build/boot
repo=ldiaz94/raz
mkdir -p $d
if [ ! -f $d/$t ] && [ -f site/public/download/$t ]; then
    cp site/public/download/$t $d/$t
fi
if [ ! -f $d/$t ]; then
    if ! curl -fsSL -o $d/$t https://github.com/$repo/releases/download/$tag/$t 2>/dev/null; then
        id=$(gh api repos/$repo/releases/tags/$tag --jq ".assets[] | select(.name == \"$t\") | .id" 2>/dev/null) &&
            [ -n "$id" ] &&
            gh api -H 'Accept: application/octet-stream' repos/$repo/releases/assets/$id >$d/$t 2>/dev/null ||
            curl -fsSL -o $d/$t https://raz.lucelad.workers.dev/download/$t 2>/dev/null ||
            { rm -f $d/$t; echo "boot: can't fetch $t; put it in $d" >&2; exit 1; }
    fi
fi
# macOS has shasum, not sha256sum
if command -v sha256sum >/dev/null; then got=$(sha256sum < $d/$t); else got=$(shasum -a 256 < $d/$t); fi
if [ "${got%% *}" != "$sum" ]; then
    echo "boot: $d/$t isn't $tag's tarball: its SHA-256 isn't BOOT's" >&2
    exit 1
fi
rm -rf $d/raz-$v-linux-x86_64
tar -xzf $d/$t -C $d
cp $d/raz-$v-linux-x86_64/raz $d/raz
ln -sfn ../../lib $d/lib
