import SupraCore

public enum SupraNetworkingModule {
    public static let courtListenerService = "com.supraai.courtlistener"
    public static let courtListenerTokenAccount = "api-token"

    public static func makeNetworkRequestID() -> NetworkRequestID {
        NetworkRequestID()
    }
}
