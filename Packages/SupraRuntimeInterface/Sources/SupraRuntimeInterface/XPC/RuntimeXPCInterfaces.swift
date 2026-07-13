import Foundation

public enum RuntimeXPCServiceNames {
    public static let defaultServiceName = "ai.supra.SupraAI.SupraRuntimeService"
}

/// Public Foundation code-signing requirements applied in both directions at
/// the XPC boundary. Debug permits ad-hoc signatures but still binds exact bundle
/// identifiers; Release additionally requires Supra's Team ID and Apple anchor.
public enum RuntimeXPCSigningRequirements {
    public static let teamID = "2DP657YB3K"

#if DEBUG
    public static let appClient = "identifier \"ai.supra.SupraAI\""
    public static let runtimeService = "identifier \"ai.supra.SupraAI.SupraRuntimeService\""
#else
    public static let appClient = "anchor apple generic and identifier \"ai.supra.SupraAI\" and certificate leaf[subject.OU] = \"2DP657YB3K\""
    public static let runtimeService = "anchor apple generic and identifier \"ai.supra.SupraAI.SupraRuntimeService\" and certificate leaf[subject.OU] = \"2DP657YB3K\""
#endif
}

public enum RuntimeXPCInterfaces {
    public static func serviceInterface() -> NSXPCInterface {
        let serviceInterface = NSXPCInterface(with: SupraRuntimeXPCServiceProtocol.self)
        serviceInterface.setInterface(
            eventSinkInterface(),
            for: #selector(SupraRuntimeXPCServiceProtocol.generate(_:eventSink:withReply:)),
            argumentIndex: 1,
            ofReply: false
        )
        return serviceInterface
    }

    public static func eventSinkInterface() -> NSXPCInterface {
        NSXPCInterface(with: SupraGenerationEventXPCSinkProtocol.self)
    }
}
