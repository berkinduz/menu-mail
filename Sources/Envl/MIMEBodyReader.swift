import CoreFoundation
import Foundation

/// Mail exposes the original MIME source, not an HTML-body scripting property.
enum MIMEBodyReader {
    private struct Part {
        let id: String
        let headers: [String: String]
        let content: String
        let sourceEncoding: String.Encoding

        var type: String {
            (headers["content-type"] ?? "text/plain").components(separatedBy: ";")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var isAttachment: Bool {
            (headers["content-disposition"] ?? "").components(separatedBy: ";")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
        }

        var filename: String? {
            MIMEBodyReader.parameter("filename", in: headers["content-disposition"] ?? "")
                ?? MIMEBodyReader.parameter("name", in: headers["content-type"] ?? "")
        }

        var contentID: String? {
            guard let value = headers["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\n")),
                  !value.isEmpty else { return nil }
            return value
        }

        func data() throws -> Data {
            let bytes = MIMEBodyReader.sourceData(content, encoding: sourceEncoding)
            switch headers["content-transfer-encoding"]?.lowercased() {
            case "base64":
                guard let data = Data(base64Encoded: bytes, options: .ignoreUnknownCharacters) else {
                    throw MailError.message("Could not decode the message's Base64 content.")
                }
                return data
            case "quoted-printable": return MIMEBodyReader.quotedPrintableData(bytes)
            default: return bytes
            }
        }

        func text() throws -> String {
            let transfer = headers["content-transfer-encoding"]?.lowercased()
            let transferEncoded = transfer == "base64" || transfer == "quoted-printable"
            if !transferEncoded, sourceEncoding == .utf8 {
                return content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            }
            let charset = MIMEBodyReader.parameter("charset", in: headers["content-type"] ?? "") ?? "utf-8"
            guard let text = MIMEBodyReader.decode(try data(), charset: charset) else {
                throw MailError.detail("Could not decode the message's character encoding: %@.", charset)
            }
            return transferEncoded ? text : text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
    }

    static func headers(from source: Data) throws -> [String: String] {
        guard let root = part(from: byteString(source), id: "mime-0", sourceEncoding: .isoLatin1) else { throw unreadableBody() }
        return root.headers
    }

    static func body(from source: Data, resolvingInlineImages: Bool = true) throws -> MailMessage.Body {
        guard let root = part(from: byteString(source), id: "mime-0", sourceEncoding: .isoLatin1) else { throw unreadableBody() }
        return try body(from: root, resolvingInlineImages: resolvingInlineImages)
    }

    static func headers(from source: String) throws -> [String: String] {
        guard let root = part(from: source, id: "mime-0") else { throw unreadableBody() }
        return root.headers
    }

    static func body(from source: String) throws -> MailMessage.Body {
        try body(from: source, resolvingInlineImages: true)
    }

    static func body(from source: String, resolvingInlineImages: Bool) throws -> MailMessage.Body {
        guard let root = part(from: source, id: "mime-0") else { throw unreadableBody() }
        return try body(from: root, resolvingInlineImages: resolvingInlineImages)
    }

    private static func body(from root: Part, resolvingInlineImages: Bool) throws -> MailMessage.Body {
        let parts = leaves(in: root)
        let bodies = parts.filter { !$0.isAttachment }
        guard let body = bodies.first(where: { $0.type == "text/html" }) ?? bodies.first(where: { $0.type == "text/plain" }) else {
            throw unreadableBody()
        }
        var content = try body.text()
        if resolvingInlineImages, body.type == "text/html" {
            for image in parts where image.type.hasPrefix("image/") {
                guard let cid = image.contentID else { continue }
                let pattern = "(?i:cid:)" + NSRegularExpression.escapedPattern(for: cid) + "(?=[\"'\\s)>]|$)"
                let regex = try NSRegularExpression(pattern: pattern)
                let replacement = "data:\(image.type);base64,\(try image.data().base64EncodedString())"
                content = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
            }
        }
        let attachments = try parts.filter { part in
            part.id != body.id && (part.isAttachment || part.filename != nil ||
                (part.type != "text/plain" && part.type != "text/html" && !part.type.hasPrefix("multipart/")))
        }.map { part in
            let attachedMultipart = part.isAttachment && part.type.hasPrefix("multipart/")
            var data = try part.data()
            if attachedMultipart {
                let headers = "MIME-Version: 1.0\r\nContent-Type: \(part.headers["content-type"]!)\r\n\r\n"
                data = Data(headers.utf8) + data
            }
            return MailAttachment(id: part.id, name: part.filename ?? (attachedMultipart || part.type == "message/rfc822" ? "Forwarded message.eml" : "Attachment"),
                mimeType: attachedMultipart ? "message/rfc822" : part.type, size: data.count, data: data, contentID: part.contentID)
        }
        return MailMessage.Body(contentType: body.type == "text/html" ? "html" : "text", content: content,
            attachments: attachments, to: addresses(in: root.headers["to"]), cc: addresses(in: root.headers["cc"]),
            replyTo: addresses(in: root.headers["reply-to"]), messageID: root.headers["message-id"], references: root.headers["references"])
    }

