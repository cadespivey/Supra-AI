import SupraCore
import SupraNetworking

public enum SupraResearchModule {
    public static func makeResearchSessionID() -> ResearchSessionID {
        ResearchSessionID()
    }

    public static var courtListenerTokenService: String {
        SupraNetworkingModule.courtListenerService
    }
}
