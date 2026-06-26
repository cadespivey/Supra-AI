import Foundation
import SupraCore
import SupraRuntimeClient
import SupraStore
@testable import SupraSessions
import XCTest

@MainActor
final class TagSearchTests: XCTestCase {

    private func stub() -> StubRuntimeClient { StubRuntimeClient { _ in .events([]) } }

    func testGlobalTagSearchSpansChatsAndNotesAcrossMatters() async throws {
        let store = try SupraStore.inMemory()
        let matter = try store.matters.createMatter(name: "Smith v. Acme")
        let globalChat = try store.chats.createGlobalChat(title: "Discovery strategy")
        _ = try store.chats.appendUserMessage(chatID: globalChat.id, content: "move fast #urgent here")
        let matterChat = try store.chats.createMatterChat(matterID: matter.id, title: "Motion timing")
        _ = try store.chats.appendUserMessage(chatID: matterChat.id, content: "deadline #urgent next week")
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-14")
        try store.scratchPad.addEntry(dayID: day.id, text: "Call client #urgent for @Acme", mentions: [matter.id], tags: ["urgent"])
        // A near-miss tag that must NOT match the exact #urgent.
        try store.scratchPad.addEntry(dayID: day.id, text: "Long-term #urgentish planning", mentions: [matter.id], tags: ["urgentish"])

        let controller = GlobalChatController(store: store, runtimeClient: stub(), scope: .global)
        controller.loadChats()
        let hits = controller.tagSearch(term: "#urgent")

        // The global chat is openable in this (global) scope.
        XCTAssertTrue(hits.contains { $0.kind == .chat && $0.openableChatID == globalChat.id })
        // The matter chat surfaces cross-matter as discovery (not openable here).
        XCTAssertTrue(hits.contains { $0.kind == .chat && $0.openableChatID == nil && $0.group == "Smith v. Acme" })
        // The #urgent note is found; the #urgentish note is NOT (exact-tag match).
        XCTAssertEqual(hits.filter { $0.kind == .note }.count, 1, "#urgentish must not match the exact #urgent tag")
        XCTAssertTrue(hits.contains { $0.kind == .note && $0.title.contains("2026-06-14") && $0.group == "Smith v. Acme" })
    }

    func testMatterScopedTagSearchIsBoundedToThatMatter() async throws {
        let store = try SupraStore.inMemory()
        let acme = try store.matters.createMatter(name: "Smith v. Acme")
        let other = try store.matters.createMatter(name: "Doe v. Roe")
        let acmeChat = try store.chats.createMatterChat(matterID: acme.id, title: "Acme chat")
        _ = try store.chats.appendUserMessage(chatID: acmeChat.id, content: "#urgent acme")
        let otherChat = try store.chats.createMatterChat(matterID: other.id, title: "Other chat")
        _ = try store.chats.appendUserMessage(chatID: otherChat.id, content: "#urgent other")
        let globalChat = try store.chats.createGlobalChat(title: "Global chat")
        _ = try store.chats.appendUserMessage(chatID: globalChat.id, content: "#urgent global")
        let day = try store.scratchPad.fetchOrCreateDay("2026-06-14")
        try store.scratchPad.addEntry(dayID: day.id, text: "#urgent for @Acme", mentions: [acme.id], tags: ["urgent"])
        try store.scratchPad.addEntry(dayID: day.id, text: "#urgent for @Doe", mentions: [other.id], tags: ["urgent"])

        let controller = GlobalChatController(store: store, runtimeClient: stub(), scope: .matter(id: acme.id))
        controller.loadChats()
        let hits = controller.tagSearch(term: "#urgent")

        // Only Acme's chat and Acme's note — not the other matter's, not the global chat.
        XCTAssertTrue(hits.contains { $0.kind == .chat && $0.openableChatID == acmeChat.id })
        XCTAssertFalse(hits.contains { $0.openableChatID == otherChat.id || $0.openableChatID == globalChat.id })
        XCTAssertEqual(hits.filter { $0.kind == .note }.count, 1, "only the in-matter note")
        XCTAssertFalse(hits.contains { $0.title.contains("Doe") })
    }

    func testFreeTextSearchMatchesMessageContent() async throws {
        let store = try SupraStore.inMemory()
        let chat = try store.chats.createGlobalChat(title: "Untitled")
        _ = try store.chats.appendUserMessage(chatID: chat.id, content: "Discuss the proportionality objection under Rule 26")
        let controller = GlobalChatController(store: store, runtimeClient: stub(), scope: .global)
        controller.loadChats()
        // A non-tag term still matches message bodies (title is "Untitled").
        let hits = controller.tagSearch(term: "proportionality")
        XCTAssertTrue(hits.contains { $0.kind == .chat && $0.openableChatID == chat.id })
    }
}
