import Foundation

let delegate = RuntimeServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
