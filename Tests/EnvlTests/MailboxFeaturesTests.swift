import Foundation
import Testing
@testable import Envl

private actor FeatureMailClient: DirectMailConnecting {
    nonisolated let capabilities: MailCapabilities = .direct
    private var rows: [String: [MailMessage]] = [
        "gmail:first": [.init(id: "shared", subject: "First budget", from: nil, receivedDateTime: "2026-11-05T09:00:00Z", body: nil, isRead: false)],
        "outlook:second": [.init(id: "shared", subject: "Second notes", from: nil, receivedDateTime: "2026-11-05T10:00:00Z", body: nil, isRead: true)]
    ]
    private(set) var actions: [(String, MailAction)] = []
    private var failSending = false
    private var failCount = false
    private var paging = false
    private var immediatePages = false
    private var counts = ["gmail:first": 120, "outlook:second": 0]
    private var moved: [String: MailMessage] = [:]
    private(set) var searchRequests: [String] = []
    private(set) var pageRequests: [String] = []
    private(set) var pageLoads = 0
    private var pendingPage: CheckedContinuation<MailPage, any Error>?
    private(set) var isPageWaiting = false
    func accounts() async throws -> [MailAccount] {
        [.init(id: "gmail:first", name: "First", provider: .gmail, address: "first@example.com")]
    }
    func signIn(provider: MailProvider) async throws -> MailAccount {
        provider == .gmail ? .init(id: "gmail:first", name: "First", provider: .gmail, address: "first@example.com")
            : .init(id: "outlook:second", name: "Second", provider: .outlook, address: "second@example.com")
    }
    func signOut(accountID: String) async throws {}
    func mailboxes(accountID: String) async throws -> [String] { ["Inbox"] }
    func inbox(accountID: String, mailbox: String, limit: Int, checkForMail: Bool) async throws -> [MailMessage] { rows[accountID] ?? [] }
    func page(accountID: String, mailbox: String, limit: Int, query: String?, pageToken: String?) async throws -> MailPage {
        pageLoads += 1
        if let query, !query.isEmpty { searchRequests.append(accountID) }
        if pageToken != nil {
            pageRequests.append(accountID)
            if immediatePages { return .init(messages: []) }
            isPageWaiting = true
            return try await withCheckedThrowingContinuation { pendingPage = $0 }
        }
        return .init(messages: (rows[accountID] ?? []).filter { $0.matches(search: query ?? "") }, nextPageToken: paging ? "older" : nil)
    }
    func unreadCount(accountID: String, mailbox: String) async throws -> Int? {
        if failCount { throw MailError.message("Count unavailable") }
        return counts[accountID]
    }
    func body(message: MailMessage, accountID: String, mailbox: String) async throws -> MailMessage.Body {
        .init(contentType: "text", content: "Body for \(accountID)")
    }
    func perform(_ action: MailAction, message: MailMessage, accountID: String, mailbox: String) async throws {
        actions.append((accountID, action))
        var accountRows = rows[accountID] ?? []
        let index = accountRows.firstIndex { $0.id == message.id }
        switch action {
        case .markRead(let read):
            if let index, let previous = accountRows[index].isRead, read != previous {
                counts[accountID, default: 0] += read ? -1 : 1
                accountRows[index] = accountRows[index].applying(action)
            }
        case .archive, .trash:
            if let index {
                let row = accountRows.remove(at: index)
                moved["\(accountID):\(message.id)"] = row
                if row.isRead == false { counts[accountID, default: 0] -= 1 }
            }
        case .moveToInbox, .restoreFromTrash:
            if let row = moved.removeValue(forKey: "\(accountID):\(message.id)") {
                accountRows.append(row)
                if row.isRead == false { counts[accountID, default: 0] += 1 }
            }
        case .star:
            if let index { accountRows[index] = accountRows[index].applying(action) }
        }
        rows[accountID] = accountRows
    }
    func send(_ draft: MailDraft) async throws {
        if failSending { throw MailError.message("Sending failed") }
    }
    func setFailSending() { failSending = true }
    func setFailCount() { failCount = true }
    func enablePaging(immediate: Bool = false) { paging = true; immediatePages = immediate }
    func setUnreadCount(_ count: Int, accountID: String) { counts[accountID] = count }
    func completePage(messages: [MailMessage]? = nil) {
        pendingPage?.resume(returning: .init(messages: messages ?? [.init(id: "older", subject: "Old search result", from: nil, receivedDateTime: nil, body: nil)]))
        pendingPage = nil
        isPageWaiting = false
    }
    func replaceRows(_ messages: [MailMessage], accountID: String) { rows[accountID] = messages }
    func restoreExternally(_ message: MailMessage, accountID: String) {
        moved[message.listID] = nil
        rows[accountID, default: []].append(message)
        if message.isRead == false { counts[accountID, default: 0] += 1 }
    }
}

