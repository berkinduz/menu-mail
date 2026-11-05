#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

build_args=(--configuration release --product Envl -Xswiftc -gnone)
sign_release=false
for argument in "$@"; do
    case "$argument" in
        --universal) build_args+=(--arch arm64 --arch x86_64) ;;
        --sign) sign_release=true ;;
        *) printf 'Usage: bash scripts/build.sh [--universal] [--sign]\n' >&2; exit 1 ;;
    esac
done
if "$sign_release" && [[ -z "${ENVL_SIGNING_IDENTITY:-}" ]]; then
    printf 'Set ENVL_SIGNING_IDENTITY to your configured Developer ID Application identity before using --sign.\n' >&2
    exit 1
fi

swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_dir="$project_dir/build/Envl.app"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Envl" "$app_dir/Contents/MacOS/Envl"
strip -S "$app_dir/Contents/MacOS/Envl"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
shopt -s nullglob dotglob
for resource in "$project_dir"/Resources/*; do
    resource_name="$(basename "$resource")"
    [[ "$resource_name" == Info.plist ]] && continue
    ditto "$resource" "$app_dir/Contents/Resources/$resource_name"
done

plutil -lint "$app_dir/Contents/Info.plist"
if "$sign_release"; then
    codesign --force --sign "$ENVL_SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements "$project_dir/distribution/Envl.entitlements" "$app_dir"
else
    codesign --force --sign - "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
printf 'App ready: %s\n' "$app_dir"
