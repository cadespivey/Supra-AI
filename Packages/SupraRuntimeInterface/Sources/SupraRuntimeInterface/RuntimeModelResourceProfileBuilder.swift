import CryptoKit
import Foundation
import SupraCore

public struct RuntimeModelResourceCalibration: Equatable, Sendable {
    public let nonWeightOverheadBytes: Int
    public let activationWorkingSetMultiplier: Int

    public init(
        nonWeightOverheadBytes: Int,
        activationWorkingSetMultiplier: Int
    ) {
        self.nonWeightOverheadBytes = nonWeightOverheadBytes
        self.activationWorkingSetMultiplier = activationWorkingSetMultiplier
    }

    public static let productionChat = RuntimeModelResourceCalibration(
        nonWeightOverheadBytes: 256 * 1_024 * 1_024,
        activationWorkingSetMultiplier: 4
    )
}

public enum RuntimeModelResourceProfileError: Error, Equatable, Sendable {
    case invalidCalibration
    case configBindingMismatch
    case invalidConfiguration
    case missingConfigurationField(String)
    case invalidConfigurationField(String)
    case unsupportedScalarType(String)
    case missingWeightArtifact
    case arithmeticOverflow(String)
}

extension RuntimeModelResourceProfileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCalibration:
            "The runtime resource calibration is invalid."
        case .configBindingMismatch:
            "The model configuration bytes do not match the exact artifact binding."
        case .invalidConfiguration:
            "The model configuration is not a valid JSON object."
        case .missingConfigurationField(let field):
            "The model configuration is missing \(field)."
        case .invalidConfigurationField(let field):
            "The model configuration field \(field) is invalid."
        case .unsupportedScalarType(let type):
            "The model scalar type \(type) is not supported for resource admission."
        case .missingWeightArtifact:
            "The exact artifact binding contains no recognized model weights."
        case .arithmeticOverflow(let operation):
            "Runtime resource profile arithmetic overflowed during \(operation)."
        }
    }
}

public struct RuntimeModelResourceProfileBuilder: Sendable {
    private let calibration: RuntimeModelResourceCalibration

    public init(calibration: RuntimeModelResourceCalibration) {
        self.calibration = calibration
    }

    public func buildChatProfile(
        profileID: String,
        modelID: ModelID,
        binding: RuntimeModelContentBinding,
        configData: Data
    ) throws -> ModelResourceProfile {
        guard calibration.nonWeightOverheadBytes >= 0,
              calibration.activationWorkingSetMultiplier > 0 else {
            throw RuntimeModelResourceProfileError.invalidCalibration
        }
        try verifyConfigBinding(binding, configData: configData)
        let config = try configurationObject(configData)
        let layerCount = try positiveInteger(
            in: config,
            keys: ["num_hidden_layers", "n_layer", "num_layers", "n_layers"],
            canonicalKey: "num_hidden_layers"
        )
        let attentionHeads = try positiveInteger(
            in: config,
            keys: ["num_attention_heads", "n_head", "num_heads"],
            canonicalKey: "num_attention_heads"
        )
        let keyValueHeads = try optionalPositiveInteger(
            in: config,
            keys: ["num_key_value_heads", "n_head_kv"]
        ) ?? attentionHeads
        guard keyValueHeads <= attentionHeads else {
            throw RuntimeModelResourceProfileError.invalidConfigurationField(
                "num_key_value_heads"
            )
        }
        let hiddenSize = try positiveInteger(
            in: config,
            keys: ["hidden_size", "d_model", "dim"],
            canonicalKey: "hidden_size"
        )
        let headDimension: Int
        if let explicit = try optionalPositiveInteger(
            in: config,
            keys: ["head_dim", "head_dimension"]
        ) {
            headDimension = explicit
        } else {
            guard hiddenSize.isMultiple(of: attentionHeads) else {
                throw RuntimeModelResourceProfileError.invalidConfigurationField(
                    "hidden_size"
                )
            }
            headDimension = hiddenSize / attentionHeads
        }
        let scalarType = try requiredString(
            in: config,
            keys: ["torch_dtype", "dtype"],
            canonicalKey: "torch_dtype"
        ).lowercased()
        let scalarBytes = try scalarByteCount(for: scalarType)
        let supportedContextTokens = try positiveInteger(
            in: config,
            keys: [
                "max_position_embeddings",
                "model_max_length",
                "n_positions",
                "max_sequence_length",
            ],
            canonicalKey: "max_position_embeddings"
        )
        let weightBytes = try exactWeightBytes(binding.files)
        let hiddenScalarBytes = try checkedMultiply(
            hiddenSize,
            scalarBytes,
            operation: "hidden-size scalar bytes"
        )
        let activationBytesPerToken = try checkedMultiply(
            hiddenScalarBytes,
            calibration.activationWorkingSetMultiplier,
            operation: "activation working set"
        )

        return ModelResourceProfile(
            profileID: profileID,
            modelID: modelID,
            modelArtifactID: binding.repositoryID,
            modelRevision: binding.revision,
            contentFingerprintSHA256: binding.fingerprintSHA256,
            weightBytes: weightBytes,
            layerCount: layerCount,
            keyValueHeadCount: keyValueHeads,
            headDimension: headDimension,
            scalarBytes: scalarBytes,
            supportedContextTokens: supportedContextTokens,
            nonWeightOverheadBytes: calibration.nonWeightOverheadBytes,
            activationBytesPerToken: activationBytesPerToken
        )
    }

