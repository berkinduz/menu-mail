import SwiftUI

struct MailInboxView: View {
    enum Focus: Hashable { case list, search }

    @Bindable var store: MailboxStore
    @Binding var isSearching: Bool
    let focus: FocusState<Focus?>.Binding
    @State private var viewportSize = CGSize.zero
    @State private var paginationFrame = CGRect.zero
    private var reachedEnd: Bool {
        !paginationFrame.isEmpty && CGRect(origin: .zero, size: viewportSize).intersects(paginationFrame)
    }

    private struct SearchRequest: Equatable {
        let text: String
        let accountID: String
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: $store.focusedMessageID) {
                    ForEach(store.visibleMessages, id: \.listID) { message in
                        Button { store.open(message) } label: {
                            MailInboxRow(message: message, settings: store.settings,
                                accountName: store.selectedAccountID.isEmpty && store.connections.count > 1
                                    ? store.connections.first { $0.id == message.accountID }?.account.name : nil)
                        }
                        .buttonStyle(.plain)
                        .tag(message.listID)
                        .id(message.listID)
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                    }
                    if store.hasMoreMessages {
                        paginationIndicator
                    }
                }
                .listStyle(.inset)
                .contentMargins(.vertical, 0, for: .scrollContent)
                .coordinateSpace(.named("inboxViewport"))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
                .overlay {
                    if store.visibleMessages.isEmpty { MailInboxEmptyState(store: store) }
                }
                .focusable()
                .focused(focus, equals: .list)
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    store.moveFocus(press.key == .downArrow ? 1 : -1)
                    return .handled
                }
                .onKeyPress(.return) {
                    store.openFocusedMessage()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard isSearching || !store.searchText.isEmpty else { return .ignored }
                    closeSearch()
                    return .handled
                }
                .onChange(of: store.focusedMessageID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .task(id: SearchRequest(text: store.searchText, accountID: store.selectedAccountID)) {
            await searchAfterTyping()
        }
        .onChange(of: store.isBusy) { _, isBusy in
            if !isBusy { loadNextPage() }
        }
        .onChange(of: reachedEnd) { _, visible in
            if visible { loadNextPage() }
        }
    }

    private var paginationIndicator: some View {
        HStack {
            Spacer()
            if store.isLoadingList {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(store.settings.text("Loading messages…"))
            }
            Spacer()
        }
        .frame(height: 28)
        .listRowSeparator(.hidden)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("inboxViewport")) } action: { paginationFrame = $0 }
        .onDisappear { paginationFrame = .zero }
    }

    private func loadNextPage() {
        guard reachedEnd, !store.isBusy, store.errorMessage == nil else { return }
        let lastID = store.visibleMessages.last?.listID
        Task { await store.loadMore(whenShowing: lastID) }
    }

    private func closeSearch() {
        store.searchText = ""
        isSearching = false
        focus.wrappedValue = .list
    }

    private func searchAfterTyping() async {
        if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await store.search()
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
            while store.isBusy { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
            await store.search()
        } catch { return }
    }
}

