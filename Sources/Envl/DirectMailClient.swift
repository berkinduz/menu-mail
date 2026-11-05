import Foundation

actor DirectMailClient: DirectMailConnecting {
    nonisolated var capabilities: MailCapabilities { .direct }
    private let transport: any MailHTTPTransport
    private let vault: any MailTokenVault
    private let accountStorage: any DirectMailAccountStorage
    private let oauth: any MailOAuthAuthorizing
    private let configuration: @Sendable (MailProvider) -> OAuthConfiguration
    private var remembered: [MailAccount]?
    private var refreshes: [String: Task<OAuthTokens, Error>] = [:]
    private var revisions: [String: UUID] = [:]
    private var isMutatingAccounts = false
    private var accountMutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(transport: any MailHTTPTransport = URLSessionMailHTTPTransport(),
         vault: any MailTokenVault = KeychainMailTokenVault(),
         accountStorage: any DirectMailAccountStorage = UserDefaultsMailAccountStorage(),
         oauth: (any MailOAuthAuthorizing)? = nil,
         configuration: @escaping @Sendable (MailProvider) -> OAuthConfiguration = { .bundled(for: $0) }) {
        self.transport = transport; self.vault = vault; self.accountStorage = accountStorage
        self.oauth = oauth ?? OAuthAuthorization(transport: transport); self.configuration = configuration
    }

    func accounts() async throws -> [MailAccount] {
        if let remembered { return remembered }
        let accounts = try await accountStorage.load()
        // A concurrently completed account mutation takes precedence over an older storage read.
        if remembered == nil { remembered = accounts }
        return remembered ?? []
    }

    func signIn(provider: MailProvider) async throws -> MailAccount {
        let config = configuration(provider)
        try config.validate()
        let tokens = try await oauth.authorize(configuration: config)
        try Task.checkCancellation()
        let account: MailAccount
        switch provider {
        case .gmail:
            struct Profile: Decodable { let emailAddress: String }
            let profile: Profile = try decode(try await profileData(url: gmailURL("profile"), tokens: tokens, provider: provider))
            guard !profile.emailAddress.isEmpty else { throw DirectMailError.invalidResponse }
            account = .init(id: "gmail:\(profile.emailAddress.lowercased())", name: profile.emailAddress, provider: .gmail, address: profile.emailAddress)
        case .outlook:
            struct Profile: Decodable { let id: String; let displayName: String?; let mail: String?; let userPrincipalName: String? }
            let profile: Profile = try decode(try await profileData(url: graphURL("me", query: ["$select": "id,displayName,mail,userPrincipalName"]), tokens: tokens, provider: provider))
            guard !profile.id.isEmpty else { throw DirectMailError.invalidResponse }
            let address = profile.mail ?? profile.userPrincipalName
            account = .init(id: "outlook:\(profile.id)", name: profile.displayName ?? address ?? "Outlook", provider: .outlook, address: address)
        case .appleMail: throw DirectMailError.unsupported
        }
        await beginAccountMutation()
        defer { endAccountMutation() }
        try Task.checkCancellation()
        var accounts = try await self.accounts()
        accounts.removeAll { $0.id == account.id }; accounts.append(account)
        try await vault.save(tokens, accountID: account.id)
        try await accountStorage.save(accounts)
        remembered = accounts
        revisions[account.id] = UUID()
        return account
    }

    func signOut(accountID: String) async throws {
        await beginAccountMutation()
        defer { endAccountMutation() }
        try Task.checkCancellation()
        let previous = try await self.accounts()
        var accounts = previous
        accounts.removeAll { $0.id == accountID }
        revisions[accountID] = UUID()
        refreshes.removeValue(forKey: accountID)?.cancel()
        // Mark removed before awaiting storage, so an in-flight response cannot restore a removed connection.
        remembered = accounts
        do {
            try await vault.remove(accountID: accountID)
            try await accountStorage.save(accounts)
        } catch {
            remembered = previous
            throw error
        }
    }

    func mailboxes(accountID: String) async throws -> [String] { _ = try await account(accountID); return ["Inbox"] }

    func inbox(accountID: String, mailbox: String, limit: Int, checkForMail: Bool) async throws -> [MailMessage] {
        try await page(accountID: accountID, mailbox: mailbox, limit: limit, query: nil, pageToken: nil).messages
    }

    func page(accountID: String, mailbox: String, limit: Int, query: String?, pageToken: String?) async throws -> MailPage {
        let account = try await account(accountID)
        try validateInbox(mailbox)
        let limit = max(1, min(limit, 100))
        switch account.provider {
        case .gmail:
            struct List: Decodable { struct Entry: Decodable { let id: String }; let messages: [Entry]?; let nextPageToken: String? }
            var parameters = ["labelIds": "INBOX", "maxResults": String(limit)]
            if let query, !query.isEmpty { parameters["q"] = query }
            if let pageToken { parameters["pageToken"] = pageToken }
            let list: List = try decode(try await request(gmailURL("messages", query: parameters), account: account))
            var messages: [MailMessage] = []
            for entry in (list.messages ?? []).prefix(limit) {
                try Task.checkCancellation()
                let detail: GmailMessageResource = try decode(try await request(gmailURL("messages/\(MailURLCoding.component(entry.id))", query: ["format": "full"]), account: account))
                messages.append(detail.message(account: account))
            }
            return .init(messages: messages, nextPageToken: list.nextPageToken)
        case .outlook:
            struct List: Decodable { let value: [GraphMessageResource]; let nextLink: String?; enum CodingKeys: String, CodingKey { case value; case nextLink = "@odata.nextLink" } }
            let url: URL
            if let pageToken { url = try graphNextPage(pageToken) }
            else {
                var parameters = ["$top": String(limit), "$select": "id,subject,from,receivedDateTime,isRead,flag,bodyPreview,toRecipients,ccRecipients,replyTo,conversationId,internetMessageId,webLink,hasAttachments"]
                if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parameters["$search"] = "\"\(query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
                } else { parameters["$orderby"] = "receivedDateTime desc" }
                url = graphURL("me/mailFolders/inbox/messages", query: parameters)
            }
            let list: List = try decode(try await request(url, account: account))
            if let next = list.nextLink { _ = try graphNextPage(next) }
            return .init(messages: try list.value.map { try $0.message(account: account) }, nextPageToken: list.nextLink)
        case .appleMail: throw DirectMailError.unsupported
        }
    }

    func unreadCount(accountID: String, mailbox: String) async throws -> Int? {
        let account = try await account(accountID)
        try validateInbox(mailbox)
        if account.provider == .gmail {
            struct Label: Decodable { let messagesUnread: Int }
            let label: Label = try decode(try await request(gmailURL("labels/INBOX"), account: account))
            return label.messagesUnread
        }
        struct Folder: Decodable { let unreadItemCount: Int }
        let folder: Folder = try decode(try await request(graphURL("me/mailFolders/inbox", query: ["$select": "unreadItemCount"]), account: account))
        return folder.unreadItemCount
    }

    func body(message: MailMessage, accountID: String, mailbox: String) async throws -> MailMessage.Body {
        let account = try await checkedAccount(accountID, message: message)
        if account.provider == .gmail {
            let source = try await gmailSource(messageID: message.id, account: account)
            return try MIMEBodyReader.body(from: source)
        }
        let resource: GraphMessageResource = try decode(try await request(graphURL("me/messages/\(MailURLCoding.component(message.id))",
            query: ["$select": "body,toRecipients,ccRecipients,replyTo,internetMessageId,internetMessageHeaders,hasAttachments"]), account: account))
        guard let content = resource.body else { throw DirectMailError.invalidResponse }
        // Graph's hasAttachments excludes inline-only messages, so enumerate attachments for every opened message.
        let attachments = try await graphAttachments(messageID: message.id, account: account)
        var html = content.content
        if content.contentType.caseInsensitiveCompare("html") == .orderedSame {
            for attachment in attachments {
                guard let cid = attachment.contentID, let data = attachment.data else { continue }
                let pattern = "(?i:cid:)" + NSRegularExpression.escapedPattern(for: cid.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))) + "(?=[\"'\\s)>]|$)"
                let regex = try NSRegularExpression(pattern: pattern)
                html = regex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html),
                    withTemplate: NSRegularExpression.escapedTemplate(for: "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"))
            }
        }
        return .init(contentType: content.contentType.lowercased(), content: html, attachments: attachments,
            to: (resource.toRecipients ?? []).map(\.emailAddress), cc: (resource.ccRecipients ?? []).map(\.emailAddress),
            replyTo: (resource.replyTo ?? []).map(\.emailAddress), messageID: resource.internetMessageId,
            references: resource.internetMessageHeaders?.first { $0.name.caseInsensitiveCompare("References") == .orderedSame }?.value)
    }

    func attachmentData(attachment: MailAttachment, message: MailMessage, accountID: String, mailbox: String) async throws -> Data {
        let account = try await checkedAccount(accountID, message: message)
        if let data = attachment.data { return data }
        guard let id = attachment.providerAttachmentID else { throw DirectMailError.attachmentUnavailable }
        if account.provider == .gmail {
            struct Content: Decodable { let data: String }
            let content: Content = try decode(try await request(gmailURL("messages/\(MailURLCoding.component(message.id))/attachments/\(MailURLCoding.component(id))"), account: account))
            guard let data = Data(base64URLEncoded: content.data) else { throw DirectMailError.attachmentUnavailable }
            return data
        }
        return try await request(graphURL("me/messages/\(MailURLCoding.component(message.id))/attachments/\(MailURLCoding.component(id))/$value"), account: account)
    }

    func perform(_ action: MailAction, message: MailMessage, accountID: String, mailbox: String) async throws {
        let account = try await checkedAccount(accountID, message: message)
        let id = MailURLCoding.component(message.id)
        if account.provider == .gmail {
            var add: [String] = [], remove: [String] = []
            switch action {
            case .markRead(let value): if value { remove = ["UNREAD"] } else { add = ["UNREAD"] }
            case .star(let value): if value { add = ["STARRED"] } else { remove = ["STARRED"] }
            case .archive: remove = ["INBOX"]
            case .moveToInbox: add = ["INBOX"]
            case .trash:
                _ = try await request(gmailURL("messages/\(id)/trash"), account: account, method: "POST"); return
            case .restoreFromTrash:
                // This client exposes Inbox only. Undo must restore that label as well as remove Trash.
                add = ["INBOX"]; remove = ["TRASH"]
            }
            _ = try await request(gmailURL("messages/\(id)/modify"), account: account, method: "POST", json: ["addLabelIds": add, "removeLabelIds": remove])
        } else {
            switch action {
            case .markRead(let value):
                _ = try await request(graphURL("me/messages/\(id)"), account: account, method: "PATCH", json: ["isRead": value])
            case .star(let value):
                _ = try await request(graphURL("me/messages/\(id)"), account: account, method: "PATCH", json: ["flag": ["flagStatus": value ? "flagged" : "notFlagged"]])
            case .archive, .trash, .moveToInbox, .restoreFromTrash:
                let folder = action == .archive ? "archive" : action == .trash ? "deleteditems" : "inbox"
                _ = try await request(graphURL("me/messages/\(id)/move"), account: account, method: "POST", json: ["destinationId": folder])
            }
        }
    }

    func send(_ draft: MailDraft) async throws {
        let account = try await account(draft.accountID)
        guard let from = account.address, !from.isEmpty else { throw DirectMailError.invalidDraft }
        try MailMIMEComposer.validate(draft, from: from)
        if account.provider == .gmail {
            let source: Data
            if let original = draft.forwardMessageID {
                let raw = try await gmailSource(messageID: original, account: account)
                let body = try MIMEBodyReader.body(from: raw, resolvingInlineImages: false)
                let forwarded = try MailMIMEComposer.forwardedBody(body, headers: MIMEBodyReader.headers(from: raw), comment: draft.text)
                source = try MailMIMEComposer.messageData(draft, from: from, body: forwarded)
            } else { source = try MailMIMEComposer.messageData(draft, from: from) }
            var json = ["raw": source.base64URLEncodedString()]
            if draft.forwardMessageID == nil, let threadID = draft.threadID { json["threadId"] = threadID }
            _ = try await request(gmailURL("messages/send"), account: account, method: "POST", json: json)
        } else if let original = draft.forwardMessageID {
            // A comment prefixes the provider's complete original; omitting body/attachments preserves both.
            _ = try await request(graphURL("me/messages/\(MailURLCoding.component(original))/forward"), account: account, method: "POST",
                json: ["comment": draft.text, "message": ["subject": draft.subject, "toRecipients": graphRecipients(draft.to),
                    "ccRecipients": graphRecipients(draft.cc), "bccRecipients": graphRecipients(draft.bcc)]])
        } else if let original = draft.replyToMessageID {
            // Graph's reply operation retains provider conversation identity and accepts edited reply-all recipients.
            _ = try await request(graphURL("me/messages/\(MailURLCoding.component(original))/reply"), account: account, method: "POST",
                json: ["message": ["subject": draft.subject, "body": ["contentType": "Text", "content": draft.text],
                    "toRecipients": graphRecipients(draft.to), "ccRecipients": graphRecipients(draft.cc), "bccRecipients": graphRecipients(draft.bcc)]])
        } else {
            // New messages use MIME so Unicode content and Bcc retain the same behavior as Gmail.
            let source = try MailMIMEComposer.messageData(draft, from: from)
            _ = try await request(graphURL("me/sendMail"), account: account, method: "POST",
                bytes: Data(source.base64EncodedString().utf8), contentType: "text/plain")
        }
    }

    private func account(_ id: String) async throws -> MailAccount {
        guard let account = try await accounts().first(where: { $0.id == id }) else { throw DirectMailError.disconnected }
        return account
    }

    private func beginAccountMutation() async {
        if !isMutatingAccounts { isMutatingAccounts = true; return }
        await withCheckedContinuation { accountMutationWaiters.append($0) }
    }

    private func endAccountMutation() {
        if accountMutationWaiters.isEmpty { isMutatingAccounts = false }
        else { accountMutationWaiters.removeFirst().resume() }
    }

    private func checkedAccount(_ id: String, message: MailMessage) async throws -> MailAccount {
        let account = try await account(id)
        guard message.accountID == id, message.provider == account.provider else { throw DirectMailError.disconnected }
        return account
    }

    private func validateInbox(_ mailbox: String) throws {
        guard mailbox.caseInsensitiveCompare("Inbox") == .orderedSame else { throw DirectMailError.unsupported }
    }

    private func gmailSource(messageID: String, account: MailAccount) async throws -> Data {
        struct Raw: Decodable { let raw: String }
        let raw: Raw = try decode(try await request(gmailURL("messages/\(MailURLCoding.component(messageID))", query: ["format": "raw"]), account: account))
        guard let bytes = Data(base64URLEncoded: raw.raw) else { throw DirectMailError.invalidResponse }
        return bytes
    }

    private func graphRecipients(_ text: String) -> [[String: [String: String]]] {
        MIMEBodyReader.addresses(in: text).map { recipient in
            var address = ["address": recipient.address ?? ""]
            if let name = recipient.name { address["name"] = name }
            return ["emailAddress": address]
        }
    }

    private func graphAttachments(messageID: String, account: MailAccount) async throws -> [MailAttachment] {
        struct List: Decodable { let value: [GraphAttachmentResource]; let next: String?; enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink" } }
        var url = graphURL("me/messages/\(MailURLCoding.component(messageID))/attachments")
        var attachments: [MailAttachment] = []
        repeat {
            let list: List = try decode(try await request(url, account: account))
            attachments += list.value.map(\.attachment)
            guard let next = list.next else { break }
            guard let candidate = URL(string: next), candidate.scheme == "https", candidate.host == "graph.microsoft.com",
                  candidate.port == nil || candidate.port == 443, candidate.path == url.path,
                  candidate.user == nil, candidate.password == nil else { throw DirectMailError.invalidResponse }
            url = candidate
        } while true
        return attachments
    }

    private func request(_ url: URL, account: MailAccount, method: String = "GET", json: [String: Any]? = nil,
                         bytes: Data? = nil, contentType: String = "application/json") async throws -> Data {
        let revision = revisions[account.id]
        var tokens = try await validTokens(account: account)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? bytes
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if account.provider == .outlook { request.setValue("IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer") }
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        var (data, response) = try await transport.send(request)
        try await verifyConnection(account.id, revision: revision)
        if response.statusCode == 401 {
            // Retry only an explicit authorization rejection, never failed mail mutations or rate limits.
            tokens = try await refreshedTokens(account: account, old: tokens)
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            (data, response) = try await transport.send(request)
            try await verifyConnection(account.id, revision: revision)
        }
        try Self.validate(response)
        return data
    }

    private func validTokens(account: MailAccount) async throws -> OAuthTokens {
        guard let tokens = try await vault.load(accountID: account.id) else { throw DirectMailError.reauthorizationRequired }
        if tokens.expiresAt <= Date() { return try await refreshedTokens(account: account, old: tokens) }
        return tokens
    }

    private func refreshedTokens(account: MailAccount, old: OAuthTokens) async throws -> OAuthTokens {
        if let task = refreshes[account.id] { return try await task.value }
        let config = configuration(account.provider)
        let oauth = self.oauth
        let revision = revisions[account.id]
        let task = Task { try await oauth.refresh(old, configuration: config) }
        refreshes[account.id] = task
        defer { refreshes[account.id] = nil }
        let tokens = try await task.value
        try await verifyConnection(account.id, revision: revision)
        try await vault.save(tokens, accountID: account.id)
        return tokens
    }

    private func verifyConnection(_ id: String, revision: UUID?) async throws {
        _ = try await account(id)
        guard revisions[id] == revision else { throw DirectMailError.disconnected }
        try Task.checkCancellation()
    }

    private func profileData(url: URL, tokens: OAuthTokens, provider: MailProvider) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        try Self.validate(response)
        return data
    }

    private static func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 { throw DirectMailError.reauthorizationRequired }
        guard (200..<300).contains(response.statusCode) else {
            throw DirectMailError.status(response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else { throw DirectMailError.invalidResponse }
        return value
    }

    private func gmailURL(_ path: String, query: [String: String] = [:]) -> URL { providerURL("https://gmail.googleapis.com/gmail/v1/users/me/", path: path, query: query) }
    private func graphURL(_ path: String, query: [String: String] = [:]) -> URL { providerURL("https://graph.microsoft.com/v1.0/", path: path, query: query) }

    private func providerURL(_ base: String, path: String, query: [String: String]) -> URL {
        var parts = URLComponents(string: base + path)!
        if !query.isEmpty {
            // Percent-encode plus signs as data, not form-encoded spaces; preserve opaque provider tokens.
            parts.percentEncodedQuery = query.keys.sorted().map { "\(MailURLCoding.component($0))=\(MailURLCoding.component(query[$0]!))" }.joined(separator: "&")
        }
        return parts.url!
    }

    private func graphNextPage(_ token: String) throws -> URL {
        guard let url = URL(string: token), url.scheme == "https", url.host == "graph.microsoft.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil,
              url.path == "/v1.0/me/mailFolders/inbox/messages" else { throw DirectMailError.invalidResponse }
        return url
    }
}
