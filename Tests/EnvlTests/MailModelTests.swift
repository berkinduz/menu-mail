import Foundation
import Testing
@testable import Envl

struct MailModelTests {
    private func message() -> MailMessage {
        .init(id: "same-server-id", subject: "Budget review", from: .init(emailAddress: .init(name: "Example Team", address: "team@example.com")), receivedDateTime: nil, body: nil)
    }

    @Test func messagesFromDifferentAccountsKeepSeparateIdentities() {
        let first = message().scoped(to: .init(id: "gmail:first", name: "First", provider: .gmail))
        let second = message().scoped(to: .init(id: "outlook:second", name: "Second", provider: .outlook))
        #expect(first.listID != second.listID)
        #expect(first.id == second.id)
        #expect(first.accountID == "gmail:first")
    }

    @Test func localSearchMatchesSenderAndSubjectWithoutChangingMessages() {
        let mail = message()
        #expect(mail.matches(search: "BUDGET"))
        #expect(mail.matches(search: "team@example.com"))
        #expect(mail.matches(search: "  "))
        #expect(!mail.matches(search: "unrelated"))
        #expect(mail.isRead == nil)
    }

    @Test func explicitStateChangesPreserveBodyAndAccount() {
        let mail = message().scoped(to: .init(id: "first", name: "First"))
            .withBody(.init(contentType: "text", content: "Retained body"))
        let updated = mail.applying(.markRead(true)).applying(.star(true))
        #expect(updated.isRead == true)
        #expect(updated.isStarred == true)
        #expect(updated.body?.content == "Retained body")
        #expect(updated.accountID == "first")
        #expect(mail.isRead == nil)
    }

    @Test func existingAccountJSONStillDecodesAsAppleMail() throws {
        let account = try JSONDecoder().decode(MailAccount.self, from: Data(#"{"id":"legacy","name":"Existing account"}"#.utf8))
        #expect(account.provider == .appleMail)
        #expect(account.address == nil)
    }

    @Test func legacyClientsRemainReadOnlyAndCanReturnPages() async throws {
        let client = LegacyClient()
        #expect(client.capabilities.isEmpty)
        let page = try await client.page(accountID: "legacy", mailbox: "Inbox", limit: 20, query: "budget", pageToken: nil)
        #expect(page.messages.count == 1)
        #expect(page.nextPageToken == nil)
        #expect(page.unreadCount == nil)
        await #expect(throws: (any Error).self) {
            try await client.perform(.markRead(true), message: message(), accountID: "legacy", mailbox: "Inbox")
        }
    }

    private struct LegacyClient: MailClient {
        func accounts() async throws -> [MailAccount] { [] }
        func mailboxes(accountID: String) async throws -> [String] { [] }
        func inbox(accountID: String, mailbox: String, limit: Int, checkForMail: Bool) async throws -> [MailMessage] {
            [.init(id: "one", subject: "Budget review", from: nil, receivedDateTime: nil, body: nil)]
        }
        func body(message: MailMessage, accountID: String, mailbox: String) async throws -> MailMessage.Body {
            .init(contentType: "text", content: "")
        }
    }
}
