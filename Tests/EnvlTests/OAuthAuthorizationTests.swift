import Foundation
import Testing
@testable import Envl

private actor OAuthFixtureBrowser: MailOAuthBrowser {
    let wrongState: Bool
    private(set) var verifier: String?
    init(wrongState: Bool = false) { self.wrongState = wrongState }
    func authorize(configuration: OAuthConfiguration, state: String, verifier: String) async throws -> OAuthBrowserResponse {
        self.verifier = verifier
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        _ = try configuration.authorizationURL(redirect: redirect, state: state, verifier: verifier)
        var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "state", value: wrongState ? "different-state" : state), .init(name: "code", value: "synthetic-authorization-code")]
        return .init(redirect: redirect, callback: callback.url!)
    }
}

@Suite struct OAuthAuthorizationTests {
    @Test func pkceUsesTheRFC7636S256Vector() throws {
        #expect(OAuthPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = try OAuthPKCE.randomValue()
        #expect(verifier.count >= 43 && verifier.count <= 128)
        #expect(verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) })
    }

    @Test func callbackRequiresTheExactRedirectAndState() throws {
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        #expect(try OAuthCallback.code(from: URL(string: "http://127.0.0.1:54321/oauth/callback?state=expected&code=fixture-code")!,
            redirect: redirect, state: "expected") == "fixture-code")
        for value in [
            "http://127.0.0.1:54321/oauth/callback?state=wrong&code=fixture-code",
            "http://127.0.0.1:54322/oauth/callback?state=expected&code=fixture-code",
            "http://127.0.0.1:54321/other?state=expected&code=fixture-code",
            "http://127.0.0.1:54321/oauth/callback?state=expected&state=wrong&code=fixture-code",
            "http://127.0.0.1:54321/oauth/callback?state=expected"
        ] {
            #expect(throws: DirectMailError.self) {
                try OAuthCallback.code(from: URL(string: value)!, redirect: redirect, state: "expected")
            }
        }
    }

    @Test func publicClientAuthorizationUsesPKCEAndProviderScopes() throws {
        let config = OAuthConfiguration(provider: .outlook, clientID: "fixture-public-client-id")
        let redirect = URL(string: "http://localhost:54321/oauth/callback")!
        let url = try config.authorizationURL(redirect: redirect, state: "fixture-state", verifier: "fixture-verifier")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "login.microsoftonline.com")
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["response_type"] == "code")
        #expect(values["scope"]?.contains("offline_access") == true)
        #expect(values["scope"]?.contains("Mail.ReadWrite") == true)
        #expect(values["scope"]?.contains("Mail.Send") == true)
        #expect(values["client_secret"] == nil)
        #expect(throws: DirectMailError.self) {
            try OAuthConfiguration(provider: .gmail, clientID: "").authorizationURL(redirect: redirect, state: "s", verifier: "v")
        }
    }

    @Test func refreshKeepsTheExistingRefreshTokenWhenProviderDoesNotRotateIt() async throws {
        let http = DirectFixtureHTTP([.json(#"{"access_token":"synthetic-new-access","expires_in":3600,"token_type":"Bearer"}"#)])
        let oauth = OAuthAuthorization(transport: http)
        let value = try await oauth.refresh(.init(accessToken: "synthetic-old-access", refreshToken: "synthetic-refresh", expiresAt: .distantPast),
            configuration: .init(provider: .gmail, clientID: "fixture-public-client-id"))
        #expect(value.refreshToken == "synthetic-refresh")
        #expect(value.expiresAt > Date())
        let request = try #require(await http.requests.first)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(String(data: request.httpBody!, encoding: .utf8)?.contains("grant_type=refresh_token") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func initialAuthorizationExchangesTheCodeWithTheSamePKCEVerifierAndRedirect() async throws {
        let browser = OAuthFixtureBrowser()
        let http = DirectFixtureHTTP([.json(#"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600}"#)])
        let oauth = OAuthAuthorization(transport: http, browser: browser)
        _ = try await oauth.authorize(configuration: .init(provider: .gmail, clientID: "fixture-public-client-id"))
        let request = try #require(await http.requests.first)
        let form = try #require(String(data: request.httpBody!, encoding: .utf8))
        #expect(form.contains("grant_type=authorization_code"))
        #expect(form.contains("code=synthetic-authorization-code"))
        #expect(form.contains("code_verifier=\(try #require(await browser.verifier))"))
        #expect(form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Foauth%2Fcallback"))
        #expect(!form.contains("client_secret"))
    }

    @Test func anInvalidInitialCallbackNeverReachesTheTokenEndpoint() async throws {
        let http = DirectFixtureHTTP()
        let oauth = OAuthAuthorization(transport: http, browser: OAuthFixtureBrowser(wrongState: true))
        await #expect(throws: DirectMailError.self) {
            try await oauth.authorize(configuration: .init(provider: .gmail, clientID: "fixture-public-client-id"))
        }
        #expect(await http.requests.isEmpty)
    }
}
