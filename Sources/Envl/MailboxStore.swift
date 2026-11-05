import Foundation
import Observation

@MainActor
@Observable
final class MailboxStore {
    enum Screen { case mailbox, settings, account, compose }
    enum Filter: String, CaseIterable, Identifiable {
        case all, unread, starred, attachments
        var id: String { rawValue }
        var title: String {
            switch self { case .all: "All"; case .unread: "Unread"; case .starred: "Starred"; case .attachments: "Attachments" }
        }
    }
    private enum ListActivity: String {
        case accounts = "Loading accounts…", mailboxes = "Loading mailboxes…"
        case messages = "Loading messages…", refreshing = "Refreshing messages…"
    }
    private struct Undo {
        let message: MailMessage
        let action: MailAction
    }

    let settings: AppSettings
    private(set) var screen: Screen = .mailbox
    private(set) var accounts: [MailAccount] = []
    private(set) var connections: [MailboxConnection] = []
    private(set) var accountID = ""
    private(set) var mailboxes: [String] = []
    var mailboxName = ""
    private(set) var messages: [MailMessage] = []
    private(set) var selected: MailMessage?
    private(set) var selectedAccountID = ""
    var searchText = ""
    var filter: Filter = .all
    var focusedMessageID: String?
    var draft: MailDraft?
    private(set) var isDemo = false
    private(set) var isLoadingBody = false
    private(set) var isPerformingAction = false
    private(set) var isSending = false
    private(set) var lastUpdated: Date?
    private(set) var error: Error?
    private(set) var accountErrors: [String: String] = [:]
    private(set) var statusMessage: String?
    private var listActivity: ListActivity?
    private var isBackgroundRefresh = false
    private var mailboxCache: [String: [String]] = [:]
    private var pages: [String: String] = [:]
    private var searchPages: [String: String] = [:]
    private var unreadCounts: [String: Int] = [:]
    private var searchResults: [MailMessage]?
    private var undo: Undo?
    private var movedMessageIDs: Set<String> = []
    private var generation = 0
    private var seenIDs: [String: Set<String>] = [:]
    private var newestReceived: [String: Date] = [:]
    private let client: any MailClient
    private let directClient: (any DirectMailConnecting)?
    @ObservationIgnored var onNewMessages: (@MainActor ([MailMessage]) -> Void)?
    @ObservationIgnored var onShowComposer: (@MainActor () -> Void)?
    @ObservationIgnored private var bodyTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var menuRefreshTask: Task<Void, Never>?
    private var didStart = false

    init(settings: AppSettings, client: any MailClient = AppleMailClient(), directClient: (any DirectMailConnecting)? = nil) {
        self.settings = settings
        self.client = client
        self.directClient = directClient
    }

