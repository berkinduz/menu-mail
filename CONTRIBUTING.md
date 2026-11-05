# Contributing to Envl

Bug fixes, translations, accessibility improvements and small usability changes are welcome. Open an issue to discuss larger ideas before starting.

1. Fork the repository and create a branch for your change.
2. Build with `bash scripts/build.sh` on macOS 14+ with Swift 6+.
3. Run `swift test` and check the flow you changed. Automated provider tests use synthetic HTTP responses and injected token storage; do not use real accounts, Keychain entries or credentials in fixtures.
4. Use **Try sample data** for screenshots. Never include real mail, account names or tokens.
5. Open a pull request explaining the problem, the change and what you checked. Separate source/unit-test results from real sign-in, Apple Mail permission, Intel runtime and notarization checks.

Envl v0.2.0 ships only the read-only Apple Mail bridge. Gmail and Outlook are Coming soon placeholders; keep them noninteractive. The future provider implementation and synthetic tests remain in the source but are not connected to the shipping app. Opening mail must not mark it read. Do not add a persistent message cache or message logs. Opening attachments may use temporary files, and saving them requires the user's chosen destination. Remote content stays blocked unless enabled.

Update both `Resources/en.lproj/Localizable.strings` and `Resources/tr.lproj/Localizable.strings` for UI changes, including dynamic labels and error formats. Keep format placeholders aligned and check both files with `plutil -lint`. Preserve notification opt-in/privacy controls and the read-only release scope.

No Google/Microsoft application registrations or provider client IDs are required for this release. Future direct-provider work needs its own scope and live sign-in verification before it can be enabled. Do not add client secrets, passwords, access/refresh tokens or mail databases to the repository.

`bash scripts/package.sh` builds universal DMG/ZIP artifacts and checksums. Maintainers should follow [distribution setup](docs/DISTRIBUTION.md) for package checks, optional Developer ID signing/notarization and Homebrew cask generation. The generator does not publish a tap. Publication of a matching release and tap is a separate step; a local artifact or generated cask is not proof of a public install.

For a release, update `Resources/Info.plist` and `docs/releases/vX.Y.Z.md`, complete the relevant manual checks, then publish through the maintained tag workflow. Keep the published bytes consistent with the cask's version/checksum. Release signing and notarization require the maintainer's own setup; do not collect credentials in scripts or tests.

Contributions are provided under the project's [MIT License](LICENSE).

## Türkçe

Hata düzeltmeleri, çeviriler, erişilebilirlik ve küçük kullanım iyileştirmeleri için katkı verebilirsin. Büyük değişiklikleri önce bir issue’da konuşalım.

Kendi dalında değiştir, `bash scripts/build.sh` ile derle, `swift test` çalıştır ve ilgili akışı kontrol et. Otomatik sağlayıcı testlerinde sahte HTTP yanıtları ve enjekte edilen token deposu kullan; gerçek hesap, Anahtar Zinciri kaydı veya kimlik bilgisi kullanma. Görsellerde **Örnek verilerle dene** seçeneğini kullan. Pull request’te sorunu, değişikliği ve kontrolleri anlat; gerçek giriş/izin akışlarını, Intel’de çalışmayı ve notarizasyonu birim testlerinden ayrı raporla.

Envl v0.2.0 yalnızca Apple Mail’i okur. Gmail ve Outlook, Çok yakında satırları olarak kalmalı ve giriş başlatmamalı. Gelecekteki sağlayıcı kodu ve sahte veri testleri kaynakta tutulur, yayımlanan uygulamaya bağlı değildir. Mail açmak okundu durumunu değiştirmemeli; kalıcı mail önbelleği veya mail logu eklenmemeli. Ek açma geçici dosya kullanabilir; kaydetme kullanıcının seçtiği konuma yapılmalı. Uzak içerik, kullanıcı açmadıkça engellenmeli.

Arayüz metinlerinde dinamik başlıklar ve hata formatları dahil iki `.strings` dosyasını güncelle. Format yer tutucularını eşleştir ve `plutil -lint` ile doğrula. Bildirimlerin isteğe bağlı olmasını ve gizlilik kontrollerini koru.

Bu sürüm için Google/Microsoft uygulama kaydı veya sağlayıcı client ID’si gerekmez. Gelecekte doğrudan bağlantılar etkinleştirilmeden önce kapsamı ve gerçek giriş akışı ayrıca doğrulanmalıdır. Client secret, şifre, access/refresh token veya mail veritabanını depoya ekleme.

Paketleme, isteğe bağlı imzalama/notarizasyon ve yerel Homebrew cask üretimi için [dağıtım rehberini](docs/DISTRIBUTION.md) izle. Gerçek hesap/izin kontrolleri ve yayımlama ayrıca yapılır. Yerel paket veya üretilmiş cask, sürümün veya tap’in herkese açık olduğunun kanıtı değildir.
