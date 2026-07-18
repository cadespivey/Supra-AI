import Foundation

@objc(SupraRuntimeXPCServiceProtocol)
public protocol SupraRuntimeXPCServiceProtocol: NSObjectProtocol {
    func loadChatModel(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    )

    func generate(
        _ requestData: Data,
        eventSink: SupraGenerationEventXPCSinkProtocol,
        withReply reply: @escaping (Data) -> Void
    )

    func countTokens(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    )

    func cancelGeneration(
        _ generationIDData: Data,
        withReply reply: @escaping (Data) -> Void
    )

    func recentEvents(
        for generationIDData: Data,
        after sequenceNumber: Int,
        withReply reply: @escaping (Data) -> Void
    )

    func unloadModel(
        withReply reply: @escaping (Data) -> Void
    )

    func reloadCurrentModel(
        withReply reply: @escaping (Data) -> Void
    )

    func runtimeStatus(
        withReply reply: @escaping (Data) -> Void
    )

#if DEBUG
    func runtimeLifecycleDebugStatus(
        withReply reply: @escaping (Data) -> Void
    )

    func triggerReservationTerminationProbe(
        _ generationIDData: Data,
        withReply reply: @escaping (Data) -> Void
    )
#endif

    // MARK: - Milestone 3: embeddings

    func loadEmbeddingModel(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    )

    func embedTexts(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    )

    func embeddingStatus(
        withReply reply: @escaping (Data) -> Void
    )
}

@objc(SupraGenerationEventXPCSinkProtocol)
public protocol SupraGenerationEventXPCSinkProtocol: NSObjectProtocol {
    func receive(
        _ eventData: Data,
        withReply reply: @escaping () -> Void
    )
}
