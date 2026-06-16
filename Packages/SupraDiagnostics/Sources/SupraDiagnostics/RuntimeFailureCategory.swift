public enum RuntimeFailureCategory: String, Codable, Sendable {
    case modelFolderAccessError
    case modelConfigMissing
    case tokenizerMissing
    case weightsMissing
    case unsupportedModelFormat
    case runtimeStartFailed
    case runtimeConnectionLost
    case modelLoadFailed
    case generationFailed
    case generationCancelFailed
    case insufficientMemoryWarning
    case unknownRuntimeError
}
