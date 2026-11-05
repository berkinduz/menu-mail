import Foundation
import Observation

@MainActor
@Observable
final class ReleaseChecker {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport
    private(set) var isChecking = false
    private(set) var latestVersion: String?
    private(set) var downloadURL: URL?
    private(set) var errorMessage: String?

    init(session: URLSession = .shared) {
        transport = { try await session.data(for: $0) }
    }

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        latestVersion = nil
        downloadURL = nil
        defer { isChecking = false }
        do {
            let url = URL(string: "https://api.github.com/repos/berkinduz/menu-mail/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Envl", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await transport(request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw ReleaseError.unavailable
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease else { return }
            guard let version = NumericReleaseVersion(release.tagName) else { throw ReleaseError.invalidVersion }
            latestVersion = version.text
            // Construct the known repository page; API-supplied URLs never become an open target.
            downloadURL = URL(string: "https://github.com/berkinduz/menu-mail/releases/tag/\(release.tagName)")
        } catch {
            errorMessage = "Unable to check for updates. Try again later."
        }
    }

    func availableVersion(current: String) -> String? {
        guard let latestVersion, Self.isNewerVersion(latestVersion, than: current) else { return nil }
        return latestVersion
    }

    nonisolated static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        guard let candidate = NumericReleaseVersion(candidate), let current = NumericReleaseVersion(current) else { return false }
        return current.components.lexicographicallyPrecedes(candidate.components)
    }

    private enum ReleaseError: Error { case unavailable, invalidVersion }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, prerelease }
    }
}

private struct NumericReleaseVersion {
    let text: String
    let components: [Int]

    init?(_ value: String) {
        text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" }
        }) else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        components = values + Array(repeating: 0, count: 3 - values.count)
    }
}
