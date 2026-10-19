#!/usr/bin/env python3
"""Build the static source browser and releases after site/build.py.

Uses git, ladle and Python's standard library. Reads committed main and
the existing, checksummed compiler distributions; writes only the website.
It does not build compilers, create tags, upload files or deploy the site.
The layout and publishing rules are in site/README.md.
"""

import argparse
import gzip
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit

from releases import main_ref, refs


ROOT = Path(__file__).resolve().parent.parent
PUBLIC = ROOT / "site/public"
URL = "https://raz.lucelad.workers.dev/source/"
LADLE = ROOT / "site/tools/ladle.gz"
BEGIN_HEADERS = "# BEGIN ladle source\n"
END_HEADERS = "# END ladle source\n"
MAX_FILES = 20000
MAX_FILE_BYTES = 25 * 1024 * 1024


def git(repo, *args):
    """Read git's text output, failing at the command that went wrong."""
    return subprocess.check_output(
        ["git", "-C", str(repo), *args], text=True
    ).strip()


def prepare_store(directory):
    """Clone main independently, keeping only tags whose commits it reaches."""
    store = directory / "raz.git"
    branch = ["--branch", "main"] if main_ref(ROOT) != "HEAD" else []
    subprocess.run([
        "git", "clone", "--quiet", "--bare", "--single-branch",
        "--no-local", *branch, str(ROOT), str(store),
    ], check=True)
    # Deployment checkouts can be detached and have no local branch.
    # Name their commit only inside this temporary published store.
    if not branch:
        git(store, "update-ref", "refs/heads/main", git(store, "rev-parse", "HEAD"))
        git(store, "symbolic-ref", "HEAD", "refs/heads/main")
    reachable = set(git(store, "rev-list", "main").splitlines())
    for tag in git(store, "tag", "--list").splitlines():
        # Tags of trees or blobs are not cloneable releases. Ask quietly:
        # such a tag is valid git, simply outside the published history.
        result = subprocess.run(
            ["git", "-C", str(store), "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"],
            capture_output=True, text=True,
        )
        if result.returncode or result.stdout.strip() not in reachable:
            git(store, "update-ref", "-d", f"refs/tags/{tag}")
    git(store, "repack", "-a", "-d", "--max-pack-size=20m")
    git(store, "update-server-info")
    return store


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def published_sum(path):
    """Read the original checksum; never replace it to fit different bytes."""
    checksum = path.with_name(path.name + ".sha256")
    words = checksum.read_text().split()
    if len(words) != 2 or not re.fullmatch(r"[0-9a-f]{64}", words[0]) or words[1] != path.name:
        raise ValueError(f"{checksum}: expected SHA-256 and {path.name}")
    return words[0]


def pinned_ladle():
    """Unpack the checked-in static builder, needing no compiler or network."""
    packed = LADLE.read_bytes()
    if hashlib.sha256(packed).hexdigest() != published_sum(LADLE):
        raise ValueError(f"{LADLE}: differs from its recorded SHA-256")
    executable = ROOT / "build/site/ladle"
    executable.parent.mkdir(parents=True, exist_ok=True)
    # Rename a new inode into place: another build may still be running
    # the previous executable, which cannot be overwritten on Linux.
    with tempfile.NamedTemporaryFile(dir=executable.parent, delete=False) as output:
        temporary = Path(output.name)
        output.write(gzip.decompress(packed))
    temporary.chmod(0o755)
    temporary.replace(executable)
    return executable


def compiler_archive(version, directory):
    """Copy the distribution, checking its existing published checksum."""
    name = f"raz-{version[1:]}-linux-x86_64.tar.gz"
    original = PUBLIC / "download" / name
    expected = published_sum(original)
    copied = directory / name
    shutil.copyfile(original, copied)
    if digest(copied) != expected:
        raise ValueError(f"{original}: differs from its published SHA-256")


def source_archive(store, version, commit, directory):
    """Archive the exact commit, with no wall-clock time or filename in gzip."""
    name = f"raz-{version[1:]}-source.tar.gz"
    with (directory / name).open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
            with subprocess.Popen([
                "git", "-C", str(store), "archive", "--format=tar",
                f"--prefix=raz-{version[1:]}/", commit,
            ], stdout=subprocess.PIPE) as process:
                shutil.copyfileobj(process.stdout, compressed)
                if process.wait():
                    raise ValueError(f"release {version}: git archive failed")


