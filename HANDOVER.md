# Handover, 2026-10-17

Where the work stands, what to tag where, and how to go on. Delete this
file once v0.20.0 is out.

## What to tag

This session could push to `main` but not tags (the environment's git
proxy refused them, 403), so the tags are the owner's to add,
retrospectively. Each is an annotated tag whose message is what
`raz --version` prints; pushing it runs CI, which checks the commit and
makes the GitHub release with its tarball.

| Tag | Commit | Message | Note |
|---|---|---|---|
| `v0.18.1` | `88b18ba` ("Docs for v0.18.1") | `raz 0.18.1, report 2026-10.32` | Never tagged, though CLAUDE.md and README call it a release; `1328b81` ("site: v0.18.1") follows it. Check the commit before tagging. |
| `v0.19.0` | `51a90a6` | `raz 0.19.0, report 2026-10.33` | Its tarball's SHA-256 is `217448cb6521c76a28d71499d70a5dfdebc2dbcbc81d6d41ed9d9590005772ed` (made here by `make dist REV=v0.19.0`). |

    git tag -a v0.18.1 -m 'raz 0.18.1, report 2026-10.32' 88b18ba
    git tag -a v0.19.0 -m 'raz 0.19.0, report 2026-10.33' 51a90a6
    git push origin v0.18.1 v0.19.0

Tarballs are the same byte for byte wherever they are made: v0.18.0's,
made here, has GitHub's SHA-256 (`d05f2adb...`). So CI's v0.19.0
tarball should have the sum above; check it (`gh api
repos/ldiaz94/raz/releases/tags/v0.19.0`, then the asset) before going
on, since v0.20.0 pins it.

## What is done (on `main`)

v0.19.0, report 2026-10.33, the ninth thaw, by the owner's word: a
`const` parameter, a variant in a constant, and the library taking
`var`, `const` or a value where it took a pointer. Commits `71db16c`
(report) to `51a90a6` (docs; the compiler follows 10.33), then
`d704863` (PROPOSALS.md: the done parts out; `[]const T` in). Each
commit passed `make check`; the fixpoint, `stress`, `kernels` and
`tests` passed at the end. Notes:

- `bench` dipped below 400,000 lines a second on some runs in this
  container; the new compiler was about 9% faster than the one before
  the work on the same machine, so it is the machine's load.
- Measured: `Map.get` and `Vec.all` taking their record as a value made
  a loop half again as slow; as `const` the code is the pointer's, so
  they take `const`. `Buf.bytes` (a value) and `Sys.entryKind` (`var`)
  wait for v0.20.0, since the seed compiles them and doesn't know
  `const`.
- A trace no longer shows `var` or `const` parameters (four `.stderr`
  files regenerated).
- The report is about 32 pages of 40 by its words; this container's
  pandoc is too old for `make pdf`. Check it by hand.

## v0.20.0: what is left

The plan, approved: v0.19.0 builds `src/`, the Pascal seed goes, then
what waited for that.

1. **Build from v0.19.0; drop the seed** (started here, not committed;
   see below). Needs the v0.19.0 release to exist, for CI.
2. **`Buf.bytes` and `Sys.entryKind` take `const`** (both `Sys`
   files), with volume 2 and `test/doc`. No caller changes.
3. **`src/`'s records only read take `const`** (`Item`, about 130
   bytes, in `Item.what`, `adrOf`, `realOf`, `discard` and the like),
   kept only where `make bench` gains.
4. Docs: README (building, "What's here", the seed), CLAUDE.md (the
   setup list loses `make tests` and `seed-bench`, gains `prev-bench`;
   "The compiler and the seed"; the readings that keep `Sys.raz`,
   `CAbi`, `src/` and its library to the seed's language, and that say
   views and the widening wait for a new seed), `doc/compiler.md`'s
   opening, `src/README.md`, and comments in `src/*.raz` that name the
   seed. `fpc` stays only for `make kernels`' Pascal twins.
