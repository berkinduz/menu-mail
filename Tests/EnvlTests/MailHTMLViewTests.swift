import AppKit
import Testing
import WebKit
@testable import Envl

@MainActor
@Suite(.serialized)
struct MailHTMLViewTests {
    @Test func remoteContentIsBlockedUntilAllowedAndCanBeBlockedAgain() async throws {
        _ = NSApplication.shared
        let handler = FixtureImageHandler()
        let configuration = MailHTMLView.webViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "mail-fixture")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        let navigation = NavigationObserver()
        webView.navigationDelegate = navigation
        let coordinator = MailHTMLView.Coordinator()
        defer { coordinator.stop(); webView.stopLoading() }
        let body = MailMessage.Body(contentType: "html", content: """
            <html><body>
            <script>document.body.dataset.scriptRan = 'yes';</script>
            <img id="remote" src="mail-fixture://fixture/pixel.png">
            <img id="inline" src="data:image/png;base64,\(FixtureImageHandler.pixel)">
            </body></html>
            """)

        coordinator.update(body: body, allowRemoteContent: false, in: webView)
        try await waitUntil { navigation.finished == 1 }
        #expect(handler.requests == 0)
        #expect(try await imageWidth("inline", in: webView) == 1)
        #expect(try await imageWidth("remote", in: webView) == 0)
        #expect(try await webView.evaluateJavaScript("document.body.dataset.scriptRan || ''") as? String == "")
        #expect(!webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)

        // The exact same HTML must reload when the user's policy changes.
        coordinator.update(body: body, allowRemoteContent: true, in: webView)
        try await waitUntil { navigation.finished == 2 }
        #expect(handler.requests == 1)
        #expect(try await imageWidth("remote", in: webView) == 1)

        coordinator.update(body: body, allowRemoteContent: false, in: webView)
        try await waitUntil { navigation.finished == 3 }
        #expect(handler.requests == 1)
        #expect(try await imageWidth("inline", in: webView) == 1)
        #expect(try await imageWidth("remote", in: webView) == 0)
    }

    @Test func changingContentTypeReloadsTheSameContentAsPlainText() async throws {
        _ = NSApplication.shared
        let webView = WKWebView(frame: .zero, configuration: MailHTMLView.webViewConfiguration())
        let navigation = NavigationObserver()
        webView.navigationDelegate = navigation
        let coordinator = MailHTMLView.Coordinator()
        defer { coordinator.stop(); webView.stopLoading() }
        coordinator.update(body: .init(contentType: "html", content: "<b>Example</b>"), allowRemoteContent: false, in: webView)
        try await waitUntil { navigation.finished == 1 }
        #expect(try await webView.evaluateJavaScript("document.body.textContent") as? String == "Example")
        coordinator.update(body: .init(contentType: "text", content: "<b>Example</b>"), allowRemoteContent: false, in: webView)
        try await waitUntil { navigation.finished == 2 }
        #expect(try await webView.evaluateJavaScript("document.body.textContent") as? String == "<b>Example</b>")
    }

    private func imageWidth(_ id: String, in webView: WKWebView) async throws -> Int {
        try await webView.evaluateJavaScript("document.getElementById('\(id)').naturalWidth") as? Int ?? -1
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            guard clock.now < deadline else { throw FixtureError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum FixtureError: Error { case timeout }

    private final class NavigationObserver: NSObject, WKNavigationDelegate {
        var finished = 0
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished += 1 }
    }

    private final class FixtureImageHandler: NSObject, WKURLSchemeHandler {
        static let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK1cAAAAASUVORK5CYII="
        var requests = 0

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            requests += 1
            let data = Data(base64Encoded: Self.pixel)!
            urlSchemeTask.didReceive(URLResponse(url: urlSchemeTask.request.url!, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }
}