    private static func unreadableBody() -> MailError {
        .message("No readable HTML or plain text body found. Encrypted or protected messages may need to be opened in Apple Mail.")
    }

    // The Latin-1 view maps each original byte to one scalar; MIME splitting stays byte-preserving.
    private static func byteString(_ data: Data) -> String {
        String(String.UnicodeScalarView(data.map { UnicodeScalar($0) }))
    }

    private static func sourceData(_ source: String, encoding: String.Encoding) -> Data {
        encoding == .isoLatin1 ? Data(source.unicodeScalars.map { UInt8($0.value) }) : Data(source.utf8)
    }

    private static func part(from source: String, id: String, sourceEncoding: String.Encoding = .utf8) -> Part? {
        let sourceLines = lines(in: source)
        guard let separator = sourceLines.firstIndex(where: { $0.text.isEmpty }) else { return nil }
        let headerText = sourceLines[..<separator].map(\.text).joined(separator: "\n")
            .replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let rawValue = String(line[line.index(after: colon)...])
            let decodedValue = sourceEncoding == .isoLatin1
                ? String(data: sourceData(rawValue, encoding: sourceEncoding), encoding: .utf8) ?? rawValue
                : rawValue
            let value = decodedValue.trimmingCharacters(in: .whitespaces)
            if let existing = headers[key] {
                headers[key] = existing + (["to", "cc", "reply-to"].contains(key) ? ", " : " ") + value
            } else {
                headers[key] = value
            }
        }
        let content = sourceLines.dropFirst(separator + 1).map { $0.text + $0.ending }.joined()
        return Part(id: id, headers: headers, content: content, sourceEncoding: sourceEncoding)
    }

    private static func leaves(in part: Part) -> [Part] {
        // An attached multipart is one downloadable object, not a candidate reader body.
        guard !part.isAttachment, part.type.hasPrefix("multipart/"),
              let boundary = parameter("boundary", in: part.headers["content-type"] ?? "") else { return [part] }
        var children: [Part] = []
        var childSource: String?
        var childIndex = 0
        func appendChild(_ source: String, beforeBoundary: Bool) {
            var source = source
            // The line break immediately before a MIME delimiter belongs to that delimiter.
            if beforeBoundary, let last = source.last, last == "\r\n" || last == "\n" || last == "\r" {
                source.removeLast()
            }
            if let child = self.part(from: source, id: "\(part.id).\(childIndex)", sourceEncoding: part.sourceEncoding) {
                children += leaves(in: child)
            }
            childIndex += 1
        }
        let boundaryWhitespace = part.sourceEncoding == .isoLatin1 ? CharacterSet(charactersIn: " \t") : .whitespaces
        for line in lines(in: part.content) {
            let delimiter = line.text.trimmingCharacters(in: boundaryWhitespace)
            if delimiter == "--\(boundary)" || delimiter == "--\(boundary)--" {
                if let childSource { appendChild(childSource, beforeBoundary: true) }
                if delimiter == "--\(boundary)--" { return children }
                childSource = ""
            } else if childSource != nil {
                childSource?.append(line.text + line.ending)
            }
        }
        if let childSource { appendChild(childSource, beforeBoundary: false) }
        return children
    }