    var isConnected: Bool { !connections.isEmpty }
    var isLoadingList: Bool { listActivity != nil }
    var isBusy: Bool { isLoadingList || isLoadingBody || isPerformingAction || isSending }
    var canConnect: Bool { !accountID.isEmpty && mailboxes.contains(mailboxName) }
    var canGoBack: Bool { screen != .mailbox || selected != nil }
    var canUndo: Bool { undo != nil && !isBusy }
    private var scopedConnections: [MailboxConnection] {
        connections.filter { selectedAccountID.isEmpty || $0.id == selectedAccountID }
    }
    var hasMoreMessages: Bool {
        let tokens = searchResults == nil ? pages : searchPages
        return scopedConnections.contains { tokens[$0.id] != nil }
    }
    var canCompose: Bool { connections.contains { capabilities(for: $0.account.id).contains(.send) } }
    var accountName: String? {
        guard isConnected else { return nil }
        return connections.count == 1 ? connections[0].account.name : settings.text("All accounts")
    }
    var connectedMailbox: String? { connections.count == 1 ? connections[0].mailbox : nil }
    var sourceLabel: String {
        if let connection = connections.first(where: { $0.id == selectedAccountID }) {
            return "\(connection.account.name) · \(connection.mailbox)"
        }
        if connections.count == 1 { return "\(connections[0].account.name) · \(connections[0].mailbox)" }
        return settings.text(isConnected ? "All accounts" : "Your inbox, in the menu bar.")
    }
    var totalUnreadCount: Int? {
        guard !connections.isEmpty, connections.allSatisfy({ unreadCounts[$0.id] != nil }) else { return nil }
        return connections.reduce(0) { $0 + (unreadCounts[$1.id] ?? 0) }
    }
    var loadingText: String? {
        if let listActivity { return settings.text(listActivity.rawValue) }
        if isSending { return settings.text("Sending message…") }
        if isPerformingAction { return settings.text("Updating message…") }
        return isLoadingBody ? settings.text("Opening message…") : nil
    }
    var errorMessage: String? {
        guard let error else { return nil }
        return settings.message(for: error)
    }
    var visibleMessages: [MailMessage] {
        (searchResults ?? messages).filter { message in
            (selectedAccountID.isEmpty || message.accountID == selectedAccountID)
                && (searchResults != nil || message.matches(search: searchText))
                && (filter != .unread || message.isRead == false)
                && (filter != .starred || message.isStarred == true)
                && (filter != .attachments || message.hasAttachments || !message.attachments.isEmpty)
        }
    }
    var searchScopeLabel: String {
        let active = connections.filter { selectedAccountID.isEmpty || $0.id == selectedAccountID }
        return settings.text(active.allSatisfy { capabilities(for: $0.id).contains(.search) } && !active.isEmpty
            ? "Search your mailbox" : "Search loaded messages")
    }
    func unreadCount(for id: String) -> Int? { unreadCounts[id] }
    func isMessageMoved(_ message: MailMessage) -> Bool { movedMessageIDs.contains(message.listID) }
    func canUndo(for message: MailMessage) -> Bool { canUndo && undo?.message.listID == message.listID }
    func capabilities(for id: String) -> MailCapabilities {
        guard let account = accounts.first(where: { $0.id == id }) ?? connections.first(where: { $0.id == id })?.account else { return [] }
        return mailClient(for: account).capabilities
    }
    private func mailClient(for account: MailAccount) -> any MailClient {
        account.provider == .appleMail ? client : directClient ?? client
    }
    private func connection(for message: MailMessage) -> MailboxConnection? {
        connections.first { $0.id == message.accountID }
    }
    private func persistConnections() {
        if let data = try? JSONEncoder().encode(connections) { settings.defaults.set(data, forKey: "MailboxConnections") }
    }
    private func merge(_ rows: [MailMessage], replacing id: String? = nil) {
        if let id { messages.removeAll { $0.accountID == id } }
        var identities = Set(messages.map(\.listID))
        messages += rows.filter { identities.insert($0.listID).inserted }
        messages.sort { ($0.receivedDateTime ?? "") > ($1.receivedDateTime ?? "") }
    }
    private func fetch(_ connection: MailboxConnection, check: Bool, query: String? = nil, token: String? = nil) async throws -> MailPage {
        let source = mailClient(for: connection.account)
        if let apple = source as? AppleMailClient {
            return try await apple.page(accountID: connection.id, mailbox: connection.mailbox, limit: settings.messageLimit.rawValue,
                query: query, pageToken: token, checkForMail: check)
        }
        if source.capabilities.contains(.pagination) || query != nil {
            var page = try await source.page(accountID: connection.id, mailbox: connection.mailbox, limit: settings.messageLimit.rawValue,
                query: query, pageToken: token)
            if query == nil, token == nil, page.unreadCount == nil {
                do { page.unreadCount = try await source.unreadCount(accountID: connection.id, mailbox: connection.mailbox) }
                catch { statusMessage = settings.text("Unread count is unavailable. Your messages are still available.") }
            }
            return page
        }
        return try await .init(messages: source.inbox(accountID: connection.id, mailbox: connection.mailbox,
            limit: settings.messageLimit.rawValue, checkForMail: check))
    }
    private func remember(_ page: MailPage, for connection: MailboxConnection, initial: Bool) -> [MailMessage] {
        let rows = page.messages.map { $0.scoped(to: connection.account) }
        movedMessageIDs.subtract(rows.map(\.listID))
        pages[connection.id] = page.nextPageToken
        unreadCounts[connection.id] = page.unreadCount
        let previous = seenIDs[connection.id] ?? []
        let baseline = newestReceived[connection.id] ?? Date()
        let arrivals = initial ? [] : rows.filter {
            !previous.contains($0.id) && $0.isRead == false && ($0.receivedAt.map { $0 > baseline } ?? false)
        }
        seenIDs[connection.id, default: []].formUnion(rows.map(\.id))
        newestReceived[connection.id] = max(rows.compactMap(\.receivedAt).max() ?? baseline, baseline)
        return arrivals
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        configureAutoRefresh()
        guard !isDemo else { return }
        let savedData = settings.defaults.data(forKey: "MailboxConnections")
        if let savedData, let saved = try? JSONDecoder().decode([MailboxConnection].self, from: savedData) {
            connections = saved.filter { directClient != nil || $0.account.provider == .appleMail }
            accounts = connections.map(\.account)
        }
        let savedID = settings.defaults.string(forKey: "AppleMailAccountID") ?? ""
        let savedMailbox = settings.defaults.string(forKey: "AppleMailMailbox") ?? ""
        guard directClient != nil || !connections.isEmpty || (!savedID.isEmpty && !savedMailbox.isEmpty) else { return }
        startupTask = Task {
            defer { startupTask = nil }
            if let directClient {
                do {
                    let remembered = try await directClient.accounts()
                    for account in remembered where !accounts.contains(where: { $0.id == account.id }) { accounts.append(account) }
                } catch { self.error = error }
            }
            if !connections.isEmpty { await refreshInbox(initial: true) }
            else if savedData == nil, !savedID.isEmpty, !savedMailbox.isEmpty {
                await loadAccounts()
                if accountID == savedID, mailboxName == savedMailbox, canConnect { await connect() }
            }
        }
    }
    func menuDidOpen() {
        start()
        guard screen == .mailbox, selected == nil, isConnected, !isDemo, !isBusy, menuRefreshTask == nil else { return }
        menuRefreshTask = Task { defer { menuRefreshTask = nil }; await refreshInbox(inBackground: true) }
    }
    func showSettings() { screen = .settings }
    func showAccountSetup() { screen = .account; error = nil }
    func goBack() {
        switch screen {
        case .settings, .compose: screen = .mailbox
        case .account: error = nil; screen = .settings
        case .mailbox: backToInbox()
        }
    }
    func selectInboxAccount(_ id: String) {
        guard id.isEmpty || connections.contains(where: { $0.id == id }) else { return }
        selectedAccountID = id
        focusedMessageID = nil
        searchResults = nil
        searchPages = [:]
    }
    func loadAccounts() async {
        guard !isBusy else { return }
        listActivity = .accounts; error = nil
        defer { listActivity = nil }
        do {
            let loaded = try await client.accounts()
            accounts = accounts.filter { $0.provider != .appleMail } + loaded
            mailboxCache = [:]
            let preferred = settings.defaults.string(forKey: "AppleMailAccountID")
            accountID = loaded.contains(where: { $0.id == preferred }) ? preferred! : (loaded.count == 1 ? loaded[0].id : "")
            mailboxes = []; mailboxName = ""
            if !accountID.isEmpty { try await updateMailboxes() }
            if loaded.isEmpty { error = MailError.message("No enabled Apple Mail accounts found. Add or enable an account in Mail first.") }
        } catch is CancellationError {} catch { self.error = error }
    }
    func selectAccount(_ id: String) async {
        guard !isBusy else { return }
        accountID = id; mailboxes = []; mailboxName = ""; error = nil
        guard !id.isEmpty else { return }
        listActivity = .mailboxes
        defer { listActivity = nil }
        do { try await updateMailboxes() } catch is CancellationError {} catch { self.error = error }
    }
    private func updateMailboxes() async throws {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        let loaded: [String]
        if let cached = mailboxCache[accountID] { loaded = cached }
        else {
            loaded = try await mailClient(for: account).mailboxes(accountID: accountID)
            mailboxCache[accountID] = loaded
        }
        mailboxes = loaded
        let preferred = connections.first(where: { $0.id == accountID })?.mailbox
            ?? (settings.defaults.string(forKey: "AppleMailAccountID") == accountID ? settings.defaults.string(forKey: "AppleMailMailbox") : nil)
        if let preferred, loaded.contains(preferred) { mailboxName = preferred }
        else { mailboxName = loaded.first { $0.caseInsensitiveCompare("INBOX") == .orderedSame } ?? "" }
    }
    func connectProvider(_ provider: MailProvider) async {
        guard !isBusy, let directClient, provider != .appleMail else { return }
        listActivity = .accounts; error = nil
        do {
            let account = try await directClient.signIn(provider: provider)
            if settings.defaults.object(forKey: "RefreshInterval") == nil { settings.refreshInterval = .oneMinute }
            accounts.removeAll { $0.id == account.id }; accounts.append(account)
            accountID = account.id
            try await updateMailboxes()
            listActivity = nil
            await connect(force: true)
        } catch is CancellationError { listActivity = nil }
        catch { self.error = error; listActivity = nil }
    }
    func connect() async { await connect(force: false) }
    private func connect(force: Bool) async {
        guard !isBusy, canConnect, let account = accounts.first(where: { $0.id == accountID }) else { return }
        if !force, connections.contains(where: { $0.id == accountID && $0.mailbox == mailboxName }) {
            screen = .mailbox; error = nil; return
        }
        listActivity = .messages; error = nil
        defer { listActivity = nil }
        let connection = MailboxConnection(account: account, mailbox: mailboxName)
        do {
            let page = try await fetch(connection, check: false)
            connections.removeAll { $0.id == account.id }; connections.append(connection)
            _ = remember(page, for: connection, initial: true)
            if isDemo { messages = [] }
            isDemo = false
            merge(page.messages.map { $0.scoped(to: account) }, replacing: account.id)
            cancelBody(); selected = nil; searchResults = nil; searchText = ""
            lastUpdated = Date(); accountErrors[account.id] = nil
            if account.provider == .appleMail {
                settings.defaults.set(account.id, forKey: "AppleMailAccountID")
                settings.defaults.set(connection.mailbox, forKey: "AppleMailMailbox")
            }
            persistConnections(); screen = .mailbox
        } catch is CancellationError {} catch { self.error = error }
    }
    func removeAccount(_ id: String) async {
        guard !isBusy, let account = accounts.first(where: { $0.id == id }) ?? connections.first(where: { $0.id == id })?.account else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            if account.provider != .appleMail { try await directClient?.signOut(accountID: id) }
            generation += 1
            if selected?.accountID == id { cancelBody(); selected = nil }
            if draft?.accountID == id { draft = nil }
            connections.removeAll { $0.id == id }; accounts.removeAll { $0.id == id }
            messages.removeAll { $0.accountID == id }; searchResults?.removeAll { $0.accountID == id }
            unreadCounts[id] = nil; pages[id] = nil; searchPages[id] = nil; accountErrors[id] = nil
            seenIDs[id] = nil; newestReceived[id] = nil; undo = nil
            movedMessageIDs = movedMessageIDs.filter { !$0.hasPrefix(id + ":") }
            if selectedAccountID == id { selectedAccountID = "" }
            if settings.defaults.string(forKey: "AppleMailAccountID") == id {
                settings.defaults.removeObject(forKey: "AppleMailAccountID"); settings.defaults.removeObject(forKey: "AppleMailMailbox")
            }
            persistConnections()
        } catch { self.error = error }
    }
    func retryAccount(_ id: String) async {
        await selectAccount(id)
        if canConnect { await connect(force: true) }
    }
    func refresh() async {
        if let selected { open(selected) } else { await refreshInbox() }
    }
    func refreshInBackground() async {
        await refreshInbox(inBackground: true, directOnly: screen != .mailbox || selected != nil)
    }
    private func refreshInbox(inBackground: Bool = false, initial: Bool = false, directOnly: Bool = false) async {
        guard !isLoadingList, !isPerformingAction, !isSending, !isLoadingBody else { return }
        if isDemo { lastUpdated = Date(); return }
        let targets = connections.filter { !directOnly || $0.account.provider != .appleMail }
        guard !targets.isEmpty else { return }
        isBackgroundRefresh = inBackground; listActivity = .refreshing; error = nil
        defer { listActivity = nil; isBackgroundRefresh = false }
        let requestGeneration = generation
        var arrivals: [MailMessage] = []
        var didUpdate = false
        for connection in targets {
            do {
                let page = try await fetch(connection, check: !initial)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                arrivals += remember(page, for: connection, initial: initial || seenIDs[connection.id] == nil)
                merge(page.messages.map { $0.scoped(to: connection.account) }, replacing: connection.id)
                accountErrors[connection.id] = nil; didUpdate = true
            } catch is CancellationError { return }
            catch { accountErrors[connection.id] = settings.message(for: error); self.error = error }
        }
        if didUpdate { lastUpdated = Date() }
        if !arrivals.isEmpty { onNewMessages?(arrivals) }
    }
    func configureAutoRefresh() {
        autoRefreshTask?.cancel(); autoRefreshTask = nil
        let interval = settings.refreshInterval == .manual && settings.notificationsEnabled ? 60 : settings.refreshInterval.rawValue
        guard interval > 0 else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self else { return }
                if !self.isBusy, !self.isDemo { await self.refreshInBackground() }
            }
        }
    }
    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || isDemo { searchResults = nil; searchPages = [:]; return }
        guard !isBusy else { return }
        listActivity = .messages; error = nil
        defer { listActivity = nil }
        let requestGeneration = generation
        let accountScope = selectedAccountID
        var result: [MailMessage] = []; var tokens: [String: String] = [:]
        for connection in scopedConnections {
            guard !Task.isCancelled, generation == requestGeneration, selectedAccountID == accountScope else { return }
            do {
                if capabilities(for: connection.id).contains(.search) {
                    let page = try await fetch(connection, check: false, query: query)
                    result += page.messages.map { $0.scoped(to: connection.account) }
                    tokens[connection.id] = page.nextPageToken
                } else { result += messages.filter { $0.accountID == connection.id && $0.matches(search: query) } }
            } catch is CancellationError { return }
            catch { self.error = error }
        }
        guard !Task.isCancelled, generation == requestGeneration, selectedAccountID == accountScope,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        searchResults = result.sorted { ($0.receivedDateTime ?? "") > ($1.receivedDateTime ?? "") }
        movedMessageIDs.subtract(result.map(\.listID))
        searchPages = tokens
    }
    func loadMore(whenShowing messageID: String? = nil) async {
        guard hasMoreMessages, !isBusy else { return }
        if let messageID, visibleMessages.last?.listID != messageID { return }
        listActivity = .messages
        defer { listActivity = nil }
        let searching = searchResults != nil
        let tokens = searching ? searchPages : pages
        let query = searchText
        let requestGeneration = generation
        let accountScope = selectedAccountID
        for connection in scopedConnections {
            guard !Task.isCancelled, generation == requestGeneration, selectedAccountID == accountScope else { return }
            guard let token = tokens[connection.id] else { continue }
            do {
                let page = try await fetch(connection, check: false, query: searching ? searchText : nil, token: token)
                try Task.checkCancellation()
                guard generation == requestGeneration, selectedAccountID == accountScope,
                      searchText == query, (searchResults != nil) == searching else { return }
                let rows = page.messages.map { $0.scoped(to: connection.account) }
                movedMessageIDs.subtract(rows.map(\.listID))
                if searching {
                    var identities = Set((searchResults ?? []).map(\.listID))
                    searchResults = (searchResults ?? []) + rows.filter { identities.insert($0.listID).inserted }
                    searchPages[connection.id] = page.nextPageToken
                } else { merge(rows); pages[connection.id] = page.nextPageToken }
            } catch { self.error = error }
        }
    }
    func open(_ message: MailMessage) {
        guard !isLoadingList || isBackgroundRefresh else { return }
        if isBackgroundRefresh { menuRefreshTask?.cancel() }
        cancelBody(); selected = message; focusedMessageID = message.listID; error = nil
        guard let connection = connection(for: message), !isDemo else { return }
        isLoadingBody = true
        bodyTask = Task {
            defer { if !Task.isCancelled { isLoadingBody = false; bodyTask = nil } }
            do {
                let body = try await mailClient(for: connection.account).body(message: message, accountID: connection.id, mailbox: connection.mailbox)
                try Task.checkCancellation()
                if selected?.listID == message.listID { selected = message.withBody(body) }
            } catch is CancellationError {} catch { if !Task.isCancelled, selected?.listID == message.listID { self.error = error } }
        }
    }
    private func cancelBody() { bodyTask?.cancel(); bodyTask = nil; isLoadingBody = false }
    func backToInbox() { cancelBody(); selected = nil; error = nil }
    func moveFocus(_ direction: Int) {
        let rows = visibleMessages
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.listID == focusedMessageID }
        let index = current.map { min(max($0 + direction, 0), rows.count - 1) } ?? (direction > 0 ? 0 : rows.count - 1)
        focusedMessageID = rows[index].listID
    }
    func openFocusedMessage() {
        if let row = visibleMessages.first(where: { $0.listID == focusedMessageID }) ?? visibleMessages.first { open(row) }
    }
    func compose() {
        if draft != nil { screen = .compose; onShowComposer?(); return }
        guard let connection = connections.first(where: { (selectedAccountID.isEmpty || $0.id == selectedAccountID) && capabilities(for: $0.id).contains(.send) }) else { return }
        draft = .init(accountID: connection.id); screen = .compose; error = nil; onShowComposer?()
    }
    func reply(to message: MailMessage, all: Bool = false, forward: Bool = false) {
        guard capabilities(for: message.accountID ?? "").contains(.send) else { return }
        if draft != nil { screen = .compose; onShowComposer?(); return }
        let own = connection(for: message)?.account.address?.lowercased()
        let reply = message.replyRecipients.compactMap(\.address)
        let additional = all ? message.recipients.compactMap(\.address).filter { $0.lowercased() != own && !reply.contains($0) } : []
        let to = Array(NSOrderedSet(array: reply + additional)) as? [String] ?? reply
        let cc = all ? message.copyRecipients.compactMap(\.address).filter { $0.lowercased() != own && !to.contains($0) } : []
        let prefix = forward ? "Fwd: " : "Re: "
        let subject = message.subject ?? ""
        let newSubject = subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : prefix + subject
        let content = ""
        let originalID = message.internetMessageID ?? message.body?.messageID
        draft = .init(accountID: message.accountID ?? "", to: forward ? "" : to.joined(separator: ", "), cc: cc.joined(separator: ", "),
            subject: newSubject, text: content, replyToMessageID: forward ? nil : message.id,
            inReplyToHeader: forward ? nil : originalID, references: forward ? nil : message.body?.references, threadID: forward ? nil : message.threadID,
            forwardMessageID: forward ? message.id : nil)
        screen = .compose; error = nil; onShowComposer?()
    }
    func discardDraft() { guard !isSending else { return }; draft = nil; screen = .mailbox; error = nil }
    func sendDraft() async {
        guard !isSending, let draft, let connection = connections.first(where: { $0.id == draft.accountID }) else { return }
        guard !draft.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = MailError.message("Add at least one recipient."); return
        }
        isSending = true; error = nil
        defer { isSending = false }
        do {
            try await mailClient(for: connection.account).send(draft)
            self.draft = nil; screen = .mailbox; statusMessage = settings.text("Message sent.")
        } catch { self.error = error }
    }
    func perform(_ action: MailAction, on message: MailMessage) async {
        guard !isBusy, !isMessageMoved(message), let connection = connection(for: message) else { return }
        isPerformingAction = true; error = nil
        defer { isPerformingAction = false }
        do {
            try await mailClient(for: connection.account).perform(action, message: message, accountID: connection.id, mailbox: connection.mailbox)
            let inverse: MailAction?
            switch action {
            case .markRead: inverse = message.isRead.map(MailAction.markRead)
            case .star: inverse = message.isStarred.map(MailAction.star)
            case .archive: inverse = .moveToInbox
            case .trash: inverse = .restoreFromTrash
            default: inverse = nil
            }
            undo = inverse.map { Undo(message: message, action: $0) }
            apply(action, to: message)
            statusMessage = settings.text("Message updated.")
            await refreshUnreadCount(connection)
        } catch { self.error = error }
    }
    private func apply(_ action: MailAction, to message: MailMessage) {
        let updated = message.applying(action)
        switch action {
        case .archive, .trash:
            movedMessageIDs.insert(message.listID)
            messages.removeAll { $0.listID == message.listID }; searchResults?.removeAll { $0.listID == message.listID }
            if selected?.listID == message.listID { backToInbox() }
            if message.isRead == false, let id = message.accountID, let count = unreadCounts[id] { unreadCounts[id] = max(count - 1, 0) }
        default:
            messages = messages.map { $0.listID == message.listID ? updated : $0 }
            searchResults = searchResults?.map { $0.listID == message.listID ? updated : $0 }
            if selected?.listID == message.listID { selected = selected?.applying(action) }
            if case .markRead(let read) = action, let previous = message.isRead, previous != read,
               let id = message.accountID, let count = unreadCounts[id] { unreadCounts[id] = max(count + (read ? -1 : 1), 0) }
        }
    }
    func undoLastAction() async {
        guard !isBusy, let undo, let connection = connection(for: undo.message) else { return }
        isPerformingAction = true; error = nil
        defer { isPerformingAction = false }
        do {
            try await mailClient(for: connection.account).perform(undo.action, message: undo.message, accountID: connection.id, mailbox: connection.mailbox)
            let current = searchResults?.first(where: { $0.listID == undo.message.listID })
                ?? messages.first(where: { $0.listID == undo.message.listID }) ?? undo.message
            let restored = current.applying(undo.action)
            movedMessageIDs.remove(undo.message.listID)
            messages.removeAll { $0.listID == undo.message.listID }; merge([restored])
            searchResults = searchResults?.map { $0.listID == restored.listID ? restored : $0 }
            if selected?.listID == undo.message.listID { selected = selected?.applying(undo.action) }
            self.undo = nil; statusMessage = settings.text("Action undone.")
            await refreshUnreadCount(connection)
            if searchResults != nil {
                isPerformingAction = false
                await search()
            }
        } catch { self.error = error }
    }
    private func refreshUnreadCount(_ connection: MailboxConnection) async {
        do { unreadCounts[connection.id] = try await mailClient(for: connection.account).unreadCount(accountID: connection.id, mailbox: connection.mailbox) }
        catch {
            unreadCounts[connection.id] = nil
            statusMessage = settings.text("Unread count is unavailable. Your messages are still available.")
        }
    }
    func attachmentData(_ attachment: MailAttachment, message: MailMessage) async throws -> Data {
        if let data = attachment.data { return data }
        guard let connection = connection(for: message) else { throw MailError.message("The account is no longer connected.") }
        return try await mailClient(for: connection.account).attachmentData(attachment: attachment, message: message, accountID: connection.id, mailbox: connection.mailbox)
    }
    func report(_ error: Error) { self.error = error }
    func clearStatus() { statusMessage = nil }
    func startDemo() {
        cancelBody(); generation += 1; connections = []; isDemo = true
        accounts = []; accountID = ""; mailboxName = ""; mailboxes = []
        draft = nil; undo = nil; statusMessage = nil; accountErrors = [:]; movedMessageIDs = []
        messages = Self.demoMessages.enumerated().map { index, original in
            var message = original
            message.isRead = index != 0
            message.isStarred = index == 1
            message.to = [.init(name: "Sample Reader", address: "reader@example.com")]
            if index == 0, var body = message.body {
                let data = Data("This is an Envl sample attachment.\n".utf8)
                body.attachments = [.init(id: "sample-notes", name: "sample-notes.txt", mimeType: "text/plain", size: data.count, data: data)]
                message.body = body
                message.hasAttachments = true
            }
            return message
        }
        selected = nil; selectedAccountID = ""; searchText = ""; filter = .all
        searchResults = nil; unreadCounts = [:]; pages = [:]; lastUpdated = Date(); error = nil; screen = .mailbox
    }

    private static var demoMessages: [MailMessage] {
        let now = Date()
        return [
            MailMessage(id: "demo-1", subject: "Welcome to Envl", from: .init(emailAddress: .init(name: "Envl", address: "hello@example.com")), receivedDateTime: now.ISO8601Format(), body: .init(contentType: "html", content: """
            <html lang="en"><head><meta charset="utf-8"></head><body style="font:15px -apple-system;padding:20px;color:#242424;background:#fff">
            <h2 style="color:#2563eb">Your inbox, one click away.</h2><p>This is a <strong>sample email</strong>, not a message from a connected account.</p>
            <p>Read a message here, then use the arrow above to return to your inbox. Open Settings to choose a language, appearance or refresh interval.</p>
            <table style="border-collapse:collapse;width:100%"><tr style="background:#eff6ff"><th style="padding:10px;text-align:left">Format</th><th style="padding:10px;text-align:left">Example</th></tr><tr><td style="padding:10px">HTML email</td><td style="padding:10px">Bold text, colors and tables</td></tr></table>
            <p>To read your own messages, choose an Apple Mail mailbox in Settings.</p>
            </body></html>
            """)),
            MailMessage(id: "demo-2", subject: "Weekly notes", from: .init(emailAddress: .init(name: "Sample Team", address: "team@example.com")), receivedDateTime: now.addingTimeInterval(-3600).ISO8601Format(), body: .init(contentType: "html", content: "<html lang=\"en\"><body style=\"font:15px -apple-system;padding:20px\"><h2>Weekly notes</h2><p>A sample message for trying the reader.</p><ul><li>Browse recent messages.</li><li>Read the full email.</li><li>Return to your inbox and refresh.</li></ul><p><em>Sample data does not verify an account connection.</em></p></body></html>")),
            MailMessage(id: "demo-3", subject: "A plain text email", from: .init(emailAddress: .init(name: "Sample Sender", address: "sender@example.com")), receivedDateTime: now.addingTimeInterval(-86400).ISO8601Format(), body: .init(contentType: "text", content: "Hello,\n\nLine breaks are preserved in plain text emails.\n<This line is displayed as text, not HTML.>\n\nThis is sample data."))
        ]
    }
}