def stage_releases(store, directory, selected):
    line = set(git(store, "rev-list", "--first-parent", "main").splitlines())
    for version, commit in selected:
        # Ref resolution is shared with build.py. Check against our snapshot
        # too, so a commit made during the build cannot split their histories.
        if commit not in line:
            raise ValueError(f"release {version}: {commit} is not in the cloned main history")
        release = directory / version
        release.mkdir(parents=True)
        (release / "commit").write_text(commit + "\n")
        notes = ROOT / "site/release-notes" / (version + ".md")
        if notes.exists():
            shutil.copyfile(notes, release / "notes.md")
        compiler_archive(version, release)
        source_archive(store, version, commit, release)


def export_store(store, output):
    """Export only the dumb-HTTP store, never configuration or local paths."""
    for name in ("HEAD", "info/refs", "objects/info/packs"):
        destination = output / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(store / name, destination)
    shutil.copytree(store / "objects/pack", output / "objects/pack")


def merged_headers(generated):
    """Replace our scoped block while keeping the host's other header rules."""
    path = PUBLIC / "_headers"
    existing = path.read_text() if path.exists() else ""
    if BEGIN_HEADERS in existing:
        before, _, rest = existing.partition(BEGIN_HEADERS)
        _, found, after = rest.partition(END_HEADERS)
        if not found:
            raise ValueError(f"{path}: source header block has no closing marker")
        existing = before + after
    scoped = "\n".join(
        "/source" + line if line.startswith("/") else line
        for line in generated.splitlines()
    ) + "\n"
    return existing.rstrip() + "\n\n" + BEGIN_HEADERS + scoped + END_HEADERS


def check_limits(source, headers):
    """Measure the proposed complete output, counting the new source tree once."""
    paths = [path for path in PUBLIC.rglob("*")
             if path.is_file() and "source" != path.relative_to(PUBLIC).parts[0]
             and path != PUBLIC / "_headers"]
    paths.extend(path for path in source.rglob("*") if path.is_file())
    sizes = [(str(path), path.stat().st_size) for path in paths]
    sizes.append((str(PUBLIC / "_headers"), len(headers.encode())))
    for name, size in sizes:
        if size > MAX_FILE_BYTES:
            raise ValueError(f"{name}: {size} bytes exceeds the 25 MiB file limit")
    if len(sizes) > MAX_FILES:
        raise ValueError(f"site: {len(sizes)} files exceeds the {MAX_FILES} file limit")
    print(f"site/public: {len(sizes)} files, {sum(size for _, size in sizes)} bytes; "
          f"largest file {max(size for _, size in sizes)} bytes")


def build(ladle=None, url=URL, extra=()):
    address = urlsplit(url)
    if address.scheme not in ("http", "https") or not address.netloc or address.path != "/source/" or address.query or address.fragment:
        raise ValueError("--url must be an HTTP(S) address ending in /source/")
    if not PUBLIC.is_dir():
        raise ValueError("site/public is missing; run site/build.py first")
    selected = refs(ROOT, extra)  # complete a shallow deployment checkout before cloning
    if ladle is None:
        ladle = pinned_ladle()
    # Build separately: a failed checksum, ladle run or host-limit check
    # leaves the previous source browser in place. Nothing reads that output.
    with tempfile.TemporaryDirectory(prefix="raz-source-") as temporary:
        directory = Path(temporary)
        store = prepare_store(directory)
        releases = directory / "releases"
        stage_releases(store, releases, selected)
        output = directory / "source"
        output.mkdir()
        export_store(store, output)
        subprocess.run([
            str(ladle), "-u", url, "-r", str(releases),
            "-t", str(ROOT / "site/source.theme"), "-o", str(output), str(store),
        ], check=True)
        headers = merged_headers((output / "_headers").read_text())
        check_limits(output, headers)
        destination = PUBLIC / "source"
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(output), destination)
        (PUBLIC / "_headers").write_text(headers)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ladle", type=Path, help="override the checked-in static ladle executable")
    parser.add_argument("--url", default=URL, help="the site's absolute /source/ address")
    parser.add_argument("releases", nargs="*", metavar="vX.Y.Z=COMMIT", help="additional existing distributions")
    args = parser.parse_args()
    try:
        extra = []
        for release in args.releases:
            version, separator, commit = release.partition("=")
            if not separator or not commit:
                raise ValueError(f"{release}: expected vX.Y.Z=COMMIT")
            extra.append((version, commit))
        build(args.ladle.resolve() if args.ladle else None, args.url, extra)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"source: {error}\n")


if __name__ == "__main__":
    main()