5. Tag `v0.20.0` (`raz 0.20.0, report 2026-10.33`).

Also waiting, not started: `PTR(s)` in PROPOSALS.md, which the owner
thought worth doing; it is a library/built-in addition that breaks no
program.

## Step 1 as it was left

Not committed; this container's working tree had it, and it is
repeated here so that a fresh session can make it again. Untested
beyond `make raz` (which built `raz 0.19.0-1-...` from build/boot/raz).

- `BOOT`, one line: `v0.19.0 217448cb6521c76a28d71499d70a5dfdebc2dbcbc81d6d41ed9d9590005772ed`
- `src/boot.sh`, executable: fetches the tarball BOOT names into
  `build/boot/` (curl for a public repository; `gh api` REST for this
  private one: GraphQL, which `gh release download` uses, is refused
  from these sessions), checks its SHA-256, puts its `raz` at
  `build/boot/raz` with `ln -sfn ../../lib build/boot/lib`. CI's check
  step then needs `GH_TOKEN: ${{ github.token }}` in its env, and no
  longer needs `fp-compiler`.
- `git rm -r seed test/scantest.pas test/enctest.pas test/handtest.pas
  src/test/ScanBench.pas src/test/ScanBench.raz`.
- The Makefile, `src/fixpoint.sh` (stage 0 is `build/boot/raz`) and
  `src/bench.sh` (now `make prev-bench`: this compiler against BOOT's,
  failing if more than a tenth slower), as in this diff:

