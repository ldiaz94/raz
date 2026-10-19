#!/usr/bin/env python3
"""Check release selection with real git histories: python3 site/check.py.

Uses Python's standard library and git. All repositories and downloads
are temporary; no release, working checkout or published file is changed.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest

from releases import refs
import source


class Releases(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.repo = self.directory / "repo"
        self.repo.mkdir()
        self.git("init", "--quiet", "--initial-branch=main")
        (self.repo / "site").mkdir()
        self.manifest = self.repo / "site/releases"
        self.manifest.write_text("# distributions\n")
        self.commits = []
        for number, version in enumerate(("v0.7.1", "v0.9.0", "v0.10.0")):
            (self.repo / "file").write_text(str(number))
            self.git("add", ".")
            self.git("commit", "--quiet", "-m", version)
            self.commits.append(self.git("rev-parse", "HEAD"))
            self.git("tag", version)
        self.manifest.write_text(f"# not tagged yet\nv0.20.0 {self.commits[-1]}\n")
        self.git("add", "site/releases")
        self.git("commit", "--quiet", "-m", "record distribution")

    def git(self, *args, repo=None):
        return subprocess.check_output([
            "git", "-C", str(repo or self.repo), "-c", "user.name=Test",
            "-c", "user.email=test@example.org", "-c", "commit.gpgSign=false", *args,
        ], text=True).strip()

    def test_numeric_tags_and_manifest(self):
        self.assertEqual(refs(self.repo), list(zip(
            ("v0.7.1", "v0.9.0", "v0.10.0", "v0.20.0"),
            self.commits + [self.commits[-1]],
        )))

    def test_manifest_cannot_move_a_tag(self):
        self.manifest.write_text(f"v0.9.0 {self.commits[0]}\n")
        with self.assertRaisesRegex(ValueError, "disagree"):
            refs(self.repo)

    def test_manifest_cannot_publish_another_line(self):
        self.git("checkout", "--quiet", "-b", "side", self.commits[0])
        (self.repo / "side").write_text("a development branch\n")
        self.git("add", "side")
        self.git("commit", "--quiet", "-m", "side")
        side = self.git("rev-parse", "HEAD")
        self.git("checkout", "--quiet", "main")
        self.manifest.write_text(f"v0.20.0 {side}\n")
        with self.assertRaisesRegex(ValueError, "first-parent"):
            refs(self.repo)
        # A new tag must not override the recorded distribution, even
        # when that tag would otherwise be skipped as off the main line.
        self.manifest.write_text(f"v0.20.0 {self.commits[-1]}\n")
        self.git("tag", "v0.20.0", side)
        with self.assertRaisesRegex(ValueError, "disagree"):
            refs(self.repo)

    def test_shallow_deploy_recovers_history_and_tags(self):
        # A file URL uses git's transport, so --depth really is shallow.
        clone = self.directory / "deploy"
        self.git("clone", "--quiet", "--depth=1", "--branch=main", self.repo.as_uri(), str(clone))
        self.assertEqual(self.git("rev-parse", "--is-shallow-repository", repo=clone), "true")
        self.assertEqual(refs(clone), refs(self.repo))
        self.assertEqual(self.git("rev-parse", "--is-shallow-repository", repo=clone), "false")

    def test_detached_shallow_deploy_needs_no_local_main(self):
        clone = self.directory / "deploy"
        self.git("clone", "--quiet", "--depth=1", "--branch=main", self.repo.as_uri(), str(clone))
        self.git("checkout", "--quiet", "--detach", repo=clone)
        self.git("branch", "-D", "main", repo=clone)
        self.assertEqual(refs(clone), refs(self.repo))
        original = source.ROOT
        self.addCleanup(setattr, source, "ROOT", original)
        source.ROOT = clone
        store = source.prepare_store(self.directory)
        self.assertEqual(self.git("rev-parse", "HEAD", repo=store), self.git("rev-parse", "HEAD", repo=clone))
        self.assertEqual(self.git("symbolic-ref", "HEAD", repo=store), "refs/heads/main")
        self.git("fsck", "--strict", repo=store)
        self.assertEqual(self.git("rev-parse", "--abbrev-ref", "HEAD", repo=clone), "HEAD")

    def test_modified_builder_is_rejected_before_unpacking(self):
        packed = self.directory / "ladle.gz"
        packed.write_bytes(b"not the published executable")
        packed.with_name("ladle.gz.sha256").write_text("0" * 64 + "  ladle.gz\n")
        original = source.LADLE
        self.addCleanup(setattr, source, "LADLE", original)
        source.LADLE = packed
        with self.assertRaisesRegex(ValueError, "recorded SHA-256"):
            source.pinned_ladle()


if __name__ == "__main__":
    unittest.main()
