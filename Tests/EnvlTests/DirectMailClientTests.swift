import Foundation
import Testing
@testable import Envl

actor DirectFixtureHTTP: MailHTTPTransport {
    struct Reply: Sendable {
        let data: Data
        let status: Int
        static func json(_ value: String, status: Int = 200) -> Self { .init(data: Data(value.utf8), status: status) }
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply] = []) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw DirectMailError.invalidResponse }
        let reply = replies.removeFirst()
        return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }
}

actor DirectFixtureVault: MailTokenVault {
    private var values: [String: OAuthTokens]
    private(set) var reads = 0
    init(_ values: [String: OAuthTokens] = [:]) { self.values = values }
    func load(accountID: String) async throws -> OAuthTokens? { reads += 1; return values[accountID] }
    func save(_ tokens: OAuthTokens, accountID: String) async throws { values[accountID] = tokens }
    func remove(accountID: String) async throws { values.removeValue(forKey: accountID) }
    func contains(_ id: String) -> Bool { values[id] != nil }
}

actor DirectFixtureAccounts: DirectMailAccountStorage {
    private var values: [MailAccount]
    init(_ accounts: [MailAccount]) { values = accounts }
    func load() async throws -> [MailAccount] { values }
    func save(_ accounts: [MailAccount]) async throws { values = accounts }
}

struct DirectFixtureOAuth: MailOAuthAuthorizing {
    let tokens: OAuthTokens
    func authorize(configuration: OAuthConfiguration) async throws -> OAuthTokens { tokens }
    func refresh(_ old: OAuthTokens, configuration: OAuthConfiguration) async throws -> OAuthTokens { tokens }
}

