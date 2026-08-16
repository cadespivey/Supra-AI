import Foundation
import SupraResearch
@_spi(ResearchPacketEgressRegistration) import SupraStore

/// Only a gate-minted consumption receipt can cross from provider policy into
/// the Store-owned research-packet ledger. An approved but unused grant is
/// intentionally representable here so callers can fail closed explicitly.
public enum ResearchPacketEgressReceiptEvidence: Sendable {
    case consumed(LegalQueryEgressConsumptionReceipt)
    case unconsumed(LegalQueryEgressGrant)
}

public enum ResearchPacketEgressReceiptRegistrationError: Error, Equatable, Sendable {
    case bindingDigestMismatch
    case unconsumedGrant
}

public struct ResearchPacketEgressReceiptRegistrar: Sendable {
    private let store: SupraStore

    public init(store: SupraStore) {
        self.store = store
    }

    @discardableResult
    public func register(
        _ evidence: ResearchPacketEgressReceiptEvidence
    ) throws -> ResearchPacketEgressAuthority {
        switch evidence {
        case .unconsumed:
            throw ResearchPacketEgressReceiptRegistrationError.unconsumedGrant
        case let .consumed(receipt):
            guard receipt.hasValidBindingDigest else {
                throw ResearchPacketEgressReceiptRegistrationError.bindingDigestMismatch
            }
            return try store.researchPackets.registerEgressConsumption(
                ResearchPacketEgressConsumptionRegistrationCommand(
                    receiptID: receipt.id,
                    providerID: receipt.providerID.rawValue,
                    grantVersion: receipt.grantVersion,
                    origin: receipt.origin.rawValue,
                    matterID: receipt.matterID,
                    researchSessionID: receipt.researchSessionID,
                    classification: receipt.classification.rawValue,
                    querySHA256: receipt.querySHA256,
                    bindingDigestSHA256: receipt.bindingDigestSHA256,
                    registeredAt: receipt.consumedAt
                )
            )
        }
    }
}
