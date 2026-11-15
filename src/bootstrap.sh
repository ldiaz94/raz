#!/bin/sh
# The bootstrap: the compiler that builds src/ on a Mac (darwin-arm64)
# while the release BOOT names has no tarball for it. src/boot.sh runs
# this in its place, so make raz works the same; once a release has a
# darwin-arm64 tarball and BOOT its sum, this is no longer used.
#
# The first Mac compiler is made from Linux's, as a Mac can't run
# Linux's raz itself: in the linux/amd64 container (make docker-image,
# so docker must be here), BOOT's Linux release builds a cross compiler
# from src/, which runs on Linux and compiles for the Mac (src/cross.sh
# darwin-arm64); and that builds src/ again with the Mac's Host, into a
# compiler that runs on the Mac (HOST=darwin src/cross.sh darwin-arm64).
# That one is build/boot/raz, the compiler make raz builds src/ with
# here, natively, as BOOT's would; make fixpoint then shows that what it
# makes makes itself again.
#
# It is kept, as build/boot/bootstrap-V/raz for BOOT's version V, since
# the container would make it again each time the build moves between
# the Mac and the container (they share build/; the Makefile's
# build/host). Remove build/boot to make it again from today's src/.
# A release's tarball (make dist) is made in a fresh checkout, without
# this copy, so that it is made from the release's own src/.
# Run from the repository root, by src/boot.sh.
set -e
tag=$(sed -n 1p BOOT)
v=${tag#v}
d=build/boot
keep=$d/bootstrap-$v
if [ ! -x $keep/raz ]; then
    echo "boot: $tag has no darwin-arm64 tarball: the first Mac compiler is made in a linux/amd64 container (src/bootstrap.sh)" >&2
    command -v docker >/dev/null || { echo "boot: docker isn't here, and the bootstrap needs it" >&2; exit 1; }
    # the version, made here, where git is, for the container's builds
    make build/src/Version.raz
    make docker-image
    mkdir -p $keep
    # BOOT's Linux raz, the cross compiler, then the Mac compiler, which
    # the container can make but not run
    docker run --rm --platform linux/amd64 $DOCKERFLAGS -v "$PWD:$PWD" -w "$PWD" raz-check \
        timeout 1800 sh -c "src/cross.sh darwin-arm64 && HOST=darwin src/cross.sh darwin-arm64 $keep/raz"
    # the container's make noted its own system in build/host; this is the Mac's
    echo darwin-arm64 >build/host
fi
rm -f $d/raz      # never written in place: macOS keeps a file's signature
cp $keep/raz $d/raz
ln -sfn ../../lib $d/lib
"$d/raz" --version >/dev/null
