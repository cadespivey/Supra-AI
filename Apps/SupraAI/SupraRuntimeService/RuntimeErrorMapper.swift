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
}

