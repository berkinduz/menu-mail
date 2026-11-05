#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

verify_app() {
    local app="$1"
    plutil -lint "$app/Contents/Info.plist"
    lipo "$app/Contents/MacOS/Envl" -verify_arch arm64 x86_64
    codesign --verify --deep --strict "$app"
}

verify_app "$project_dir/build/Envl.app"
hdiutil verify "$project_dir/build/Envl.dmg"
(
    cd "$project_dir/build"
    shasum -a 256 -c SHA256SUMS.txt
)

verification_dir="$(mktemp -d "$project_dir/build/verification.XXXXXX")"
mount_dir="$verification_dir/dmg"
mounted=false
cleanup() {
    if "$mounted"; then
        hdiutil detach "$mount_dir" > /dev/null || true
    fi
    rm -rf "$verification_dir"
}
trap cleanup EXIT
mkdir -p "$mount_dir" "$verification_dir/zip"

hdiutil attach "$project_dir/build/Envl.dmg" -readonly -nobrowse -mountpoint "$mount_dir" > /dev/null
mounted=true
verify_app "$mount_dir/Envl.app"
diff -qr "$project_dir/build/Envl.app" "$mount_dir/Envl.app"
hdiutil detach "$mount_dir" > /dev/null
mounted=false

ditto -x -k "$project_dir/build/Envl.zip" "$verification_dir/zip"
verify_app "$verification_dir/zip/Envl.app"
diff -qr "$project_dir/build/Envl.app" "$verification_dir/zip/Envl.app"
printf 'Universal app, DMG contents, ZIP contents, signatures and checksums verified.\n'
