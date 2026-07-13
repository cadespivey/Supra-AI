import Foundation
import SupraRuntimeInterface

enum RuntimeErrorMapper {
    static func invalidRequest(_ message: String, technicalDetails: String? = nil) -> RuntimeError {
        RuntimeError(category: "invalidRequest", message: message, technicalDetails: technicalDetails)
    }

    static func modelNotLoaded() -> RuntimeError {
        RuntimeError(category: "modelNotLoaded", message: "No matching runtime model is loaded.")
    }

    static func generationBusy() -> RuntimeError {
        RuntimeError(category: "generationBusy", message: "A generation is already running.")
    }

    static func unloadWhileGenerating() -> RuntimeError {
        RuntimeError(category: "generationActive", message: "The model cannot be unloaded while a generation is active.")
    }

    static func modelMutationWhileGenerating() -> RuntimeError {
        RuntimeError(category: "generationActive", message: "The model cannot be replaced while a generation is active.")
    }

    static func modelLoadFailed(_ error: Error) -> RuntimeError {
        let details = error.localizedDescription
        if looksLikeMemoryPressure(details) {
            return RuntimeError(
                category: "modelLoadFailed",
                message: "The MLX model could not be loaded. The Mac may not have enough free unified memory for the selected quantization/context.",
                technicalDetails: details
            )
        }
        return RuntimeError(
            category: "modelLoadFailed",
            message: "The MLX model could not be loaded.",
            technicalDetails: details
        )
    }

    static func modelAccessFailed(_ error: RuntimeModelDirectoryAccessError) -> RuntimeError {
        invalidRequest(error.localizedDescription)
    }

    static func embeddingFailed(_ error: Error) -> RuntimeError {
        RuntimeError(
            category: "embeddingFailed",
            message: "The MLX model could not generate embeddings.",
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

    private static func looksLikeMemoryPressure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("memory")
            || lower.contains("out of resource")
            || lower.contains("allocation")
            || lower.contains("metal")
            || lower.contains("mps")
    }
}