struct MailInboxMenu: View {
    @Bindable var store: MailboxStore
    @State private var isPresented = false
    private var settings: AppSettings { store.settings }
    private var title: String {
        if let connection = store.connections.first(where: { $0.id == store.selectedAccountID }) {
            return connection.account.name
        }
        if store.connections.count == 1 { return store.connections[0].account.name }
        return settings.text("All accounts")
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: store.filter == .all ? "tray" : "tray.fill")
                .foregroundStyle(store.filter == .all ? Color.primary : Color.accentColor)
                .frame(width: 24, height: 24)
        }
        .help("\(title) · \(settings.text(store.filter.title))")
        .accessibilityLabel(settings.text("Account"))
        .accessibilityValue("\(title), \(settings.text(store.filter.title))")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(settings.text("Accounts")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(settings.text("Manage accounts…")) {
                        isPresented = false
                        store.showAccountSetup()
                    }
                    .buttonStyle(.link).font(.system(size: 12))
                }
                VStack(spacing: 3) {
                    if store.connections.count > 1 {
                        accountOption(title: settings.text("All accounts"), subtitle: nil, symbol: "tray.2", id: "")
                    }
                    ForEach(store.connections) { connection in
                        accountOption(title: accountLabel(connection), subtitle: connection.account.address ?? connection.mailbox,
                            symbol: "envelope", id: connection.id)
                    }
                    if store.isDemo {
                        Text(settings.text("Sample data · No account connected"))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
                Divider()
                Text(settings.text("Filter")).font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(MailboxStore.Filter.allCases) { filter in
                        InboxChoice(isSelected: store.filter == filter) {
                            store.filter = filter
                            isPresented = false
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: symbol(for: filter)).frame(width: 16)
                                Text(settings.text(filter.title)).lineLimit(1)
                                Spacer(minLength: 0)
                                if store.filter == filter { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                            }
                            .font(.system(size: 13, weight: store.filter == filter ? .semibold : .regular))
                        }
                    }
                }
            }
            .padding(16).frame(width: 320)
            .environment(\.locale, settings.locale)
            .preferredColorScheme(settings.appearance.colorScheme)
        }
    }

    private func accountOption(title: String, subtitle: String?, symbol: String, id: String) -> some View {
        let selected = store.selectedAccountID == id || (store.selectedAccountID.isEmpty && store.connections.count == 1)
        return InboxChoice(isSelected: selected) {
            store.selectInboxAccount(id)
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)) }
            }
        }
    }

    private func symbol(for filter: MailboxStore.Filter) -> String {
        switch filter {
        case .all: "tray"
        case .unread: "envelope.badge"
        case .starred: "star"
        case .attachments: "paperclip"
        }
    }

    private func accountLabel(_ connection: MailboxConnection) -> String {
        guard let unread = store.unreadCount(for: connection.id) else { return connection.account.name }
        return "\(connection.account.name) (\(unread))"
    }
}

private struct InboxChoice<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) { label().frame(maxWidth: .infinity, alignment: .leading).padding(10) }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background(isSelected ? Color.accentColor.opacity(0.12) : isHovered ? Color.primary.opacity(0.05) : .clear,
                in: RoundedRectangle(cornerRadius: 8))
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MailInboxRow: View {
    let message: MailMessage
    let settings: AppSettings
    let accountName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.sender(language: settings.language))
                    .font(.system(size: 15, weight: message.isRead == false ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if message.isStarred == true {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                        .accessibilityLabel(settings.text("Starred"))
                }
                if message.hasAttachments || !message.attachments.isEmpty {
                    Image(systemName: "paperclip").accessibilityLabel(settings.text("Attachments"))
                }
                if message.isRead == false {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5)).foregroundStyle(.tint)
                        .accessibilityLabel(settings.text("Unread"))
                }
                Text(message.shortDate(locale: settings.locale))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(message.title(language: settings.language))
                .font(.system(size: 14, weight: message.isRead == false ? .medium : .regular))
                .lineLimit(settings.compactList ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !settings.compactList, let snippet = message.snippet, !snippet.isEmpty {
                Text(snippet).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let accountName {
                Text(accountName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, settings.compactList ? 7 : 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MailInboxEmptyState: View {
    let store: MailboxStore
    private var settings: AppSettings { store.settings }
    private var hasSearch: Bool { !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var title: String {
        if store.isLoadingList { return "Loading messages" }
        if hasSearch { return "No search results" }
        return store.filter == .all ? "Your inbox is empty" : "No matching messages"
    }
    private var description: String {
        if store.isLoadingList { return "Getting your recent messages." }
        if hasSearch { return "Try a different search or account." }
        return store.filter == .all ? "Click Refresh to check again." : "Try another filter."
    }

    var body: some View {
        ContentUnavailableView {
            Label(settings.text(title), systemImage: hasSearch ? "magnifyingglass" : "tray")
        } description: {
            Text(settings.text(description))
        }
    }
}
