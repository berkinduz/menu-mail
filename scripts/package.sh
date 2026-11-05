#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

sign_release=false
notarize_release=false
for argument in "$@"; do
    case "$argument" in
        --sign) sign_release=true ;;
        --notarize) notarize_release=true ;;
        *) printf 'Usage: bash scripts/package.sh [--sign [--notarize]]\n' >&2; exit 1 ;;
    esac
done
if "$notarize_release" && ! "$sign_release"; then
    printf 'Notarization requires an explicit --sign flag.\n' >&2
    exit 1
fi
if "$notarize_release" && [[ -z "${ENVL_NOTARY_PROFILE:-}" ]]; then
    printf 'Set ENVL_NOTARY_PROFILE to your configured notarytool profile before using --notarize.\n' >&2
    exit 1
fi

build_options=(--universal)
if "$sign_release"; then
    build_options+=(--sign)
fi
bash scripts/build.sh "${build_options[@]}"
app_dir="$project_dir/build/Envl.app"
staging_dir="$(mktemp -d "$project_dir/build/package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

notarize() {
    local artifact="$1"
    local receipt="$2"
    xcrun notarytool submit "$artifact" --keychain-profile "$ENVL_NOTARY_PROFILE" \
        --wait --output-format json > "$receipt"
    python3 - "$receipt" <<'PYTHON'
import json
import sys

with open(sys.argv[1]) as stream:
    receipt = json.load(stream)
if receipt.get("status") != "Accepted":
    sys.exit("Notarization was not accepted; inspect the receipt and notary log before distributing.")
PYTHON
}

if "$notarize_release"; then
    ditto -c -k --keepParent "$app_dir" "$staging_dir/notarization.zip"
    notarize "$staging_dir/notarization.zip" "$project_dir/build/notarization-app.json"
    rm "$staging_dir/notarization.zip"
    xcrun stapler staple "$app_dir"
    xcrun stapler validate "$app_dir"
    codesign --verify --deep --strict "$app_dir"
    spctl --assess --type execute "$app_dir"
fi

ditto "$app_dir" "$staging_dir/Envl.app"
ln -s /Applications "$staging_dir/Applications"
cp "$project_dir/LICENSE" "$staging_dir/LICENSE.txt"
cat > "$staging_dir/Install Envl.txt" <<'TEXT'
Envl — read email from your menu bar

1. Drag Envl to Applications.
2. Open Envl and click its envelope in the menu bar.
3. Choose Apple Mail and select an account or mailbox.

Requires macOS 14+. The universal app includes Apple silicon and Intel builds.
This release reads accounts already configured in Apple Mail. Allow macOS
Automation access when prompted. Apple Mail must keep running to synchronize,
and its Dock icon remains visible. Envl does not send, delete, archive or change
message read status. Independent Gmail and Outlook sign-in is coming soon.

Türkçe

1. Envl’i Applications / Uygulamalar klasörüne sürükle.
2. Envl’i aç ve menü çubuğundaki zarfa tıkla.
3. Apple Mail’i seç, hesabını ve posta kutunu belirle.

Dil: Settings > App language > Türkçe.
macOS 14+ gerekir. Bu sürüm, Apple Mail’e eklenmiş hesapları salt okunur kullanır.
macOS sorarsa otomasyon izni ver. Eşitleme için Apple Mail çalışır durumda kalır
ve Dock simgesi görünür. Envl ileti göndermez, silmez, arşivlemez veya okundu
durumunu değiştirmez. Bağımsız Gmail ve Outlook girişi çok yakında.

Source / Kaynak: https://github.com/berkinduz/menu-mail
Contact / İletişim: mberkinduz@gmail.com
TEXT

if "$notarize_release"; then
    printf '\nSigning: Developer ID signed; Apple notarization accepted and app ticket stapled.\n' >> "$staging_dir/Install Envl.txt"
else
    cat >> "$staging_dir/Install Envl.txt" <<'TEXT'

This build is not notarized. macOS may require approval in System Settings >
Privacy & Security. Bu derleme notarize edilmedi; macOS onayı gerekebilir.
Apple's instructions: https://support.apple.com/en-us/102445
TEXT
fi

rm -f "$project_dir/build/Envl.dmg" "$project_dir/build/Envl.zip"
hdiutil create -volname Envl -srcfolder "$staging_dir" -fs HFS+ -format UDZO "$project_dir/build/Envl.dmg"
if "$sign_release"; then
    codesign --force --sign "$ENVL_SIGNING_IDENTITY" --timestamp "$project_dir/build/Envl.dmg"
fi
if "$notarize_release"; then
    notarize "$project_dir/build/Envl.dmg" "$project_dir/build/notarization-dmg.json"
    xcrun stapler staple "$project_dir/build/Envl.dmg"
    xcrun stapler validate "$project_dir/build/Envl.dmg"
    spctl --assess --type open --context context:primary-signature "$project_dir/build/Envl.dmg"
fi
ditto -c -k --keepParent "$app_dir" "$project_dir/build/Envl.zip"
(
    cd "$project_dir/build"
    shasum -a 256 Envl.dmg Envl.zip
) > "$project_dir/build/SHA256SUMS.txt"
bash scripts/validate-package.sh
python3 scripts/homebrew.py
python3 scripts/homebrew.py --check
printf 'Release files: build/Envl.dmg, build/Envl.zip, build/SHA256SUMS.txt\n'
printf 'Local Homebrew cask: build/homebrew/Casks/envl.rb\n'
