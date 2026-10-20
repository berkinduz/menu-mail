import AppKit
import SwiftUI

@main
struct MenuMailApp: App {
    @State private var mailbox = MailboxStore(settings: AppSettings())

    var body: some Scene {
        MenuBarExtra("MenuMail", systemImage: mailbox.settings.menuBarIcon.rawValue) {
            MailboxView(store: mailbox)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MailboxView: View {
    @Bindable var store: MailboxStore
    private var settings: AppSettings { store.settings }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.screen != .settings && store.screen != .about {
                if store.isDemo {
                    Label(settings.text("Sample data · No account connected"), systemImage: "testtube.2")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(.orange.opacity(0.08))
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.red.opacity(0.05))
                }
            }

            switch store.screen {
            case .settings:
                MailSettingsView(store: store, settings: settings)
            case .about:
                AboutView(settings: settings)
            case .account:
                setup
            case .mailbox:
                if !store.isConnected && !store.isDemo {
                    setup
                } else if let selected = store.selected {
                    reader(selected)
                } else {
                    inbox
                }
            }

            Divider()
            footer
        }
        .frame(width: 460, height: 580)
        .environment(\.locale, settings.locale)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onAppear { store.start() }
        .onChange(of: settings.refreshInterval) { store.configureAutoRefresh() }
    }

    private var headerTitle: String {
        switch store.screen {
        case .settings: settings.text("Settings")
        case .account: settings.text("Choose mailbox")
        case .about: settings.text("About MenuMail")
        case .mailbox: store.selected == nil ? "MenuMail" : settings.text("Message")
        }
    }

    private var headerSubtitle: String {
        switch store.screen {
        case .settings: settings.text("Make MenuMail your own.")
        case .account: settings.text("Apple Mail · Read only")
        case .about: settings.text("A little less switching. A little more reading.")
        case .mailbox: store.sourceLabel
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if store.canGoBack {
                Button { store.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 30)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                }
                .help(settings.text("Back"))
                .accessibilityLabel(settings.text("Back"))
                .buttonStyle(.plain)
            } else {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let loadingText = store.loadingText, store.isLoadingList || store.selected?.body != nil {
                HStack(spacing: 6) {
                    Text(loadingText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(loadingText)
                }
                .help(loadingText)
            }

            if store.screen == .mailbox && (store.isConnected || store.isDemo) {
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(store.isLoadingList)
                .help(settings.text("Refresh"))
                .accessibilityLabel(settings.text("Refresh"))
            }
        }
        .padding(16)
    }

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)

                Text(settings.text("Your inbox, in the menu bar."))
                    .font(.title2.weight(.semibold))
                Text(settings.text("Use an account already added to Apple Mail on this Mac. macOS will ask you to allow MenuMail to access Mail."))
                    .foregroundStyle(.secondary)

                Button(settings.text(store.accounts.isEmpty ? "Connect Apple Mail" : "Reload accounts")) {
                    Task {
                        await store.loadAccounts()
                        if store.canConnect { await store.connect() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)

                if store.accounts.isEmpty {
                    Text(settings.text("1. Add your account in Apple Mail.\n2. Connect here and allow Mail access.\n3. Choose a mailbox if prompted."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button(settings.text("Open Apple Mail")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app"))
                    }
                    .buttonStyle(.link)
                }

                if !store.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker(settings.text("Account"), selection: Binding(get: { store.accountID }, set: { id in
                            Task { await store.selectAccount(id) }
                        })) {
                            Text(settings.text("Choose an account")).tag("")
                            ForEach(store.accounts) { account in
                                Text(account.name).tag(account.id)
                            }
                        }
                        Picker(settings.text("Mailbox"), selection: $store.mailboxName) {
                            Text(settings.text("Choose Inbox / INBOX")).tag("")
                            ForEach(store.mailboxes, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        Text(settings.text("Choose your inbox once. MenuMail remembers it for next time."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(store.isBusy)

                    Button(settings.text("Show messages")) {
                        Task { await store.connect() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canConnect || store.isBusy)
                }

                Text(settings.text("Apple Mail handles sign-in and sync. MenuMail only reads your messages."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !store.isConnected && !store.isDemo {
                    Button(settings.text("Try sample data")) { store.startDemo() }
                        .buttonStyle(.link)
                        .disabled(store.isBusy)
                }
            }
            .padding(22)
        }
    }

    private var inbox: some View {
        Group {
            if store.messages.isEmpty {
                ContentUnavailableView {
                    Label(settings.text(store.isBusy ? "Loading messages" : "Your inbox is empty"), systemImage: "tray")
                } description: {
                    Text(settings.text(store.isBusy ? "Getting your recent messages." : "Click Refresh to check again."))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: settings.compactList ? 2 : 4) {
                        ForEach(store.messages) { message in
                            MailRow(message: message, settings: settings) { store.open(message) }
                        }
                    }
                    .padding(settings.compactList ? 8 : 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reader(_ message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(message.title(language: settings.language))
                    .font(.system(size: 17, weight: .semibold))
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    SenderAvatar(name: message.sender(language: settings.language))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message.sender(language: settings.language)).font(.system(size: 12, weight: .medium))
                        if let address = message.from?.emailAddress.address {
                            Text(address).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(message.longDate(locale: settings.locale)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(18)
            Divider()

            if let body = message.body {
                MailHTMLView(body: body).id(message.id)
            } else if store.isLoadingBody {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(settings.text("Opening message…")).font(.system(size: 13, weight: .medium))
                    Text(settings.text("You can return to your inbox while this loads."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(settings.text("Could not load the message"), systemImage: "envelope.badge")
                } description: {
                    Text(settings.text("Open another message or try again."))
                } actions: {
                    Button(settings.text("Try again")) { Task { await store.refresh() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if store.screen == .settings {
                Button { store.showAbout() } label: {
                    Label(settings.text("About MenuMail"), systemImage: "info.circle")
                }
            } else if store.screen == .about {
                Text("MenuMail").foregroundStyle(.secondary)
            } else {
                Button { store.showSettings() } label: {
                    Label(settings.text("Settings"), systemImage: "gearshape")
                }
            }
            Spacer()
            if store.screen == .mailbox, let updated = store.lastUpdated {
                Text(settings.text("%d messages · %@", store.messages.count,
                    updated.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: settings.locale))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help(settings.text("Quit MenuMail"))
            .accessibilityLabel(settings.text("Quit MenuMail"))
        }
        .font(.caption)
        .buttonStyle(.plain)
        .padding(12)
        .background(.primary.opacity(0.02))
    }
}

private struct SenderAvatar: View {
    let name: String

    private var initials: String {
        name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.blue)
            .frame(width: 34, height: 34)
            .background(.blue.opacity(0.10), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct MailRow: View {
    let message: MailMessage
    let settings: AppSettings
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                if !settings.compactList {
                    SenderAvatar(name: message.sender(language: settings.language))
                }
                VStack(alignment: .leading, spacing: settings.compactList ? 3 : 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(message.sender(language: settings.language))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(message.shortDate(locale: settings.locale))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Text(message.title(language: settings.language))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(settings.compactList ? 1 : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(settings.compactList ? 9 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.blue.opacity(0.08) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(message.sender(language: settings.language)), \(message.title(language: settings.language)), \(message.shortDate(locale: settings.locale))")
    }
}
