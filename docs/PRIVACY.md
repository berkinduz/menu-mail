# Data and permissions

MenuMail reads accounts, top-level mailboxes, recent message metadata and the selected message's MIME source through Apple Mail's scripting interface. macOS Automation permission permits control of Mail; the OS does not provide a separate read-only permission for this interface. MenuMail's commands only read data and request new-mail checks.

- No password, token, Keychain access, Mail database access or backend.
- No sending, deletion, moving or read-status changes.
- Message contents stay in memory and are not logged or saved by MenuMail.
- The selected account ID, mailbox name and app preferences are stored in local macOS UserDefaults.
- HTML uses a nonpersistent WebKit data store with JavaScript disabled. Remote images can load from their original URLs. Clicked links open in the default browser or mail handler.
- Launch at login is optional and managed through macOS Login Items. Its default is off.

Only the configured number of entries in Mail's mailbox collection is read, then sorted locally. Refresh reads Mail's current local state and asks it to check for new mail. New messages may require another refresh after Apple Mail syncs.

One mailbox at a time. Attachment downloads, sending and decryption of protected messages are not supported. Some messages or organization policies may require action in Apple Mail. Never share private mail when reporting a problem.

## Türkçe

MenuMail, Apple Mail’in otomasyon arayüzünden seçilen kutuyu ve maili okur. macOS izni teknik olarak Mail’i denetleme iznidir; uygulamanın komutları okuma ve yeni posta kontrolüyle sınırlıdır. Şifre, token, Keychain veya mail veritabanı okunmaz. İçerikler bellekte kalır, dosyaya ya da loglara yazılmaz. Hesap/kutu seçimi ve uygulama tercihleri bu Mac’te saklanır. HTML’de JavaScript kapalıdır; uzak görseller kendi adreslerine bağlanabilir. Açılışta çalıştırma isteğe bağlıdır ve varsayılan olarak kapalıdır. Sunucu eşitlemesini Apple Mail yönetir.
