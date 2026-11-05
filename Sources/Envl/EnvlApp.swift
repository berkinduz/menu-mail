import AppKit
import SwiftUI

@main
struct EnvlApp: App {
    @NSApplicationDelegateAdaptor(EnvlDelegate.self) private var delegate
    @State private var menuIsInserted = true

    var body: some Scene {
        MenuBarExtra(isInserted: $menuIsInserted) {
            MenuBarMailboxView(delegate: delegate)
        } label: {
            MailStatusLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarMailboxView: View {
    let delegate: EnvlDelegate
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        delegate.mailboxView { dismiss() }
            .background(MenuWindowObserver(onOpen: { delegate.menuDidOpen() }, onWindowChange: { [weak delegate] window in
                delegate?.menuWindow = window
            }).frame(width: 0, height: 0))
    }
}

private struct MailStatusLabel: View {
    @Bindable var store: MailboxStore

    private var image: NSImage {
        let selected = store.settings.menuBarIcon
        let image = selected == .fold
            ? Bundle.main.url(forResource: "EnvlTemplate", withExtension: "pdf").flatMap(NSImage.init(contentsOf:))
            : NSImage(systemSymbolName: selected.rawValue, accessibilityDescription: "Envl")
        let result = image ?? NSImage(systemSymbolName: "envelope", accessibilityDescription: "Envl")!
        result.isTemplate = true
        result.size = NSSize(width: 18, height: 18)
        return result
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: image)
            if store.settings.showUnreadCount, let count = store.totalUnreadCount, count > 0 {
                Text(count.formatted()).monospacedDigit()
            }
        }
        .accessibilityLabel("Envl")
        .help(store.accountErrors.isEmpty ? "Envl" : store.settings.text("An account needs attention. Open Envl to reconnect."))
    }
}

