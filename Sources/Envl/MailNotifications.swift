import Foundation
import Observation
import UserNotifications

enum MailNotificationPermission: Sendable {
    case notDetermined, denied, authorized
}

struct MailNotificationContent: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
}

@MainActor
protocol MailNotificationDelivering: AnyObject {
    var onOpen: ((String) -> Void)? { get set }
    func authorizationStatus() async -> MailNotificationPermission
    func requestAuthorization() async throws
    func deliver(_ content: MailNotificationContent) async throws
}

enum MailNotificationRules {
    static func isQuietHour(_ hour: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        return start < end ? (start..<end).contains(hour) : hour >= start || hour < end
    }

    static func isEligible(_ message: MailMessage, mutedAccountIDs: Set<String>) -> Bool {
        message.isRead == false && !mutedAccountIDs.contains(message.accountID ?? "")
    }
}

@MainActor
@Observable
final class MailNotifications {
    private let delivery: any MailNotificationDelivering
    private let now: () -> Date
    private var deliveredIDs: Set<String> = []
    private(set) var permissionStatus: MailNotificationPermission = .notDetermined
    private(set) var errorMessage: String?
    var onOpen: ((String) -> Void)?

    var statusTitle: String {
        switch permissionStatus {
        case .notDetermined: "Not requested"
        case .denied: "Disabled in System Settings"
        case .authorized: "Allowed"
        }
    }

    init(delivery: (any MailNotificationDelivering)? = nil, now: @escaping () -> Date = Date.init) {
        let delivery = delivery ?? SystemMailNotificationDelivery()
        self.delivery = delivery
        self.now = now
        delivery.onOpen = { [weak self] in self?.onOpen?($0) }
    }

    func refreshPermission() async {
        permissionStatus = await delivery.authorizationStatus()
    }

    func requestPermission() async {
        errorMessage = nil
        do {
            try await delivery.requestAuthorization()
            await refreshPermission()
        } catch {
            errorMessage = "Unable to request notification permission."
        }
    }

    func send(_ messages: [MailMessage], settings: AppSettings) async {
        guard settings.notificationsEnabled else { return }
        let hour = Calendar.current.component(.hour, from: now())
        guard !settings.quietHoursEnabled || !MailNotificationRules.isQuietHour(hour, start: settings.quietHoursStart, end: settings.quietHoursEnd) else { return }
        await refreshPermission()
        guard permissionStatus == .authorized else { return }
        errorMessage = nil
        // The store supplies fresh arrivals after its per-account synchronization baseline.
        for message in messages where MailNotificationRules.isEligible(message, mutedAccountIDs: settings.mutedAccountIDs) {
            let currentHour = Calendar.current.component(.hour, from: now())
            guard settings.notificationsEnabled,
                  !settings.quietHoursEnabled || !MailNotificationRules.isQuietHour(currentHour, start: settings.quietHoursStart, end: settings.quietHoursEnd) else { return }
            guard deliveredIDs.insert(message.listID).inserted else { continue }
            let content = MailNotificationContent(
                id: message.listID,
                title: settings.notificationPreview ? message.sender(language: settings.language) : settings.text("New mail"),
                body: settings.notificationPreview ? message.title(language: settings.language) : settings.text("Open Envl to read your message.")
            )
            do {
                try await delivery.deliver(content)
            } catch {
                deliveredIDs.remove(message.listID)
                errorMessage = settings.text("Unable to show a notification.")
            }
        }
    }
}

@MainActor
private final class SystemMailNotificationDelivery: NSObject, MailNotificationDelivering, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    var onOpen: ((String) -> Void)?

    override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> MailNotificationPermission {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let status: MailNotificationPermission
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: status = .authorized
                case .denied: status = .denied
                case .notDetermined: status = .notDetermined
                @unknown default: status = .denied
                }
                continuation.resume(returning: status)
            }
        }
    }

    func requestAuthorization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func deliver(_ content: MailNotificationContent) async throws {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        let request = UNNotificationRequest(identifier: content.id, content: notification, trigger: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let identifier = response.notification.request.identifier
        await MainActor.run { self.onOpen?(identifier) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
