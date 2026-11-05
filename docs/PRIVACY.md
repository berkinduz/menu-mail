# Data and permissions

This document describes Envl v0.2.0, an Apple Mail reader. Independent Gmail and Outlook connections are **coming soon** and are not enabled in this release.

## Apple Mail access

Envl reads accounts, top-level mailboxes, message metadata and selected MIME sources through Mail’s scripting interface. macOS grants Automation control of Mail, not a separate read-only OS permission. Envl’s bridge commands only read data and request mail checks; they do not send, move, delete, star or change read status. Opening a message in Envl does not mark it read.

Apple Mail owns authentication and synchronization. Envl does not request provider sign-in, access provider tokens or use a separate Google/Microsoft application registration. Apple Mail must remain running to synchronize messages, and its Dock icon remains visible. Your organization’s account and access policies still apply.

## What stays on this Mac

- Selected account IDs, display names, mailboxes and preferences use local **UserDefaults**. Envl does not read the Mail database or provide a backend, message logs or analytics service.
- Message lists, bodies and downloaded attachment bytes stay in memory. There is no persistent mailbox cache.
- **Open attachment** writes a file to a private, randomly named directory under macOS temporary storage so another app can open it. Envl attempts to remove its temporary attachment directory on normal termination. A crash or force quit can leave files behind until they are removed or macOS clears temporary storage. Other apps may retain their own copies.
- **Save attachment** writes to the location you choose. Those saved files remain until you remove them.
- Removing an account from Envl removes its Envl connection; it does not remove the account or mail from Apple Mail or the provider.

## Network requests and notifications

HTML uses a nonpersistent WebKit data store with message JavaScript disabled. Remote content is **blocked by default**; inline images included in the message can still appear. Enabling remote content allows requests to original URLs, which can reveal your IP address and that content was loaded. Clicked links open in your default browser or mail handler.

macOS notifications are **opt in** and require system permission. Settings provide per-account mutes and quiet hours. Sender/subject previews, when enabled, are passed to macOS and may remain in Notification Center. Turning previews off uses generic text. Message bodies are not used as notification previews. With notifications enabled and manual refresh selected, Envl checks for new mail every minute.

Update checks request the repository’s latest release from the **public, unauthenticated GitHub API**. Checks are manual unless you enable checking at launch; enabling that option also checks immediately. No account identifiers or mail content are included. GitHub receives normal network information such as your IP address and the Envl user-agent. Envl links to the release page and does not automatically install updates.

The global shortcut can be changed or disabled. Launch at login is optional, off by default, and managed through macOS Login Items. Never include private mail or account details in a bug report.

## Türkçe

Bu belge Apple Mail okuyucusu Envl v0.2.0’ı anlatır. Bağımsız Gmail ve Outlook bağlantıları **çok yakında**; bu sürümde etkin değildir.

Envl hesapları, üst düzey posta kutularını, mail bilgilerini ve seçilen mailin MIME kaynağını Mail’in otomasyon arayüzünden okur. macOS izni teknik olarak Mail’i denetleme iznidir; Envl’in komutları okuma ve yeni posta kontrolüyle sınırlıdır. Mail gönderilmez, taşınmaz, silinmez; yıldız ve okundu durumu değiştirilmez. Mail açmak onu okundu yapmaz.

Giriş ve eşitlemeyi Apple Mail yönetir. Envl sağlayıcıya giriş istemez, sağlayıcı token’larına erişmez veya ayrı Google/Microsoft uygulama kaydı kullanmaz. Eşitleme için Apple Mail çalışır durumda kalır ve Dock simgesi görünür. Kurumunun erişim kuralları geçerlidir.

- Hesap seçimleri, görünen adlar, posta kutuları ve tercihler yerel **UserDefaults**’tadır. Mail veritabanı okunmaz; Envl’in kendi sunucusu, mail logları veya analiz servisi yoktur.
- Liste, gövde ve indirilen ek baytları bellekte kalır; kalıcı posta önbelleği yoktur.
- **Eki aç**, macOS geçici alanında özel, rastgele adlı bir klasöre dosya yazar. Normal çıkışta klasörün silinmesi denenir. Çökme veya zorla çıkıştan sonra dosyalar silinene veya macOS temizleyene kadar kalabilir. Diğer uygulamalar kendi kopyalarını tutabilir.
- **Eki kaydet**, seçtiğin konuma yazar. Kaydedilen dosyalar sen silene kadar kalır.
- Envl’den hesap kaldırmak yalnızca Envl bağlantısını kaldırır; Mail’deki veya sağlayıcıdaki hesabı ve mailleri silmez.

HTML, kalıcı olmayan WebKit veri alanında ve JavaScript kapalıyken gösterilir. Uzak içerik **varsayılan olarak engellenir**; maille gelen ekli görseller gösterilebilir. Uzak içeriği açmak orijinal adreslere istek gönderir; IP adresin ve içeriğin yüklendiği bilgisi paylaşılabilir. Tıkladığın bağlantılar varsayılan tarayıcıda veya mail uygulamasında açılır.

Bildirimler **isteğe bağlıdır** ve macOS izni ister. Hesap bazında kapatma ve sessiz saatler vardır. Gönderen/konu önizlemesi açıksa bu bilgiler macOS bildirimlerine aktarılır ve Bildirim Merkezi’nde kalabilir; kapalıyken genel metin gösterilir. Mail gövdesi önizlemeye eklenmez. Bildirimler açık ve yenileme elle seçiliyse yeni mailler dakikada bir kontrol edilir.

Güncelleme kontrolü GitHub’ın **herkese açık, kimlik doğrulamasız sürüm API’sine** gider. Elle çalışır; açılışta kontrolü seçersen açılışta ve seçeneği etkinleştirdiğinde de kontrol edilir. Hesap veya mail içeriği gönderilmez; GitHub IP adresi ve Envl user-agent bilgisi gibi normal ağ bilgilerini alır. Sürüm sayfasına bağlantı verilir; otomatik kurulum yapılmaz.

Global kısayol değiştirilebilir veya kapatılabilir. Oturum açılışında çalıştırma isteğe bağlıdır, başlangıçta kapalıdır ve macOS Giriş Öğeleri’nden yönetilir. Hata bildirirken özel mail veya hesap bilgisi paylaşma.
