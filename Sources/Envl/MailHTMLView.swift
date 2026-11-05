import AppKit
import SwiftUI
import WebKit

struct MailHTMLView: NSViewRepresentable {
    let body: MailMessage.Body
    let allowRemoteContent: Bool
    let language: AppLanguage

    init(body: MailMessage.Body, allowRemoteContent: Bool = false, language: AppLanguage = .english) {
        self.body = body
        self.allowRemoteContent = allowRemoteContent
        self.language = language
    }

    static func webViewConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        return configuration
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: Self.webViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.pageZoom = 1.1
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(body: body, allowRemoteContent: allowRemoteContent, language: language, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private struct RenderedContent: Equatable {
            let isHTML: Bool
            let content: String
            let allowRemoteContent: Bool
            let language: AppLanguage
        }

        private var renderedContent: RenderedContent?
        private var renderTask: Task<Void, Never>?

        // Compile once, and install before any message HTML reaches WebKit.
        private static let blockingRules: Task<WKContentRuleList, Error> = Task { @MainActor in
            let json = """
                [
                  {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
                  {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
                  {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}
                ]
                """
            guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "MenuMail.BlockRemoteContent.v1", encodedContentRuleList: json) else {
                throw MailError.message("Could not prepare remote content blocking.")
            }
            return rules
        }

        func update(body: MailMessage.Body, allowRemoteContent: Bool, language: AppLanguage = .english, in webView: WKWebView) {
            let next = RenderedContent(isHTML: body.contentType.lowercased() == "html", content: body.content,
                allowRemoteContent: allowRemoteContent, language: language)
            guard renderedContent != next else { return }
            renderedContent = next
            renderTask?.cancel()
            webView.stopLoading()
            renderTask = Task { [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    let rules = allowRemoteContent ? nil : try await Self.blockingRules.value
                    try Task.checkCancellation()
                    let controller = webView.configuration.userContentController
                    controller.removeAllContentRuleLists()
                    if let rules { controller.add(rules) }
                    webView.loadHTMLString(Self.html(for: next), baseURL: nil)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    // A rule-compilation failure must never load unprotected message HTML.
                    self.renderedContent = nil
                    let message = L10n.text("Could not prepare remote content blocking. Reopen the message or use your mail app.", language: language)
                    webView.loadHTMLString("<html><body><p>\(message)</p></body></html>", baseURL: nil)
                }
            }
        }

        func stop() {
            renderTask?.cancel()
            renderTask = nil
            renderedContent = nil
        }

        private static func html(for body: RenderedContent) -> String {
            if body.isHTML { return body.content }
            let escaped = body.content.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            return "<html><head><meta charset=\"utf-8\"></head><body><pre style=\"white-space:pre-wrap;overflow-wrap:anywhere;font:16px -apple-system;padding:16px\">\(escaped)</pre></body></html>"
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else if navigationAction.request.url?.scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
