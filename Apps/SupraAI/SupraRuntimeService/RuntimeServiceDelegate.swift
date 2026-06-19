import Foundation
import SupraRuntimeInterface

final class RuntimeServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service = SupraRuntimeService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedObject = service
        newConnection.exportedInterface = RuntimeXPCInterfaces.serviceInterface()
        // If the client dies or its connection drops mid-generation, cancel the
        // orphaned generation so it doesn't hold the single generation slot forever
        // and block every future request.
        newConnection.invalidationHandler = { [weak service, weak newConnection] in
            service?.handleConnectionTermination(newConnection)
        }
        newConnection.interruptionHandler = { [weak service, weak newConnection] in
            service?.handleConnectionTermination(newConnection)
        }
        newConnection.resume()
        return true
    }
}
