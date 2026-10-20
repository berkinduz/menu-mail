#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

bash scripts/build.sh --universal
app_dir="$project_dir/build/MenuMail.app"
staging_dir="$(mktemp -d "$project_dir/build/package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

ditto --norsrc --noqtn "$app_dir" "$staging_dir/MenuMail.app"
ln -s /Applications "$staging_dir/Applications"
cp "$project_dir/LICENSE" "$staging_dir/LICENSE.txt"
cat > "$staging_dir/Install MenuMail.txt" <<'TEXT'
MenuMail — read email from your menu bar

1. Drag MenuMail to Applications.
2. Open MenuMail and click its envelope in the menu bar.
3. Choose Connect Apple Mail and allow access when macOS asks.

Requires macOS 14+ and an account in Apple Mail. The app supports Apple silicon
and Intel Macs. This release is not notarized. macOS may ask for approval in
System Settings > Privacy & Security. Apple's instructions:
https://support.apple.com/en-us/102445

Türkçe

1. MenuMail’i Applications / Uygulamalar klasörüne sürükle.
2. MenuMail’i aç ve menü çubuğundaki zarfa tıkla.
3. Apple Mail’e bağlan; macOS sorarsa Mail erişimine izin ver.

Dil: Settings > App language > Türkçe.
macOS 14+ ve Apple Mail’e eklenmiş bir hesap gerekir.

Source / Kaynak: https://github.com/berkinduz/menu-mail
Contact / İletişim: mberkinduz@gmail.com
TEXT

rm -f "$project_dir/build/MenuMail.dmg" "$project_dir/build/MenuMail.zip"
hdiutil create -volname MenuMail -srcfolder "$staging_dir" -fs HFS+ -format UDZO "$project_dir/build/MenuMail.dmg"
ditto -c -k --norsrc --noqtn --keepParent "$app_dir" "$project_dir/build/MenuMail.zip"
(
    cd "$project_dir/build"
    shasum -a 256 MenuMail.dmg MenuMail.zip
) > "$project_dir/build/SHA256SUMS.txt"
printf 'Release files: build/MenuMail.dmg, build/MenuMail.zip, build/SHA256SUMS.txt\n'
