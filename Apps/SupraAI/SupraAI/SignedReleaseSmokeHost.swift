import Darwin
import Dispatch
import Foundation
import SupraRuntimeClient
import SupraSessions

@main
enum SupraAIEntryPoint {
    private static let signedSmokeSentinel = "--supra-signed-release-smoke-v1"

    static func main() {
#if SUPRA_SIGNED_RELEASE_SMOKE_HOST
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains(signedSmokeSentinel) {
            guard arguments == [signedSmokeSentinel] else {
                Darwin.exit(EX_USAGE)
            }
            SignedReleaseSmokeHost.runAndExit()
        }
#endif
        SupraAIApp.main()
    }
}

#if SUPRA_SIGNED_RELEASE_SMOKE_HOST
private enum SignedReleaseSmokeHost {
    private static let appBundleIdentifier = "ai.supra.SupraAI"
    private static let xpcBundleIdentifier = "ai.supra.SupraAI.SupraRuntimeService"
    private static let maximumReportBytes = 16_384
    private static let environmentKeys = Set([
        "SUPRA_RELEASE_SMOKE_SOURCE_SHA",
        "SUPRA_RELEASE_SMOKE_APP_TREE_SHA256",
        "SUPRA_RELEASE_SMOKE_MODEL_SHA256",
        "SUPRA_RELEASE_SMOKE_NONCE",
        "SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY",
    ])

    static func runAndExit() -> Never {
        let bindings = validatedBindingsOrExit()
        guard fcntl(3, F_GETFD) != -1 else {
            Darwin.exit(EX_IOERR)
        }

        Task.detached(priority: .userInitiated) {
            let status = await execute(bindings: bindings)
            Darwin.exit(status)
        }
        dispatchMain()
    }

    private static func execute(bindings: Bindings) async -> Int32 {
        do {
            let bundleMetadata = try loadBundleMetadata()
            let managedRoot = ManagedModelStorage.modelsDirectory().standardizedFileURL
            let authorization = try SignedReleaseModelAuthorization.authorize(
                modelDirectory: bindings.modelDirectory,
                managedRoot: managedRoot,
                expectedSHA256: bindings.modelSHA256
            )
            let runtimeClient = RuntimeClient()
            defer { runtimeClient.disconnect() }
            let runner = SignedReleaseSmokeRunner(
                runtimeClient: runtimeClient,
                authorization: authorization,
                metadata: SignedReleaseSmokeMetadata(
                    sourceSha: bindings.sourceSha,
                    appTreeSHA256: bindings.appTreeSHA256,
                    nonce: bindings.nonce,
                    appBundleIdentifier: bundleMetadata.appBundleIdentifier,
                    xpcBundleIdentifier: bundleMetadata.xpcBundleIdentifier,
                    version: bundleMetadata.version,
                    build: bundleMetadata.build
                )
            )
            let attestation = try await runner.run()
            var report = try JSONEncoder.releaseSmokeEncoder.encode(attestation)
            report.append(0x0A)
            guard !report.isEmpty, report.count <= maximumReportBytes else {
                return EX_SOFTWARE
            }
            return writeReport(report) ? EX_OK : EX_IOERR
        } catch {
            return EX_SOFTWARE
        }
    }

    private static func validatedBindingsOrExit() -> Bindings {
        let environment = ProcessInfo.processInfo.environment
        let suppliedSmokeKeys = Set(
            environment.keys.filter { $0.hasPrefix("SUPRA_RELEASE_SMOKE_") }
        )
        guard suppliedSmokeKeys == environmentKeys,
              let sourceSha = nonempty(environment["SUPRA_RELEASE_SMOKE_SOURCE_SHA"]),
              let appTreeSHA256 = nonempty(environment["SUPRA_RELEASE_SMOKE_APP_TREE_SHA256"]),
              let modelSHA256 = nonempty(environment["SUPRA_RELEASE_SMOKE_MODEL_SHA256"]),
              let nonce = nonempty(environment["SUPRA_RELEASE_SMOKE_NONCE"]),
              let modelPath = nonempty(environment["SUPRA_RELEASE_SMOKE_MODEL_DIRECTORY"]),
              modelPath.hasPrefix("/") else {
            Darwin.exit(EX_CONFIG)
        }
        return Bindings(
            sourceSha: sourceSha,
            appTreeSHA256: appTreeSHA256,
            modelSHA256: modelSHA256,
            nonce: nonce,
            modelDirectory: URL(fileURLWithPath: modelPath, isDirectory: true)
                .standardizedFileURL
        )
    }

    private static func loadBundleMetadata() throws -> BundleMetadata {
        let appBundle = Bundle.main
        let xpcURL = appBundle.bundleURL
            .appendingPathComponent("Contents/XPCServices", isDirectory: true)
            .appendingPathComponent("SupraRuntimeService.xpc", isDirectory: true)
        guard appBundle.bundleIdentifier == appBundleIdentifier,
              let xpcBundle = Bundle(url: xpcURL),
              xpcBundle.bundleIdentifier == xpcBundleIdentifier,
              let version = appBundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let build = appBundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              xpcBundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String == version,
              xpcBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == build else {
            throw HostError.invalidBundleMetadata
        }
        return BundleMetadata(
            appBundleIdentifier: appBundleIdentifier,
            xpcBundleIdentifier: xpcBundleIdentifier,
            version: version,
            build: build
        )
    }

    private static func writeReport(_ report: Data) -> Bool {
        defer { _ = Darwin.close(3) }
        return report.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    3,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private struct Bindings: Sendable {
        let sourceSha: String
        let appTreeSHA256: String
        let modelSHA256: String
        let nonce: String
        let modelDirectory: URL
    }

    private struct BundleMetadata: Sendable {
        let appBundleIdentifier: String
        let xpcBundleIdentifier: String
        let version: String
        let build: String
    }

    private enum HostError: Error {
        case invalidBundleMetadata
    }
}

private extension JSONEncoder {
    static var releaseSmokeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
#endif
