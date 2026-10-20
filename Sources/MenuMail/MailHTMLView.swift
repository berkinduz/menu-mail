import AppKit
import SwiftUI
import WebKit

struct MailHTMLView: NSViewRepresentable {
    let body: MailMessage.Body

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .textBackgroundColor
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.content != body.content else { return }
        context.coordinator.content = body.content
        let html: String
        if body.contentType.lowercased() == "html" {
            html = body.content
        } else {
            let escaped = body.content.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            html = "<html><head><meta charset=\"utf-8\"></head><body><pre style=\"white-space:pre-wrap;overflow-wrap:anywhere;font:14px -apple-system;padding:16px\">\(escaped)</pre></body></html>"
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var content: String?

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
