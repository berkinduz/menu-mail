import Foundation
import Testing
@testable import Envl

struct AppleMailPageTests {
    @Test func bridgeMetadataKeepsServerUnreadCountAndMessagePositions() throws {
        let json = #"{"messages":[{"id":"20","sourceIndex":50,"subject":"Older mail","sender":"Example <person@example.com>","receivedDateTime":"2026-11-04T09:00:00Z","isRead":false,"isStarred":true}],"nextPageToken":"100","unreadCount":340}"#
        let page = try AppleMailClient.decodeInbox(Data(json.utf8))
        #expect(page.unreadCount == 340)
        #expect(page.nextPageToken == "100")
        let message = try #require(page.messages.first)
        #expect(message.sourceIndex == 50)
        #expect(message.isRead == false)
        #expect(message.isStarred == true)
        #expect(message.from?.emailAddress.address == "person@example.com")
    }
}
