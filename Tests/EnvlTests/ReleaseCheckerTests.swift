import Foundation
import Testing
@testable import Envl

@MainActor
struct ReleaseCheckerTests {
    @Test func comparesNumericVersionComponentsWithoutLexicalOrdering() {
        #expect(ReleaseChecker.isNewerVersion("v1.10.0", than: "1.9.9"))
        #expect(ReleaseChecker.isNewerVersion("0.2.0", than: "v0.1.0"))
        #expect(!ReleaseChecker.isNewerVersion("1.0", than: "1.0.0"))
        #expect(!ReleaseChecker.isNewerVersion("1.0.0", than: "2.0.0"))
        #expect(!ReleaseChecker.isNewerVersion("1.0.0-beta", than: "0.1.0"))
        #expect(!ReleaseChecker.isNewerVersion("latest", than: "0.1.0"))
        #expect(!ReleaseChecker.isNewerVersion("2.0.0", than: "unknown"))
    }

    private func checker(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false, status: Int = 200) throws -> ReleaseChecker {
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "html_url": "https://untrusted.example/download",
        ])
        return ReleaseChecker(transport: { request in
            #expect(request.url?.absoluteString == "https://api.github.com/repos/berkinduz/menu-mail/releases/latest")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        })
    }

    @Test func usesOnlyTheExpectedPublicReleasePageForDownloads() async throws {
        let checker = try checker()
        await checker.check()
        #expect(!checker.isChecking)
        #expect(checker.latestVersion == "0.2.0")
        #expect(checker.availableVersion(current: "0.1.0") == "0.2.0")
        #expect(checker.availableVersion(current: "0.2.0") == nil)
        #expect(checker.downloadURL?.absoluteString == "https://github.com/berkinduz/menu-mail/releases/tag/v0.2.0")
        #expect(checker.errorMessage == nil)
    }

    @Test func draftAndPrereleaseResponsesNeverOfferAnUpdate() async throws {
        let draft = try checker(draft: true)
        await draft.check()
        #expect(draft.latestVersion == nil)
        #expect(draft.downloadURL == nil)
        let prerelease = try checker(prerelease: true)
        await prerelease.check()
        #expect(prerelease.latestVersion == nil)
        #expect(prerelease.downloadURL == nil)
    }

    @Test func invalidTagsAndHTTPFailuresProduceAnErrorWithoutAnUpdateURL() async throws {
        let invalid = try checker(tag: "v0.2.0/../../elsewhere")
        await invalid.check()
        #expect(invalid.errorMessage != nil)
        #expect(invalid.downloadURL == nil)
        let failure = try checker(status: 403)
        await failure.check()
        #expect(failure.errorMessage != nil)
        #expect(failure.latestVersion == nil)
    }
}
