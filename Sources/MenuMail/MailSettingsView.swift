import AppKit
import SwiftUI

struct MailSettingsView: View {
    @Bindable var store: MailboxStore
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section(settings.text("Language")) {
                Picker(settings.text("App language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.name).tag(language)
                    }
                }
            }

            Section(settings.text("Mailbox")) {
                if let account = store.accountName, let mailbox = store.connectedMailbox {
                    LabeledContent(settings.text("Account"), value: account)
                    LabeledContent(settings.text("Mailbox"), value: mailbox)
                } else {
                    Text(settings.text(store.isDemo ? "Using sample data" : "No mailbox connected"))
                        .foregroundStyle(.secondary)
                }
                Button(settings.text(store.isConnected ? "Change mailbox…" : "Choose mailbox…")) {
                    store.showAccountSetup()
                }
                .disabled(store.isBusy)
            }

            Section(settings.text("Reading")) {
                Picker(settings.text("Recent messages"), selection: $settings.messageLimit) {
                    ForEach(MessageLimit.allCases) { limit in
                        Text(settings.text("%d messages", limit.rawValue)).tag(limit)
                    }
                }
                Picker(settings.text("Auto refresh"), selection: $settings.refreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(settings.text(interval.title)).tag(interval)
                    }
                }
                Text(settings.text("The message limit applies on the next refresh. Auto refresh pauses while reading or in Settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(settings.text("Appearance")) {
                Picker(settings.text("Menu bar icon"), selection: $settings.menuBarIcon) {
                    ForEach(MenuBarIcon.allCases) { icon in
                        Label(settings.text(icon.title), systemImage: icon.rawValue).tag(icon)
                    }
                }
                Picker(settings.text("Theme"), selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(settings.text(appearance.title)).tag(appearance)
                    }
                }
                Toggle(settings.text("Compact message list"), isOn: $settings.compactList)
            }

            Section(settings.text("Startup")) {
                Toggle(settings.text("Launch at login"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                Text(settings.text("Keep MenuMail in Applications before enabling this option."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.loginRequiresApproval || settings.loginUpdateFailed {
                    Text(settings.text(settings.loginRequiresApproval
                        ? "Allow MenuMail in Login Items to finish enabling startup."
                        : "Could not update startup. Check Login Items in System Settings."))
                        .font(.caption)
                        .foregroundStyle(settings.loginUpdateFailed ? .red : .secondary)
                    Button(settings.text("Open Login Items")) { settings.openLoginItems() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { settings.refreshLoginItemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refreshLoginItemStatus()
        }
    }
}
