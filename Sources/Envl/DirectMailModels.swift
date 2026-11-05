import Foundation

struct GmailMessageResource: Decodable, Sendable {
    struct Header: Decodable, Sendable { let name: String; let value: String }
    struct Part: Decodable, Sendable {
        struct Content: Decodable, Sendable {
            let data: String?
            let attachmentId: String?
            let size: Int?
        }
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Content?
        let parts: [Part]?
        var allParts: [Part] { [self] + (parts ?? []).flatMap(\.allParts) }
    }
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let internalDate: String?
    let snippet: String?
    let payload: Part?

    func message(account: MailAccount) -> MailMessage {
        let headers = payload?.headers ?? []
        func header(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        let sender = MIMEBodyReader.addresses(in: header("From")).first
        let date = internalDate.flatMap(Double.init).map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1000)) }
        return MailMessage(id: id, subject: header("Subject").map(MIMEBodyReader.decodeEncodedWords), from: sender.map { .init(emailAddress: $0) },
            receivedDateTime: date, body: nil, accountID: account.id, provider: .gmail,
            isRead: !(labelIds ?? []).contains("UNREAD"), isStarred: (labelIds ?? []).contains("STARRED"), snippet: snippet,
            to: MIMEBodyReader.addresses(in: header("To")), cc: MIMEBodyReader.addresses(in: header("Cc")),
            replyTo: MIMEBodyReader.addresses(in: header("Reply-To")), threadID: threadId,
            internetMessageID: header("Message-ID"),
            hasAttachments: (payload?.allParts ?? []).contains { !($0.filename ?? "").isEmpty })
    }
}

struct GraphMessageResource: Decodable, Sendable {
    struct Recipient: Decodable, Sendable { let emailAddress: MailMessage.Address }
    struct Content: Decodable, Sendable { let contentType: String; let content: String }
    struct Flag: Decodable, Sendable { let flagStatus: String? }
    struct Header: Decodable, Sendable { let name: String; let value: String }
    let id: String?
    let subject: String?
    let from: Recipient?
    let receivedDateTime: String?
    let isRead: Bool?
    let flag: Flag?
    let bodyPreview: String?
    let toRecipients: [Recipient]?
    let ccRecipients: [Recipient]?
    let replyTo: [Recipient]?
    let conversationId: String?
    let internetMessageId: String?
    let internetMessageHeaders: [Header]?
    let webLink: String?
    let hasAttachments: Bool?
    let body: Content?

    func message(account: MailAccount) throws -> MailMessage {
        guard let id, !id.isEmpty else { throw DirectMailError.invalidResponse }
        return MailMessage(id: id, subject: subject, from: from.map { .init(emailAddress: $0.emailAddress) },
            receivedDateTime: receivedDateTime, body: nil, accountID: account.id, provider: .outlook,
            isRead: isRead, isStarred: flag?.flagStatus == "flagged", snippet: bodyPreview,
            to: (toRecipients ?? []).map(\.emailAddress), cc: (ccRecipients ?? []).map(\.emailAddress),
            replyTo: (replyTo ?? []).map(\.emailAddress), threadID: conversationId, internetMessageID: internetMessageId,
            webURL: webLink.flatMap(URL.init(string:)), hasAttachments: hasAttachments ?? false)
    }
}

struct GraphAttachmentResource: Decodable, Sendable {
    let id: String
    let name: String?
    let contentType: String?
    let size: Int?
    let contentBytes: String?
    let contentId: String?
    let isInline: Bool?
    let odataType: String?
    private enum CodingKeys: String, CodingKey {
        case id, name, contentType, size, contentBytes, contentId, isInline
        case odataType = "@odata.type"
    }
    var attachment: MailAttachment {
        .init(id: id, name: name ?? "Attachment", mimeType: contentType ?? "application/octet-stream", size: size,
              data: contentBytes.flatMap { Data(base64Encoded: $0) }, providerAttachmentID: id, contentID: contentId)
    }
}

