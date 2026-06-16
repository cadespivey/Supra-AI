import Combine
import Foundation
import SupraRuntimeClient
import SupraStore

/// A view-facing snapshot of a matter (a folder that groups chats).
public struct MatterSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var updatedAt: Date

    public init(id: String, name: String, updatedAt: Date) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
    }

    init(record: MatterRecord) {
        self.init(id: record.id, name: record.name, updatedAt: record.updatedAt)
    }
}

/// Manages the list of matters and, for the selected matter, vends a
/// matter-scoped `GlobalChatController` so the same chat UI works inside a matter.
@MainActor
public final class MattersController: ObservableObject {
    @Published public private(set) var matters: [MatterSummary] = []
    @Published public private(set) var selectedMatterID: String?
    @Published public private(set) var chatController: GlobalChatController?

    private let store: SupraStore
    private let runtimeClient: any RuntimeClientProtocol
    private let defaultSystemPrompt: String?

    public init(
        store: SupraStore,
        runtimeClient: any RuntimeClientProtocol,
        defaultSystemPrompt: String? = nil
    ) {
        self.store = store
        self.runtimeClient = runtimeClient
        self.defaultSystemPrompt = defaultSystemPrompt
    }

    public func loadMatters() {
        matters = (try? store.matters.fetchMatters())?.map(MatterSummary.init) ?? []
        if let selectedMatterID, matters.contains(where: { $0.id == selectedMatterID }) {
            if chatController == nil { select(matterID: selectedMatterID) }
        } else {
            select(matterID: matters.first?.id)
        }
    }

    @discardableResult
    public func createMatter(name: String = "New Matter") throws -> MatterSummary {
        let record = try store.matters.createMatter(name: name)
        let summary = MatterSummary(record: record)
        matters = (try? store.matters.fetchMatters())?.map(MatterSummary.init) ?? matters
        // Keep selection consistent even if the refetch failed to include the new row.
        if !matters.contains(where: { $0.id == summary.id }) {
            matters.insert(summary, at: 0)
        }
        select(matterID: record.id)
        return summary
    }

    public func select(matterID: String?) {
        selectedMatterID = matterID
        guard let matterID else {
            chatController = nil
            return
        }
        let controller = GlobalChatController(
            store: store,
            runtimeClient: runtimeClient,
            defaultSystemPrompt: defaultSystemPrompt,
            scope: .matter(id: matterID)
        )
        controller.loadChats()
        chatController = controller
    }
}