    private func verifyConfigBinding(
        _ binding: RuntimeModelContentBinding,
        configData: Data
    ) throws {
        guard let configFile = binding.files.first(where: { $0.path == "config.json" }),
              configFile.size == Int64(configData.count),
              constantTimeEqual(configFile.actualSHA256, sha256(configData)) else {
            throw RuntimeModelResourceProfileError.configBindingMismatch
        }
    }

    private func configurationObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw RuntimeModelResourceProfileError.invalidConfiguration
        }
        return dictionary
    }

    private func positiveInteger(
        in object: [String: Any],
        keys: [String],
        canonicalKey: String
    ) throws -> Int {
        guard let key = keys.first(where: { object[$0] != nil }) else {
            throw RuntimeModelResourceProfileError.missingConfigurationField(canonicalKey)
        }
        guard let value = integer(object[key]), value > 0 else {
            throw RuntimeModelResourceProfileError.invalidConfigurationField(key)
        }
        return value
    }

    private func optionalPositiveInteger(
        in object: [String: Any],
        keys: [String]
    ) throws -> Int? {
        guard let key = keys.first(where: { object[$0] != nil }) else { return nil }
        guard let value = integer(object[key]), value > 0 else {
            throw RuntimeModelResourceProfileError.invalidConfigurationField(key)
        }
        return value
    }

    private func requiredString(
        in object: [String: Any],
        keys: [String],
        canonicalKey: String
    ) throws -> String {
        guard let key = keys.first(where: { object[$0] != nil }) else {
            throw RuntimeModelResourceProfileError.missingConfigurationField(canonicalKey)
        }
        guard let value = object[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeModelResourceProfileError.invalidConfigurationField(key)
        }
        return value
    }

    private func integer(_ value: Any?) -> Int? {
        guard let value, !(value is Bool) else { return nil }
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite,
                  double.rounded(.towardZero) == double,
                  double >= Double(Int.min),
                  double <= Double(Int.max) else { return nil }
            return Int(double)
        }
        return nil
    }

    private func scalarByteCount(for type: String) throws -> Int {
        switch type {
        case "float16", "half", "fp16", "bfloat16", "bf16":
            2
        case "float32", "float", "fp32":
            4
        case "float64", "double", "fp64":
            8
        case "int8", "uint8", "float8_e4m3fn", "float8_e5m2":
            1
        default:
            throw RuntimeModelResourceProfileError.unsupportedScalarType(type)
        }
    }

    private func exactWeightBytes(
        _ files: [RuntimeModelContentBinding.File]
    ) throws -> Int {
        let weights = files.filter { file in
            let path = file.path.lowercased()
            return path.hasSuffix(".safetensors")
                || path.hasSuffix(".gguf")
                || path.hasSuffix(".bin")
        }
        guard !weights.isEmpty else {
            throw RuntimeModelResourceProfileError.missingWeightArtifact
        }
        return try weights.reduce(into: 0) { total, file in
            guard file.size <= Int64(Int.max) else {
                throw RuntimeModelResourceProfileError.arithmeticOverflow(
                    "weight byte conversion"
                )
            }
            let (next, overflow) = total.addingReportingOverflow(Int(file.size))
            guard !overflow else {
                throw RuntimeModelResourceProfileError.arithmeticOverflow(
                    "weight byte sum"
                )
            }
            total = next
        }
    }

    private func checkedMultiply(
        _ lhs: Int,
        _ rhs: Int,
        operation: String
    ) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw RuntimeModelResourceProfileError.arithmeticOverflow(operation)
        }
        return result
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
