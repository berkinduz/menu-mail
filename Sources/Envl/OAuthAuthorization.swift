import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum DirectMailError: LocalizedError, Equatable, Sendable {
    case unconfigured(MailProvider)
    case reauthorizationRequired
    case disconnected
    case invalidResponse
    case status(Int, retryAfter: Int?)
    case invalidCallback
    case authorizationDenied
    case authorizationExpired
    case browserUnavailable
    case localCallbackUnavailable
    case unsupported
    case invalidDraft
    case attachmentUnavailable
    case tokenStorage(Int32)
    case accountStorage

    var errorDescription: String? {
        switch self {
        case .unconfigured(let provider):
            let key = provider == .gmail ? "EnvlGoogleClientID" : "EnvlMicrosoftClientID"
            return "\(provider == .gmail ? "Gmail" : "Microsoft") sign-in needs a public application client ID. Set \(key) when building Envl."
        case .reauthorizationRequired: return "Your mail authorization has expired or was revoked. Remove this connection and sign in again."
        case .disconnected: return "This account is no longer connected."
        case .invalidResponse: return "The mail provider returned an unreadable response. Please try again."
        case .status(403, _): return "The provider denied this mail operation. Check the application's mail permissions or your organization's policy."
        case .status(429, let delay):
            return delay.map { "The mail provider is busy. Try again in \($0) seconds." } ?? "The mail provider is busy. Please try again later."
        case .status(let status, _): return "The mail provider could not complete this operation (HTTP \(status)). Please try again."
        case .invalidCallback: return "The sign-in response did not match this authorization request. Start sign-in again."
        case .authorizationDenied: return "Sign-in was cancelled or permission was not granted."
        case .authorizationExpired: return "Sign-in timed out. Start sign-in again."
        case .browserUnavailable: return "Could not open your default browser for sign-in."
        case .localCallbackUnavailable: return "Could not open the local sign-in callback. Start sign-in again."
        case .unsupported: return "This operation is not available for this mail connection."
        case .invalidDraft: return "Check the recipient addresses and message headers before sending."
        case .attachmentUnavailable: return "This attachment could not be downloaded from the mail provider."
        case .tokenStorage(let code): return "Could not access this connection in Keychain (\(code))."
        case .accountStorage: return "Could not read the saved mail connections."
        }
    }
}

protocol MailHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class MailHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Provider endpoints are canonical; do not carry mailbox authorization across redirects.
        completionHandler(nil)
    }
}

struct URLSessionMailHTTPTransport: MailHTTPTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: MailHTTPRedirectPolicy(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DirectMailError.invalidResponse }
        return (data, response)
    }
}

struct OAuthConfiguration: Sendable {
    let provider: MailProvider
    let clientID: String
    var language: AppLanguage = .english

    static func bundled(for provider: MailProvider) -> Self {
        let key = provider == .gmail ? "EnvlGoogleClientID" : "EnvlMicrosoftClientID"
        return .init(provider: provider, clientID: Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "",
            language: AppLanguage(rawValue: UserDefaults.standard.string(forKey: "Language") ?? "en") ?? .english)
    }

