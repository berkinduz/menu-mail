import Foundation

enum MailProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleMail, gmail, outlook
    var id: String { rawValue }
    var name: String {
        switch self {
        case .appleMail: "Apple Mail"
        case .gmail: "Gmail"
        case .outlook: "Outlook / Microsoft 365"
        }
    }
}

struct MailAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var provider: MailProvider = .appleMail
    var address: String? = nil

    init(id: String, name: String, provider: MailProvider = .appleMail, address: String? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.address = address
    }

    private enum CodingKeys: String, CodingKey { case id, name, provider, address }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        provider = try values.decodeIfPresent(MailProvider.self, forKey: .provider) ?? .appleMail
        address = try values.decodeIfPresent(String.self, forKey: .address)
    }
}

struct MailAttachment: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    var size: Int? = nil
    var data: Data? = nil
    var providerAttachmentID: String? = nil
    var contentID: String? = nil
}

struct MailMessage: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let subject: String?
    let from: Sender?
    let receivedDateTime: String?
    var body: Body?
    var sourceIndex: Int? = nil
    var accountID: String? = nil
    var provider: MailProvider = .appleMail
    var isRead: Bool? = nil
    var isStarred: Bool? = nil
    var snippet: String? = nil
    var to: [Address] = []
    var cc: [Address] = []
    var replyTo: [Address] = []
    var threadID: String? = nil
    var internetMessageID: String? = nil
    var webURL: URL? = nil
    var hasAttachments = false

    struct Sender: Decodable, Equatable, Sendable { let emailAddress: Address }
    struct Address: Decodable, Equatable, Sendable { let name: String?; let address: String? }
    struct Body: Decodable, Equatable, Sendable {
        let contentType: String
        let content: String
        var attachments: [MailAttachment] = []
        var to: [Address] = []
        var cc: [Address] = []
        var replyTo: [Address] = []
        var messageID: String? = nil
        var references: String? = nil
    }

    var listID: String { accountID.map { "\($0):\(id)" } ?? id }
    var attachments: [MailAttachment] { body?.attachments ?? [] }
    var recipients: [Address] { to.isEmpty ? body?.to ?? [] : to }
    var copyRecipients: [Address] { cc.isEmpty ? body?.cc ?? [] : cc }
    var replyRecipients: [Address] {
        let recipients = replyTo.isEmpty ? body?.replyTo ?? [] : replyTo
        return recipients.isEmpty ? from.map { [$0.emailAddress] } ?? [] : recipients
    }

    func scoped(to account: MailAccount) -> Self {
        var message = self
        message.accountID = account.id
        message.provider = account.provider
        return message
    }

    func applying(_ action: MailAction) -> Self {
        var message = self
        switch action {
        case .markRead(let value): message.isRead = value
        case .star(let value): message.isStarred = value
        default: break
        }
        return message
    }

    func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [subject, from?.emailAddress.name, from?.emailAddress.address, snippet]
            .compactMap { $0 }.contains { $0.localizedStandardContains(query) }
    }

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

    var receivedAt: Date? { date }

    func shortDate(locale: Locale) -> String {
        guard let date else { return "" }
        return date.formatted(Date.FormatStyle(date: Calendar.current.isDateInToday(date) ? .omitted : .numeric,
                                               time: .shortened, locale: locale))
    }

    func longDate(locale: Locale) -> String {
        date?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)) ?? ""
    }

    func withBody(_ body: Body) -> Self {
        var message = self
        message.body = body
        return message
    }
}

struct MailCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let search = Self(rawValue: 1 << 0)
    static let pagination = Self(rawValue: 1 << 1)
    static let readState = Self(rawValue: 1 << 2)
    static let star = Self(rawValue: 1 << 3)
    static let archive = Self(rawValue: 1 << 4)
    static let trash = Self(rawValue: 1 << 5)
    static let send = Self(rawValue: 1 << 6)
    static let attachments = Self(rawValue: 1 << 7)
    static let direct: Self = [.search, .pagination, .readState, .star, .archive, .trash, .send, .attachments]
}

struct MailPage: Sendable {
    let messages: [MailMessage]
    var nextPageToken: String? = nil
    var unreadCount: Int? = nil
}

enum MailAction: Equatable, Sendable {
    case markRead(Bool), star(Bool), archive, trash, moveToInbox, restoreFromTrash
}

struct MailDraft: Identifiable, Sendable {
    let id = UUID()
    var accountID: String
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var text = ""
    var replyToMessageID: String? = nil
    var inReplyToHeader: String? = nil
    var references: String? = nil
    var threadID: String? = nil
    var forwardMessageID: String? = nil
}

struct MailboxConnection: Codable, Identifiable, Equatable, Sendable {
    let account: MailAccount
    let mailbox: String
    var id: String { account.id }
}
