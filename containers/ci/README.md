# raz CI image

`0.21.0-debian12-r1` is an x86-64 Linux build environment containing the
released raz 0.21.0, concha and robbie. Debian 12 slim provides Bash, the
normal `/bin/sh`, Make, Git, curl, CA certificates, Python 3, C/C++ build
tools, pkg-config, groff, bsdextrautils (including `col`), procps
(including external `kill`) and timezone
data. No entrypoint replaces the
command supplied by CI; the default command is Bash.

Build from the repository root:

```sh
docker build --platform linux/amd64 \
  -t raz:0.21.0-debian12-r1 containers/ci
docker run --rm raz:0.21.0-debian12-r1 \
  sh /usr/local/share/raz-ci/smoke.sh
docker save raz:0.21.0-debian12-r1 | python3 containers/ci/check-layers.py
```

Behind a TLS-inspecting proxy, supply a combined trusted CA bundle through
BuildKit, without adding it to the image:

```sh
docker build --platform linux/amd64 \
  --secret id=proxy_ca,src=/path/to/combined-ca-bundle.pem \
  -t raz:0.21.0-debian12-r1 containers/ci
```

The build verifies the release archive against the SHA-256 published with
raz's distribution, fetches the exact source commits recorded in
`build-tools.sh`, and runs rzone's checks and concha's and robbie's test
suites before installing the programs. The final image also compiles and
runs static and glibc-linked raz programs, compiles its formatter and
executes both added tools.
`/usr/local/share/raz-ci/versions.txt` records application versions and
`packages.txt` records installed Debian packages. License files and tool
manual pages are included. rzone is compiled into concha and is not
installed as a global source library.

Robbie's pinned source uses raz 0.18.0's library interfaces. Its latest
commit changes the declared compiler version without porting those calls,
so the build explicitly selects the verified 0.18.0 release and overrides
`RAZVERSION` for robbie's tests and installation. The bootstrap compiler
and its library stay in the build stage. Only raz 0.21.0 is installed in
the final image. `versions.txt` records both archive checksums and the
compiler used to build robbie.

The compiler, its standard library, source tools and release documentation
live together under `/opt/raz`. `/usr/local/bin/raz` is a symlink to the
actual executable. `RAZ_PATH` is left unset: the 0.21.0 release predates
support for this variable.

Use the image to build a checked-out project:

```sh
docker run --rm -v "$PWD:/workspace" raz:0.21.0-debian12-r1 make check
docker run --rm -v "$PWD:/workspace" raz:0.21.0-debian12-r1 robbie check
```

The working directory is `/workspace`. Containers run as root by default,
so bind-mounted build outputs are owned by root on Linux. Pass
`--user "$(id -u):$(id -g)"` when the project supports an arbitrary user;
set `HOME` to a writable directory if its build tools need one.

The base image is pinned by its amd64 manifest digest. Debian packages are
installed from the configured repositories at build time, so rebuilding
may receive package updates. Publish each image revision once and pin the
published image digest in downstream CI for an exact environment. Keep
`0.21.0-debian12-r1` immutable; use `r2` for a changed tool revision, base,
or package refresh. Registry deployment and publishing are documented in
the repository's `registry/` directory.

The layer check streams the export and measures each layer's gzip size,
without extracting the image. Every layer must stay below 90,000,000 bytes,
leaving room beneath Cloudflare's 100 MB request-body limit. Package
installation is split across layers for this reason. Run the check before
publishing any changed image; a local registry does not enforce the edge
request limit. Downstream projects adding large layers must also respect it.
