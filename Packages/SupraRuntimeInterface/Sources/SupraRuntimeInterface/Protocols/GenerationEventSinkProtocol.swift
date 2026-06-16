import Foundation

public protocol GenerationEventSinkProtocol {
    func receive(
        _ event: GenerationEvent,
        reply: @escaping () -> Void
    )
}
