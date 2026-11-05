import Foundation
import Testing
@testable import Envl

@Suite struct DirectMailForwardingTests {
    private static let gmail = MailAccount(id: "gmail:forward@example.test", name: "Forward Gmail", provider: .gmail, address: "forward@example.test")
    private static let outlook = MailAccount(id: "outlook:forward-user", name: "Forward Outlook", provider: .outlook, address: "forward@example.test")

    private func fixture(_ replies: [DirectFixtureHTTP.Reply], account: MailAccount = Self.gmail) -> (DirectMailClient, DirectFixtureHTTP) {
        let http = DirectFixtureHTTP(replies)
        let tokens = OAuthTokens(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600))
        return (DirectMailClient(transport: http, vault: DirectFixtureVault([account.id: tokens]),
            accountStorage: DirectFixtureAccounts([account]), oauth: DirectFixtureOAuth(tokens: tokens),
            configuration: { .init(provider: $0, clientID: "fixture-public-client-id") }), http)
    }

    private func rawReply(_ source: String) throws -> DirectFixtureHTTP.Reply {
        .init(data: try JSONSerialization.data(withJSONObject: ["raw": Data(source.utf8).base64URLEncodedString()]), status: 200)
    }

    private func sentMIME(_ http: DirectFixtureHTTP) async throws -> (String, [String: String]) {
        let requests = await http.requests
        #expect(requests.count == 2)
        let send = try #require(requests.last)
        #expect(send.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        let requestBody = try #require(send.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: String])
        let raw = try #require(payload["raw"])
        let bytes = try #require(Data(base64URLEncoded: raw))
        return (try #require(String(data: bytes, encoding: .utf8)), payload)
    }

    private struct IndependentNestedMessage: Decodable {
        let type: String
        let encoding: String
        let subject: String?
        let body: String
    }

    /// Check interoperability with Python's MIME parser rather than relying on our reader's tolerance.
    private func independentlyParsedNestedMessage(_ mime: Data) throws -> IndependentNestedMessage {
        let script = """
            import base64, json, sys
            from email import policy
            from email.parser import BytesParser
            message = BytesParser(policy=policy.default).parsebytes(sys.stdin.buffer.read())
            part = next(part for part in message.walk() if part.get_content_type() == 'message/rfc822')
            nested = part.get_payload(0)
            print(json.dumps({'type': part.get_content_type(),
                              'encoding': part.get('Content-Transfer-Encoding', '7bit'),
                              'subject': nested.get('Subject'),
                              'body': base64.b64encode(nested.get_payload(decode=True) or b'').decode('ascii')}))
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-S", "-c", script]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: mime)
        try input.fileHandleForWriting.close()
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        try output.fileHandleForReading.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try JSONDecoder().decode(IndependentNestedMessage.self, from: result)
    }

    @Test func rfc822AttachmentsRemainNestedMessagesForAnIndependentParser() throws {
        let nested = Data("From: original@example.test\r\nSubject: Nested original\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nComplete nested body\r\n".utf8)
        let draft = MailDraft(accountID: Self.gmail.id, to: "recipient@example.test", subject: "Fwd: Outer")
        let body = MailMessage.Body(contentType: "text", content: "Outer body", attachments: [
            .init(id: "nested", name: "original.eml", mimeType: "message/rfc822", data: nested)
        ])
        let mime = try MailMIMEComposer.source(draft, from: "forward@example.test", body: body)
        let parsed = try independentlyParsedNestedMessage(Data(mime.utf8))
        #expect(parsed.type == "message/rfc822")
        #expect(["7bit", "8bit", "binary"].contains(parsed.encoding.lowercased()))
        #expect(parsed.subject == "Nested original")
        #expect(Data(base64Encoded: parsed.body) == Data("Complete nested body\r\n".utf8))
    }

    @Test func gmailForwardPreservesArbitraryNestedMessageBytesWithoutAStringRoundTrip() async throws {
        let nestedBody = Data([0x52, 0x61, 0x77, 0x20, 0xE9, 0x00, 0xFF, 0x0D, 0x0A]) + Data("LAST NESTED LINE".utf8)
        let nested = Data("From: original@example.test\r\nSubject: Nested binary original\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: binary\r\n\r\n".utf8) + nestedBody
        var original = Data("From: outer@example.test\r\nSubject: Outer original\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=original-boundary\r\n\r\n--original-boundary\r\nContent-Type: text/plain\r\n\r\nOriginal outer body\r\n--original-boundary\r\nContent-Type: message/rfc822\r\nContent-Disposition: attachment; filename=original.eml\r\nContent-Transfer-Encoding: binary\r\n\r\n".utf8)
        original.append(nested)
        original.append(Data("\r\n--original-boundary--\r\n".utf8))
        let rawReply = DirectFixtureHTTP.Reply(data: try JSONSerialization.data(withJSONObject: ["raw": original.base64URLEncodedString()]), status: 200)
        let (client, http) = fixture([rawReply, .json("{}")])
        var draft = MailDraft(accountID: Self.gmail.id, to: "recipient@example.test", subject: "Fwd: Outer", text: "My comment")
        draft.forwardMessageID = "outer"
        try await client.send(draft)
        let requests = await http.requests
        #expect(requests.count == 2)
        let request = try #require(requests.last)
        let bytes = try #require(request.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: String])
        let encoded = try #require(payload["raw"])
        let sent = try #require(Data(base64URLEncoded: encoded))
        #expect(sent.range(of: nested) != nil)
        let parsed = try independentlyParsedNestedMessage(sent)
        #expect(parsed.type == "message/rfc822")
        #expect(["7bit", "8bit", "binary"].contains(parsed.encoding.lowercased()))
        #expect(parsed.subject == "Nested binary original")
        #expect(Data(base64Encoded: parsed.body) == nestedBody)
    }

    @Test func gmailForwardFetchesAndSendsTheCompletePlainTextOriginal() async throws {
        let original = String(repeating: "Full original line beyond a preview.\n", count: 80) + "FINAL ORIGINAL LINE"
        let source = "From: Original <original@example.test>\r\nDate: Thu, 05 Nov 2026 10:00:00 +0000\r\nSubject: Full original\r\nTo: old-recipient@example.test\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" + original
        let (client, http) = fixture([try rawReply(source), .json("{}")])
        var draft = MailDraft(accountID: Self.gmail.id, to: "recipient@example.test", subject: "Fwd: Full original", text: "My forwarding comment")
        draft.forwardMessageID = "original/1"
        try await client.send(draft)
        let (mime, payload) = try await sentMIME(http)
        let forwarded = try MIMEBodyReader.body(from: mime)
        #expect(forwarded.content.contains(original))
        #expect(forwarded.content.hasPrefix("My forwarding comment"))
        #expect(forwarded.content.contains("From: Original <original@example.test>"))
        #expect(forwarded.content.contains("Date: Thu, 05 Nov 2026 10:00:00 +0000"))
        #expect(forwarded.content.contains("Subject: Full original"))
        #expect(forwarded.content.contains("To: old-recipient@example.test"))
        #expect(payload["threadId"] == nil)
        let requests = await http.requests
        #expect(requests.first?.httpMethod == "GET")
        #expect(requests.first?.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/original%2F1?format=raw")
        #expect(requests.allSatisfy { $0.httpMethod == "GET" || $0.url?.path.hasSuffix("/messages/send") == true })
    }

    @Test func gmailHTMLForwardRetainsFullMarkupAttachmentsAndCIDReferences() async throws {
        let attachment = Data([0, 1, 2, 3, 255, 10, 13])
        let inline = Data([137, 80, 78, 71])
        let html = "<html><head><style>table { color: red; }</style></head><body data-title=\">\"><p>Original HTML begins</p><img src=\"cid:original-inline\"><table><tr><td>FULL CONTENT AFTER PREVIEW</td></tr></table></body></html>"
        let source = [
            "From: Original <original@example.test>", "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=original-mixed", "",
            "--original-mixed", "Content-Type: multipart/related; boundary=original-related", "",
            "--original-related", "Content-Type: text/html; charset=utf-8", "Content-Transfer-Encoding: base64", "", Data(html.utf8).base64EncodedString(),
            "--original-related", "Content-Type: image/png", "Content-Disposition: inline; filename=inline.png", "Content-ID: <original-inline>",
            "Content-Transfer-Encoding: base64", "", inline.base64EncodedString(), "--original-related--",
            "--original-mixed", "Content-Type: application/pdf", "Content-Disposition: attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
            "Content-Transfer-Encoding: base64", "", attachment.base64EncodedString(), "--original-mixed--"
        ].joined(separator: "\r\n")
        let (client, http) = fixture([try rawReply(source), .json("{}")])
        var draft = MailDraft(accountID: Self.gmail.id, to: "recipient@example.test", subject: "Fwd: HTML", text: "My <literal> comment\nSecond line")
        draft.forwardMessageID = "original-html"
        try await client.send(draft)
        let (mime, _) = try await sentMIME(http)
        let forwarded = try MIMEBodyReader.body(from: mime, resolvingInlineImages: false)
        #expect(forwarded.content.contains("FULL CONTENT AFTER PREVIEW"))
        #expect(forwarded.content.contains("<style>table { color: red; }</style>"))
        #expect(forwarded.content.contains("data-title=\">\""))
        #expect(forwarded.content.contains("cid:original-inline"))
        #expect(!forwarded.content.contains("data:image/png"))
        #expect(forwarded.content.contains("My &lt;literal&gt; comment"))
        let commentRange = try #require(forwarded.content.range(of: "My &lt;literal&gt;"))
        let originalRange = try #require(forwarded.content.range(of: "Original HTML begins"))
        #expect(commentRange.lowerBound < originalRange.lowerBound)
        #expect(forwarded.attachments.first { $0.name == "résumé.pdf" }?.data == attachment)
        #expect(forwarded.attachments.first { $0.contentID == "original-inline" }?.data == inline)
        #expect(mime.contains("multipart/related"))
        #expect(mime.contains("Content-ID: <original-inline>"))
    }

    @Test func graphForwardUsesTheOriginalMessageAndEditedToCcBccWithoutReplacingItsBody() async throws {
        let (client, http) = fixture([.json("", status: 202)], account: Self.outlook)
        var draft = MailDraft(accountID: Self.outlook.id, to: "Person <recipient@example.test>", cc: "copy@example.test", bcc: "hidden@example.test",
            subject: "Fwd: Original", text: "My forwarding comment")
        draft.forwardMessageID = "original/1+="
        try await client.send(draft)
        let requests = await http.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://graph.microsoft.com/v1.0/me/messages/original%2F1%2B%3D/forward")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let requestBody = try #require(request.httpBody)
        let payload = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(payload["comment"] as? String == "My forwarding comment")
        #expect(payload["toRecipients"] == nil)
        let message = try #require(payload["message"] as? [String: Any])
        #expect((message["toRecipients"] as? [[String: [String: String]]])?.first?["emailAddress"]?["address"] == "recipient@example.test")
        #expect((message["ccRecipients"] as? [[String: [String: String]]])?.first?["emailAddress"]?["address"] == "copy@example.test")
        #expect((message["bccRecipients"] as? [[String: [String: String]]])?.first?["emailAddress"]?["address"] == "hidden@example.test")
        #expect(message["body"] == nil)
        #expect(message["attachments"] == nil)
    }

    @Test func aFailedOriginalDownloadNeverSendsAPartialForward() async throws {
        let (client, http) = fixture([.json("{}", status: 404)])
        var draft = MailDraft(accountID: Self.gmail.id, to: "recipient@example.test", subject: "Fwd: Missing", text: "My comment")
        draft.forwardMessageID = "missing"
        await #expect(throws: DirectMailError.self) { try await client.send(draft) }
        let requests = await http.requests
        #expect(requests.count == 1)
        #expect(requests.first?.httpMethod == "GET")
    }
}
