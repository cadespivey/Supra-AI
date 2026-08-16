import SupraDiagnostics

/// The narrow set of purposes for which an operational RAG receipt may be
/// presented. A receipt reports how retrieval ran; it never supplies legal or
/// policy authority for a later operation.
enum RAGExecutionReceiptUse: String, Equatable, Sendable {
    case operationalDiagnostics
    case egressAuthorization
    case documentReadiness
    case sourceProvenance
    case legalAuthority
    case legalAggregateCompletion
}

enum RAGExecutionReceiptAuthorityError: Error, Equatable, Sendable {
    case prohibitedUse(RAGExecutionReceiptUse)
}

struct RAGExecutionReceiptAuthorityBoundary: Sendable {
    func perform<Result>(
        receipt: RAGExecutionReceipt,
        use: RAGExecutionReceiptUse,
        operation: () throws -> Result
    ) throws -> Result {
        _ = receipt.receiptID
        guard use == .operationalDiagnostics else {
            throw RAGExecutionReceiptAuthorityError.prohibitedUse(use)
        }
        return try operation()
    }
}
