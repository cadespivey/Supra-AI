import Foundation
import SupraRuntimeInterface

final class RuntimeServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service = SupraRuntimeService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedObject = service
        newConnection.exportedInterface = RuntimeXPCInterfaces.serviceInterface()
        newConnection.resume()
        return true
    }
}
