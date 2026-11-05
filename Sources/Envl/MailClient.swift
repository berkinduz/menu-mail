import Foundation

protocol MailClient: Sendable {
    var capabilities: MailCapabilities { get }
    func accounts() async throws -> [MailAccount]
    func mailboxes(accountID: String) async throws -> [String]
    func inbox(accountID: String, mailbox: String, limit: Int, checkForMail: Bool) async throws -> [MailMessage]
    func body(message: MailMessage, accountID: String, mailbox: String) async throws -> MailMessage.Body
    func page(accountID: String, mailbox: String, limit: Int, query: String?, pageToken: String?) async throws -> MailPage
    func unreadCount(accountID: String, mailbox: String) async throws -> Int?
    func attachmentData(attachment: MailAttachment, message: MailMessage, accountID: String, mailbox: String) async throws -> Data
    func perform(_ action: MailAction, message: MailMessage, accountID: String, mailbox: String) async throws
    func send(_ draft: MailDraft) async throws
}

protocol DirectMailConnecting: MailClient {
    func signIn(provider: MailProvider) async throws -> MailAccount
    func signOut(accountID: String) async throws
}

extension MailClient {
    var capabilities: MailCapabilities { [] }

    func page(accountID: String, mailbox: String, limit: Int, query: String?, pageToken: String?) async throws -> MailPage {
        let messages = try await inbox(accountID: accountID, mailbox: mailbox, limit: limit, checkForMail: false)
        return .init(messages: messages.filter { $0.matches(search: query ?? "") })
    }

    func unreadCount(accountID: String, mailbox: String) async throws -> Int? { nil }

    func attachmentData(attachment: MailAttachment, message: MailMessage, accountID: String, mailbox: String) async throws -> Data {
        if let data = attachment.data { return data }
        throw MailError.message("This attachment is not available. Open the original message to download it.")
    }

    func perform(_ action: MailAction, message: MailMessage, accountID: String, mailbox: String) async throws {
        throw MailError.message("This connection is read only. Use your mail app for this action.")
    }

    func send(_ draft: MailDraft) async throws {
        throw MailError.message("This connection is read only. Use your mail app to send messages.")
    }
}