```
diff --git a/Makefile b/Makefile
index cad4c6d..6a20acd 100644
--- a/Makefile
+++ b/Makefile
@@ -1,19 +1,15 @@
 # Builds the compiler, raz, from src/ into the repository's root; the
-# library it needs is lib/, beside it. The seed, the Pascal compiler in
-# seed/, builds it: fpc makes the seed in build/seed/ (with lib/ beside
-# it, as every raz has), and the seed compiles src/. The one module
-# the build makes, Version, holds what git says the version is.
+# library it needs is lib/, beside it. The previous release builds it:
+# BOOT names that release and its tarball's SHA-256, and src/boot.sh
+# puts its raz in build/boot/, with this lib/ beside it (as every raz
+# has its library), so that src/ is built against today's library. The
+# one module the build makes, Version, holds what git says the version is.
 
-FPC = fpc
-FPCFLAGS = -O2 -Mobjfpc -Sh- -vew -FUbuild
+raz: build/boot/raz src/*.raz build/src/Version.raz
+	build/boot/raz -Werror -I src -I build/src -o raz src/Raz.raz
 
-raz: build/seed/raz src/*.raz build/src/Version.raz
-	build/seed/raz -Werror -I src -I build/src -o raz src/Raz.raz
-
-build/seed/raz: seed/*.pas build/version.inc | build
-	mkdir -p build/seed
-	$(FPC) $(FPCFLAGS) -Fibuild -FEbuild/seed -obuild/seed/raz seed/raz.pas
-	ln -sfn ../../lib build/seed/lib
+build/boot/raz: BOOT src/boot.sh | build
+	src/boot.sh
 
 build/src/Version.raz: build/version.inc | build
 	mkdir -p build/src
@@ -27,16 +23,6 @@ build/version.inc: FORCE | build
 
 FORCE:
 
-units: seed/*.pas | build
-	for u in diag scan sym chunk x64 link elf; do $(FPC) $(FPCFLAGS) seed/$$u.pas || exit 1; done
-
-# tests of the parts below the parser, built from test/
-tests: units
-	$(FPC) $(FPCFLAGS) -Fuseed -obuild/scantest test/scantest.pas
-	$(FPC) $(FPCFLAGS) -Fuseed -obuild/enctest test/enctest.pas
-	$(FPC) $(FPCFLAGS) -Fuseed -obuild/handtest test/handtest.pas
-	build/handtest build/hand && build/hand; test $$? = 42
-
 build:
 	mkdir -p build
 
@@ -47,12 +33,13 @@ clean:
 check: raz build/raz-lib.3
 	test/check.sh
 
-# the scanner's and the compiler's speed against the seed's
-seed-bench: raz | build
+# the compiler's speed against the previous release's, BOOT's, on the
+# same program: fails if this one is more than a tenth slower
+prev-bench: raz | build
 	src/bench.sh
 
-# the seed builds src/, that builds src/, that builds it again: the
-# last two must be the same file; check and bench then run on it
+# the previous release builds src/, that builds src/, that builds it
+# again: the last two must be the same file; check and bench then run on it
 fixpoint: raz | build
 	src/fixpoint.sh
 
@@ -185,4 +172,4 @@ dist:
 site: raz pdf
 	python3 site/build.py
 
-.PHONY: units tests seed-bench fixpoint check gdb bench kernels stress alpine fmt loc man pdf dist site clean install uninstall
+.PHONY: prev-bench fixpoint check gdb bench kernels stress alpine fmt loc man pdf dist site clean install uninstall
diff --git a/src/bench.sh b/src/bench.sh
index 5d211f3..385050d 100755
--- a/src/bench.sh
+++ b/src/bench.sh
@@ -1,35 +1,25 @@
 #!/bin/sh
-# The scanner's speed against the seed's, on the compiler's own
-# benchmark program: the best of seven runs of each. Run from the
-# repository root, after make raz.
+# The compiler's speed against the previous release's, the one BOOT
+# names (build/boot/raz), on the same generated program: the best of
+# five runs of each, as build/cmp/raz, which finds the library beside
+# it. A regression test: it fails if this compiler takes more than a
+# tenth longer. Run from the repository root, after make raz.
 set -e
-b=build/src
-mkdir -p $b
-python3 test/genbench.py 12000 >$b/Bench.raz
-fpc -O2 -Mobjfpc -Sh- -vew -FUbuild -Fuseed -o$b/scanbench.seed src/test/ScanBench.pas >/dev/null
-./raz -Werror -I src -o $b/scanbench.src src/test/ScanBench.raz
-echo "$(wc -l <$b/Bench.raz) lines"
-for t in seed src; do
-    best=0
-    for i in 1 2 3 4 5 6 7; do
-        s=$(date +%s%N); $b/scanbench.$t $b/Bench.raz >/dev/null; e=$(date +%s%N)
-        d=$(( (e - s) / 1000000 )); if [ $best = 0 ] || [ $d -lt $best ]; then best=$d; fi
-    done
-    echo "$t: $best ms"
-done
-
-# The whole compiler's speed, the seed's and this one's, on the same
-# program: the best of five runs of each, as build/cmp/raz, which finds
-# the library beside it.
 mkdir -p build/cmp/bench
 ln -sfn ../../lib build/cmp/lib
-cp $b/Bench.raz build/cmp/bench/Bench.raz
-for t in seed src; do
-    if [ $t = seed ]; then cp build/seed/raz build/cmp/raz; else cp $b/raz.src build/cmp/raz; fi
+python3 test/genbench.py 12000 >build/cmp/bench/Bench.raz
+echo "$(wc -l <build/cmp/bench/Bench.raz) lines"
+for t in prev this; do
+    if [ $t = prev ]; then cp build/boot/raz build/cmp/raz; else cp raz build/cmp/raz; fi
     best=0
     for i in 1 2 3 4 5; do
         s=$(date +%s%N); build/cmp/raz -o build/cmp/bench/Bench.$t build/cmp/bench/Bench.raz; e=$(date +%s%N)
         d=$(( (e - s) / 1000000 )); if [ $best = 0 ] || [ $d -lt $best ]; then best=$d; fi
     done
-    echo "compile, $t: $best ms"
+    echo "$t: $best ms"
+    eval "ms_$t=$best"
 done
+if [ $((ms_this * 10)) -gt $((ms_prev * 11)) ]; then
+    echo "slower than the previous release, $(cut -d" " -f1 BOOT), by more than a tenth"
+    exit 1
+fi
diff --git a/src/fixpoint.sh b/src/fixpoint.sh
index 5375bc0..8ace35a 100755
--- a/src/fixpoint.sh
+++ b/src/fixpoint.sh
@@ -1,19 +1,20 @@
 #!/bin/sh
-# The fixpoint: the seed builds src/ (stage 1), that builds src/
-# (stage 2), that builds it again (stage 3), and stages 2 and 3 must
-# be the same file. A program holds the paths it was made from, so each
+# The fixpoint: the previous release, BOOT's, builds src/ (stage 1),
+# that builds src/ (stage 2), that builds it again (stage 3), and
+# stages 2 and 3 must be the same file. A program holds the paths it was made from, so each
 # stage is built by the same command in the same place, from the
 # compiler before it copied to build/fix/raz. Run from the repository
 # root, after `make raz`. Then stage 3 stands in for ./raz (messages name
 # the library by its path from the compiler, so it must be at the root)
-# while `make check` and `make bench` run on it; the seed's comes back.
+# while `make check` and `make bench` run on it; the one make built
+# comes back.
 set -e
 d=build/fix
 rm -rf $d
 mkdir -p $d/v
 ln -s ../../lib $d/lib
 printf 'module Version;\nconst Text* = "%s";\nend Version.\n' "$(tr -d "'" < build/version.inc)" >$d/v/Version.raz
-cp build/seed/raz $d/stage0
+cp build/boot/raz $d/stage0
 for n in 1 2 3; do
     cp $d/stage$((n - 1)) $d/raz
     $d/raz -Werror -I src -I $d/v -o $d/stage$n src/Raz.raz
```

