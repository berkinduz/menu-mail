#!/usr/bin/env python3
"""Exercise local cask generation without builds, downloads or credentials."""

import hashlib
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


PROJECT = pathlib.Path(__file__).resolve().parents[1]
GENERATOR = PROJECT / "scripts" / "homebrew.py"


class HomebrewGenerationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="menumail-cask-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.artifact = self.root / "Envl.dmg"
        self.artifact.write_bytes(b"synthetic distribution fixture\n")
        self.app = self.root / "Envl.app"
        (self.app / "Contents").mkdir(parents=True)
        self.write_plist("0.2.0")
        self.output = self.root / "homebrew" / "Casks" / "envl.rb"

    def write_plist(self, version):
        with (self.app / "Contents" / "Info.plist").open("wb") as stream:
            plistlib.dump({
                "CFBundleIdentifier": "app.menumail.desktop",
                "CFBundleShortVersionString": version,
                "LSMinimumSystemVersion": "14.0",
            }, stream)

    def run_generator(self, *arguments):
        return subprocess.run([
            sys.executable, str(GENERATOR),
            "--artifact", str(self.artifact),
            "--app", str(self.app),
            "--output", str(self.output),
            *arguments,
        ], capture_output=True, text=True)

    def test_generates_version_and_real_artifact_checksum(self):
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        cask = self.output.read_text()
        digest = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
        self.assertIn('version "0.2.0"', cask)
        self.assertIn('sha256 "{}"'.format(digest), cask)
        self.assertIn('/releases/download/v#{version}/Envl.dmg"', cask)
        self.assertIn('depends_on macos: ">= :sonoma"', cask)
        self.assertIn('app "Envl.app"', cask)
        syntax = subprocess.run(["ruby", "-c", str(self.output)], capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)

    def test_check_rejects_an_artifact_changed_after_generation(self):
        generated = self.run_generator()
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.artifact.write_bytes(b"changed distribution fixture\n")
        checked = self.run_generator("--check")
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("does not match", checked.stderr)

    def test_check_rejects_an_unpinned_cask(self):
        generated = self.run_generator()
        self.assertEqual(generated.returncode, 0, generated.stderr)
        cask = self.output.read_text()
        digest = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
        self.output.write_text(cask.replace('sha256 "{}"'.format(digest), "sha256 :no_check"))
        checked = self.run_generator("--check")
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("does not match", checked.stderr)

    def test_rejects_a_version_that_could_change_the_ruby_program(self):
        self.write_plist('0.2.0"; system("false")')
        result = self.run_generator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
