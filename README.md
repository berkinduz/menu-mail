<p align="center">
  <img src="docs/images/icon.png" width="88" alt="MenuMail icon">
</p>
<h1 align="center">MenuMail</h1>
<p align="center">Your inbox, one click away. Right in the Mac menu bar.</p>
<p align="center">
  <a href="https://github.com/berkinduz/menu-mail/releases/latest/download/MenuMail.dmg"><strong>Download for Mac</strong></a> ·
  <a href="README.tr.md">Türkçe</a> ·
  <a href="https://github.com/berkinduz/menu-mail/issues">Feedback</a>
</p>

<p align="center">
  <img src="docs/images/inbox.png" width="31%" alt="MenuMail inbox preview with example messages">
  <img src="docs/images/reader.png" width="31%" alt="Full HTML message reader">
  <img src="docs/images/settings.png" width="31%" alt="Appearance and launch at login settings">
</p>

Read recent messages without switching apps. MenuMail connects to an account already in **Apple Mail** and remembers your mailbox. Free, open source, and built for macOS.

### Install in a minute

1. [Download MenuMail.dmg](https://github.com/berkinduz/menu-mail/releases/latest/download/MenuMail.dmg) and drag **MenuMail** to **Applications**.
2. Open it, click the menu bar envelope, and choose **Connect Apple Mail**.
3. Allow Mail access when macOS asks. Choose an account or mailbox if prompted.

**macOS 14+ · Apple silicon & Intel · No Xcode needed for the download.**

This release is **not notarized**. macOS may require your approval in **System Settings → Privacy & Security**. [Apple's instructions](https://support.apple.com/en-us/102445).

### Small app, useful details

- Full HTML and plain text reading, with a quick return to your inbox.
- **20 recent messages** by default; choose 10, 20 or 50.
- Manual or automatic refresh, light/dark themes, and a compact list.
- Four menu bar icons and optional **Launch at login**.
- English by default; switch to **Türkçe** in Settings.

**Privacy:** Your account stays in Apple Mail. MenuMail has no backend, does not ask for passwords, and does not save or log message contents. It does not send, delete, move or mark mail as read. Remote images in emails may load from their original URLs. [Details](docs/PRIVACY.md).

### Build or contribute

Bug reports, translations and focused pull requests are welcome. [Contributor guide](CONTRIBUTING.md).

```sh
git clone https://github.com/berkinduz/menu-mail.git
cd menu-mail
bash scripts/build.sh
open build/MenuMail.app
```

Requires Swift 6+ and macOS 14+. `bash scripts/package.sh` creates a universal DMG and ZIP. One mailbox at a time; account setup and server sync stay in Apple Mail.

---

Made by [berkinduz](https://github.com/berkinduz) · [Contact](mailto:mberkinduz@gmail.com) · [MIT License](LICENSE)

[![Buy me a coffee](docs/images/buy-me-a-coffee.svg)](https://buymeacoffee.com/berkinduz)
