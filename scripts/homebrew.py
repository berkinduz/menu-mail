#!/usr/bin/env python3
"""Generate or check a release-pinned cask using local packaged app metadata."""

import argparse
import hashlib
import pathlib
import plistlib
import re
import subprocess
import sys


PROJECT = pathlib.Path(__file__).resolve().parents[1]


def render_cask(artifact, app):
    if artifact.name not in ("Envl.dmg", "Envl.zip"):
        raise ValueError("artifact must be named Envl.dmg or Envl.zip")
    if not artifact.is_file() or artifact.stat().st_size == 0:
        raise ValueError("a nonempty local release artifact is required")
    with (app / "Contents" / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "app.menumail.desktop":
        raise ValueError("app must use the Envl bundle identifier")
    version = info.get("CFBundleShortVersionString", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", version):
        raise ValueError("app version must be a release version such as 0.2.0")
    if info.get("LSMinimumSystemVersion") not in ("14.0", "14.0.0"):
        raise ValueError("update the cask macOS requirement to match the packaged app")
    checksum = hashlib.sha256()
    with artifact.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return '''cask "envl" do
  version "{version}"
  sha256 "{checksum}"

  url "https://github.com/berkinduz/menu-mail/releases/download/v#{{version}}/{filename}"
  name "Envl"
  desc "Read your Apple Mail inbox from the menu bar"
  homepage "https://github.com/berkinduz/menu-mail"

  depends_on macos: ">= :sonoma"

  app "Envl.app"
end
'''.format(version=version, checksum=checksum.hexdigest(), filename=artifact.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=pathlib.Path, default=PROJECT / "build" / "Envl.dmg")
    parser.add_argument("--app", type=pathlib.Path, default=PROJECT / "build" / "Envl.app")
    parser.add_argument("--output", type=pathlib.Path, default=PROJECT / "build" / "homebrew" / "Casks" / "envl.rb")
    parser.add_argument("--check", action="store_true", help="check an existing cask without modifying it")
    arguments = parser.parse_args()
    try:
        cask = render_cask(arguments.artifact, arguments.app)
        if arguments.check and arguments.output.read_text() != cask:
            raise ValueError("cask does not match the current app version and artifact checksum; regenerate it")
        syntax = subprocess.run(["ruby", "-c"], input=cask, capture_output=True, text=True)
        if syntax.returncode != 0:
            raise ValueError("generated cask failed Ruby syntax validation: " + syntax.stderr.strip())
        if not arguments.check:
            arguments.output.parent.mkdir(parents=True, exist_ok=True)
            arguments.output.write_text(cask)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print("Cask error: {}".format(error), file=sys.stderr)
        return 1
    print("Cask {}: {}".format("checked" if arguments.check else "generated", arguments.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