enum MailMIMEComposer {
    static func validate(_ draft: MailDraft, from address: String) throws {
        let headers = [address, draft.to, draft.cc, draft.bcc, draft.subject, draft.inReplyToHeader ?? "", draft.references ?? ""]
        guard headers.allSatisfy({ !$0.unicodeScalars.contains { $0.value == 13 || $0.value == 10 || $0.value == 0 } }),
              !draft.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DirectMailError.invalidDraft }
        let recipients = MIMEBodyReader.addresses(in: [draft.to, draft.cc, draft.bcc].filter { !$0.isEmpty }.joined(separator: ","))
        guard !recipients.isEmpty, recipients.allSatisfy({
            guard let address = $0.address, let at = address.lastIndex(of: "@") else { return false }
            return at != address.startIndex && address.index(after: at) != address.endIndex && !address.contains(where: \.isWhitespace)
        }) else { throw DirectMailError.invalidDraft }
    }

    static func source(_ draft: MailDraft, from address: String, body: MailMessage.Body? = nil) throws -> String {
        guard let source = String(data: try messageData(draft, from: address, body: body), encoding: .utf8) else {
            throw DirectMailError.invalidDraft
        }
        return source
    }

    static func messageData(_ draft: MailDraft, from address: String, body: MailMessage.Body? = nil) throws -> Data {
        try validate(draft, from: address)
        let subject = draft.subject.unicodeScalars.allSatisfy(\.isASCII) ? draft.subject : "=?UTF-8?B?\(Data(draft.subject.utf8).base64EncodedString())?="
        var lines = ["From: \(address)", "To: \(draft.to)", "Subject: \(subject)"]
        if !draft.cc.isEmpty { lines.append("Cc: \(draft.cc)") }
        if !draft.bcc.isEmpty { lines.append("Bcc: \(draft.bcc)") }
        if let original = draft.inReplyToHeader, !original.isEmpty {
            lines.append("In-Reply-To: \(original)")
            let references = draft.references?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lines.append("References: \(references.isEmpty ? original : references + (references.hasSuffix(original) ? "" : " " + original))")
        }
        lines.append("MIME-Version: 1.0")
        let body = body ?? .init(contentType: "text", content: draft.text)
        let html = body.contentType.caseInsensitiveCompare("html") == .orderedSame
        var entity = Data("Content-Type: text/\(html ? "html" : "plain"); charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64(Data(body.content.utf8)))".utf8)
        let inline = html ? body.attachments.filter { $0.contentID != nil } : []
        let regular = body.attachments.filter { !html || $0.contentID == nil }
        if !inline.isEmpty { entity = multipart("related", parts: [entity] + (try inline.map(attachmentPart))) }
        if !regular.isEmpty { entity = multipart("mixed", parts: [entity] + (try regular.map(attachmentPart))) }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8) + entity
    }

    static func forwardedBody(_ original: MailMessage.Body, headers: [String: String], comment: String) -> MailMessage.Body {
        let fields = [("from", "From"), ("date", "Date"), ("subject", "Subject"), ("to", "To"), ("cc", "Cc")]
            .compactMap { key, label in headers[key].map { "\(label): \(MIMEBodyReader.decodeEncodedWords($0))" } }
        let context = "---------- Forwarded message ----------\n" + fields.joined(separator: "\n")
        let textPrefix = (comment.isEmpty ? "" : comment + "\n\n") + context + "\n\n"
        if original.contentType.caseInsensitiveCompare("html") == .orderedSame {
            let prefix = "<div>" + htmlText(textPrefix) + "</div><hr>"
            return .init(contentType: "html", content: prefixHTML(prefix, original: original.content), attachments: original.attachments)
        }
        return .init(contentType: "text", content: textPrefix + original.content, attachments: original.attachments)
    }

    private static func base64(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    private static func multipart(_ subtype: String, parts: [Data]) -> Data {
        let boundary = "menumail-\(UUID().uuidString)"
        var content = Data()
        for part in parts {
            content.append(Data("--\(boundary)\r\n".utf8))
            content.append(part)
            content.append(Data("\r\n".utf8))
        }
        content.append(Data("--\(boundary)--".utf8))
        var headers = ["Content-Type: multipart/\(subtype); boundary=\"\(boundary)\""]
        let encoding = rawTransferEncoding(content)
        if encoding != "7bit" { headers.append("Content-Transfer-Encoding: \(encoding)") }
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + content
    }

    private static func attachmentPart(_ attachment: MailAttachment) throws -> Data {
        guard let data = attachment.data else { throw DirectMailError.attachmentUnavailable }
        let tokens = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
        let type = attachment.mimeType.split(separator: "/", omittingEmptySubsequences: false)
        guard type.count == 2, type.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(tokens.contains) }),
              attachment.contentID.map({ !$0.unicodeScalars.contains { $0.value == 13 || $0.value == 10 || $0.value == 0 } }) ?? true else {
            throw DirectMailError.invalidDraft
        }
        // RFC 2046 §5.2.1 requires an actual nested message, never Base64 at this boundary.
        let nestedMessage = attachment.mimeType.caseInsensitiveCompare("message/rfc822") == .orderedSame
        let encoding = nestedMessage ? rawTransferEncoding(data) : "base64"
        var headers = ["Content-Type: \(attachment.mimeType)", "Content-Transfer-Encoding: \(encoding)",
            "Content-Disposition: \(attachment.contentID == nil ? "attachment" : "inline"); filename*=UTF-8''\(MailURLCoding.component(attachment.name))"]
        if let cid = attachment.contentID { headers.append("Content-ID: <\(cid)>") }
        let content = nestedMessage ? data : Data(base64(data).utf8)
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + content
    }

    /// Classify unencoded MIME bytes without normalizing their line endings or payload.
    private static func rawTransferEncoding(_ data: Data) -> String {
        var index = data.startIndex
        var lineLength = 0
        var hasEightBit = false
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0 { return "binary" }
            if byte == 13 {
                let next = data.index(after: index)
                guard next < data.endIndex, data[next] == 10 else { return "binary" }
                index = data.index(after: next)
                lineLength = 0
                continue
            }
            if byte == 10 { return "binary" }
            lineLength += 1
            if lineLength > 998 { return "binary" }
            if byte > 127 { hasEightBit = true }
            index = data.index(after: index)
        }
        return hasEightBit ? "8bit" : "7bit"
    }

    private static func htmlText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Insert into the original body without rewriting its markup, CSS or CID references.
    private static func prefixHTML(_ prefix: String, original: String) -> String {
        var searchStart = original.startIndex
        while let body = original.range(of: "<body", options: .caseInsensitive, range: searchStart..<original.endIndex) {
            var index = body.upperBound
            guard index < original.endIndex else { break }
            if !original[index].isWhitespace && original[index] != ">" { searchStart = index; continue }
            var quote: Character?
            while index < original.endIndex {
                let character = original[index]
                if let current = quote {
                    if character == current { quote = nil }
                } else if character == "\"" || character == "'" { quote = character }
                else if character == ">" {
                    let afterTag = original.index(after: index)
                    return String(original[..<afterTag]) + prefix + original[afterTag...]
                }
                index = original.index(after: index)
            }
            break
        }
        return prefix + original
    }
}
