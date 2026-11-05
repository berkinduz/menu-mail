import Foundation
import Testing
@testable import Envl

struct MIMEBodyReaderTests {
    @Test func attachedMultipartHTMLNeverReplacesTheMainBody() throws {
        let source = """
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary="forwarded"
        Content-Disposition: attachment; filename="forwarded.eml"

        --forwarded
        Content-Type: text/html; charset="utf-8"

        <p>Attached message</p>
        --forwarded--
        --outer
        Content-Type: text/plain; charset="utf-8"

        Main message
        --outer--
        """
        let body = try MIMEBodyReader.body(from: source)
        #expect(body.contentType == "text")
        #expect(body.content.trimmingCharacters(in: .whitespacesAndNewlines) == "Main message")
        let attachment = try #require(body.attachments.first)
        #expect(attachment.mimeType == "message/rfc822")
        let data = try #require(attachment.data)
        let original = try #require(String(data: data, encoding: .utf8))
        #expect(original.contains("Content-Type: multipart/alternative; boundary=\"forwarded\""))
        let attachedBody = try MIMEBodyReader.body(from: original)
        #expect(attachedBody.content.trimmingCharacters(in: .whitespacesAndNewlines) == "<p>Attached message</p>")
    }

    @Test func inlineCIDImagesAndQuotedPrintableCharsetRemainReadable() throws {
        let source = """
        MIME-Version: 1.0
        Content-Type: multipart/related; boundary="related"

        --related
        Content-Type: text/html; charset="iso-8859-1"
        Content-Transfer-Encoding: quoted-printable

        <p>caf=E9</p><img src=3D"CID:logo@example.test">
        --related
        Content-Type: image/png
        Content-ID: <logo@example.test>
        Content-Transfer-Encoding: base64

        AQID
        --related--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let body = try MIMEBodyReader.body(from: source)
        #expect(body.contentType == "html")
        #expect(body.content.contains("<p>café</p>"))
        #expect(body.content.contains("src=\"data:image/png;base64,AQID\""))
    }

    @Test func nonUTF8Base64PlainTextUsesItsDeclaredCharset() throws {
        let source = """
        Content-Type: text/plain; charset="windows-1252"
        Content-Transfer-Encoding: base64

        UHJpY2U6IIDg
        """
        let body = try MIMEBodyReader.body(from: source)
        #expect(body.contentType == "text")
        #expect(body.content == "Price: €à")
    }

    @Test func messageHeadersPreserveRecipientsAndReplyIdentity() throws {
        let source = """
        To: "Doe, Jane" <jane@example.test>, =?UTF-8?Q?Berkin_D=C3=BCz?= <berkin@example.test>
        Cc: Project: first@example.test,
            "Second Person" <second@example.test>;
        Reply-To: =?UTF-8?B?U3VwcG9ydCBUZWFt?= <reply@example.test>
        Message-ID: <original@example.test>
        References: <parent@example.test>
            <thread@example.test>
        Content-Type: text/plain; charset=utf-8

        Original body
        """
        let body = try MIMEBodyReader.body(from: source)
        #expect(body.to == [
            .init(name: "Doe, Jane", address: "jane@example.test"),
            .init(name: "Berkin Düz", address: "berkin@example.test")
        ])
        #expect(body.cc == [
            .init(name: nil, address: "first@example.test"),
            .init(name: "Second Person", address: "second@example.test")
        ])
        #expect(body.replyTo == [.init(name: "Support Team", address: "reply@example.test")])
        #expect(body.messageID == "<original@example.test>")
        #expect(body.references == "<parent@example.test> <thread@example.test>")
    }

    @Test func attachmentsDecodeRFC2231NamesAndExposeOriginalBytes() throws {
        let source = """
        Content-Type: multipart/mixed; boundary="mixed"

        --mixed
        Content-Type: text/plain

        See the files.
        --mixed
        Content-Type: application/pdf; name="fallback.pdf"
        Content-Disposition: attachment;
          filename*0*=utf-8''caf%C3%A9-;
          filename*1*=plan.pdf
        Content-Transfer-Encoding: base64

        AAEC/w==
        --mixed
        Content-Type: text/csv; charset=iso-8859-1
        Content-Disposition: attachment; filename="=?ISO-8859-1?Q?r=E9sum=E9.csv?="
        Content-Transfer-Encoding: quoted-printable

        name,caf=E9=0A
        --mixed--
        """
        let body = try MIMEBodyReader.body(from: source)
        #expect(body.attachments.map(\.name) == ["café-plan.pdf", "résumé.csv"])
        #expect(body.attachments.map(\.mimeType) == ["application/pdf", "text/csv"])
        #expect(body.attachments.first?.data == Data([0, 1, 2, 255]))
        #expect(body.attachments.first?.size == 4)
        #expect(body.attachments.last?.data == Data([110, 97, 109, 101, 44, 99, 97, 102, 233, 10]))
        #expect(Set(body.attachments.map(\.id)).count == 2)
    }

    @Test func attachedOriginalMessageRemainsAnAttachmentWithItsHeaders() throws {
        let source = """
        Content-Type: multipart/mixed; boundary="mixed"

        --mixed
        Content-Type: text/plain

        Main body
        --mixed
        Content-Type: message/rfc822; name="original.eml"
        Content-Disposition: attachment; filename="original.eml"

        To: nested@example.test
        Message-ID: <nested@example.test>
        Content-Type: text/html

        <p>Forwarded HTML</p>
        --mixed--
        """
        let body = try MIMEBodyReader.body(from: source)
        #expect(body.contentType == "text")
        #expect(body.messageID == nil)
        #expect(body.to.isEmpty)
        let attachment = try #require(body.attachments.first)
        #expect(attachment.name == "original.eml")
        #expect(attachment.mimeType == "message/rfc822")
        #expect(String(data: try #require(attachment.data), encoding: .utf8)?.contains("Message-ID: <nested@example.test>") == true)
    }


    @Test func quotedPunctuationInRecipientsAndFilenamesIsPreserved() throws {
        let source = #"""
        To: "Support: \"Europe\"" <support@example.test>
        Content-Type: multipart/mixed; boundary="mixed"

        --mixed
        Content-Type: text/plain

        File attached.
        --mixed
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="notes; \"final\".txt"
        Content-Transfer-Encoding: base64

        SGVsbG8=
        --mixed--
        """#
        let body = try MIMEBodyReader.body(from: source)
        #expect(body.to == [.init(name: "Support: \"Europe\"", address: "support@example.test")])
        #expect(body.attachments.first?.name == "notes; \"final\".txt")
    }


    @Test func quotedPrintableAttachmentBytesRetainCRLFAndDecodeSoftWraps() throws {
        let source = """
        Content-Type: multipart/mixed; boundary="mixed"

        --mixed
        Content-Type: text/plain

        Main message
        --mixed
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="bytes.bin"
        Content-Transfer-Encoding: quoted-printable

        A=00=
        B
        C=FF
        --mixed--
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let body = try MIMEBodyReader.body(from: source)
        #expect(body.attachments.first?.data == Data([65, 0, 66, 13, 10, 67, 255]))
        #expect(body.attachments.first?.size == 7)
    }


