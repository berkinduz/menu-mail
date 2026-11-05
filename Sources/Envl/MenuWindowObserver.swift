import AppKit
import SwiftUI

/// MenuBarExtra can keep its content alive between openings; observe its actual window.
struct MenuWindowObserver: NSViewRepresentable {
    let onOpen: @MainActor () -> Void
    var onWindowChange: (@MainActor (NSWindow?) -> Void)? = nil

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onOpen = onOpen
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onOpen = onOpen
        nsView.onWindowChange = onWindowChange
    }

    final class ObserverView: NSView {
        var onOpen: (@MainActor () -> Void)?
        var onWindowChange: (@MainActor (NSWindow?) -> Void)?
        private var wasVisible = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            wasVisible = false
            onWindowChange?(window)
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowStateChanged),
                    name: name, object: window)
            }
            reportVisibility()
        }

        @objc private func windowStateChanged(_ notification: Notification) {
            reportVisibility()
        }

        private func reportVisibility() {
            let visible = window?.isVisible ?? false
            guard visible != wasVisible else { return }
            wasVisible = visible
            if visible { Task { @MainActor [weak self] in self?.onOpen?() } }
        }
    }
}
