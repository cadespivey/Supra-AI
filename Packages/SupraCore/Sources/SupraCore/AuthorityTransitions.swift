import Foundation

public extension AuthorityUseStatus {
    /// The use-statuses this status may transition to (spec §11.4). A change is
    /// permitted only when the target is in this set; the citator-check and
    /// verified states are never assigned automatically.
    var allowedTransitions: [AuthorityUseStatus] {
        switch self {
        case .retrievedFromCourtListener:
            [.needsCitatorCheck, .userMarkedVerified, .doNotUse]
        case .needsCitatorCheck:
            [.userMarkedVerified, .doNotUse]
        case .unverified:
            [.needsCitatorCheck, .userMarkedVerified, .doNotUse]
        case .userMarkedVerified:
            [.needsCitatorCheck, .doNotUse]
        case .doNotUse:
            [.needsCitatorCheck]
        }
    }

    func canTransition(to target: AuthorityUseStatus) -> Bool {
        allowedTransitions.contains(target)
    }
}