    @Test func forwardingCanKeepCIDReferencesAndTheSameInlineAttachmentBytes() throws {
        let source = """
        To: person@example.test
        Message-ID: <original@example.test>
        Content-Type: multipart/related; boundary="related"

        --related
        Content-Type: text/html

        <img src="cid:logo@example.test">
        --related
        Content-Type: image/png
        Content-ID: <logo@example.test>
        Content-Transfer-Encoding: base64

        AQID
        --related--
        """
        let resolved = try MIMEBodyReader.body(from: source)
        let original = try MIMEBodyReader.body(from: source, resolvingInlineImages: false)
        #expect(original.content.contains("src=\"cid:logo@example.test\""))
        #expect(resolved.content.contains("src=\"data:image/png;base64,AQID\""))
        #expect(original.attachments == resolved.attachments)
        #expect(original.to == resolved.to)
        #expect(original.messageID == resolved.messageID)
    }


    @Test func forwardingHeadersComeOnlyFromTheOriginalRootAndKeepEncodedWords() throws {
        let source = """
        From: Main Sender <main@example.test>
        To: first@example.test,
            second@example.test
        Date: Thu, 5 Nov 2026 09:00:00 +0000
        Subject: =?UTF-8?Q?Caf=C3=A9?=
        Content-Type: message/rfc822

        From: Nested Sender <nested@example.test>
        Subject: Nested subject
        Content-Type: text/plain

        Nested body
        """
        let headers = try MIMEBodyReader.headers(from: source)
        #expect(headers["from"] == "Main Sender <main@example.test>")
        #expect(headers["to"] == "first@example.test, second@example.test")
        #expect(headers["date"] == "Thu, 5 Nov 2026 09:00:00 +0000")
        #expect(headers["subject"] == "=?UTF-8?Q?Caf=C3=A9?=")
    }


