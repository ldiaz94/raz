#!/usr/bin/env python3
"""Compile through a replacement host with independent arguments and policy."""

import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


RAZ = str(Path(sys.argv.pop(1)).resolve())
ROOT = Path(__file__).resolve().parents[1]


class CompilerHost(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.staging = tempfile.TemporaryDirectory(prefix="raz-compiler-host-")
        cls.addClassCleanup(cls.staging.cleanup)
        cls.stage = Path(cls.staging.name)
        sources = cls.stage / "src"
        sources.mkdir()
        for source in (ROOT / "src").glob("*.raz"):
            shutil.copyfile(source, sources / source.name)
        shutil.copyfile(ROOT / "test/host/Host.raz", sources / "Host.raz")
        cls.compiler = cls.stage / "bin/compiler"
        cls.compiler.parent.mkdir()
        result = subprocess.run(
            [RAZ, "-Werror", "-I", str(sources), "-I", str(ROOT / "build/src"),
             "-o", str(cls.compiler), str(sources / "Raz.raz")],
            cwd=ROOT, text=True, capture_output=True,
        )
        if result.returncode:
            raise RuntimeError("replacement-host compiler build failed:\n" + result.stderr)
        cls.library = cls.stage / "library"
        shutil.copytree(ROOT / "lib", cls.library)
        (cls.library / "HostValue.raz").write_text(
            "module HostValue; const value* = 42; end HostValue.\n")

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="raz-host-case-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.source = self.root / "Main.raz"
        self.source.write_text("""module Main;
import Out, HostValue;
proc main*;
begin Out.int(HostValue.value); Out.ln; end;
end Main.
""")
        self.output = self.root / "program"
        self.env = dict(os.environ)
        self.env["RAZ_PATH"] = ""
        self.env["NO_COLOR"] = "1"
        self.env.pop("RAZ_PROFILE", None)
        for key in tuple(self.env):
            if key.startswith("RAZ_TEST_"):
                del self.env[key]
        self.env["RAZ_TEST_LIBRARY"] = str(self.library)

    def invoke(self, *arguments, **settings):
        arguments = ["/synthetic/compiler", *map(str, arguments)]
        self.env["RAZ_TEST_COUNT"] = str(len(arguments))
        for i, value in enumerate(arguments):
            self.env[f"RAZ_TEST_ARG{i}"] = value
        for key, value in settings.items():
            self.env["RAZ_TEST_" + key.upper()] = str(value)
        # None of these is a valid source path or compiler option. The host's
        # synthetic argv must be the only input to the compiler driver.
        return subprocess.run(
            [str(self.compiler), "--not-a-real-option", "ignored", "raw", "argv"],
            cwd=self.root, env=self.env, text=True, capture_output=True,
        )

    def compile(self, **settings):
        return self.invoke("-Werror", "-o", self.output, self.source, **settings)

    def test_arguments_library_and_writer(self):
        result = self.compile()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.access(self.output, os.X_OK))
        result = subprocess.run([str(self.output)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "42\n")

    def test_unsupported_run_precedes_source_access(self):
        result = self.invoke("run", self.root / "missing.raz")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("run", result.stderr)
        self.assertIn("support", result.stderr)
        self.assertNotIn("can't open", result.stderr)

    def test_unsupported_c_output(self):
        self.source.write_text("""module Main;
extern proc getpid: I32;
proc main*;
begin _ := getpid(); end;
end Main.
""")
        result = self.compile()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("C", result.stderr)
        self.assertIn("support", result.stderr)
        self.assertFalse(self.output.exists())

    def test_writer_refusal(self):
        result = self.compile(write="refuse")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("can't write", result.stderr)
        self.assertFalse(self.output.exists())

    def test_run_preparation_refusal(self):
        executable = self.root / "prepared-run-file"
        marker = self.root / "execute-marker"
        result = self.invoke("run", self.source, run="yes", prepare="refuse",
                             run_path=executable, exec_marker=marker)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("host run preparation failed", result.stderr)
        self.assertFalse(executable.exists())
        self.assertFalse(marker.exists())

    def test_run_preparation_and_execution(self):
        executable = self.root / "prepared-run-file"
        marker = self.root / "execute-marker"
        result = self.invoke("run", self.source, run="yes", run_path=executable,
                             exec_marker=marker)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("can't run", result.stderr)
        self.assertTrue(executable.read_bytes().startswith(b"\x7fELF"))
        self.assertEqual(marker.read_text(), str(executable))

    def test_c_library_preference(self):
        self.source.write_text("""module Main;
extern proc getpid: I32;
proc main*;
begin _ := getpid(); end;
end Main.
""")
        result = self.compile(c="yes", musl="yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"/lib/ld-musl-x86_64.so.1\0", self.output.read_bytes())

    def test_bare_high_address_output(self):
        self.source.write_text(
            "module Main; proc main*; begin end; end Main.\n")
        base = 0xffffffff80000000
        result = self.invoke("-bare", "-s", "-base", "0FFFFFFFF80000000H",
                             "-o", self.output, self.source)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = self.output.read_bytes()
        self.assertEqual(data[:7], b"\x7fELF\x02\x01\x01")
        entry, phoff = struct.unpack_from("<QQ", data, 24)
        size, count = struct.unpack_from("<HH", data, 54)
        self.assertGreaterEqual(entry, base)
        loads = []
        for index in range(count):
            kind, flags, offset, virtual, physical, files, memory, alignment = (
                struct.unpack_from("<IIQQQQQQ", data, phoff + index * size))
            self.assertNotIn(kind, (2, 3))  # no dynamic table or interpreter
            if kind != 1:
                continue
            self.assertGreaterEqual(virtual, base)
            self.assertEqual(physical, virtual)
            self.assertEqual(alignment, 4096)
            self.assertEqual(offset % alignment, virtual % alignment)
            self.assertIn(flags, (4, 5, 6))
            self.assertLessEqual(files, memory)
            loads.append((flags, virtual, files))
        self.assertTrue(any(flags == 5 and start <= entry < start + files
                            for flags, start, files in loads))


if __name__ == "__main__":
    unittest.main()
