import Foundation

/// The headless diagnostic probes the app executable can run instead of a normal
/// session, and the isolation contract each runs under (measurement qualification,
/// review finding #5).
///
/// WHY these ship in the Release app at all: the probes measure the real MLX runtime
/// through the app's bundled XPC service, against model files inside the app's
/// TCC-protected container, under the signed hardened-runtime environment the
/// measurement must reflect. No separate command-line target can reach that
/// combination, and a Debug-only executable would measure the wrong build (and
/// violate the Release-only rule for anything near real data). The compensating
/// boundary is explicit and testable:
///
/// - at most ONE probe mode per launch (`resolve` returns `.conflict` for more, and
///   the caller runs none of them);
/// - model-dependent modes run on an isolated throwaway store
///   (`requiresIsolatedStore`) — the user's normal app-support store is never opened
///   or migrated, and the user's active-model selection is never read or written
///   (the registry is rebuilt from disk manifests by `DiskModelRegistrar`);
/// - the coverage probe is the one real-store diagnostic, justified because its
///   entire purpose is to replay THIS store's chat history; it is read-only and
///   additionally skipped on fallback/recovery stores;
/// - probes leave through the app's normal termination path, never `exit(0)`.
public enum HeadlessProbeMode: String, CaseIterable, Sendable, Equatable {
    /// Replays the real store's matter-chat questions through the routing shadow.
    case coverageShadow = "-runCoverageShadowProbe"
    /// Loads a model and measures typed-generation capability.
    case capability = "-runCapabilityProbe"
    /// Runs the typed-vs-prose A/B over authored fixtures.
    case typedProseAB = "-runTypedProseABProbe"

    /// The outcome of resolving a launch-argument list.
    public enum Resolution: Equatable, Sendable {
        /// No probe flag present — a normal app launch.
        case none
        /// Exactly one probe requested.
        case single(HeadlessProbeMode)
        /// More than one probe flag present. Probes are mutually exclusive; the
        /// caller must run NONE of them and report the conflict.
        case conflict([HeadlessProbeMode])
    }

    /// Resolves launch arguments to at most one probe mode, in declaration order.
    public static func resolve(arguments: [String]) -> Resolution {
        let requested = allCases.filter { arguments.contains($0.rawValue) }
        switch requested.count {
        case 0: return .none
        case 1: return .single(requested[0])
        default: return .conflict(requested)
        }
    }

    /// Whether this probe must run against an isolated throwaway store. True for
    /// every mode that does not, by its very purpose, need the user's data.
    public var requiresIsolatedStore: Bool {
        switch self {
        case .coverageShadow: return false
        case .capability, .typedProseAB: return true
        }
    }
}
