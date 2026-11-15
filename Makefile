# Builds the compiler, raz, from src/ into the repository's root; the
# library it needs is lib/, beside it. The previous release builds it:
# BOOT names that release and its tarball's SHA-256, and src/boot.sh
# puts its raz in build/boot/, with this lib/ beside it (as every raz
# has its library), so that src/ is built against today's library. The
# one module the build makes, Version, holds what git says the version is.

raz: build/boot/raz src/*.raz build/src/Version.raz
	build/boot/raz -Werror -I src -I build/src -o raz src/Raz.raz

build/boot/raz: BOOT src/boot.sh | build
	src/boot.sh

build/src/Version.raz: build/version.inc | build
	mkdir -p build/src
	printf 'module Version;\nconst Text* = "%s";\nend Version.\n' "$$(tr -d "'" < build/version.inc)" >$@

# The version is git's name for the commit (a tag's, or with no tag, as in a
# shallow fetch, the commit's hash), or VERSION where it is given
# (make dist REV=... VERSION=0.20.0 packs a release before its tag is
# pushed, as the tag will); the file changes only when that does, so
# raz isn't rebuilt for nothing.
build/version.inc: FORCE | build
	@v=$(if $(VERSION),$(VERSION),$$(git describe --tags --always --dirty 2>/dev/null || echo unknown)); \
	v="'$${v#v}'"; echo "$$v" | cmp -s - $@ || echo "$$v" >$@

FORCE:

build:
	mkdir -p build

clean:
	rm -rf build raz

# every example and test, against what it should print
check: raz build/raz-lib.3
	test/check.sh

# the compiler's speed against the previous release's, BOOT's, on the
# same program: fails if this one is more than a tenth slower
prev-bench: raz | build
	src/bench.sh

# the previous release builds src/, that builds src/, that builds it
# again: the last two must be the same file; check and bench then run on it
fixpoint: raz | build
	src/fixpoint.sh

# line numbers: gdb stops at a line and names it
gdb: raz
	test/gdb.sh

# the compiler's speed, on a generated program of about 350,000 lines,
# the best of three runs; fails below 400,000 lines a second
bench: raz | build
	sh test/genbench.sh 12000 > build/Bench.raz
	@lines=$$(($$(wc -l < build/Bench.raz))); best=0; \
	for i in 1 2 3; do \
	    start=$$(sh test/nanos.sh); ./raz build/Bench.raz || exit 1; end=$$(sh test/nanos.sh); \
	    t=$$((end - start)); if [ $$best = 0 ] || [ $$t -lt $$best ]; then best=$$t; fi; \
	done; \
	rate=$$((lines * 1000000000 / best)); \
	echo "$$lines lines in $$((best / 1000000)) ms: $$rate lines a second"; \
	test $$rate -ge 400000

# the code's speed: the kernels of test/bench, which say check off,
# against their twins in Pascal built by FPC -O2
kernels: raz
	test/bench/run.sh

# native threads under load: 40,000 spawned and joined, 200 alive at a
# time, all waiting on one Mutex; then, with little memory, spawn must
# fail with Thread.Failed. make check runs a small version.
# test/libc on Alpine, over musl, in docker
alpine: raz
	test/alpine.sh

stress: raz | build
	./raz -o build/Stress lib/Thread.linux-x86_64.raz
	build/Stress 40000 200
	(ulimit -v 60000; build/Stress fail)

# the formatter, tools/Pretty.raz: the library, examples, tools and site programs are
# formatted already
fmt: raz | build
	./raz -o build/Pretty tools/Pretty.raz
	@fail=0; for f in lib/*.raz examples/*.raz tools/*.raz site/*.raz src/*.raz src/test/*.raz; do \
	    build/Pretty $$f | cmp -s - $$f || { echo "not formatted: $$f"; fail=1; }; \
	done; test $$fail = 0

# lines of the compiler, by rloc: each file's blank, comment and code,
# then the lines of code in all
loc:
	@rloc -f src/*.raz
	@rloc -c src/*.raz

# raz-lib(3), the library's manual page, made by tools/Doc.raz from
# its sources, in the order of doc/raz-lib.md, between the page's own
# head (with its date) and tail
LIBDOC = Rt Mem Heap Arena Lock Thread.linux-x86_64 Out Sys.linux-x86_64 \
	Str Bytes.x86_64 Buf Fmt List Map Vec Task Guarded Sort Math Files Opt Width Rand Check Prop C

man: build/raz-lib.3

build/raz-lib.3: raz tools/Doc.raz tools/Scan.raz lib/*.raz doc/raz-lib.head doc/raz-lib.tail | build
	./raz -Werror -o build/Doc tools/Doc.raz
	build/Doc man $(LIBDOC:%=lib/%.raz) > build/raz-lib.modules
	cat doc/raz-lib.head build/raz-lib.modules doc/raz-lib.tail > $@

# the two volumes of the report as PDFs, by pandoc and Chromium; not
# part of check, as CI has neither
pdf: build/raz.pdf build/raz-lib.pdf

build/%.pdf: doc/%.md doc/report.css | build
	pandoc doc/$*.md -s --toc --toc-depth=1 --shift-heading-level-by=-1 \
	    --syntax-highlighting=none -c ../doc/report.css \
	    -o build/$*.html
	chromium --headless --no-pdf-header-footer --print-to-pdf=$@ build/$*.html 2>/dev/null

# raz, its library and its tools go together under $(PREFIX)/lib/raz,
# laid out as in the tarball; the link on PATH works since raz finds
# lib/ beside its real path, and a program's make finds tools/ so.
# raztest, tools/Test.raz, is built onto PATH by this raz. The manual
# pages go where man looks, beside bin.
PREFIX = $(HOME)/.local
MAN = $(PREFIX)/share/man
TOOLS = Pretty Doc Scan Test

install: raz build/raz-lib.3
	rm -rf $(PREFIX)/lib/raz
	mkdir -p $(PREFIX)/lib/raz/tools $(PREFIX)/bin $(MAN)/man1 $(MAN)/man3 $(MAN)/man7
	cp -r raz lib $(PREFIX)/lib/raz
	cp $(TOOLS:%=tools/%.raz) $(PREFIX)/lib/raz/tools
	ln -sf $(PREFIX)/lib/raz/raz $(PREFIX)/bin/raz
	./raz -Werror -o $(PREFIX)/bin/raztest tools/Test.raz
	cp doc/raz.1 doc/raztest.1 $(MAN)/man1
	cp build/raz-lib.3 $(MAN)/man3/raz-lib.3
	cp doc/raz.7 doc/raz-tutorial.7 $(MAN)/man7

uninstall:
	rm -rf $(PREFIX)/lib/raz $(PREFIX)/bin/raz $(PREFIX)/bin/raztest \
	    $(MAN)/man1/raz.1 $(MAN)/man1/raztest.1 $(MAN)/man3/raz-lib.3 \
	    $(MAN)/man7/raz.7 $(MAN)/man7/raz-tutorial.7

# A release's tarball, build/raz-V-linux-x86_64.tar.gz: raz, the lib/
# it reads beside itself, the tools a program's make may build (the
# formatter, Doc and the Scan they share, and raztest) and the manual
# pages, V being what raz --version says. It is made of the commit
# REV, HEAD unless given: CI packs the tag it checked out, and
# site/Build.raz each tag it lacks. A release whose tag isn't pushed yet
# is made with VERSION, its version without the v: the same tarball as
# the tag's, once the tag is at REV.
#
# The tarball is the same, byte for byte, wherever it is made, so that
# its SHA-256 can be checked against GitHub's or the website's. raz is
# built in a checkout at a fixed place, DIST, since the debugging
# information names the directory it was built in; the archive gives
# every file the commit's time, owner 0 and plain modes, in order of
# name, and gzip leaves out its own date.
REV = HEAD
DIST = /tmp/raz-dist

dist:
	rm -rf $(DIST) && git worktree prune && git worktree add -q --detach $(DIST) $(REV)
	# the tarball BOOT names, if fetched, lent to the checkout (src/boot.sh checks its sum)
	if [ -d build/boot ]; then mkdir -p $(DIST)/build/boot && cp build/boot/*.tar.gz $(DIST)/build/boot/; fi
	$(MAKE) -C $(DIST) raz man
	v=$$($(DIST)/raz --version | sed 's/^raz \([^,]*\),.*/\1/'); \
	d=raz-$$v-linux-x86_64; \
	rm -rf build/$$d && mkdir -p build/$$d/man && \
	cp -r $(DIST)/raz $(DIST)/lib $(DIST)/LICENSE $(DIST)/README.md build/$$d && \
	mkdir build/$$d/tools && cp $(TOOLS:%=$(DIST)/tools/%.raz) build/$$d/tools && \
	cp $(DIST)/doc/raz.1 $(DIST)/doc/raztest.1 $(DIST)/doc/raz.7 $(DIST)/doc/raz-tutorial.7 \
	    $(DIST)/build/raz-lib.3 build/$$d/man && \
	tar -cf - --format=gnu --sort=name --mtime=@$$(git log -1 --format=%ct $(REV)) \
	    --owner=0 --group=0 --numeric-owner --mode=a+rX,u+w,go-w \
	    -C build $$d | gzip -9n > build/$$d.tar.gz && \
	rm -rf build/$$d && echo build/$$d.tar.gz
	git worktree remove --force $(DIST)

