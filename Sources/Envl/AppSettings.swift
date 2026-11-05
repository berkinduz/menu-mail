import Foundation
import Observation
import ServiceManagement
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }
    var name: String { self == .english ? "English" : "Türkçe" }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum MessageLimit: Int, CaseIterable, Identifiable {
    case ten = 10, twenty = 20, fifty = 50
    var id: Int { rawValue }
}

enum MenuBarIcon: String, CaseIterable, Identifiable {
    case fold = "MenuMailTemplate"
    case envelope = "envelope"
    case filledEnvelope = "envelope.fill"
    case inbox = "tray"
    case paperPlane = "paperplane"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fold: "Fold"
        case .envelope: "Envelope"
        case .filledEnvelope: "Filled envelope"
        case .inbox: "Inbox"
        case .paperPlane: "Paper plane"
        }
    }
}

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case manual = 0, oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .manual: "Manually"
        case .oneMinute: "Every minute"
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    let defaults: UserDefaults

    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: "Language") } }
    var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: "Appearance") } }
    var messageLimit: MessageLimit { didSet { defaults.set(messageLimit.rawValue, forKey: "MessageLimit") } }
    var refreshInterval: RefreshInterval { didSet { defaults.set(refreshInterval.rawValue, forKey: "RefreshInterval") } }
    var compactList: Bool { didSet { defaults.set(compactList, forKey: "CompactList") } }
    var menuBarIcon: MenuBarIcon { didSet { defaults.set(menuBarIcon.rawValue, forKey: "MenuBarIcon") } }
    var showUnreadCount: Bool { didSet { defaults.set(showUnreadCount, forKey: "ShowUnreadCount") } }
    var allowRemoteContent: Bool { didSet { defaults.set(allowRemoteContent, forKey: "AllowRemoteContent") } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: "NotificationsEnabled") } }
    var notificationPreview: Bool { didSet { defaults.set(notificationPreview, forKey: "NotificationPreview") } }
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: "QuietHoursEnabled") } }
    var quietHoursStart: Int { didSet { defaults.set(quietHoursStart, forKey: "QuietHoursStart") } }
    var quietHoursEnd: Int { didSet { defaults.set(quietHoursEnd, forKey: "QuietHoursEnd") } }
    var mutedAccountIDs: Set<String> { didSet { defaults.set(Array(mutedAccountIDs), forKey: "MutedAccountIDs") } }
    var shortcutPreset: GlobalShortcutPreset { didSet { defaults.set(shortcutPreset.rawValue, forKey: "GlobalShortcutPreset") } }
    var checkForUpdatesAutomatically: Bool { didSet { defaults.set(checkForUpdatesAutomatically, forKey: "CheckForUpdatesAutomatically") } }
    private(set) var launchAtLogin = false
    private(set) var loginRequiresApproval = false
    private(set) var loginUpdateFailed = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: "Language") ?? "") ?? .english
        appearance = AppAppearance(rawValue: defaults.string(forKey: "Appearance") ?? "") ?? .system
        messageLimit = MessageLimit(rawValue: defaults.integer(forKey: "MessageLimit")) ?? .twenty
        refreshInterval = RefreshInterval(rawValue: defaults.integer(forKey: "RefreshInterval")) ?? .manual
        compactList = defaults.bool(forKey: "CompactList")
        menuBarIcon = MenuBarIcon(rawValue: defaults.string(forKey: "MenuBarIcon") ?? "") ?? .fold
        showUnreadCount = defaults.object(forKey: "ShowUnreadCount") as? Bool ?? true
        allowRemoteContent = defaults.bool(forKey: "AllowRemoteContent")
        notificationsEnabled = defaults.bool(forKey: "NotificationsEnabled")
        notificationPreview = defaults.object(forKey: "NotificationPreview") as? Bool ?? true
        quietHoursEnabled = defaults.bool(forKey: "QuietHoursEnabled")
        quietHoursStart = defaults.object(forKey: "QuietHoursStart") as? Int ?? 22
        quietHoursEnd = defaults.object(forKey: "QuietHoursEnd") as? Int ?? 8
        mutedAccountIDs = Set(defaults.stringArray(forKey: "MutedAccountIDs") ?? [])
        shortcutPreset = GlobalShortcutPreset(rawValue: defaults.string(forKey: "GlobalShortcutPreset") ?? "") ?? .optionCommandM
        checkForUpdatesAutomatically = defaults.bool(forKey: "CheckForUpdatesAutomatically")
        refreshLoginItemStatus()
    }

    var locale: Locale { Locale(identifier: language.rawValue) }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        L10n.text(key, language: language, arguments: arguments)
    }

    func message(for error: Error) -> String {
        if let error = error as? MailError { return error.message(language: language) }
        if let error = error as? DirectMailError { return error.message(language: language) }
        if error is DecodingError { return text("Could not read the mail response. Please try again.") }
        return text(error.localizedDescription)
    }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginRequiresApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginUpdateFailed = false
        } catch {
            loginUpdateFailed = true
        }
        refreshLoginItemStatus()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum L10n {
    static func text(_ key: String, language: AppLanguage, arguments: [CVarArg] = []) -> String {
        let bundle = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap(Bundle.init(url:))
        let format = bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
}