struct MailboxView: View {
    @Bindable var store: MailboxStore
    let notifications: MailNotifications
    let updates: ReleaseChecker
    let shortcut: GlobalShortcut
    let onDetach: (MailMessage) -> Void
    let onDismiss: () -> Void
    @State private var isSearching = false
    @FocusState private var inboxFocus: MailInboxView.Focus?
    private var settings: AppSettings { store.settings }
    private var isInbox: Bool {
        store.screen == .mailbox && store.selected == nil && (store.isConnected || store.isDemo)
    }
    private var searchIsPresented: Bool { isSearching || !store.searchText.isEmpty }
    static func contentSize(for store: MailboxStore) -> NSSize {
        let inbox = store.screen == .mailbox && store.selected == nil && (store.isConnected || store.isDemo)
        return NSSize(width: inbox ? 420 : 480, height: inbox ? 550 : 650)
    }
    private var availableVersion: String? {
        updates.availableVersion(current: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12.5)).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.red.opacity(0.05))
            }
            if let message = store.statusMessage {
                HStack {
                    Text(message).font(.system(size: 12.5))
                    Spacer()
                    if store.canUndo { Button(settings.text("Undo")) { Task { await store.undoLastAction() } } }
                    Button { store.clearStatus() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(settings.text("Dismiss"))
                }
                .buttonStyle(.borderless).padding(10).background(.blue.opacity(0.06))
            }
            content
        }
        .frame(width: Self.contentSize(for: store).width, height: Self.contentSize(for: store).height)
        .font(.system(size: 14))
        .environment(\.locale, settings.locale)
        .preferredColorScheme(settings.appearance.colorScheme)
        .defaultFocus($inboxFocus, isInbox ? (searchIsPresented ? .search : .list) : nil)
        .onExitCommand {
            if isInbox, searchIsPresented { closeSearch() }
            else if store.canGoBack { store.goBack() }
            else { onDismiss() }
        }
    }

    @ViewBuilder private var content: some View {
        switch store.screen {
        case .settings:
            MailSettingsView(store: store, settings: settings, notifications: notifications, updates: updates, shortcut: shortcut)
        case .account: MailAccountView(store: store)
        case .compose: MailComposerView(store: store)
        case .mailbox:
            if !store.isConnected && !store.isDemo { MailAccountView(store: store) }
            else if let selected = store.selected { MailReaderView(message: selected, store: store, onDetach: onDetach) }
            else { MailInboxView(store: store, isSearching: $isSearching, focus: $inboxFocus) }
        }
    }
    private var title: String {
        switch store.screen {
        case .settings: settings.text("Settings")
        case .account: settings.text("Accounts")
        case .compose: settings.text("New message")
        case .mailbox: settings.text(store.selected == nil ? "Accounts" : "Message")
        }
    }
    private var header: some View {
        HStack(spacing: 6) {
            if store.canGoBack {
                Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(settings.text("Back"))
                    .keyboardShortcut("[", modifiers: .command)
                    .frame(width: 24, height: 24)
            }
            if isInbox {
                MailInboxMenu(store: store)
            } else {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            if store.isDemo {
                Text(settings.text("Sample"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .help(settings.text("Sample data · No account connected"))
            }
            Spacer(minLength: 0)
            if let text = store.loadingText {
                ProgressView().controlSize(.small).help(text).accessibilityLabel(text)
            }
            if isInbox {
                searchField
                Button { toggleSearch() } label: { Image(systemName: "magnifyingglass") }
                    .foregroundStyle(searchIsPresented ? Color.accentColor : Color.primary)
                    .help(settings.text(searchIsPresented ? "Close search" : "Search"))
                    .accessibilityLabel(settings.text(searchIsPresented ? "Close search" : "Search"))
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 24, height: 24)
            }
            if store.screen == .mailbox {
                if store.canCompose || store.draft != nil {
                    Button { store.compose() } label: { Image(systemName: store.draft == nil ? "square.and.pencil" : "pencil.line") }
                        .help(settings.text(store.draft == nil ? "New message" : "Resume draft"))
                        .accessibilityLabel(settings.text(store.draft == nil ? "New message" : "Resume draft"))
                        .keyboardShortcut("n", modifiers: .command)
                        .frame(width: 24, height: 24)
                }
                if store.isConnected || store.isDemo {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(settings.text("Refresh")).accessibilityLabel(settings.text("Refresh"))
                        .keyboardShortcut("r", modifiers: .command).disabled(store.isBusy)
                        .frame(width: 24, height: 24)
                }
            }
            appMenu
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .animation(.smooth(duration: 0.22), value: searchIsPresented)
    }
    private var searchField: some View {
        TextField(settings.text("Search"), text: $store.searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($inboxFocus, equals: .search)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .frame(width: searchIsPresented ? 200 : 0)
            .opacity(searchIsPresented ? 1 : 0)
            .clipped()
            .allowsHitTesting(searchIsPresented)
            .accessibilityHidden(!searchIsPresented)
            .accessibilityLabel(store.searchScopeLabel)
            .help(store.searchScopeLabel)
            .onKeyPress(.escape) { closeSearch(); return .handled }
    }
    private func toggleSearch() {
        if searchIsPresented { closeSearch() }
        else { isSearching = true; inboxFocus = .search }
    }
    private func closeSearch() {
        store.searchText = ""
        isSearching = false
        inboxFocus = .list
    }
    private var appMenu: some View {
        Menu {
            Button(settings.text("Settings"), systemImage: "gearshape") { store.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button(settings.text("Manage accounts…"), systemImage: "person.crop.circle") { store.showAccountSetup() }
            if let version = availableVersion, let url = updates.downloadURL {
                Divider()
                Link(settings.text("Download version %@", version), destination: url)
            }
            if let updated = store.lastUpdated, store.screen == .mailbox {
                Divider()
                Text(settings.text("%d messages · %@", store.visibleMessages.count,
                    updated.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: settings.locale))))
            }
            Divider()
            Button(settings.text("Quit Envl")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: availableVersion != nil && updates.downloadURL != nil ? "arrow.down.circle" : "ellipsis")
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize()
        .help(availableVersion.map { settings.text("Download version %@", $0) } ?? settings.text("More"))
        .accessibilityLabel(settings.text("More"))
    }
}
