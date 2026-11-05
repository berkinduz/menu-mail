import AppKit
import SwiftUI

struct MailSettingsView: View {
    @Bindable var store: MailboxStore
    @Bindable var settings: AppSettings
    @Bindable var notifications: MailNotifications
    @Bindable var updates: ReleaseChecker
    @Bindable var shortcut: GlobalShortcut
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                accountSettings
                generalSettings
                readingSettings
                appearanceSettings
                notificationSettings
                updateSettings
                SettingsGroup(title: settings.text("About"), symbol: "info.circle") {
                    AboutSection(settings: settings).padding(16)
                }
            }
            .padding(18)
        }
        .font(.system(size: 14))
        .controlSize(.regular)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { settings.refreshLoginItemStatus(); await notifications.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLoginItemStatus()
            Task { await notifications.refreshPermission() }
        }
    }

    private var accountSettings: some View {
        SettingsGroup(title: settings.text("Accounts"), symbol: "person.crop.circle") {
            Button { store.showAccountSetup() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "envelope.open")
                        .font(.system(size: 19)).foregroundStyle(.tint).frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.connections.count == 1 ? store.connections[0].account.name
                            : settings.text("%d connected accounts", store.connections.count))
                            .font(.system(size: 14, weight: .medium))
                        Text(settings.text("Manage accounts…"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle()).padding(14)
            }
            .buttonStyle(.plain)
        }
    }

    private var generalSettings: some View {
        SettingsGroup(title: settings.text("General"), symbol: "slider.horizontal.3") {
            settingRow(settings.text("App language")) {
                Picker(settings.text("App language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                }.labelsHidden().frame(width: 160, alignment: .trailing)
            }
            rowDivider
            settingRow(settings.text("Open Envl")) {
                Picker(settings.text("Open Envl"), selection: $settings.shortcutPreset) {
                    ForEach(GlobalShortcutPreset.allCases) { Text(settings.text($0.title)).tag($0) }
                }.labelsHidden().frame(width: 160, alignment: .trailing)
            }
            .help(settings.text("Use the arrow keys to browse messages, Return to open, and Escape to go back."))
            if shortcut.registrationFailed {
                note("This shortcut is unavailable. Choose another shortcut.", isError: true)
            }
            rowDivider
            toggleRow("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
            if settings.loginRequiresApproval || settings.loginUpdateFailed {
                note(settings.loginRequiresApproval ? "Allow Envl in Login Items to finish enabling startup."
                    : "Could not update startup. Check Login Items in System Settings.", isError: true)
                Button(settings.text("Open Login Items")) { settings.openLoginItems() }
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }

    private var readingSettings: some View {
        SettingsGroup(title: settings.text("Reading"), symbol: "text.alignleft") {
            settingRow(settings.text("Messages per load")) {
                Picker(settings.text("Messages per load"), selection: $settings.messageLimit) {
                    ForEach(MessageLimit.allCases) { Text(settings.text("%d messages", $0.rawValue)).tag($0) }
                }.labelsHidden().frame(width: 160, alignment: .trailing)
            }
            rowDivider
            settingRow(settings.text("Auto refresh")) {
                Picker(settings.text("Auto refresh"), selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { Text(settings.text($0.title)).tag($0) }
                }.labelsHidden().frame(width: 160, alignment: .trailing)
            }
            .help(settings.text("Apple Mail refresh pauses while reading. Direct accounts continue checking in the background."))
            rowDivider
            toggleRow("Compact message list", isOn: $settings.compactList)
            rowDivider
            toggleRow("Load remote images and content", isOn: $settings.allowRemoteContent)
            note("Remote content can contact the sender's servers. Inline attachments remain visible.")
        }
    }

    private var appearanceSettings: some View {
        SettingsGroup(title: settings.text("Appearance"), symbol: "paintpalette") {
            settingRow(settings.text("Menu bar icon")) {
                Picker(settings.text("Menu bar icon"), selection: $settings.menuBarIcon) {
                    ForEach(MenuBarIcon.allCases) { Text(settings.text($0.title)).tag($0) }
                }.labelsHidden().frame(width: 160, alignment: .trailing)
            }
            rowDivider
            toggleRow("Show unread count", isOn: $settings.showUnreadCount)
            rowDivider
            settingRow(settings.text("Theme")) {
                Picker(settings.text("Theme"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text(settings.text($0.title)).tag($0) }
                }.labelsHidden().frame(width: 160, alignment: .trailing)
            }
        }
    }

    private var notificationSettings: some View {
        SettingsGroup(title: settings.text("Notifications"), symbol: "bell") {
            toggleRow("New mail notifications", isOn: $settings.notificationsEnabled)
                .onChange(of: settings.notificationsEnabled) {
                    if settings.notificationsEnabled { Task { await notifications.requestPermission() } }
                }
            rowDivider
            settingRow(settings.text("Permission")) {
                Text(settings.text(notifications.statusTitle)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if notifications.permissionStatus == .denied {
                Button(settings.text("Open notification settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(url) }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
            if settings.notificationsEnabled {
                rowDivider
                toggleRow("Show sender and subject", isOn: $settings.notificationPreview)
                rowDivider
                toggleRow("Quiet hours", isOn: $settings.quietHoursEnabled)
                if settings.quietHoursEnabled {
                    rowDivider
                    settingRow(settings.text("Start hour")) {
                        Picker(settings.text("Start hour"), selection: $settings.quietHoursStart) {
                            ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }.labelsHidden().frame(width: 160, alignment: .trailing)
                    }
                    rowDivider
                    settingRow(settings.text("Until")) {
                        Picker(settings.text("Until"), selection: $settings.quietHoursEnd) {
                            ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }.labelsHidden().frame(width: 160, alignment: .trailing)
                    }
                }
                ForEach(store.connections) { connection in
                    rowDivider
                    settingRow(connection.account.name) {
                        Toggle(connection.account.name, isOn: Binding(
                            get: { !settings.mutedAccountIDs.contains(connection.id) },
                            set: { enabled in
                                if enabled { settings.mutedAccountIDs.remove(connection.id) }
                                else { settings.mutedAccountIDs.insert(connection.id) }
                            })).labelsHidden().toggleStyle(.switch)
                    }
                }
                note("Notifications check every minute when automatic refresh is off.")
            }
            if let error = notifications.errorMessage { note(error, isError: true) }
        }
    }

    private var updateSettings: some View {
        SettingsGroup(title: settings.text("Updates"), symbol: "arrow.down.circle") {
            toggleRow("Check for updates at launch", isOn: $settings.checkForUpdatesAutomatically)
                .onChange(of: settings.checkForUpdatesAutomatically) {
                    if settings.checkForUpdatesAutomatically { Task { await updates.check() } }
                }
            rowDivider
            HStack {
                Text(settings.text("Version %@", version)).foregroundStyle(.secondary)
                Spacer()
                Button(settings.text(updates.isChecking ? "Checking for updates…" : "Check for updates")) {
                    Task { await updates.check() }
                }
                .disabled(updates.isChecking)
            }.font(.system(size: 13)).padding(14)
            if let newVersion = updates.availableVersion(current: version), let url = updates.downloadURL {
                Link(settings.text("Download version %@", newVersion), destination: url)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            } else if updates.latestVersion != nil {
                note("You are up to date.")
            }
            if let error = updates.errorMessage { note(error, isError: true) }
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(.primary.opacity(0.18)).frame(height: 1).padding(.horizontal, 14)
    }

    private func settingRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            control().frame(width: 160, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 26)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        settingRow(settings.text(title)) {
            Toggle(settings.text(title), isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    private func note(_ text: String, isError: Bool = false) -> some View {
        Text(settings.text(text)).font(.system(size: 12.5)).foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.bottom, 12)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.10), lineWidth: 1) }
        }
    }
}