    var tokenURL: URL {
        URL(string: provider == .gmail ? "https://oauth2.googleapis.com/token" : "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
    }

    var scopes: String {
        provider == .gmail ? "https://www.googleapis.com/auth/gmail.modify" : "offline_access User.Read Mail.ReadWrite Mail.Send"
    }

    func validate() throws {
        guard provider == .gmail || provider == .outlook else { throw DirectMailError.unsupported }
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !clientID.contains("$("), !clientID.contains("${") else { throw DirectMailError.unconfigured(provider) }
    }

    func authorizationURL(redirect: URL, state: String, verifier: String) throws -> URL {
        try validate()
        var components = URLComponents(string: provider == .gmail ? "https://accounts.google.com/o/oauth2/v2/auth" : "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect.absoluteString), .init(name: "scope", value: scopes),
            .init(name: "state", value: state), .init(name: "code_challenge", value: OAuthPKCE.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256")
        ]
        if provider == .gmail {
            components.queryItems?.append(contentsOf: [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")])
        } else {
            components.queryItems?.append(.init(name: "response_mode", value: "query"))
        }
        guard let url = components.url else { throw DirectMailError.invalidCallback }
        return url
    }
}

enum OAuthPKCE {
    static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DirectMailError.localCallbackUnavailable
        }
        return Data(bytes).base64URLEncodedString()
    }

    static func challenge(for verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString() }
}

enum OAuthCallback {
    static func code(from url: URL, redirect: URL, state: String) throws -> String {
        guard url.scheme == redirect.scheme, url.host == redirect.host, url.port == redirect.port,
              url.path == redirect.path, url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw DirectMailError.invalidCallback }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states.first?.value == state else { throw DirectMailError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw DirectMailError.authorizationDenied }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else { throw DirectMailError.invalidCallback }
        return code
    }
}

protocol MailOAuthAuthorizing: Sendable {
    func authorize(configuration: OAuthConfiguration) async throws -> OAuthTokens
    func refresh(_ old: OAuthTokens, configuration: OAuthConfiguration) async throws -> OAuthTokens
}

struct OAuthBrowserResponse: Sendable {
    let redirect: URL
    let callback: URL
}

protocol MailOAuthBrowser: Sendable {
    func authorize(configuration: OAuthConfiguration, state: String, verifier: String) async throws -> OAuthBrowserResponse
}

private struct SystemMailOAuthBrowser: MailOAuthBrowser {
    func authorize(configuration: OAuthConfiguration, state: String, verifier: String) async throws -> OAuthBrowserResponse {
        let listener = OAuthLoopbackListener(language: configuration.language)
        let redirect = try await listener.start(useLocalhost: configuration.provider == .outlook)
        defer { listener.cancel() }
        let url = try configuration.authorizationURL(redirect: redirect, state: state, verifier: verifier)
        guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else { throw DirectMailError.browserUnavailable }
        return .init(redirect: redirect, callback: try await listener.callback())
    }
}

struct OAuthAuthorization: MailOAuthAuthorizing {
    private let transport: any MailHTTPTransport
    private let browser: any MailOAuthBrowser
    init(transport: any MailHTTPTransport = URLSessionMailHTTPTransport(), browser: (any MailOAuthBrowser)? = nil) {
        self.transport = transport; self.browser = browser ?? SystemMailOAuthBrowser()
    }

    func authorize(configuration: OAuthConfiguration) async throws -> OAuthTokens {
        try configuration.validate()
        let verifier = try OAuthPKCE.randomValue()
        let state = try OAuthPKCE.randomValue()
        let response = try await browser.authorize(configuration: configuration, state: state, verifier: verifier)
        let code = try OAuthCallback.code(from: response.callback, redirect: response.redirect, state: state)
        return try await exchange(configuration: configuration, fields: [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": response.redirect.absoluteString, "code_verifier": verifier
        ], existingRefreshToken: nil)
    }

    func refresh(_ old: OAuthTokens, configuration: OAuthConfiguration) async throws -> OAuthTokens {
        try configuration.validate()
        guard let refreshToken = old.refreshToken, !refreshToken.isEmpty else { throw DirectMailError.reauthorizationRequired }
        return try await exchange(configuration: configuration,
            fields: ["grant_type": "refresh_token", "refresh_token": refreshToken], existingRefreshToken: refreshToken)
    }