# The website, plain files in site/public/: its home page, the tour
# "Raz, Set, Go" (whose programs are run here, so the output shown is
# real), the report and the latest release's tarball. site/Build.raz
# says how; it needs ./raz, pandoc and pdfinfo. RELEASES, "vX.Y.Z=COMMIT ...",
# adds release records to those kept in site/releases. site-source runs
# ladle after the pages: its Git store and releases live under /source/,
# with their headers merged at the upload's root. The pinned ladle is
# bundled for Cloudflare; LADLE may name a locally built one instead.
# The site's programs are raz programs, site/Build.raz, Source.raz and
# Verify.raz, built by this raz into build/site/.
LADLE ?=
build/site/%: site/%.raz site/*.raz raz
	mkdir -p build/site
	./raz -Werror -o $@ site/$*.raz

site: raz pdf build/site/Build
	build/site/Build $(RELEASES)
	$(MAKE) site-source

# Wrangler runs this before deploying the committed pages. The generated
# Git store must never be committed: otherwise later stores contain copies
# of earlier ones. See site/README.md for the release and upload procedure.
site-source: build/site/Source
	build/site/Source $(if $(LADLE),--ladle $(LADLE)) $(RELEASES)

# Checks the site's release selection against small real Git repositories.
site-check: build/site/Verify
	build/site/Verify

.PHONY: docker-image docker-check mac-check docker-shell prev-bench fixpoint check gdb bench kernels stress alpine fmt loc man pdf dist site site-source site-check clean install uninstall

# `make check` in a linux/amd64 container, for a machine that isn't one
# (the repository is mounted at its own path, so git and the tests see
# the same names). DOCKERFLAGS is for what a host's runtime needs.
DOCKER = docker run --rm --platform linux/amd64 $(DOCKERFLAGS) -v $(CURDIR):$(CURDIR) -w $(CURDIR)
DOCKERIMAGE = raz-check
docker-image:
	docker build --platform linux/amd64 -t $(DOCKERIMAGE) containers/check

docker-check: docker-image
	$(DOCKER) $(DOCKERIMAGE) sh -c "git config --global --add safe.directory '*' && make check"

# test/mac's programs (test/mac.sh), on an Apple Silicon Mac: compiled
# for darwin-arm64 by the cross compiler in the container, then run here
mac-check: docker-image
	$(DOCKER) $(DOCKERIMAGE) sh -c "git config --global --add safe.directory '*' && timeout 1200 test/mac.sh build"
	test/mac.sh run

docker-shell: docker-image
	$(DOCKER) -it $(DOCKERIMAGE) sh -c "git config --global --add safe.directory '*' && exec bash"