private actor ReadOnlyFeatureClient: MailClient {
    private(set) var refreshes = 0
    func accounts() async throws -> [MailAccount] { [.init(id: "apple", name: "Apple test")] }
    func mailboxes(accountID: String) async throws -> [String] { ["Inbox"] }
    func inbox(accountID: String, mailbox: String, limit: Int, checkForMail: Bool) async throws -> [MailMessage] {
        if checkForMail { refreshes += 1 }
        return [.init(id: "apple-message", subject: "Apple sample", from: nil, receivedDateTime: nil, body: nil)]
    }
    func body(message: MailMessage, accountID: String, mailbox: String) async throws -> MailMessage.Body { .init(contentType: "text", content: "Body") }
}

@MainActor
struct MailboxFeaturesTests {
    private func fixture() -> (MailboxStore, FeatureMailClient, UserDefaults, String) {
        let domain = "EnvlFeatureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let client = FeatureMailClient()
        return (MailboxStore(settings: AppSettings(defaults: defaults), directClient: client), client, defaults, domain)
    }

    @Test func appleMailOnlyStartupDoesNotRestoreDirectProviderConnections() async throws {
        let domain = "EnvlAppleMailOnlyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let saved = [
            MailboxConnection(account: .init(id: "apple", name: "Apple test"), mailbox: "Inbox"),
            MailboxConnection(account: .init(id: "gmail:first", name: "Gmail test", provider: .gmail), mailbox: "Inbox"),
            MailboxConnection(account: .init(id: "outlook:second", name: "Outlook test", provider: .outlook), mailbox: "Inbox")
        ]
        defaults.set(try JSONEncoder().encode(saved), forKey: "MailboxConnections")
        let settings = AppSettings(defaults: defaults)
        settings.refreshInterval = .manual
        let store = MailboxStore(settings: settings, client: ReadOnlyFeatureClient())

        store.start()
        try await waitUntil { store.lastUpdated != nil && !store.isBusy }