    private func exchange(configuration: OAuthConfiguration, fields: [String: String], existingRefreshToken: String?) async throws -> OAuthTokens {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        struct Rejection: Decodable { let error: String? }
        var fields = fields
        fields["client_id"] = configuration.clientID
        if configuration.provider == .outlook { fields["scope"] = configuration.scopes }
        var request = URLRequest(url: configuration.tokenURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.keys.sorted().map { "\(MailURLCoding.component($0))=\(MailURLCoding.component(fields[$0]!))" }.joined(separator: "&").utf8)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if (try? JSONDecoder().decode(Rejection.self, from: data))?.error == "invalid_grant" {
                throw DirectMailError.reauthorizationRequired
            }
            throw DirectMailError.status(response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        guard let result = try? JSONDecoder().decode(Response.self, from: data),
              !result.access_token.isEmpty, result.expires_in > 0 else { throw DirectMailError.invalidResponse }
        return OAuthTokens(accessToken: result.access_token, refreshToken: result.refresh_token ?? existingRefreshToken,
            expiresAt: Date().addingTimeInterval(result.expires_in))
    }
}

enum MailURLCoding {
    static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

/// A short-lived listener bound to IPv4 loopback only; nothing is served on a LAN interface.
private final class OAuthLoopbackListener: @unchecked Sendable {
    private let language: AppLanguage
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.berkin.menumail.oauth-callback")
    private var listener: NWListener?
    private var redirect: URL?
    private var startup: CheckedContinuation<URL, Error>?
    private var pending: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var timeout: DispatchWorkItem?

    init(language: AppLanguage) { self.language = language }

    func start(useLocalhost: Bool) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    let completed = lock.withLock { () -> Result<URL, Error>? in
                        if let result { return result }
                        self.listener = listener; startup = continuation; return nil
                    }
                    if let completed { listener.cancel(); continuation.resume(with: completed); return }
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port,
                                  let url = URL(string: "http://\(useLocalhost ? "localhost" : "127.0.0.1"):\(port.rawValue)/oauth/callback") else {
                                self.finish(.failure(DirectMailError.localCallbackUnavailable)); return
                            }
                            let ready = self.lock.withLock { () -> CheckedContinuation<URL, Error>? in
                                self.redirect = url
                                let ready = self.startup; self.startup = nil; return ready
                            }
                            ready?.resume(returning: url)
                        case .failed: self.finish(.failure(DirectMailError.localCallbackUnavailable))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        connection.start(queue: self?.queue ?? .global())
                        self?.receive(connection, collected: Data())
                    }
                    let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(DirectMailError.authorizationExpired)) }
                    lock.withLock { self.timeout = timeout }
                    queue.asyncAfter(deadline: .now() + 180, execute: timeout)
                    listener.start(queue: queue)
                    if Task.isCancelled { cancel() }
                } catch { continuation.resume(throwing: DirectMailError.localCallbackUnavailable) }
            }
        } onCancel: { self.cancel() }
    }

    func callback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completed = lock.withLock { () -> Result<URL, Error>? in
                    if let result { return result }
                    pending = continuation; return nil
                }
                if let completed { continuation.resume(with: completed) }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func receive(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            let combined = collected + (data ?? Data())
            guard combined.count <= 16_384, error == nil else { connection.cancel(); return }
            guard let text = String(data: combined, encoding: .utf8), text.contains("\r\n\r\n") else {
                if !complete { self.receive(connection, collected: combined) } else { connection.cancel() }
                return
            }
            let request = text.components(separatedBy: "\r\n")[0].split(separator: " ")
            let redirect = self.lock.withLock { self.redirect }
            guard request.count == 3, request[0] == "GET", request[1].hasPrefix("/"),
                  let redirect, let origin = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
                  let url = URL(string: "http://\(origin.host!):\(origin.port!)\(request[1])"), url.path == redirect.path else {
                self.respond(connection, status: "404 Not Found", body: "Not found."); return
            }
            self.respond(connection, status: "200 OK", body: L10n.text("Sign-in response received. You can close this page and return to Envl.", language: self.language))
            self.finish(.success(url))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ value: Result<URL, Error>) {
        let callbacks = lock.withLock { () -> (CheckedContinuation<URL, Error>?, CheckedContinuation<URL, Error>?) in
            guard result == nil else { return (nil, nil) }
            result = value
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel(); listener = nil
            timeout?.cancel(); timeout = nil
            let callbacks = (startup, pending); startup = nil; pending = nil; return callbacks
        }
        callbacks.0?.resume(with: value)
        callbacks.1?.resume(with: value)
    }
}
