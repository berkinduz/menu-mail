import CoreFoundation
import Foundation

/// Mail exposes the original MIME source, not an HTML-body scripting property.
enum MIMEBodyReader {
    private struct Part {
        let headers: [String: String]
        let content: String

        var type: String {
            (headers["content-type"] ?? "text/plain").components(separatedBy: ";")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        func data() throws -> Data {
            switch headers["content-transfer-encoding"]?.lowercased() {
            case "base64":
                guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
                    throw MailError.message("Could not decode the message's Base64 content.")
                }
                return data
            case "quoted-printable":
                let bytes = Array(content.utf8)
                var output = Data()
                var index = 0
                while index < bytes.count {
                    if bytes[index] == 61 {
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
            default: return Data(content.utf8)
            }
        }

        func text() throws -> String {
            let transfer = headers["content-transfer-encoding"]?.lowercased()
            if transfer != "base64" && transfer != "quoted-printable" { return content }
            let charset = MIMEBodyReader.parameter("charset", in: headers["content-type"] ?? "") ?? "utf-8"
            let encodingID = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard encodingID != kCFStringEncodingInvalidId,
                  let text = String(data: try data(), encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encodingID))) else {
                throw MailError.detail("Could not decode the message's character encoding: %@.", charset)
            }
            return text
        }
    }

    static func body(from source: String) throws -> MailMessage.Body {
        let parts = leaves(in: source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        let bodies = parts.filter { !($0.headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") }
        guard let body = bodies.first(where: { $0.type == "text/html" }) ?? bodies.first(where: { $0.type == "text/plain" }) else {
            throw MailError.message("No readable HTML or plain text body found. Encrypted or protected messages may need to be opened in Apple Mail.")
        }
        var content = try body.text()
        if body.type == "text/html" {
            for image in parts where image.type.hasPrefix("image/") {
                guard let header = image.headers["content-id"] else { continue }
                let cid = header.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\n"))
                guard !cid.isEmpty else { continue }
                let pattern = "(?i:cid:)" + NSRegularExpression.escapedPattern(for: cid) + "(?=[\"'\\s)>]|$)"
                let regex = try NSRegularExpression(pattern: pattern)
                let replacement = "data:\(image.type);base64,\(try image.data().base64EncodedString())"
                content = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
            }
        }
        return MailMessage.Body(contentType: body.type == "text/html" ? "html" : "text", content: content)
    }

    private static func leaves(in source: String) -> [Part] {
        guard let separator = source.range(of: "\n\n") else { return [] }
        let headerText = String(source[..<separator.lowerBound])
            .replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let content = String(source[separator.upperBound...])
        let part = Part(headers: headers, content: content)
        guard part.type.hasPrefix("multipart/"), let boundary = parameter("boundary", in: headers["content-type"] ?? "") else {
            return [part]
        }

        var children: [Part] = []
        var lines: [String]?
        for line in content.components(separatedBy: "\n") {
            let delimiter = line.trimmingCharacters(in: .whitespaces)
            if delimiter == "--\(boundary)" || delimiter == "--\(boundary)--" {
                if let lines { children += leaves(in: lines.joined(separator: "\n")) }
                if delimiter == "--\(boundary)--" { return children }
                lines = []
            } else if lines != nil {
                lines?.append(line)
            }
        }
        if let lines { children += leaves(in: lines.joined(separator: "\n")) }
        return children
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        let pattern = "(?:^|;)\\s*" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(?:\"([^\"]*)\"|([^;\\s]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        for index in 1...2 {
            if let range = Range(match.range(at: index), in: header) { return String(header[range]) }
        }
        return nil
    }
}
