import Foundation

// MARK: - Event Merge Proposal

/// A single proposed action for the user to review during the event merge flow.
struct EventMergeProposal: Identifiable {
    let id: UUID
    let action: Action
    var decision: Decision

    enum Action {
        /// Two events from different services appear to be the same.
        case synced(EventMatch)

        /// An event exists in one service but not the other(s).
        case missingFrom(MissingEvent)

        /// Field-level differences between matched events (location, notes, end time).
        case fieldConflict(EventFieldConflict)
    }

    enum Decision {
        case pending
        case approved
        case rejected
        case modified(CanonicalEvent)
    }

    var isResolved: Bool {
        switch decision {
        case .pending: false
        default: true
        }
    }
}

// MARK: - Action Details

struct EventMatch {
    let events: [CanonicalEvent]
    let mergedResult: CanonicalEvent
    let confidence: EventMatchConfidence
}

struct MissingEvent {
    let event: CanonicalEvent
    let presentIn: [ServiceType]
    let missingFrom: [ServiceType]
}

struct EventFieldConflict {
    let events: [CanonicalEvent]
    let conflictingFields: [EventConflictingField]
    let mergedResult: CanonicalEvent
}

struct EventConflictingField {
    let fieldName: String
    let entries: [FieldEntry]

    struct FieldEntry: Identifiable {
        let id = UUID()
        let service: ServiceType
        let value: String
        let event: CanonicalEvent
    }
}

// MARK: - Match Confidence

enum EventMatchConfidence: Comparable {
    case exact      // title + start time + duration all match
    case high       // title + start time match, minor duration diff
    case medium     // title matches, time close
    case low        // weak signals

    var label: String {
        switch self {
        case .exact: "Exact match"
        case .high: "High confidence"
        case .medium: "Medium confidence"
        case .low: "Low confidence"
        }
    }
}

// MARK: - Event Merge Session

struct EventMergeSession: Identifiable {
    let id: UUID
    let createdDate: Date
    var proposals: [EventMergeProposal]
    let servicesSynced: [ServiceType]

    var pendingCount: Int {
        proposals.filter { !$0.isResolved }.count
    }

    var approvedCount: Int {
        proposals.filter {
            if case .approved = $0.decision { return true }
            if case .modified = $0.decision { return true }
            return false
        }.count
    }

    var pushableCount: Int {
        proposals.filter { proposal in
            switch proposal.decision {
            case .modified: return true
            case .approved:
                if case .synced(let match) = proposal.action, match.confidence == .exact {
                    return false
                }
                return true
            default: return false
            }
        }.count
    }

    var rejectedCount: Int {
        proposals.filter {
            if case .rejected = $0.decision { return true }
            return false
        }.count
    }

    init(proposals: [EventMergeProposal], servicesSynced: [ServiceType]) {
        self.id = UUID()
        self.createdDate = Date()
        self.proposals = proposals
        self.servicesSynced = servicesSynced
    }
}
