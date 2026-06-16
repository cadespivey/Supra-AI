import SupraCore
import SupraRuntimeInterface

public protocol RuntimeClientProtocol: Sendable {
    func connect() async throws
    func loadModel(_ request: LoadModelRequest) async throws -> LoadModelResponse
    func generate(_ request: GenerateRequest) throws -> AsyncThrowingStream<GenerationEvent, Error>
    func cancelGeneration(_ generationID: GenerationID) async throws -> CancelGenerationResponse
    func recentEvents(for generationID: GenerationID, after sequenceNumber: Int) async throws -> [GenerationEvent]
    func unloadModel() async throws -> UnloadModelResponse
    func reloadCurrentModel() async throws -> LoadModelResponse
    func runtimeStatus() async throws -> RuntimeStatus
    func restartRuntimeService() async throws
}
