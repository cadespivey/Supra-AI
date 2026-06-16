import Foundation
import SupraRuntimeInterface

enum RuntimeErrorMapper {
    static func invalidRequest(_ message: String, technicalDetails: String? = nil) -> RuntimeError {
        RuntimeError(category: "invalidRequest", message: message, technicalDetails: technicalDetails)
    }

    static func modelNotLoaded() -> RuntimeError {
        RuntimeError(category: "modelNotLoaded", message: "No matching chat model is loaded.")
    }

    static func generationBusy() -> RuntimeError {
        RuntimeError(category: "generationBusy", message: "A generation is already running.")
    }

    static func unloadWhileGenerating() -> RuntimeError {
        RuntimeError(category: "generationActive", message: "The model cannot be unloaded while a generation is active.")
    }

    static func modelLoadFailed(_ error: Error) -> RuntimeError {
        RuntimeError(
            category: "modelLoadFailed",
            message: "The MLX model could not be loaded.",
            technicalDetails: error.localizedDescription
        )
    }

    static func generationFailed(_ error: Error) -> RuntimeError {
        RuntimeError(
            category: "generationFailed",
            message: "The MLX generation failed.",
            technicalDetails: error.localizedDescription
        )
    }
}
