#!/usr/bin/env python3
"""Exercise the compiler's library lookup in an isolated environment."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RAZ = str(Path(sys.argv.pop(1)).resolve())


class LibraryPaths(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="raz-path-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.env = dict(os.environ)
        self.env.pop("RAZ_PATH", None)
        self.env.pop("RAZ_PROFILE", None)
        self.env["HOME"] = str(self.root / "home space")
        self.default = Path(self.env["HOME"]) / ".raz/lib"
        self.main = self.root / "src/Main.raz"
        self.write(self.main, """module Main;
import Out, PathLib;
proc main*;
begin Out.int(PathLib.value); Out.ln; end;
end Main.
""")

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def library(self, directory, value=42, suffix=""):
        path = directory / f"PathLib{suffix}.raz"
        self.write(path, f"module PathLib; const value* = {value}; end PathLib.\n")
        return path

    def compile(self, *flags, run=False):
        args = [RAZ, "run"] if run else [RAZ, "-o", str(self.root / "app")]
        return subprocess.run(
            [*args, "-Werror", *map(str, flags), str(self.main)],
            cwd=self.root, env=self.env, text=True, capture_output=True,
        )

    def succeeds(self, *flags, run=False):
        result = self.compile(*flags, run=run)
        self.assertEqual(result.returncode, 0, result.stderr)
        if not run:
            result = subprocess.run(
                [str(self.root / "app")], env=self.env,
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "42\n")

    def fails(self, message, *flags):
        result = self.compile(*flags)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(message, result.stderr)

    def test_default(self):
        self.library(self.default)
        self.succeeds()
        self.succeeds(run=True)

    def test_colon_in_home(self):
        # Unlike RAZ_PATH, HOME is one path, not a list.
        self.env["HOME"] = str(self.root / "home : space")
        self.library(Path(self.env["HOME"]) / ".raz/lib")
        self.succeeds()

    def test_empty_disables_default(self):
        self.library(self.default)
        self.env["RAZ_PATH"] = ""
        self.fails("can't find module PathLib")
        # Explicit dependencies and the bundled standard library still work.
        self.succeeds("-I", self.default)

    def test_list_replaces_default(self):
        self.library(self.default, 99)
        first = self.root / "first directory"
        second = self.root / "second directory"
        self.library(second)
        self.env["RAZ_PATH"] = f"{first}:{second}"
        self.succeeds()
        self.succeeds(run=True)
        self.env["RAZ_PATH"] = str(first)
        self.fails("can't find module PathLib")

    def test_relative_and_empty_entries(self):
        self.library(self.root / "relative")
        # A cwd module must not be found through the empty entries.
        self.library(self.root, 99)
        self.env["RAZ_PATH"] = ":relative::missing:"
        self.succeeds()
        self.env["RAZ_PATH"] = ":::"
        self.fails("can't find module PathLib")

    def test_missing_home(self):
        self.env.pop("HOME")
        self.fails("can't find module PathLib")
        self.env["HOME"] = ""
        self.fails("can't find module PathLib")
        self.library(self.root / "explicit")
        self.env["RAZ_PATH"] = "explicit"
        self.succeeds()

    def test_no_recursion(self):
        self.library(self.default / "package")
        self.fails("can't find module PathLib")
        self.env["RAZ_PATH"] = str(self.default / "package")
        self.succeeds()

    def test_missing_module_lists_all_search_directories(self):
        self.env["RAZ_PATH"] = "first:second"
        result = self.compile("-I", "explicit")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("explicit, first, second,", result.stderr)
        self.assertIn(str(Path(RAZ).parent / "lib"), result.stderr)

    def test_no_path_expansion(self):
        self.library(self.default)
        for path in ("~/.raz/lib", "$HOME/.raz/lib"):
            self.env["RAZ_PATH"] = path
            self.fails("can't find module PathLib")

    def test_target_file_and_interface(self):
        self.library(self.default, suffix=".linux-x86_64")
        self.library(self.default, 99)
        self.succeeds()
        self.write(self.default / "PathLib.raz",
                   "module PathLib; const other* = 42; end PathLib.\n")
        self.fails("isn't exported")

    def test_trailing_slash_keeps_sibling_paths(self):
        directory = self.root / "target"
        chosen = self.library(directory, suffix=".linux-x86_64")
        sibling = directory / "PathLib.raz"
        self.write(sibling, "module PathLib; const other* = 42; end PathLib.\n")
        for source in ("include", "user"):
            with self.subTest(source=source):
                flags = ("-I", str(directory) + "/") if source == "include" else ()
                self.env["RAZ_PATH"] = str(directory) + "/" if source == "user" else ""
                result = self.compile(*flags)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("isn't exported", result.stderr)
                self.assertIn(str(chosen), result.stderr)
                self.assertIn(str(sibling), result.stderr)
                self.assertNotIn("//", result.stderr)

    def test_duplicate_main_and_include(self):
        chosen = self.library(self.default)
        for directory in (self.main.parent, self.root / "include"):
            duplicate = self.library(directory)
            flags = ("-I", directory) if directory != self.main.parent else ()
            self.fails("module PathLib is in", *flags)
            duplicate.unlink()
            duplicate.symlink_to(chosen)
            self.succeeds(*flags)
            duplicate.unlink()

    def test_hard_link_chooses_same_module(self):
        chosen = self.library(self.default)
        duplicate = self.main.parent / chosen.name
        os.link(chosen, duplicate)
        self.succeeds()

    def test_equal_contents_do_not_choose_distinct_module(self):
        chosen = self.library(self.default)
        duplicate = self.main.parent / chosen.name
        self.write(duplicate, chosen.read_text())
        # Selection follows file identity, not equal source text.
        self.fails("module PathLib is in")

    def test_symbolic_link_to_distinct_module_does_not_choose(self):
        self.library(self.default)
        other = self.library(self.root / "elsewhere")
        (self.main.parent / other.name).symlink_to(other)
        self.fails("module PathLib is in")

    def test_duplicate_user_directories(self):
        self.library(self.default)
        other = self.root / "other"
        self.library(other)
        self.env["RAZ_PATH"] = f"{self.default}:{other}"
        self.fails("module PathLib is in")
        self.env["RAZ_PATH"] = f"{self.default}:{self.default}"
        self.succeeds()

    def test_duplicate_standard_library(self):
        self.library(self.default)
        self.write(self.default / "Out.raz", "module Out; end Out.\n")
        self.fails("module Out is in")

    def test_user_paths_do_not_consume_include_slots(self):
        self.library(self.default)
        flags = [arg for _ in range(16) for arg in ("-I", "missing")]
        self.succeeds(*flags)
        self.env["RAZ_PATH"] = ":".join(["missing"] * 32 + [str(self.default)])
        self.succeeds(*flags)


if __name__ == "__main__":
    unittest.main()
