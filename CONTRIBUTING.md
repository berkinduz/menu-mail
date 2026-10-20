# Contributing to MenuMail

Bug fixes, translations, accessibility improvements and small usability changes are welcome. Open an issue to discuss larger ideas before starting.

1. Fork the repository and create a branch for your change.
2. Build with `bash scripts/build.sh` on macOS 14+ with Swift 6+.
3. Check the flow you changed. Use **Try sample data** for screenshots; never include real mail, account names or credentials.
4. Open a pull request explaining the problem, the change and what you checked.

Keep the app small, preserve the read-only Mail behavior, and update both `en.lproj` and `tr.lproj` strings when changing UI text. Do not add credentials, mail databases or message logs.

For releases, `bash scripts/package.sh` builds both architectures and creates `build/MenuMail.dmg`, `build/MenuMail.zip` and checksums. Release signing and notarization are separate from the local build.

Contributions are provided under the project's [MIT License](LICENSE).

## Türkçe

Hata düzeltmeleri, çeviriler, erişilebilirlik ve küçük kullanım iyileştirmeleri için katkı verebilirsin. Büyük değişiklikleri önce bir issue’da konuşalım. Kendi dalında değiştir, ilgili akışı kontrol et ve neyi değiştirdiğini anlatan bir pull request aç. Görsellerde örnek veri kullan; gerçek mail, hesap bilgisi veya kimlik bilgisi paylaşma. Arayüz metinlerinde iki dili de güncelle.
