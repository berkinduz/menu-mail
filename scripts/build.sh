#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

build_args=(--configuration release --product MenuMail -Xswiftc -gnone)
if [[ "${1:-}" == "--universal" && "$#" -eq 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
elif [[ "$#" -ne 0 ]]; then
    printf 'Usage: bash scripts/build.sh [--universal]\n' >&2
    exit 1
fi

swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_dir="$project_dir/build/MenuMail.app"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/MenuMail" "$app_dir/Contents/MacOS/MenuMail"
strip -S "$app_dir/Contents/MacOS/MenuMail"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/MenuMail.icns" "$app_dir/Contents/Resources/MenuMail.icns"
cp "$project_dir/Resources/MailBridge.js" "$app_dir/Contents/Resources/MailBridge.js"
cp "$project_dir/Resources/MailInbox.applescript" "$app_dir/Contents/Resources/MailInbox.applescript"
cp "$project_dir/Resources/MailSource.applescript" "$app_dir/Contents/Resources/MailSource.applescript"
for language in en tr; do
    mkdir -p "$app_dir/Contents/Resources/$language.lproj"
    cp "$project_dir/Resources/$language.lproj/Localizable.strings" "$app_dir/Contents/Resources/$language.lproj/Localizable.strings"
    cp "$project_dir/Resources/$language.lproj/InfoPlist.strings" "$app_dir/Contents/Resources/$language.lproj/InfoPlist.strings"
done
codesign --force --sign - "$app_dir"
printf 'App ready: %s\n' "$app_dir"
