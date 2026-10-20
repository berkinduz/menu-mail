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

MenuMail is a free, open-source **macOS menu bar email reader** that works with your existing **Apple Mail** mailbox. Read recent messages without switching apps. MenuMail remembers your mailbox for next time.

### Work email when other apps need admin approval

Corporate **Microsoft 365 (Office 365) and Exchange** accounts can restrict sign-ins to approved email clients. Other third-party apps may be blocked or show **[“Need admin approval”](https://learn.microsoft.com/en-us/troubleshoot/entra/entra-id/app-integration/troubleshoot-consent-issues)** when requesting access to your company email.

When your organization already permits the account in **Apple Mail on Mac**, MenuMail offers **work email in the macOS menu bar** through local Mail automation—**no separate provider login or Microsoft Entra app registration**.

**[Sign in to Apple Mail](https://support.apple.com/guide/mail/mail35803/mac) → Connect MenuMail → Read from the menu bar.** Apple Mail handles authentication and server sync; you allow MenuMail to access Mail when macOS asks.

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
- Refreshes the inbox whenever you open the menu, keeping the current list available while it checks Apple Mail.
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

### Next steps · Contributions welcome

- [ ] **Real Apple Mail integration checks:** first-run permissions, Mail open/closed, connection failures, HTML messages, and back/refresh flows across macOS versions. Report these separately from unit tests.
- [ ] **Faster navigation:** a global keyboard shortcut, arrow-key navigation, Enter/Escape controls, and search within the loaded recent messages.
- [ ] **Update notifications:** show when a new release is available and link to its download; explore in-app updates afterward.

Want to help? [Open an issue](https://github.com/berkinduz/menu-mail/issues) to discuss an item, then follow the [contributor guide](CONTRIBUTING.md).