    private static func lines(in source: String) -> [(text: String, ending: String)] {
        var result: [(text: String, ending: String)] = []
        var current = ""
        for character in source {
            if character == "\r\n" || character == "\n" || character == "\r" {
                result.append((current, String(character)))
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append((current, ""))
        return result
    }

    private static func quotedPrintableData(_ content: Data) -> Data {
        let bytes = Array(content)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61 {
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                    index += 3
                    continue
                }
                if index + 1 < bytes.count, bytes[index + 1] == 10 {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count,
                   let value = UInt8(String(bytes: bytes[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) {
                    output.append(value)
                    index += 3
                    continue
                }
            }
            output.append(bytes[index])
            index += 1
        }
        return output
    }

    private static func decode(_ data: Data, charset: String) -> String? {
        let encodingID = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard encodingID != kCFStringEncodingInvalidId else { return nil }
        return String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encodingID)))
    }

    static func decodeEncodedWords(_ header: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bqBQ])\?([^?]*)\?="#) else { return header }
        let matches = regex.matches(in: header, range: NSRange(header.startIndex..., in: header))
        var result = ""
        var previousEnd = header.startIndex
        var previousWasEncoded = false
        for match in matches {
            guard let range = Range(match.range, in: header),
                  let charsetRange = Range(match.range(at: 1), in: header),
                  let encodingRange = Range(match.range(at: 2), in: header),
                  let valueRange = Range(match.range(at: 3), in: header) else { continue }
            let gap = String(header[previousEnd..<range.lowerBound])
            if !previousWasEncoded || !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result += gap }
            let value = String(header[valueRange])
            let data = header[encodingRange].lowercased() == "b" ? Data(base64Encoded: value) : quotedPrintableData(Data(value.replacingOccurrences(of: "_", with: " ").utf8))
            if let data, let decoded = decode(data, charset: String(header[charsetRange])) {
                result += decoded
                previousWasEncoded = true
            } else {
                result += String(header[range])
                previousWasEncoded = false
            }
            previousEnd = range.upperBound
        }
        result += header[previousEnd...]
        return result
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        let fields = split(header, separators: [";"], respectAngles: false)
        var parameters: [String: String] = [:]
        for field in fields.dropFirst() {
            guard let equals = field.firstIndex(of: "=") else { continue }
            let key = field[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = field[field.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parameters[key] = unquote(value)
        }
        if let extended = parameters[name + "*"], let value = extendedParameter(extended) { return value }
        var continuation = ""
        var encoded = false
        var index = 0
        while let value = parameters["\(name)*\(index)*"] ?? parameters["\(name)*\(index)"] {
            encoded = encoded || parameters["\(name)*\(index)*"] != nil
            continuation += value
            index += 1
        }
        if index > 0 {
            return encoded ? extendedParameter(continuation) : decodeEncodedWords(continuation)
        }
        return parameters[name].map(decodeEncodedWords)
    }

    private static func extendedParameter(_ value: String) -> String? {
        let components = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        let bytes = Array(components[2].utf8)
        var data = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37, index + 2 < bytes.count,
               let byte = UInt8(String(bytes: bytes[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) {
                data.append(byte)
                index += 3
            } else {
                data.append(bytes[index])
                index += 1
            }
        }
        return decode(data, charset: String(components[0]))
    }

    static func addresses(in header: String?) -> [MailMessage.Address] {
        guard let header else { return [] }
        return split(header, separators: [",", ";"], respectAngles: true).compactMap { value in
            var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // A group label precedes its first mailbox and is not a display name.
            let group = split(value, separators: [":"], respectAngles: true)
            if group.count > 1, !group[0].contains("@") {
                value = group.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
            }
            if let open = value.lastIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
                let address = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let name = decodeEncodedWords(unquote(value[..<open].trimmingCharacters(in: .whitespaces)))
                guard !address.isEmpty else { return nil }
                return .init(name: name.isEmpty ? nil : name, address: address)
            }
            guard !value.isEmpty else { return nil }
            return .init(name: nil, address: value)
        }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
    }

    private static func split(_ text: String, separators: Set<Character>, respectAngles: Bool) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        var angleDepth = 0
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if !quoted, respectAngles, character == "<" {
                angleDepth += 1
                current.append(character)
            } else if !quoted, respectAngles, character == ">" {
                angleDepth = max(0, angleDepth - 1)
                current.append(character)
            } else if !quoted, angleDepth == 0, separators.contains(character) {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }
}
