import Foundation
import Testing
@testable import Envl

@MainActor
private final class NotificationDeliveryFixture: MailNotificationDelivering {
    var permissionStatus: MailNotificationPermission = .authorized
    var permissionRequests = 0
    var delivered: [MailNotificationContent] = []
    var onOpen: ((String) -> Void)?
    var failsDelivery = false
    var onAuthorizationStatus: (() -> Void)?

    func authorizationStatus() async -> MailNotificationPermission {
        onAuthorizationStatus?()
        return permissionStatus
    }
    func requestAuthorization() async throws {
        permissionRequests += 1
        permissionStatus = .authorized
    }
    func deliver(_ content: MailNotificationContent) async throws {
        if failsDelivery { throw NotificationFailure.synthetic }
        delivered.append(content)
        await Task.yield()
    }
    private enum NotificationFailure: Error { case synthetic }
}

@MainActor
struct MailNotificationsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(id: String = "one", account: String = "first", isRead: Bool? = false) -> MailMessage {
        .init(id: id, subject: "Example private subject",
              from: .init(emailAddress: .init(name: "Example Sender", address: "sender@example.com")),
              receivedDateTime: ISO8601DateFormatter().string(from: now),
              body: nil, accountID: account, provider: .gmail, isRead: isRead)
    }

    @MainActor
    private struct SettingsFixture {
        let domain = "MailNotificationsTests.\(UUID().uuidString)"
        let settings: AppSettings
        init() {
            settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
            settings.notificationsEnabled = true
            settings.notificationPreview = false
            settings.quietHoursEnabled = false
            settings.mutedAccountIDs = []
        }
        func cleanup() { settings.defaults.removePersistentDomain(forName: domain) }
    }

    @Test func quietHoursHandleOvernightAndBoundaryHours() {
        #expect(MailNotificationRules.isQuietHour(22, start: 22, end: 8))
        #expect(MailNotificationRules.isQuietHour(2, start: 22, end: 8))
        #expect(!MailNotificationRules.isQuietHour(8, start: 22, end: 8))
        #expect(!MailNotificationRules.isQuietHour(12, start: 22, end: 8))
        #expect(MailNotificationRules.isQuietHour(10, start: 9, end: 17))
        #expect(!MailNotificationRules.isQuietHour(17, start: 9, end: 17))
        #expect(!MailNotificationRules.isQuietHour(12, start: 12, end: 12))
    }

    @Test func eligibilityRequiresUnreadStateAndHonorsTheAccountMute() {
        #expect(MailNotificationRules.isEligible(message(), mutedAccountIDs: []))
        #expect(!MailNotificationRules.isEligible(message(isRead: true), mutedAccountIDs: []))
        #expect(!MailNotificationRules.isEligible(message(isRead: nil), mutedAccountIDs: []))
        #expect(!MailNotificationRules.isEligible(message(), mutedAccountIDs: ["first"]))
        #expect(MailNotificationRules.isEligible(message(account: "second"), mutedAccountIDs: ["first"]))
    }

    @Test func deliveryDeduplicatesScopedIdentitiesAndKeepsPreviewPrivate() async {
        let delivery = NotificationDeliveryFixture()
        let notifications = MailNotifications(delivery: delivery, now: { now })
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        await notifications.send([message(), message(), message(account: "second")], settings: settings)
        await notifications.send([message()], settings: settings)
        #expect(delivery.delivered.map(\.id) == ["first:one", "second:one"])
        #expect(delivery.permissionRequests == 0)
        #expect(!delivery.delivered[0].body.contains("Example private subject"))
        #expect(!delivery.delivered[0].title.contains("Example Sender"))

        settings.notificationPreview = true
        await notifications.send([message(id: "two")], settings: settings)
        #expect(delivery.delivered.last?.body == "Example private subject")
        #expect(delivery.delivered.last?.title == "Example Sender")
    }

    @Test func permissionsAreRequestedOnlyByAnExplicitRequest() async {
        let delivery = NotificationDeliveryFixture()
        delivery.permissionStatus = .notDetermined
        let notifications = MailNotifications(delivery: delivery, now: { now })
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        await notifications.send([message()], settings: fixture.settings)
        #expect(delivery.delivered.isEmpty)
        #expect(delivery.permissionRequests == 0)
        #expect(notifications.permissionStatus == .notDetermined)
        await notifications.requestPermission()
        #expect(delivery.permissionRequests == 1)
        #expect(notifications.permissionStatus == .authorized)
    }

    @Test func disabledMutedAndQuietHourSettingsSuppressDelivery() async {
        let delivery = NotificationDeliveryFixture()
        let notifications = MailNotifications(delivery: delivery, now: { now })
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        settings.notificationsEnabled = false
        await notifications.send([message()], settings: settings)
        settings.notificationsEnabled = true
        settings.mutedAccountIDs = ["first"]
        await notifications.send([message()], settings: settings)
        settings.mutedAccountIDs = []
        settings.quietHoursEnabled = true
        let hour = Calendar.current.component(.hour, from: now)
        settings.quietHoursStart = hour
        settings.quietHoursEnd = (hour + 1) % 24
        await notifications.send([message()], settings: settings)
        #expect(delivery.delivered.isEmpty)
    }

    @Test func openCallbackRetainsTheAccountScopedMessageIdentifier() {
        let delivery = NotificationDeliveryFixture()
        let notifications = MailNotifications(delivery: delivery, now: { now })
        var opened: String?
        notifications.onOpen = { opened = $0 }
        delivery.onOpen?("second:one")
        #expect(opened == "second:one")
    }

    @Test func disablingNotificationsDuringPermissionLookupSuppressesDelivery() async {
        let delivery = NotificationDeliveryFixture()
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        delivery.onAuthorizationStatus = { fixture.settings.notificationsEnabled = false }
        let notifications = MailNotifications(delivery: delivery, now: { now })
        await notifications.send([message()], settings: fixture.settings)
        #expect(delivery.delivered.isEmpty)
    }

    @Test func failedDeliveryCanRetryWithoutBeingMarkedAsDelivered() async {
        let delivery = NotificationDeliveryFixture()
        delivery.failsDelivery = true
        let notifications = MailNotifications(delivery: delivery, now: { now })
        let fixture = SettingsFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        await notifications.send([message()], settings: settings)
        #expect(notifications.errorMessage != nil)
        delivery.failsDelivery = false
        await notifications.send([message()], settings: settings)
        #expect(delivery.delivered.count == 1)
        #expect(notifications.errorMessage == nil)
    }
}
