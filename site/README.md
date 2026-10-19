# Building raz's website

`make site` builds the pages, tours, reports and downloads with
`build.py`, then the source browser and release pages with `source.py`.
The latter needs git and Python 3 on x86-64 Linux. Its pinned static
ladle executable is kept compressed under `tools/`, with a checksum
and build instructions. The helper verifies the compressed bytes,
unpacks it into `build/site/ladle` and runs it. No compiler or network
connection is needed with a full checkout. If a deployment service
clones shallowly, the helper first fetches the full history and tags
from that checkout's origin, using its existing repository access.

The existing `/download/` URLs and archives stay as they are. Before
attaching an archive to a release, `source.py` checks its bytes against
the published checksum beside it. It fails if either is missing or
the sum differs; it never replaces that checksum to fit new bytes.

## The source browser

`source.py` makes a fresh bare clone of `main`, with its reachable
tags, using `--single-branch --no-local`. Other branches, reflogs and
unreachable tags are not published. The store is repacked with a
20 MiB target, and `git update-server-info` prepares it for cloning
over plain HTTP. The exported files are only `HEAD`, `info/refs`,
`objects/info/packs` and `objects/pack/`: no git configuration, hooks
or local paths. ladle writes the pages beside these files.

The clone's committed tree is the source of every page. A detached
deployment checkout is supported too: the publishing service chooses
main, and the helper names its commit `main` only in the temporary
store. Uncommitted
files and the generated source site do not enter it. In particular,
`public/source/` must stay ignored: committing a source browser's own
output would publish a copy of the previous output on the next build.

The result lives at `public/source/`, browsed and cloned at
<https://raz.lucelad.workers.dev/source/>. To build just this part,
after the normal downloads exist:

```sh
make site-source
```

Or run `python3 site/source.py` directly. `--ladle /path/to/ladle`
overrides the bundled executable for development. `--url` may give
another absolute address ending in `/source/`, for
previewing the feeds and clone line. `source.theme` starts from
ladle's paper theme, with raz's page and link colours; ladle checks
its light and dark contrast when it runs.

## Releases and downloads

Each supported tag from `v0.7.1` onward gets its existing Linux
x86-64 compiler archive and a separate source archive of the tagged
commit. Source archives use `git archive` and gzip without a timestamp;
their names include the version, and they do not include submodules.
ladle writes each artifact's size and SHA-256 on its release page,
with a downloadable `.sha256` beside it.

`releases` lists distributions whose tags have not yet been pushed:
one `vX.Y.Z FULL_COMMIT_HASH` per line, with `#` comments. The commit
must be on `main`'s first-parent line. A tag added later must name the
same commit; otherwise the build fails. Remove a manifest row only
after that tag exists. This records existing distributions; the site
build never creates tags or compiler releases.

`release-notes/vX.Y.Z.md`, when present, supplies that version's notes.
Otherwise an annotated tag supplies them.

Both builders read this list through `releases.py`, so the home page
and source browser offer the same versions. An existing distribution
can also be given as `vX.Y.Z=COMMIT` on either helper's command line;
`make site RELEASES='vX.Y.Z=COMMIT'` passes it to both. Permanent
distributions belong in the manifest rather than a remembered command.

## Headers and hosting

ladle's header rules are prefixed with `/source` and merged into the
root `public/_headers` between marked comments. Rebuilding replaces
that block, preserving other root rules. Its general security policy
therefore applies only to `/source/*`, including raw files and git
objects. `source.py` never changes `_redirects`, so `/download/latest`
continues to work. Cloudflare reads the root header file; the nested
one is not enough.

The new source tree is built in a temporary directory before replacing
the old one. The complete output is counted before it is installed:
at most 20,000 files, each at most 25 MiB. A 20 MiB pack target is not
a guarantee, since git may place a larger object in its own pack.
The final file check catches that too. No total-byte limit is assumed;
the build prints total bytes for review against the hosting plan.

Before deploying, serve `public/` locally, clone `/source/` and run
`git fsck` in the clone. Download a compiler and its checksum from a
release page, check it, then unpack it and compile Hello. Repeat the
clone and download checks against the live address after deployment;
a local file server does not test Cloudflare's headers.

`python3 site/check.py` checks release identity and ordering against
small real Git repositories, including shallow deployment checkouts,
and rejects a damaged bundled builder. `make check` remains the
compiler's required check before committing.

The Wrangler configuration runs `make site-source` before deployment.
The usual `npx wrangler deploy` therefore generates the ignored source
browser from the committed repository before uploading the assets.
It uses the already generated main pages and distributions; it does
not run the compiler, pandoc or the tours on the deployment machine.
