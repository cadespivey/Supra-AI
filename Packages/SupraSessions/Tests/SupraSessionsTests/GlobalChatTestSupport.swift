import Foundation
import SupraCore
import SupraNetworking
import SupraResearch
import SupraRuntimeClient
import SupraRuntimeInterface
@testable import SupraSessions
import SupraStore

/// Hermetic test wiring for `GlobalChatController`.
///
/// The controller's default init wires REAL statutory/developments sources (GovInfo,
/// eCFR, Open Legal Codes, Federal Register, OpenStates, LegiScan, Regulations.gov)
/// through live `URLSession` clients and reads API keys from the user's Keychain.
/// Unit tests must never do either, so every test constructs the controller through
/// `makeGlobalChatController(...)`, which substitutes offline defaults for every
/// externally-wired dependency. A test that exercises one of those tiers passes its
/// own stub (e.g. `StubStatutorySource`) instead.

/// Token store that never touches the Keychain and holds no keys.
struct OfflineTokenStore: APIKeyStoreProtocol {
    func saveCourtListenerToken(_ token: String) throws {}
    func loadCourtListenerToken() throws -> String? { nil }
    func deleteCourtListenerToken() throws {}
    func hasCourtListenerToken() throws -> Bool { false }
}

/// CourtListener client that answers every search with an empty result set.
struct OfflineCourtListenerClient: CourtListenerClientProtocol {
    func searchOpinions(
        _ request: CourtListenerSearchRequest,
        relatedResearchSessionID: String?
    ) async throws -> CourtListenerSearchResponse {
        CourtListenerSearchResponse(count: 0, next: nil, previous: nil, results: [])
    }
}

/// Statutory source returning a canned result, for tests that exercise the
/// statutory-grounding tier without live Open Legal Codes / eCFR / GovInfo data.
struct StubStatutorySource: StatutorySource {
    var id = "stub-statutes"
    var displayName = "Stub Statutes"
    var weightTier: SourceWeightTier = .currencyVerifiable
    var providesCurrency = true
    var result: StatutoryLookupResult

    func lookup(_ query: StatutoryQuery) async -> StatutoryLookupResult { result }
}

/// Developments source returning a canned result, for tests that exercise the
/// legal-developments tier without live Federal Register / OpenStates data.
struct StubLegalDevelopmentSource: LegalDevelopmentSource {
    var id = "stub-developments"
    var displayName = "Stub Developments"
    var kind: LegalDevelopmentKind = .regulatory
    var result: LegalDevelopmentLookupResult

    func lookup(_ query: LegalDevelopmentQuery) async -> LegalDevelopmentLookupResult { result }
}

/// Builds a `GlobalChatController` whose external dependencies are all offline:
/// no network client is ever constructed and the Keychain is never read. Pass an
/// explicit stub for the tier a test exercises; everything else stays inert.
@MainActor
func makeGlobalChatController(
    store: SupraStore,
    runtimeClient: any RuntimeClientProtocol,
    defaultSystemPrompt: String? = nil,
    scope: ChatScope = .global,
    embedder: (any TextEmbedder)? = nil,
    legalConfiguration: LegalModelConfiguration = .fromEnvironment(),
    tokenStore: (any APIKeyStoreProtocol)? = nil,
    courtListenerClient: (any CourtListenerClientProtocol)? = nil,
    statutoryOrchestrator: StatutorySourceOrchestrator? = nil,
    developmentsOrchestrator: LegalDevelopmentOrchestrator? = nil
) -> GlobalChatController {
    GlobalChatController(
        store: store,
        runtimeClient: runtimeClient,
        defaultSystemPrompt: defaultSystemPrompt,
        scope: scope,
        embedder: embedder,
        legalConfiguration: legalConfiguration,
        tokenStore: tokenStore ?? OfflineTokenStore(),
        courtListenerClient: courtListenerClient ?? OfflineCourtListenerClient(),
        statutoryOrchestrator: statutoryOrchestrator ?? StatutorySourceOrchestrator(sources: []),
        developmentsOrchestrator: developmentsOrchestrator ?? LegalDevelopmentOrchestrator(sources: [])
    )
}
