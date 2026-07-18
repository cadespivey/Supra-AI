import Foundation

/// Revision-independent input to the structural diff engine. Persisted structure
/// records can be projected into this type without making SupraDocuments depend
/// on the store package.
public struct StructuralDiffNode: Sendable, Equatable, Codable {
    public var nodeID: String
    public var nodeKey: String
    public var parentNodeKey: String?
    public var ordinal: Int
    public var kind: DocumentStructureNodeKind
    public var text: String?

    public init(
        nodeID: String,
        nodeKey: String,
        parentNodeKey: String?,
        ordinal: Int,
        kind: DocumentStructureNodeKind,
        text: String?
    ) {
        self.nodeID = nodeID
        self.nodeKey = nodeKey
        self.parentNodeKey = parentNodeKey
        self.ordinal = ordinal
        self.kind = kind
        self.text = text
    }
}

public struct StructuralDiffLocator: Sendable, Equatable, Codable {
    public var nodeID: String
    public var nodeKey: String
    public var ordinal: Int
    public var kind: DocumentStructureNodeKind
    public var text: String?

    public init(node: StructuralDiffNode) {
        nodeID = node.nodeID
        nodeKey = node.nodeKey
        ordinal = node.ordinal
        kind = node.kind
        text = node.text
    }
}

public enum StructuralDiffChangeKind: String, Sendable, Equatable, Codable {
    case changed
    case inserted
    case deleted
}

public struct StructuralDiffChange: Sendable, Equatable, Codable {
    public var kind: StructuralDiffChangeKind
    public var before: StructuralDiffLocator?
    public var after: StructuralDiffLocator?

    public init(
        kind: StructuralDiffChangeKind,
        before: StructuralDiffLocator?,
        after: StructuralDiffLocator?
    ) {
        self.kind = kind
        self.before = before
        self.after = after
    }
}

public struct StructuralDiffResult: Sendable, Equatable, Codable {
    public var changes: [StructuralDiffChange]

    public init(changes: [StructuralDiffChange]) {
        self.changes = changes
    }

    public var changed: [StructuralDiffChange] { changes.filter { $0.kind == .changed } }
    public var inserted: [StructuralDiffChange] { changes.filter { $0.kind == .inserted } }
    public var deleted: [StructuralDiffChange] { changes.filter { $0.kind == .deleted } }
}

/// Deterministic node-tree alignment. Natural node keys are stable across
/// extraction revisions; node IDs remain revision-bound locators returned to
/// callers for review and citation navigation.
public enum StructuralDiff {
    public static func compare(
        before: [StructuralDiffNode],
        after: [StructuralDiffNode]
    ) -> StructuralDiffResult {
        let beforeByKey = groupedByNaturalKey(before)
        let afterByKey = groupedByNaturalKey(after)
        let keys = Set(beforeByKey.keys).union(afterByKey.keys).sorted()
        var ordered: [(ordinal: Int, priority: Int, key: String, change: StructuralDiffChange)] = []

        for key in keys {
            let beforeNodes = beforeByKey[key, default: []]
            let afterNodes = afterByKey[key, default: []]
            let pairCount = min(beforeNodes.count, afterNodes.count)

            if pairCount > 0 {
                for index in 0..<pairCount {
                    let lhs = beforeNodes[index]
                    let rhs = afterNodes[index]
                    guard lhs.kind != rhs.kind
                            || lhs.parentNodeKey != rhs.parentNodeKey
                            || lhs.text != rhs.text else { continue }
                    ordered.append((
                        min(lhs.ordinal, rhs.ordinal),
                        0,
                        key,
                        StructuralDiffChange(
                            kind: .changed,
                            before: StructuralDiffLocator(node: lhs),
                            after: StructuralDiffLocator(node: rhs)
                        )
                    ))
                }
            }

            for node in beforeNodes.dropFirst(pairCount) {
                ordered.append((
                    node.ordinal,
                    1,
                    key,
                    StructuralDiffChange(
                        kind: .deleted,
                        before: StructuralDiffLocator(node: node),
                        after: nil
                    )
                ))
            }
            for node in afterNodes.dropFirst(pairCount) {
                ordered.append((
                    node.ordinal,
                    2,
                    key,
                    StructuralDiffChange(
                        kind: .inserted,
                        before: nil,
                        after: StructuralDiffLocator(node: node)
                    )
                ))
            }
        }

        ordered.sort { lhs, rhs in
            (lhs.ordinal, lhs.priority, lhs.key, lhs.change.before?.nodeID ?? "", lhs.change.after?.nodeID ?? "")
                < (rhs.ordinal, rhs.priority, rhs.key, rhs.change.before?.nodeID ?? "", rhs.change.after?.nodeID ?? "")
        }
        return StructuralDiffResult(changes: ordered.map(\.change))
    }

    private static func groupedByNaturalKey(
        _ nodes: [StructuralDiffNode]
    ) -> [String: [StructuralDiffNode]] {
        Dictionary(grouping: nodes, by: \.nodeKey).mapValues { group in
            group.sorted { lhs, rhs in
                (lhs.ordinal, lhs.kind.rawValue, lhs.nodeID)
                    < (rhs.ordinal, rhs.kind.rawValue, rhs.nodeID)
            }
        }
    }
}
