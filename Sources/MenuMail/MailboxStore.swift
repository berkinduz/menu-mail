import Foundation
import Observation

struct MailMessage: Decodable, Identifiable, Sendable {
    let id: String
    let subject: String?
    let from: Sender?
    let receivedDateTime: String?
    let body: Body?
    var sourceIndex: Int? = nil

    struct Sender: Decodable, Sendable { let emailAddress: Address }
    struct Address: Decodable, Sendable { let name: String?; let address: String? }
    struct Body: Decodable, Sendable { let contentType: String; let content: String }

    func title(language: AppLanguage) -> String {
        subject.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("(No subject)", language: language)
    }

    func sender(language: AppLanguage) -> String {
        let address = from?.emailAddress
        return address?.name.flatMap { $0.isEmpty ? nil : $0 } ?? address?.address
            ?? L10n.text("Unknown sender", language: language)
    }

    private var date: Date? {
        guard let receivedDateTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: receivedDateTime) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: receivedDateTime)
    }

    func shortDate(locale: Locale) -> String {
        guard let date else { return "" }
        return date.formatted(Date.FormatStyle(date: Calendar.current.isDateInToday(date) ? .omitted : .numeric,
                                               time: .shortened, locale: locale))
    }

    func longDate(locale: Locale) -> String {
        date?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)) ?? ""
    }

    func withBody(_ body: Body) -> MailMessage {
        MailMessage(id: id, subject: subject, from: from, receivedDateTime: receivedDateTime, body: body, sourceIndex: sourceIndex)
    }
}

@MainActor
@Observable
final class MailboxStore {
    enum Screen { case mailbox, settings, account, about }

    private enum ListActivity: String {
        case accounts = "Loading accounts…"
        case mailboxes = "Loading mailboxes…"
        case messages = "Loading messages…"
        case refreshing = "Refreshing messages…"
    }

    private struct Connection {
        let accountID: String
        let accountName: String
        let mailbox: String
    }

    let settings: AppSettings
    private(set) var screen: Screen = .mailbox
    private(set) var accounts: [MailAccount] = []
    // Draft choices do not replace the active connection until Connect succeeds.
    private(set) var accountID = ""
    private(set) var mailboxes: [String] = []
    var mailboxName = ""
    private(set) var messages: [MailMessage] = []
    private(set) var selected: MailMessage?
    private(set) var isDemo = false
    private var listActivity: ListActivity?
    private(set) var isLoadingBody = false
    private(set) var lastUpdated: Date?
    private(set) var error: Error?

    private var connection: Connection?
    private var mailboxCache: [String: [String]] = [:]
    private let client = AppleMailClient()
    @ObservationIgnored private var bodyTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    private var didStart = false

    init(settings: AppSettings) { self.settings = settings }

    var isConnected: Bool { connection != nil }
    var isLoadingList: Bool { listActivity != nil }
    var isBusy: Bool { isLoadingList || isLoadingBody }
    var loadingText: String? {
        if let listActivity { return settings.text(listActivity.rawValue) }
        return isLoadingBody ? settings.text("Opening message…") : nil
    }
    var canConnect: Bool { !accountID.isEmpty && mailboxes.contains(mailboxName) }
    var canGoBack: Bool { screen != .mailbox || selected != nil }
    var accountName: String? { connection?.accountName }
    var connectedMailbox: String? { connection?.mailbox }
    var sourceLabel: String {
        guard let connection else { return settings.text("Apple Mail · Read only") }
        return "\(connection.accountName) · \(connection.mailbox)"
    }

    var errorMessage: String? {
        guard let error else { return nil }
        if let mailError = error as? MailError { return mailError.message(language: settings.language) }
        if error is DecodingError { return settings.text("Could not read Apple Mail's response. Please try again.") }
        return error.localizedDescription
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        configureAutoRefresh()
        guard !isDemo else { return }
        let savedID = settings.defaults.string(forKey: "AppleMailAccountID") ?? ""
        let savedMailbox = settings.defaults.string(forKey: "AppleMailMailbox") ?? ""
        guard !savedID.isEmpty, !savedMailbox.isEmpty else { return }
        startupTask = Task {
            defer { startupTask = nil }
            await loadAccounts()
            // Do not substitute a different mailbox for an unavailable saved choice.
            if accountID == savedID, mailboxName == savedMailbox, canConnect {
                await connect()
            }
        }
    }

    func showSettings() { screen = .settings }

    func showAbout() { screen = .about }

    func showAccountSetup() {
        screen = .account
        error = nil
    }

    func goBack() {
        switch screen {
        case .settings: screen = .mailbox
        case .about: screen = .settings
        case .account:
            error = nil
            screen = .settings
        case .mailbox: backToInbox()
        }
    }

