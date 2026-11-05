import AppKit
import Network
import Observation
import SwiftUI

@MainActor
final class EnvlDelegate: NSObject, NSApplicationDelegate {
    let store: MailboxStore = {
        let demo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--demo-open")
        let defaults = demo ? UserDefaults(suiteName: "app.menumail.sample-preferences")! : .standard
        return MailboxStore(settings: AppSettings(defaults: defaults))
    }()
    let notifications = MailNotifications()
    let updates = ReleaseChecker()
    let shortcut = GlobalShortcut()
    weak var menuWindow: NSWindow?
    private var quickPanel: NSPanel?
    private var shortcutPreset: GlobalShortcutPreset?
    private var refreshConfiguration: String?
    private var windows: [String: MailMessageWindow] = [:]
    private let network = NWPathMonitor()
    private var wasOffline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--demo-open") { store.startDemo() }
        store.onNewMessages = { [weak self] messages in
            guard let self else { return }
            Task { await self.notifications.send(messages, settings: self.store.settings) }
        }
        store.onShowComposer = { [weak self] in self?.showMenu() }
        notifications.onOpen = { [weak self] identity in
            guard let self else { return }
            self.showMenu()
            if let message = self.store.messages.first(where: { $0.listID == identity }) { self.store.open(message) }
        }
        observePresentation()
        store.start()
        if store.settings.checkForUpdatesAutomatically, !store.isDemo { Task { await updates.check() } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        if !store.isDemo {
            network.pathUpdateHandler = { [weak self] path in
                let connected = path.status == .satisfied
                Task { @MainActor in
                    guard let self else { return }
                    if connected, self.wasOffline { await self.store.refreshInBackground() }
                    self.wasOffline = !connected
                }
            }
            network.start(queue: DispatchQueue(label: "app.menumail.network"))
        }
        if CommandLine.arguments.contains("--demo-open") { showMenu() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenu()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        network.cancel()
        shortcut.unregister()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    func mailboxView(onDismiss: @escaping () -> Void) -> MailboxView {
        MailboxView(store: store, notifications: notifications, updates: updates, shortcut: shortcut,
            onDetach: { [weak self] message in onDismiss(); self?.openWindow(message) }, onDismiss: onDismiss)
    }
    func menuDidOpen() {
        quickPanel?.orderOut(nil)
        store.menuDidOpen()
    }
    private func observePresentation() {
        withObservationTracking {
            updatePresentation()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePresentation() }
        }
    }
    private func updatePresentation() {
        let settings = store.settings
        let contentSize = MailboxView.contentSize(for: store)
        quickPanel?.setContentSize(contentSize)
        if shortcutPreset != settings.shortcutPreset {
            shortcutPreset = settings.shortcutPreset
            shortcut.register(preset: settings.shortcutPreset) { [weak self] in self?.toggleMenu() }
        }
        let configuration = "\(settings.refreshInterval.rawValue):\(settings.notificationsEnabled)"
        if refreshConfiguration != configuration {
            refreshConfiguration = configuration
            store.configureAutoRefresh()
        }
    }
    private func toggleMenu() {
        if let window = menuWindow, window.isVisible { window.close() }
        else if let panel = quickPanel, panel.isVisible { panel.close() }
        else { showMenu() }
    }
    private func showMenu() {
        if let window = menuWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
        } else {
            let panel: NSPanel
            if let existing = quickPanel { panel = existing }
            else {
                panel = NSPanel(contentRect: NSRect(origin: .zero, size: MailboxView.contentSize(for: store)),
                    styleMask: [.titled, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
                panel.title = "Envl"
                panel.titleVisibility = .hidden
                panel.titlebarAppearsTransparent = true
                panel.isReleasedWhenClosed = false
                panel.isRestorable = false
                panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                panel.contentViewController = NSHostingController(rootView: mailboxView { [weak panel] in panel?.close() }
                    .ignoresSafeArea(.container, edges: .top))
                panel.center()
                quickPanel = panel
            }
            panel.setContentSize(MailboxView.contentSize(for: store))
            panel.makeKeyAndOrderFront(nil)
            store.menuDidOpen()
        }
        NSApp.activate()
    }
    @objc private func didWake() { Task { await store.refreshInBackground() } }
    private func openWindow(_ message: MailMessage) {
        if let existing = windows[message.listID] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let window = MailMessageWindow(message: message, store: store)
        window.onClose = { [weak self] in self?.windows[message.listID] = nil }
        windows[message.listID] = window
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

@MainActor
private final class MailMessageWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    init(message: MailMessage, store: MailboxStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = message.title(language: store.settings.language)
        window.isRestorable = false
        window.minSize = NSSize(width: 420, height: 400)
        window.contentView = NSHostingView(rootView: MailReaderView(message: message, store: store, showsStoreErrors: true)
            .environment(\.locale, store.settings.locale).preferredColorScheme(store.settings.appearance.colorScheme))
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
