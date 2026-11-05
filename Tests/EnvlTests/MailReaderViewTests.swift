import Foundation
import Testing
@testable import Envl

@MainActor
struct MailReaderViewTests {
    private func message(accountID: String, body: String) -> MailMessage {
        .init(id: "same-provider-id", subject: "Synthetic message", from: nil, receivedDateTime: nil,
            body: .init(contentType: "text", content: body), accountID: accountID, isRead: false, isStarred: false)
    }

    @Test func readerUsesCurrentFlagsWithoutTakingAnotherAccountsBody() {
        let snapshot = message(accountID: "first", body: "First body")
        let current = snapshot.applying(.markRead(true)).applying(.star(true))
        let other = message(accountID: "second", body: "Second body")
        let displayed = MailReaderPresentation.currentMessage(snapshot: snapshot, rows: [other, current], selection: other)
        #expect(displayed.isRead == true)
        #expect(displayed.isStarred == true)
        #expect(displayed.body?.content == "First body")
        #expect(displayed.accountID == "first")
    }

    @Test func aRefreshedRowWithoutBodyDoesNotClearTheReader() {
        let snapshot = message(accountID: "first", body: "Retained body")
        var current = snapshot.applying(.markRead(true))
        current.body = nil
        let displayed = MailReaderPresentation.currentMessage(snapshot: snapshot, rows: [current], selection: nil)
        #expect(displayed.body?.content == "Retained body")
        #expect(displayed.isRead == true)
    }

    @Test func originalMessageURLUsesAWebLinkOrAnEncodedMessageID() {
        var message = message(accountID: "first", body: "Body")
        message.body?.messageID = "<original+tag@example.test>"
        #expect(MailReaderPresentation.originalURL(for: message)?.absoluteString == "message://%3Coriginal%2Btag%40example.test%3E")
        message.webURL = URL(string: "https://outlook.example.test/mail/original")
        #expect(MailReaderPresentation.originalURL(for: message) == message.webURL)
    }

    @Test func attachmentPathsAndDuplicateNamesKeepSeparateFilesAndOriginalBytes() throws {
        let files = MailAttachmentTemporaryFiles()
        defer { files.removeAll() }
        let first = try files.write(Data([0, 1, 255]), name: "../../invoice.txt")
        let second = try files.write(Data([2, 3]), name: #"C:\Exports\invoice.txt"#)
        #expect(first.lastPathComponent == "invoice.txt")
        #expect(second.lastPathComponent == "invoice.txt")
        #expect(first.deletingLastPathComponent().deletingLastPathComponent() == files.directory)
        #expect(second.deletingLastPathComponent().deletingLastPathComponent() == files.directory)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data([0, 1, 255]))
        #expect(try Data(contentsOf: second) == Data([2, 3]))
        files.removeAll()
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func dotAndControlOnlyAttachmentNamesCannotEscapeTheOwnedDirectory() throws {
        let files = MailAttachmentTemporaryFiles()
        defer { files.removeAll() }
        for name in ["..", ".", "\0\n"] {
            let url = try files.write(Data([5]), name: name)
            #expect(url.lastPathComponent == "Attachment")
            #expect(url.deletingLastPathComponent().deletingLastPathComponent() == files.directory)
        }
    }
}