    @Test func dataSourcePreservesAnUnencodedNestedMessageAndEveryBinaryAttachmentByte() throws {
        let nested = Data("From: nested@example.test\r\nContent-Type: text/plain; charset=windows-1252\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
            + Data([65, 128, 255, 13, 10])
        let binary = Data((0...255).map(UInt8.init)) + Data("\r\n--raw-boundary".utf8)
            + Data([160]) + Data("\r\nTail".utf8)
        var source = Data("Content-Type: multipart/mixed; boundary=raw-boundary\r\n\r\n--raw-boundary\r\nContent-Type: text/plain\r\n\r\nMain body\r\n--raw-boundary\r\nContent-Type: message/rfc822\r\nContent-Disposition: attachment; filename=original.eml\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
        source += nested
        source += Data("\r\n--raw-boundary\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=bytes.bin\r\nContent-Transfer-Encoding: binary\r\n\r\n".utf8)
        source += binary
        source += Data("\r\n--raw-boundary--\r\n".utf8)
        let body = try MIMEBodyReader.body(from: source, resolvingInlineImages: false)
        #expect(body.content == "Main body")
        #expect(body.attachments.first?.mimeType == "message/rfc822")
        #expect(body.attachments.first?.data == nested)
        #expect(body.attachments.first?.size == nested.count)
        #expect(body.attachments.last?.data == binary)
        #expect(body.attachments.last?.size == 279)
    }

    @Test func rawDataDecodesUTF8HeadersIndependentlyFromTheDeclaredBodyCharset() throws {
        var source = Data("Subject: Café 🧠\r\nFrom: Zoë <sender@example.test>\r\nTo: Çağrı <recipient@example.test>\r\nContent-Type: text/plain; charset=windows-1252\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
        source += Data([80, 114, 105, 99, 101, 58, 32, 128, 32, 233, 255])
        let headers = try MIMEBodyReader.headers(from: source)
        let body = try MIMEBodyReader.body(from: source)
        #expect(headers["subject"] == "Café 🧠")
        #expect(headers["from"] == "Zoë <sender@example.test>")
        #expect(body.to == [.init(name: "Çağrı", address: "recipient@example.test")])
        #expect(body.content == "Price: € éÿ")

        let utf8 = Data("Content-Type: text/plain; charset=utf-8\r\n\r\nMerhaba, dünya\r\n".utf8)
        #expect(try MIMEBodyReader.body(from: utf8).content == "Merhaba, dünya\n")
    }

    @Test func aRawAttachedMultipartKeepsItsBoundaryWrapperAndPayloadBytes() throws {
        let attached = Data("--forwarded\r\nContent-Type: text/plain; charset=windows-1252\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".utf8)
            + Data([128, 255]) + Data("\r\n--forwarded--\r\n".utf8)
        var source = Data("Content-Type: multipart/mixed; boundary=outer\r\n\r\n--outer\r\nContent-Type: text/plain\r\n\r\nMain body\r\n--outer\r\nContent-Type: multipart/alternative; boundary=forwarded\r\nContent-Disposition: attachment; filename=forwarded.eml\r\n\r\n".utf8)
        source += attached + Data("\r\n--outer--\r\n".utf8)
        let body = try MIMEBodyReader.body(from: source)
        let attachment = try #require(body.attachments.first)
        let expected = Data("MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=forwarded\r\n\r\n".utf8) + attached
        #expect(attachment.mimeType == "message/rfc822")
        #expect(attachment.data == expected)
        #expect(try MIMEBodyReader.body(from: expected).content == "€ÿ")
    }

}