        #expect(store.connections.map(\.id) == ["apple"])
        #expect(store.accounts.map(\.id) == ["apple"])
        #expect(store.messages.map(\.accountID) == ["apple"])
        #expect(!store.canCompose)
    }

    @Test func sampleInboxSearchUsesLocalMessagesAndClearingRestoresTheList() async {
        let domain = "EnvlSampleSearchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let client = FeatureMailClient()
        let store = MailboxStore(settings: AppSettings(defaults: defaults), client: client, directClient: client)
        store.startDemo()
        let allSampleIDs = store.visibleMessages.map(\.listID)

        store.searchText = "Weekly"
        await store.search()
        #expect(store.visibleMessages.map(\.subject) == ["Weekly notes"])

        store.searchText = ""
        await store.search()
        #expect(store.visibleMessages.map(\.listID) == allSampleIDs)
        #expect(await client.pageLoads == 0)
    }

    @Test func unifiedInboxKeepsBothAccountsAndUsesFullUnreadTotals() async throws {
        let (store, _, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await store.connectProvider(.gmail)
        await store.connectProvider(.outlook)
        #expect(store.connections.count == 2)
        #expect(store.messages.count == 2)
        #expect(Set(store.messages.map(\.listID)).count == 2)
        #expect(store.totalUnreadCount == 120)
        store.filter = .unread
        #expect(store.visibleMessages.map(\.subject) == ["First budget"])
        store.filter = .all
        store.searchText = "Second"
        await store.search()
        #expect(store.visibleMessages.count == 1)
        #expect(store.visibleMessages.first?.accountID == "outlook:second")
    }

    @Test func mutationAndUndoOnlyChangeTheOriginatingAccount() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await store.connectProvider(.gmail)
        await store.connectProvider(.outlook)
        let first = try #require(store.messages.first { $0.accountID == "gmail:first" })
        await store.perform(.markRead(true), on: first)
        #expect(store.messages.first { $0.accountID == "gmail:first" }?.isRead == true)
        #expect(store.messages.first { $0.accountID == "outlook:second" }?.isRead == true)
        await store.undoLastAction()
        #expect(store.messages.first { $0.accountID == "gmail:first" }?.isRead == false)
        let actions = await client.actions
        #expect(actions.count == 2)
        #expect(actions.allSatisfy { $0.0 == "gmail:first" })
        #expect(actions.last?.1 == .markRead(false))
    }

    @Test func draftsSurviveNavigationAndFailedSend() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await store.connectProvider(.gmail)
        store.compose()
        store.draft?.to = "recipient@example.com"
        store.draft?.text = "Keep this reply"
        store.goBack()
        #expect(store.draft?.text == "Keep this reply")
        await client.setFailSending()
        await store.sendDraft()
        #expect(store.draft?.text == "Keep this reply")
        #expect(store.errorMessage == "Sending failed")
    }

    @Test func replyRequestsAVisibleComposerAndResumingKeepsTheDraft() async throws {
        let (store, _, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await store.connectProvider(.gmail)
        var presentations = 0
        store.onShowComposer = { presentations += 1 }
        let message = try #require(store.messages.first)
        store.reply(to: message)
        #expect(presentations == 1)
        store.draft?.text = "Retain this reply"
        store.goBack()
        store.compose()
        #expect(presentations == 2)
        #expect(store.draft?.text == "Retain this reply")
    }

    @Test func removingOneAccountPreservesTheOther() async throws {
        let (store, _, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await store.connectProvider(.gmail)
        await store.connectProvider(.outlook)
        await store.removeAccount("gmail:first")
        #expect(store.connections.map(\.id) == ["outlook:second"])
        #expect(store.messages.allSatisfy { $0.accountID == "outlook:second" })
    }

    @Test func connectingAfterSampleDataReplacesTheSampleMessages() async throws {
        let (store, _, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        store.startDemo()
        #expect(store.isDemo)
        await store.connectProvider(.gmail)
        #expect(!store.isDemo)
        #expect(store.messages.count == 1)
        #expect(store.messages.allSatisfy { $0.accountID == "gmail:first" })
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            if ContinuousClock.now > deadline { throw WaitFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private enum WaitFailure: Error { case timeout }

    @Test func rememberedAccountCanRecoverWithoutFirstOpeningAppleMail() async throws {
        let (store, _, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        store.start()
        try await waitUntil { store.accounts.count == 1 }
        #expect(!store.isConnected)
        await store.retryAccount("gmail:first")
        #expect(store.connections.map(\.id) == ["gmail:first"])
        #expect(store.messages.count == 1)
    }

    @Test func rememberedUnconnectedAccountCanBeRemoved() async throws {
        let (store, _, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        store.start()
        try await waitUntil { store.accounts.count == 1 }
        await store.removeAccount("gmail:first")
        #expect(store.accounts.isEmpty)
        #expect(!store.isConnected)
    }

    @Test func countFailureKeepsMessagesAndDoesNotInventZeroUnread() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await client.setFailCount()
        await store.connectProvider(.gmail)
        #expect(store.isConnected)
        #expect(store.messages.count == 1)
        #expect(store.totalUnreadCount == nil)
        #expect(store.statusMessage != nil)
    }

    @Test func scrollingOnlyLoadsAnotherPageAtTheLastVisibleMessage() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await client.replaceRows([
            .init(id: "recent", subject: "Recent mail", from: nil, receivedDateTime: "2026-11-05T10:00:00Z", body: nil),
            .init(id: "previous", subject: "Previous mail", from: nil, receivedDateTime: "2026-11-05T09:00:00Z", body: nil)
        ], accountID: "gmail:first")
        await client.enablePaging(immediate: true)
        await store.connectProvider(.gmail)
        let rows = store.visibleMessages

        await store.loadMore(whenShowing: rows[0].listID)
        #expect(await client.pageRequests.isEmpty)

        await store.loadMore(whenShowing: rows[1].listID)
        #expect(await client.pageRequests == ["gmail:first"])
        #expect(!store.hasMoreMessages)

        let last = try #require(store.visibleMessages.last)
        await store.loadMore(whenShowing: last.listID)
        #expect(await client.pageRequests == ["gmail:first"])
    }

    @Test func latePageDoesNotEnterANewerSearchContext() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await client.enablePaging()
        await store.connectProvider(.gmail)
        let loading = Task { await store.loadMore() }
        try await waitUntil { await client.isPageWaiting }
        store.searchText = "Different search"
        await client.completePage()
        await loading.value
        #expect(!store.messages.contains { $0.id == "older" })
        #expect(store.visibleMessages.isEmpty)
    }

    @Test func initialSynchronizationAndRepeatRefreshDoNotNotifyOldMessages() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        var notifications: [String] = []
        store.onNewMessages = { notifications += $0.map(\.listID) }
        await client.replaceRows([.init(id: "old-mail", subject: "Existing mail", from: nil,
            receivedDateTime: Date().addingTimeInterval(-60).ISO8601Format(), body: nil, isRead: false)], accountID: "gmail:first")
        await store.connectProvider(.gmail)
        #expect(notifications.isEmpty)
        let arrival = MailMessage(id: "new-arrival", subject: "New mail", from: nil,
            receivedDateTime: Date().addingTimeInterval(2).ISO8601Format(), body: nil, isRead: false)
        await client.replaceRows([arrival], accountID: "gmail:first")
        await store.refreshInBackground()
        await store.refreshInBackground()
        #expect(notifications == ["gmail:first:new-arrival"])
    }

    @Test func detachedSnapshotCannotRepeatAMovedMessageMutation() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await store.connectProvider(.gmail)
        let detached = try #require(store.messages.first)
        await store.perform(.archive, on: detached)
        await store.perform(.trash, on: detached)
        #expect(await client.actions.count == 1)
        #expect(store.totalUnreadCount == 119)
        await store.undoLastAction()
        #expect(store.messages.count == 1)
        #expect(store.totalUnreadCount == 120)
    }

    @Test func searchAndPaginationOnlyContactTheSelectedAccount() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await client.enablePaging(immediate: true)
        await store.connectProvider(.gmail)
        await store.connectProvider(.outlook)
        store.selectInboxAccount("outlook:second")
        store.searchText = "notes"
        await store.search()
        await store.loadMore()
        #expect(await client.searchRequests == ["outlook:second", "outlook:second"])
        #expect(await client.pageRequests == ["outlook:second"])
    }

    @Test func undoUsesTheCurrentUnreadTotalAfterAnotherRefresh() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await store.connectProvider(.gmail)
        let message = try #require(store.messages.first)
        await store.perform(.markRead(true), on: message)
        #expect(store.totalUnreadCount == 119)
        await client.setUnreadCount(120, accountID: "gmail:first")
        await store.refreshInBackground()
        #expect(store.totalUnreadCount == 120)
        await store.undoLastAction()
        #expect(store.totalUnreadCount == 121)
    }

    @Test func undoRestoresAMatchingSearchResultWithoutLosingTheQuery() async throws {
        let (store, _, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await store.connectProvider(.gmail)
        store.searchText = "budget"
        await store.search()
        let message = try #require(store.visibleMessages.first)
        await store.perform(.archive, on: message)
        #expect(store.visibleMessages.isEmpty)
        await store.undoLastAction()
        #expect(store.searchText == "budget")
        #expect(store.visibleMessages.map(\.id) == ["shared"])
    }

    @Test func providerSearchAndPagingCanConfirmAnExternallyRestoredMessage() async throws {
        let (store, client, defaults, domain) = fixture()
        defer { defaults.removePersistentDomain(forName: domain) }
        await client.enablePaging()
        await store.connectProvider(.gmail)
        let original = try #require(store.messages.first)
        await store.perform(.archive, on: original)
        #expect(store.isMessageMoved(original))
        await client.restoreExternally(original, accountID: "gmail:first")
        store.searchText = "budget"
        await store.search()
        #expect(!store.isMessageMoved(original))
        await store.perform(.archive, on: original)
        #expect(store.isMessageMoved(original))
        store.searchText = ""
        await store.search()
        await client.restoreExternally(original, accountID: "gmail:first")
        let load = Task { await store.loadMore() }
        try await waitUntil { await client.isPageWaiting }
        await client.completePage(messages: [original])
        await load.value
        #expect(!store.isMessageMoved(original))
    }

    @Test func mixedAccountsKeepDirectRefreshRunningWhileAppleMailIsPaused() async throws {
        let domain = "EnvlMixedRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let apple = ReadOnlyFeatureClient()
        let direct = FeatureMailClient()
        let store = MailboxStore(settings: AppSettings(defaults: defaults), client: apple, directClient: direct)
        await store.loadAccounts()
        await store.connect()
        await store.connectProvider(.gmail)
        store.showSettings()
        await store.refreshInBackground()
        #expect(await apple.refreshes == 0)
        #expect(await direct.pageLoads == 2)
    }
}