    func loadAccounts() async {
        guard !isBusy else { return }
        listActivity = .accounts
        error = nil
        defer { listActivity = nil }
        do {
            let loaded = try await client.accounts()
            accounts = loaded
            mailboxCache = [:]
            let preferredID = connection?.accountID ?? settings.defaults.string(forKey: "AppleMailAccountID")
            if let preferredID, loaded.contains(where: { $0.id == preferredID }) {
                accountID = preferredID
            } else {
                accountID = loaded.count == 1 ? loaded[0].id : ""
            }
            mailboxes = []
            mailboxName = ""
            if !accountID.isEmpty { try await updateMailboxes() }
            if loaded.isEmpty {
                error = MailError.message("No enabled Apple Mail accounts found. Add or enable an account in Mail first.")
            }
        } catch is CancellationError {
        } catch { self.error = error }
    }

    func selectAccount(_ id: String) async {
        guard !isBusy else { return }
        accountID = id
        mailboxes = []
        mailboxName = ""
        error = nil
        guard !id.isEmpty else { return }
        listActivity = .mailboxes
        defer { listActivity = nil }
        do { try await updateMailboxes() }
        catch is CancellationError {
        } catch { self.error = error }
    }

    private func updateMailboxes() async throws {
        let loaded: [String]
        if let cached = mailboxCache[accountID] {
            loaded = cached
        } else {
            listActivity = .mailboxes
            loaded = try await client.mailboxes(accountID: accountID)
            mailboxCache[accountID] = loaded
        }
        mailboxes = loaded
        let savedID = settings.defaults.string(forKey: "AppleMailAccountID")
        let preferred = connection?.accountID == accountID ? connection?.mailbox
            : savedID == accountID ? settings.defaults.string(forKey: "AppleMailMailbox") : nil
        if let preferred, loaded.contains(preferred) {
            mailboxName = preferred
        } else if let inbox = loaded.first(where: { $0.caseInsensitiveCompare("INBOX") == .orderedSame }) {
            mailboxName = inbox
        }
    }

    func connect() async {
        guard !isBusy, canConnect else { return }
        if connection?.accountID == accountID, connection?.mailbox == mailboxName {
            screen = .mailbox
            error = nil
            return
        }
        listActivity = .messages
        error = nil
        defer { listActivity = nil }
        let newConnection = Connection(accountID: accountID,
            accountName: accounts.first(where: { $0.id == accountID })?.name ?? "Apple Mail", mailbox: mailboxName)
        do {
            let loaded = try await client.inbox(accountID: newConnection.accountID, mailbox: newConnection.mailbox,
                                                limit: settings.messageLimit.rawValue)
            connection = newConnection
            isDemo = false
            messages = loaded
            selected = nil
            lastUpdated = Date()
            settings.defaults.set(newConnection.accountID, forKey: "AppleMailAccountID")
            settings.defaults.set(newConnection.mailbox, forKey: "AppleMailMailbox")
            screen = .mailbox
        } catch is CancellationError {
        } catch { self.error = error }
    }

    func refresh() async {
        if let selected {
            open(selected)
        } else {
            await refreshInbox()
        }
    }

    private func refreshInbox() async {
        guard !isBusy else { return }
        if isDemo {
            lastUpdated = Date()
            return
        }
        guard let connection else { return }
        listActivity = .refreshing
        error = nil
        defer { listActivity = nil }
        do {
            messages = try await client.inbox(accountID: connection.accountID, mailbox: connection.mailbox,
                limit: settings.messageLimit.rawValue, checkForMail: true)
            lastUpdated = Date()
        } catch is CancellationError {
        } catch { self.error = error }
    }

    func configureAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        let interval = settings.refreshInterval.rawValue
        guard interval > 0 else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                guard let self else { return }
                // Reading and choosing settings are not interrupted by a background refresh.
                if self.screen == .mailbox, self.selected == nil, !self.isBusy, !self.isDemo {
                    await self.refreshInbox()
                }
            }
        }
    }

    func open(_ message: MailMessage) {
        guard !isLoadingList else { return }
        cancelBody()
        selected = message
        error = nil
        guard let connection, !isDemo else { return }
        isLoadingBody = true
        bodyTask = Task {
            defer {
                if !Task.isCancelled {
                    isLoadingBody = false
                    bodyTask = nil
                }
            }
            do {
                let body = try await client.body(message: message, accountID: connection.accountID, mailbox: connection.mailbox)
                try Task.checkCancellation()
                if selected?.id == message.id { selected = message.withBody(body) }
            } catch is CancellationError {
                // Navigation cancelled this read; keep the next screen's state.
            } catch {
                if !Task.isCancelled, selected?.id == message.id { self.error = error }
            }
        }
    }

    private func cancelBody() {
        bodyTask?.cancel()
        bodyTask = nil
        isLoadingBody = false
    }

    func backToInbox() {
        cancelBody()
        selected = nil
        error = nil
    }

    func startDemo() {
        cancelBody()
        connection = nil
        isDemo = true
        messages = Self.demoMessages
        selected = nil
        lastUpdated = Date()
        error = nil
        screen = .mailbox
    }

    private static var demoMessages: [MailMessage] {
        let now = Date()
        return [
            MailMessage(id: "demo-1", subject: "Welcome to MenuMail", from: .init(emailAddress: .init(name: "MenuMail", address: "hello@example.com")), receivedDateTime: now.ISO8601Format(), body: .init(contentType: "html", content: """
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
