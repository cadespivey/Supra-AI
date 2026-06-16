import Foundation

public enum RuntimeXPCServiceNames {
    public static let defaultServiceName = "ai.supra.SupraAI.SupraRuntimeService"
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

