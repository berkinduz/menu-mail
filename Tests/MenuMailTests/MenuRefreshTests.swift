import AppKit
import Testing
@testable import MenuMail

private actor TestMailClient: MailClient {
    private var pendingRefresh: CheckedContinuation<[MailMessage], Error>?
    private(set) var refreshRequests = 0
    private(set) var requestedLimit = 0

    func accounts() async throws -> [MailAccount] { [.init(id: "test", name: "Test account")] }
    func mailboxes(accountID: String) async throws -> [String] { ["Inbox"] }

    func inbox(accountID: String, mailbox: String, limit: Int, checkForMail: Bool) async throws -> [MailMessage] {
        guard checkForMail else { return [Self.message("cached")] }
        refreshRequests += 1
        requestedLimit = limit
        // Deliberately waits for the test, even if cancelled, to exercise late replies.
        return try await withCheckedThrowingContinuation { pendingRefresh = $0 }
    }

    func body(message: MailMessage, accountID: String, mailbox: String) async throws -> MailMessage.Body {
        .init(contentType: "text", content: "Test body")
    }

    func completeRefresh(id: String) {
        let pending = pendingRefresh
        pendingRefresh = nil
        pending?.resume(returning: [Self.message(id)])
    }

    func failRefresh() {
        let pending = pendingRefresh
        pendingRefresh = nil
        pending?.resume(throwing: MailError.message("Test refresh failed"))
    }

    static func message(_ id: String) -> MailMessage {
        .init(id: id, subject: "Example", from: nil, receivedDateTime: nil, body: nil, sourceIndex: 0)
    }
}

@MainActor
@Suite
struct MenuRefreshTests {
    @MainActor
    private struct Fixture {
        let domain = "MenuMailTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let client = TestMailClient()
        let store: MailboxStore

        init() {
            defaults = UserDefaults(suiteName: domain)!
            store = MailboxStore(settings: AppSettings(defaults: defaults), client: client)
            store.start()
        }

        func connect() async {
            await store.loadAccounts()
            await store.connect()
        }

        func cleanup() { defaults.removePersistentDomain(forName: domain) }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard clock.now < deadline else { throw WaitError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum WaitError: Error { case timeout }

    @Test func everyOpeningRefreshesWhileKeepingTheExistingList() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        await fixture.connect()
        let initialUpdate = fixture.store.lastUpdated

        fixture.store.menuDidOpen()
        #expect(fixture.store.messages.first?.id == "cached")
        try await waitUntil { await fixture.client.refreshRequests == 1 }
        #expect(fixture.store.isLoadingList)
        #expect(fixture.store.lastUpdated == initialUpdate)
        #expect(await fixture.client.requestedLimit == 20)
        await fixture.client.completeRefresh(id: "new")
        try await waitUntil { !fixture.store.isBusy }
        #expect(fixture.store.messages.first?.id == "new")

        fixture.store.menuDidOpen()
        #expect(fixture.store.messages.first?.id == "new")
        try await waitUntil { await fixture.client.refreshRequests == 2 }
        await fixture.client.completeRefresh(id: "newer")
        try await waitUntil { !fixture.store.isBusy }
        #expect(fixture.store.messages.first?.id == "newer")
    }

    @Test func repeatedOpenEventsShareTheInFlightRefresh() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        await fixture.connect()
        fixture.store.menuDidOpen()
        fixture.store.menuDidOpen()
        fixture.store.menuDidOpen()
        try await waitUntil { await fixture.client.refreshRequests == 1 }
        await fixture.client.completeRefresh(id: "new")
        try await waitUntil { !fixture.store.isBusy }
        #expect(await fixture.client.refreshRequests == 1)
    }

    @Test func aCachedMessageCanOpenDuringRefreshAndLateRepliesAreDiscarded() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        await fixture.connect()
        let cached = try #require(fixture.store.messages.first)
        let initialUpdate = fixture.store.lastUpdated
        fixture.store.menuDidOpen()
        try await waitUntil { await fixture.client.refreshRequests == 1 }

        fixture.store.open(cached)
        #expect(fixture.store.selected?.id == "cached")
        try await waitUntil { !fixture.store.isLoadingBody }
        #expect(fixture.store.selected?.body?.content == "Test body")
        await fixture.client.completeRefresh(id: "late reply")
        try await waitUntil { !fixture.store.isLoadingList }
        #expect(fixture.store.messages.first?.id == "cached")
        #expect(fixture.store.lastUpdated == initialUpdate)
        #expect(fixture.store.error == nil)
    }

    @Test func refreshFailurePreservesTheListAndItsTimestamp() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        await fixture.connect()
        let initialUpdate = fixture.store.lastUpdated
        fixture.store.menuDidOpen()
        try await waitUntil { await fixture.client.refreshRequests == 1 }
        await fixture.client.failRefresh()
        try await waitUntil { !fixture.store.isBusy }
        #expect(fixture.store.messages.first?.id == "cached")
        #expect(fixture.store.lastUpdated == initialUpdate)
        #expect(fixture.store.errorMessage == "Test refresh failed")
    }

    @Test func settingsReaderAndSampleDataAreNotInterrupted() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        await fixture.connect()
        fixture.store.showSettings()
        fixture.store.menuDidOpen()
        #expect(await fixture.client.refreshRequests == 0)

        fixture.store.goBack()
        fixture.store.open(try #require(fixture.store.messages.first))
        try await waitUntil { !fixture.store.isLoadingBody }
        fixture.store.menuDidOpen()
        #expect(await fixture.client.refreshRequests == 0)
        #expect(fixture.store.selected?.body != nil)

        fixture.store.startDemo()
        fixture.store.menuDidOpen()
        #expect(await fixture.client.refreshRequests == 0)
        #expect(fixture.store.isDemo)
    }

    @Test func theSameWindowCanReportMultipleOpenings() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let observer = MenuWindowObserver.ObserverView()
        var openings = 0
        observer.onOpen = { openings += 1 }
        window.contentView = observer
        defer { window.orderOut(nil); otherWindow.orderOut(nil) }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: otherWindow)
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await waitUntil { openings == 1 }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await Task.yield()
        #expect(openings == 1)
        window.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        window.orderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try await waitUntil { openings == 2 }
        window.contentView = nil
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await Task.yield()
        #expect(openings == 2)
    }
}
