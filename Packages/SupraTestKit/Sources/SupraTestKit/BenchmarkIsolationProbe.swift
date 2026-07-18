import Foundation

public struct BenchmarkMatterQueryObservation: Equatable, Sendable {
    public var surface: String
    public var requestedMatterID: String
    public var returnedMatterIDs: [String]

    public init(surface: String, requestedMatterID: String, returnedMatterIDs: [String]) {
        self.surface = surface
        self.requestedMatterID = requestedMatterID
        self.returnedMatterIDs = returnedMatterIDs
    }
}

public struct BenchmarkSharedBlobObservation: Equatable, Sendable {
    public var blobIDs: [String]
    public var documentIDsByMatter: [String: Set<String>]
    public var tagNamesByDocument: [String: [String]]
    public var sourceDocumentIDsByMatter: [String: Set<String>]

    public init(
        blobIDs: [String],
        documentIDsByMatter: [String: Set<String>],
        tagNamesByDocument: [String: [String]],
        sourceDocumentIDsByMatter: [String: Set<String>]
    ) {
        self.blobIDs = blobIDs
        self.documentIDsByMatter = documentIDsByMatter
        self.tagNamesByDocument = tagNamesByDocument
        self.sourceDocumentIDsByMatter = sourceDocumentIDsByMatter
    }
}

public enum BenchmarkIsolationProbeError: Error, Equatable, LocalizedError {
    case queryLeak(surface: String, requestedMatterID: String, returnedMatterID: String)
    case blobWasNotShared
    case documentIdentityShared(documentID: String)
    case unknownTaggedDocument(documentID: String)
    case derivedTagLeak(tagName: String)
    case sourcePacketLeak(requestedMatterID: String, documentID: String)
    case crossMatterWrite(surface: String, ownerMatterID: String, relatedMatterID: String)

    public var errorDescription: String? {
        switch self {
        case let .queryLeak(surface, requested, returned):
            return "\(surface) requested \(requested) but returned \(returned)"
        case .blobWasNotShared:
            return "the shared-blob probe did not resolve every instance to one blob"
        case let .documentIdentityShared(documentID):
            return "document identity \(documentID) appeared in more than one matter"
        case let .unknownTaggedDocument(documentID):
            return "tag observation referenced unknown document \(documentID)"
        case let .derivedTagLeak(tagName):
            return "derived tag \(tagName) appeared on both matter-local document instances"
        case let .sourcePacketLeak(requestedMatterID, documentID):
            return "source packet for \(requestedMatterID) included \(documentID)"
        case let .crossMatterWrite(surface, ownerMatterID, relatedMatterID):
            return "\(surface) owned by \(ownerMatterID) referenced \(relatedMatterID)"
        }
    }
}

/// Reusable, production-independent assertions for the standing matter-isolation
/// suite. Later schema work feeds its repository results and write scopes into
/// these probes, so every new surface inherits the same fail-closed contract.
public enum BenchmarkIsolationProbe {
    public static func verifyQueryIsolation(
        _ observations: [BenchmarkMatterQueryObservation]
    ) throws {
        for observation in observations {
            for returnedMatterID in observation.returnedMatterIDs
            where returnedMatterID != observation.requestedMatterID {
                throw BenchmarkIsolationProbeError.queryLeak(
                    surface: observation.surface,
                    requestedMatterID: observation.requestedMatterID,
                    returnedMatterID: returnedMatterID
                )
            }
        }
    }

    public static func verifySharedBlobIsolation(
        _ observation: BenchmarkSharedBlobObservation
    ) throws {
        guard !observation.blobIDs.isEmpty, Set(observation.blobIDs).count == 1 else {
            throw BenchmarkIsolationProbeError.blobWasNotShared
        }

        var matterByDocumentID: [String: String] = [:]
        for (matterID, documentIDs) in observation.documentIDsByMatter {
            for documentID in documentIDs {
                if matterByDocumentID.updateValue(matterID, forKey: documentID) != nil {
                    throw BenchmarkIsolationProbeError.documentIdentityShared(documentID: documentID)
                }
            }
        }

        var tagOwnerByName: [String: String] = [:]
        for (documentID, tagNames) in observation.tagNamesByDocument {
            guard let matterID = matterByDocumentID[documentID] else {
                throw BenchmarkIsolationProbeError.unknownTaggedDocument(documentID: documentID)
            }
            for tagName in tagNames {
                if let existing = tagOwnerByName[tagName], existing != matterID {
                    throw BenchmarkIsolationProbeError.derivedTagLeak(tagName: tagName)
                }
                tagOwnerByName[tagName] = matterID
            }
        }

        for (requestedMatterID, sourceDocumentIDs) in observation.sourceDocumentIDsByMatter {
            let allowed = observation.documentIDsByMatter[requestedMatterID] ?? []
            for documentID in sourceDocumentIDs where !allowed.contains(documentID) {
                throw BenchmarkIsolationProbeError.sourcePacketLeak(
                    requestedMatterID: requestedMatterID,
                    documentID: documentID
                )
            }
        }
    }

    public static func requireSameMatter(
        surface: String,
        ownerMatterID: String,
        relatedMatterIDs: [String]
    ) throws {
        for relatedMatterID in relatedMatterIDs where relatedMatterID != ownerMatterID {
            throw BenchmarkIsolationProbeError.crossMatterWrite(
                surface: surface,
                ownerMatterID: ownerMatterID,
                relatedMatterID: relatedMatterID
            )
        }
    }
}