and `src/boot.sh`:

```
#!/bin/sh
# The compiler that builds src/: the release BOOT names, by its tag and
# its tarball's SHA-256. A release's tarball is the same, byte for byte,
# wherever it is made (the Makefile's dist), so the sum pins the very
# compiler; and since that release was built by the one before it, back
# to v0.19.0, which the Pascal seed built (git has it at that tag),
# raz can always be built again from source alone.
#
# The tarball is taken from build/boot/ if it is there; else from the
# GitHub release, by curl, or by gh's REST API where the repository is
# private and gh has a token; a machine with no network has it put
# there by hand. Its raz goes to build/boot/raz, with this repository's
# lib/ beside it, since src/ is built against today's library. Run from
# the repository root, by make.
set -e
read tag sum < BOOT
v=${tag#v}
t=raz-$v-linux-x86_64.tar.gz
d=build/boot
repo=ldiaz94/raz
mkdir -p $d
if [ ! -f $d/$t ]; then
    if ! curl -fsSL -o $d/$t https://github.com/$repo/releases/download/$tag/$t 2>/dev/null; then
        id=$(gh api repos/$repo/releases/tags/$tag --jq ".assets[] | select(.name == \"$t\") | .id" 2>/dev/null) &&
            [ -n "$id" ] &&
            gh api -H 'Accept: application/octet-stream' repos/$repo/releases/assets/$id >$d/$t 2>/dev/null ||
            { rm -f $d/$t; echo "boot: can't fetch $t; put it in $d" >&2; exit 1; }
    fi
fi
if ! echo "$sum  $d/$t" | sha256sum -c --quiet - >/dev/null 2>&1; then
    echo "boot: $d/$t isn't $tag's tarball: its SHA-256 isn't BOOT's" >&2
    exit 1
fi
rm -rf $d/raz-$v-linux-x86_64
tar -xzf $d/$t -C $d
cp $d/raz-$v-linux-x86_64/raz $d/raz
ln -sfn ../../lib $d/lib
```
