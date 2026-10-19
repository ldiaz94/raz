# Handover

## Website source integration, 2026-10-19

`make site` now adds ladle's source browser, history, release pages
and a dumb-HTTP clone store under `/source/`. The existing Cloudflare
deploy command stays `npx wrangler deploy`; its custom build hook runs
`make site-source` before uploading. The source output is ignored,
avoiding a Git store that contains copies of its own earlier builds.
The compressed static ladle executable is pinned at 509b9d3 with its
checksum and build instructions in `site/tools/`.

`site/releases` records the existing v0.18.1, v0.19.0 and v0.20.0
website distributions at the commits below. Both site builders read
it, so a plain build keeps v0.20.0 as the latest download. All
original compiler archives and their published checksums keep their
bytes. Each supported version also has a source archive; the three
untagged versions have notes under `site/release-notes/` explaining
their status. No compiler release or tag was created here.

The root `_headers` carries scoped `/source/` rules, including the
canonical release-page URLs Cloudflare serves. Other pages keep their
existing policy; `/download/latest` keeps its redirect. `site/README.md`
gives the full build and verification procedure. The bundled builder
needs only Python 3 and git on x86-64 Linux. A shallow deployment
checkout fetches the full history and tags from its own origin.

Checks before pushing: `make check` (1,012 checks), `make site`, six
Git and checksum checks in `site/check.py`, and Wrangler's actual
custom build in a deploy dry run. The existing report PDFs were
reused; Pandoc 3.8 rebuilds the HTML report as before. Live deployment
and HTTP download/clone verification follow the push to main.

## Releases, 2026-10-19

The tags v0.18.1, v0.19.0, v0.20.0 and v0.21.0 are pushed, oldest
first, each annotated with what `raz --version` prints at its commit.
The session that pushed them couldn't see the repository through `gh`,
so it didn't see CI's runs or releases. Check each release, and its
tarball's SHA-256 against the website's, which `make dist` made the
same, byte for byte:

    gh run list -R ldiaz94/raz
    gh release download vX.Y.Z -R ldiaz94/raz -p '*.tar.gz'
    sha256sum raz-X.Y.Z-linux-x86_64.tar.gz
    cat site/public/download/raz-X.Y.Z-linux-x86_64.tar.gz.sha256

`BOOT` names v0.20.0 (`bfa954d2...`); if CI's v0.20.0 differs, the
website's copy is wrong and must be replaced by CI's, and `BOOT` with
it. A run that failed because the release before it wasn't out yet
is run again from the Actions tab. Delete this section once all four
are checked.

## What comes next

Not started; each the owner's call. `PROPOSALS.md` and
`MEM_PROPOSAL.md` hold what waits for a later thaw.
