import Foundation

enum MailError: LocalizedError, Sendable {
    case message(String)
    case detail(String, String)
    case timeout(String)

    var errorDescription: String? { message(language: .english) }

    func message(language: AppLanguage) -> String {
        switch self {
        case .message(let key): L10n.text(key, language: language)
        case .detail(let key, let value): L10n.text(key, language: language, arguments: [value])
        case .timeout(let stage):
            L10n.text("Apple Mail did not respond in time (%@).", language: language,
                arguments: [L10n.text(stage, language: language)])
        }
    }
}

struct MailAccount: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// Uses Mail's documented scripting interface. Mail owns authentication and sync.
struct AppleMailClient: Sendable {
    private struct Status: Decodable {
        let errorNumber: Int?
        let stage: String?

        var stageLabel: String {
            switch stage {
            case "account": "account"
            case "mailbox": "mailbox"
            case "message", "identity": "message"
            case "source": "message source"
            case "encoding": "source encoding"
            default: "Apple Mail request"
            }
        }
    }

    func accounts() async throws -> [MailAccount] {
        struct Response: Decodable, Sendable { let accounts: [MailAccount] }
        let response: Response = try await run(["accounts"])
        return response.accounts
    }

    func mailboxes(accountID: String) async throws -> [String] {
        struct Response: Decodable, Sendable { let mailboxes: [String] }
        let response: Response = try await run(["mailboxes", accountID])
        return response.mailboxes
    }

    func inbox(accountID: String, mailbox: String, limit: Int, checkForMail: Bool = false) async throws -> [MailMessage] {
        struct Response: Decodable, Sendable { let messages: [MailMessage] }
        let response: Response = try await run(["inbox", accountID, mailbox, checkForMail ? "check" : "local", String(limit)])
        return response.messages
    }

    func body(message: MailMessage, accountID: String, mailbox: String) async throws -> MailMessage.Body {
        struct Response: Decodable, Sendable { let source: String }
        guard let index = message.sourceIndex else {
            throw MailError.message("The message reference has expired. Return to the inbox and refresh.")
        }
        let response: Response = try await run(["source", accountID, mailbox, message.id, String(index)])
        let decoded = try await Task.detached(priority: .userInitiated) {
            try MIMEBodyReader.body(from: response.source)
        }.value
        try Task.checkCancellation()
        return decoded
    }

    private func run<Value: Decodable & Sendable>(_ arguments: [String]) async throws -> Value {
        let readingSource = arguments.first == "source"
        let resource = readingSource ? "MailSource" : "MailBridge"
        let fileExtension = readingSource ? "applescript" : "js"
        guard let script = Bundle.main.url(forResource: resource, withExtension: fileExtension) else {
            throw MailError.message("The Mail connection script is missing. Build with scripts/build.sh and open the .app bundle.")
        }
        let execution = MailScriptExecution(script: script,
            arguments: readingSource ? Array(arguments.dropFirst()) : arguments,
            language: readingSource ? "AppleScript" : "JavaScript")
        let data = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try execution.read() }.value
        } onCancel: {
            execution.stop(.cancelled)
        }
        try Task.checkCancellation()
        let status = try JSONDecoder().decode(Status.self, from: data)
        if let number = status.errorNumber {
            switch number {
            case -1743:
                throw MailError.message("Apple Mail access was denied. Enable Mail for MenuMail in System Settings → Privacy & Security → Automation.")
            case -1728:
                throw MailError.message("The account, mailbox or message was not found. Choose the mailbox again, or return to the inbox and refresh.")
            case -1712:
                throw MailError.timeout(status.stageLabel)
            default:
                throw MailError.detail("Could not read Apple Mail (error %@). Open Mail and try again.", String(number))
            }
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

/// Owns one subprocess so leaving the reader can cancel that request immediately.
private final class MailScriptExecution: @unchecked Sendable {
    enum StopReason { case cancelled, timedOut }

    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var stopReason: StopReason?

    init(script: URL, arguments: [String], language: String = "JavaScript") {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", language, script.path] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func read() throws -> Data {
        try lock.withLock {
            if stopReason != nil { throw CancellationError() }
            try process.run()
        }
        // The parent must not keep a pipe writer alive while waiting for EOF.
        try? output.fileHandleForWriting.close()
        let timeout = DispatchWorkItem { [weak self] in self?.stop(.timedOut) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        defer {
            timeout.cancel()
            try? output.fileHandleForReading.close()
        }
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        let reason = lock.withLock { stopReason }
        if reason == .cancelled { throw CancellationError() }
        if reason == .timedOut {
            throw MailError.message("Apple Mail did not respond within 15 seconds. Return to the inbox or try again.")
        }
        guard process.terminationStatus == 0 else {
            throw MailError.message("Could not start the Apple Mail connection. Check that Mail can be opened.")
        }
        return data
    }

    func stop(_ reason: StopReason) {
        lock.withLock {
            guard stopReason == nil else { return }
            stopReason = reason
            if process.isRunning { process.terminate() }
        }
    }
}