private actor DirectRemovalFixtureVault: MailTokenVault {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var removalStarted = false
    let failRemoval: Bool
    init(failRemoval: Bool = false) { self.failRemoval = failRemoval }
    func load(accountID: String) async throws -> OAuthTokens? { nil }
    func save(_ tokens: OAuthTokens, accountID: String) async throws {}
    func remove(accountID: String) async throws {
        if failRemoval { throw DirectMailError.tokenStorage(-25308) }
        if !removalStarted {
            removalStarted = true
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite struct DirectMailClientTests {
    private static let gmail = MailAccount(id: "gmail:fixture@example.test", name: "Fixture Gmail", provider: .gmail, address: "fixture@example.test")
    private static let outlook = MailAccount(id: "outlook:fixture-user", name: "Fixture Outlook", provider: .outlook, address: "fixture@example.test")
    private static var tokens: OAuthTokens { .init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600)) }

    private func fixture(_ replies: [DirectFixtureHTTP.Reply], account: MailAccount = Self.gmail,
                         tokens: OAuthTokens = Self.tokens) -> (DirectMailClient, DirectFixtureHTTP, DirectFixtureVault) {
        let http = DirectFixtureHTTP(replies)
        let vault = DirectFixtureVault([account.id: tokens])
        let client = DirectMailClient(transport: http, vault: vault,
            accountStorage: DirectFixtureAccounts([account]), oauth: OAuthAuthorization(transport: http),
            configuration: { OAuthConfiguration(provider: $0, clientID: "fixture-public-client-id") })
        return (client, http, vault)
    }

    @Test func rememberedAccountsDoNotReadTokensOrUseTheNetwork() async throws {
        let (client, http, vault) = fixture([])
        #expect(try await client.accounts().first?.id == Self.gmail.id)
        #expect(await vault.reads == 0)
        #expect(await http.requests.isEmpty)
        try await client.signOut(accountID: Self.gmail.id)
        #expect(try await client.accounts().isEmpty)
        #expect(await vault.contains(Self.gmail.id) == false)
        #expect(await http.requests.isEmpty)
    }

    @Test func failedKeychainRemovalKeepsTheDescriptorAvailableForRetry() async throws {
        let client = DirectMailClient(transport: DirectFixtureHTTP(), vault: DirectRemovalFixtureVault(failRemoval: true),
            accountStorage: DirectFixtureAccounts([Self.gmail]), oauth: DirectFixtureOAuth(tokens: Self.tokens))
        await #expect(throws: DirectMailError.self) { try await client.signOut(accountID: Self.gmail.id) }
        #expect(try await client.accounts().map(\.id) == [Self.gmail.id])
    }

    @Test func overlappingRemovalsCannotPersistAnAlreadyRemovedAccount() async throws {
        let storage = DirectFixtureAccounts([Self.gmail, Self.outlook])
        let vault = DirectRemovalFixtureVault()
        let client = DirectMailClient(transport: DirectFixtureHTTP(), vault: vault, accountStorage: storage,
            oauth: DirectFixtureOAuth(tokens: Self.tokens))
        let first = Task { try await client.signOut(accountID: Self.gmail.id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await vault.removalStarted) {
            guard ContinuousClock.now < deadline else { Issue.record("The first removal did not start"); return }
            try await Task.sleep(for: .milliseconds(1))
        }
        let second = Task { try await client.signOut(accountID: Self.outlook.id) }
        try await Task.sleep(for: .milliseconds(30))
        await vault.release()
        try await first.value
        try await second.value
        #expect(try await storage.load().isEmpty)
        #expect(try await client.accounts().isEmpty)
    }

    @Test func gmailPageDecodesLabelsMetadataAndProviderPagination() async throws {
        let (client, http, _) = fixture([
            .json(#"{"messages":[{"id":"m/1","threadId":"thread-1"}],"nextPageToken":"page+/=2"}"#),
            .json(#"{"id":"m/1","threadId":"thread-1","labelIds":["INBOX","UNREAD","STARRED"],"internalDate":"1700000000000","snippet":"Preview","payload":{"mimeType":"multipart/mixed","headers":[{"name":"Subject","value":"Fixture"},{"name":"From","value":"Sender <sender@example.test>"},{"name":"To","value":"Person <recipient@example.test>"},{"name":"Message-ID","value":"<fixture@example.test>"}],"parts":[{"filename":"report.pdf","mimeType":"application/pdf","body":{"attachmentId":"attachment/1","size":7}}]}}"#)
        ])
        let page = try await client.page(accountID: Self.gmail.id, mailbox: "Inbox", limit: 900, query: "subject:hello + world", pageToken: "first+/=1")
        let message = try #require(page.messages.first)
        #expect(page.nextPageToken == "page+/=2")
        #expect(message.accountID == Self.gmail.id && message.provider == .gmail)
        #expect(message.isRead == false && message.isStarred == true)
        #expect(message.to.first?.address == "recipient@example.test")
        #expect(message.internetMessageID == "<fixture@example.test>")
        #expect(message.hasAttachments)
        let requests = await http.requests
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(query["maxResults"] == "100")
        #expect(query["q"] == "subject:hello + world")
        #expect(query["pageToken"] == "first+/=1")
        #expect(requests[1].url?.absoluteString.contains("m%2F1") == true)
        #expect(requests.allSatisfy { $0.timeoutInterval > 0 && $0.timeoutInterval <= 60 })
    }

    @Test func gmailListDecodesEncodedSubjectAndSenderNames() throws {
        let fixture = #"{"id":"m1","payload":{"headers":[{"name":"Subject","value":"=?UTF-8?B?w5xuaWNvZGU=?="},{"name":"From","value":"=?UTF-8?B?w4dhxJ9yxLE=?= <sender@example.test>"}]}}"#
        let resource = try JSONDecoder().decode(GmailMessageResource.self, from: Data(fixture.utf8))
        let message = resource.message(account: Self.gmail)
        #expect(message.subject == "Ünicode")
        #expect(message.from?.emailAddress.name == "Çağrı")
    }

    @Test func gmailUnreadIsTheFolderTotalAndBodyUsesRawMIME() async throws {
        let raw = Data("From: Sender <sender@example.test>\r\nTo: Person <person@example.test>\r\nMessage-ID: <fixture@example.test>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSynthetic body".utf8).base64URLEncodedString()
        let (client, _, _) = fixture([
            .json(#"{"id":"INBOX","messagesUnread":317}"#),
            .json("{\"raw\":\"\(raw)\"}")
        ])
        #expect(try await client.unreadCount(accountID: Self.gmail.id, mailbox: "Inbox") == 317)
        let body = try await client.body(message: .init(id: "m1", subject: nil, from: nil, receivedDateTime: nil, body: nil,
            accountID: Self.gmail.id, provider: .gmail), accountID: Self.gmail.id, mailbox: "Inbox")
        #expect(body.content == "Synthetic body")
    }

    @Test func graphPageDecodesRecipientsAndFollowsOnlyTheTrustedInboxNextLink() async throws {
        let next = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$skip=20"
        let (client, http, _) = fixture([
            .json("{\"value\":[{\"id\":\"graph/1\",\"subject\":\"Fixture\",\"isRead\":false,\"flag\":{\"flagStatus\":\"flagged\"},\"toRecipients\":[{\"emailAddress\":{\"name\":\"Person\",\"address\":\"person@example.test\"}}],\"conversationId\":\"conversation-1\",\"hasAttachments\":true}],\"@odata.nextLink\":\"\(next)\"}"),
            .json(#"{"value":[]}"#)
        ], account: Self.outlook)
        let page = try await client.page(accountID: Self.outlook.id, mailbox: "Inbox", limit: 20, query: nil, pageToken: nil)
        #expect(page.messages.first?.isStarred == true)
        #expect(page.messages.first?.to.first?.address == "person@example.test")
        #expect(page.nextPageToken == next)
        _ = try await client.page(accountID: Self.outlook.id, mailbox: "Inbox", limit: 20, query: nil, pageToken: page.nextPageToken)
        #expect(await http.requests.last?.url?.absoluteString == next)
        #expect(await http.requests.first?.value(forHTTPHeaderField: "Prefer")?.contains("ImmutableId") == true)
        await #expect(throws: DirectMailError.self) {
            try await client.page(accountID: Self.outlook.id, mailbox: "Inbox", limit: 20, query: nil,
                pageToken: "https://untrusted.example.test/v1.0/me/mailFolders/inbox/messages")
        }
        #expect(await http.requests.count == 2)
    }

    @Test func actionsUseReversibleProviderOperationsAndEscapeMessageIDs() async throws {
        let (gmail, gmailHTTP, _) = fixture([.json("{}"), .json("{}"), .json("{}")])
        let message = MailMessage(id: "m/1", subject: nil, from: nil, receivedDateTime: nil, body: nil,
            accountID: Self.gmail.id, provider: .gmail)
        try await gmail.perform(.markRead(true), message: message, accountID: Self.gmail.id, mailbox: "Inbox")
        try await gmail.perform(.archive, message: message, accountID: Self.gmail.id, mailbox: "Inbox")
        try await gmail.perform(.trash, message: message, accountID: Self.gmail.id, mailbox: "Inbox")
        let requests = await gmailHTTP.requests
        let first = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: [String]]
        #expect(first["removeLabelIds"] == ["UNREAD"])
        #expect(requests[2].url?.absoluteString.hasSuffix("m%2F1/trash") == true)
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })

        let (graph, graphHTTP, _) = fixture([.json("{}", status: 201)], account: Self.outlook)
        try await graph.perform(.trash, message: .init(id: "id/+=", subject: nil, from: nil, receivedDateTime: nil, body: nil,
            accountID: Self.outlook.id, provider: .outlook), accountID: Self.outlook.id, mailbox: "Inbox")
        let graphRequest = try #require(await graphHTTP.requests.first)
        #expect(graphRequest.httpMethod == "POST")
        #expect(graphRequest.url?.absoluteString.contains("id%2F%2B%3D/move") == true)
        #expect(try JSONSerialization.jsonObject(with: graphRequest.httpBody!) as? [String: String] == ["destinationId": "deleteditems"])
    }

    @Test func gmailTrashUndoRestoresTheOriginalInboxLabel() async throws {
        let (client, http, _) = fixture([.json("{}")])
        try await client.perform(.restoreFromTrash, message: .init(id: "m1", subject: nil, from: nil, receivedDateTime: nil, body: nil,
            accountID: Self.gmail.id, provider: .gmail), accountID: Self.gmail.id, mailbox: "Inbox")
        let request = try #require(await http.requests.first)
        #expect(request.url?.absoluteString.hasSuffix("/messages/m1/modify") == true)
        let payload = try #require(request.httpBody)
        #expect(try JSONSerialization.jsonObject(with: payload) as? [String: [String]] == ["addLabelIds": ["INBOX"], "removeLabelIds": ["TRASH"]])
    }

    @Test func gmailSendPreservesReplyHeadersAndThreadWithoutInjectingHeaders() async throws {
        let (client, http, _) = fixture([.json("{}")])
        var draft = MailDraft(accountID: Self.gmail.id, to: "person@example.test", subject: "Re: Fixture", text: "Synthetic reply",
            replyToMessageID: "m1", inReplyToHeader: "<original@example.test>", references: "<older@example.test>", threadID: "thread-1")
        try await client.send(draft)
        let request = try #require(await http.requests.first)
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        let mime = String(data: try #require(Data(base64URLEncoded: payload["raw"]!)), encoding: .utf8)!
        #expect(payload["threadId"] == "thread-1")
        #expect(mime.contains("In-Reply-To: <original@example.test>\r\n"))
        #expect(mime.contains("References: <older@example.test> <original@example.test>\r\n"))
        draft.subject = "Injected\r\nBcc: hidden@example.test"
        await #expect(throws: DirectMailError.self) { try await client.send(draft) }
        #expect(await http.requests.count == 1)
    }

    @Test func graphReplyTargetsTheOriginalMessageAndPreservesEditedRecipients() async throws {
        let (client, http, _) = fixture([.json("", status: 202)], account: Self.outlook)
        let draft = MailDraft(accountID: Self.outlook.id, to: "Person <person@example.test>", cc: "copy@example.test",
            subject: "Re: Fixture", text: "Synthetic reply", replyToMessageID: "original/1", inReplyToHeader: "<original@example.test>")
        try await client.send(draft)
        let request = try #require(await http.requests.first)
        #expect(request.url?.absoluteString == "https://graph.microsoft.com/v1.0/me/messages/original%2F1/reply")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let payload = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let message = try #require(payload["message"] as? [String: Any])
        let to = try #require(message["toRecipients"] as? [[String: [String: String]]])
        #expect(to.first?["emailAddress"]?["address"] == "person@example.test")
        #expect((message["body"] as? [String: String])?["content"] == "Synthetic reply")
    }

    @Test func graphUnreadBodyAndAttachmentMetadataUseTheSyntheticMailbox() async throws {
        let (client, http, _) = fixture([
            .json(#"{"unreadItemCount":421}"#),
            .json(#"{"body":{"contentType":"html","content":"<img src=\"cid:fixture-inline\">"},"toRecipients":[{"emailAddress":{"name":"Person","address":"person@example.test"}}],"internetMessageId":"<graph@example.test>","internetMessageHeaders":[{"name":"References","value":"<original@example.test>"}],"hasAttachments":false}"#),
            .json(##"{"value":[{"@odata.type":"#microsoft.graph.fileAttachment","id":"attachment/1","name":"inline.png","contentType":"image/png","contentBytes":"AQID","contentId":"fixture-inline","isInline":true,"size":3}]}"##)
        ], account: Self.outlook)
        #expect(try await client.unreadCount(accountID: Self.outlook.id, mailbox: "Inbox") == 421)
        let body = try await client.body(message: .init(id: "m1", subject: nil, from: nil, receivedDateTime: nil, body: nil,
            accountID: Self.outlook.id, provider: .outlook), accountID: Self.outlook.id, mailbox: "Inbox")
        #expect(body.content.contains("data:image/png;base64,AQID"))
        #expect(body.attachments.first?.data == Data([1, 2, 3]))
        #expect(body.to.first?.address == "person@example.test")
        #expect(body.references == "<original@example.test>")
        #expect(await http.requests.count == 3)
    }

    @Test func a401RefreshesOnceButOtherFailuresDoNotRetryOrExposeProviderDetails() async throws {
        let (client, http, _) = fixture([
            .json(#"{"error":"synthetic-private-provider-details"}"#, status: 401),
            .json(#"{"access_token":"synthetic-new","expires_in":3600}"#),
            .json(#"{"messagesUnread":7}"#)
        ])
        #expect(try await client.unreadCount(accountID: Self.gmail.id, mailbox: "Inbox") == 7)
        #expect(await http.requests.count == 3)
        let (busy, busyHTTP, _) = fixture([.json(#"{"error":"synthetic-private-provider-details"}"#, status: 429)])
        do {
            _ = try await busy.unreadCount(accountID: Self.gmail.id, mailbox: "Inbox")
            Issue.record("A rate-limited request unexpectedly succeeded")
        } catch {
            #expect(!error.localizedDescription.contains("synthetic-private-provider-details"))
        }
        #expect(await busyHTTP.requests.count == 1)
    }

    @Test func expiryRefreshIsUsedOnlyWhenNeededAndInvalidGrantRequiresReconnect() async throws {
        let expired = OAuthTokens(accessToken: "synthetic-expired", refreshToken: "synthetic-refresh", expiresAt: .distantPast)
        let (client, http, _) = fixture([
            .json(#"{"access_token":"synthetic-new","expires_in":3600}"#),
            .json(#"{"messagesUnread":8}"#), .json(#"{"messagesUnread":9}"#)
        ], tokens: expired)
        #expect(try await client.unreadCount(accountID: Self.gmail.id, mailbox: "Inbox") == 8)
        #expect(try await client.unreadCount(accountID: Self.gmail.id, mailbox: "Inbox") == 9)
        #expect(await http.requests.filter { $0.url?.host == "oauth2.googleapis.com" }.count == 1)
        let (rejected, _, _) = fixture([.json(#"{"error":"invalid_grant","error_description":"synthetic-private-details"}"#, status: 400)], tokens: expired)
        do {
            _ = try await rejected.unreadCount(accountID: Self.gmail.id, mailbox: "Inbox")
            Issue.record("Expired authorization unexpectedly succeeded")
        } catch {
            #expect(error as? DirectMailError == .reauthorizationRequired)
            #expect(!error.localizedDescription.contains("synthetic-private-details"))
        }
    }

    @Test func signInPersistsTheAccountAndSignOutRemovesItsToken() async throws {
        let http = DirectFixtureHTTP([.json(#"{"emailAddress":"Fixture@Example.test"}"#)])
        let vault = DirectFixtureVault()
        let client = DirectMailClient(transport: http, vault: vault, accountStorage: DirectFixtureAccounts([]),
            oauth: DirectFixtureOAuth(tokens: Self.tokens), configuration: { .init(provider: $0, clientID: "fixture-public-client-id") })
        let account = try await client.signIn(provider: .gmail)
        #expect(account.id == "gmail:fixture@example.test")
        #expect(try await client.accounts().count == 1)
        #expect(await vault.contains(account.id))
        try await client.signOut(accountID: account.id)
        #expect(await vault.contains(account.id) == false)
        #expect(try await client.accounts().isEmpty)
    }
}
