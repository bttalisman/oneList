import Foundation

// MARK: - Merge Proposal

/// A single proposed action for the user to review during the merge flow.
struct MergeProposal: Identifiable {
    let id: UUID
    let action: Action
    /// User's decision -- starts as the suggested default, user can override.
    var decision: Decision

    enum Action {
        /// Two tasks from different services appear to be the same item.
        /// Proposes merging them into one canonical task.
        case duplicate(DuplicateMatch)

        /// A task exists in one service but not the other(s).
        /// Proposes adding it to the missing service(s).
        case missingFrom(MissingTask)

        /// A task was completed in one service but not another.
        case completionConflict(CompletionConflict)

        /// Field-level differences between matched tasks (due date, notes, priority).
        case fieldConflict(FieldConflict)
    }

    enum Decision {
        case pending
        case approved
        case rejected
        case modified(CanonicalTask) // user manually edited the merged result
    }

    var isResolved: Bool {
        switch decision {
        case .pending: false
        default: true
        }
    }
}

// MARK: - Action Details

struct DuplicateMatch {
    let taskA: CanonicalTask
    let taskB: CanonicalTask
    /// The proposed merged result, combining the best of both.
    let mergedResult: CanonicalTask
    let confidence: MatchConfidence
}

struct MissingTask {
    let task: CanonicalTask
    /// The service(s) where the task exists.
    let presentIn: [ServiceType]
    /// The service(s) where it's missing.
    let missingFrom: [ServiceType]
}

struct CompletionConflict {
    let task: CanonicalTask
    /// Service where it's marked completed.
    let completedIn: ServiceType
    /// Service where it's still open.
    let openIn: ServiceType
}

struct FieldConflict {
    let tasks: [CanonicalTask]
    let conflictingFields: [ConflictingField]
    let mergedResult: CanonicalTask
    let missingFrom: [ServiceType]
}

struct ConflictingField {
    let fieldName: String
    let entries: [FieldEntry]

    struct FieldEntry: Identifiable {
        let id = UUID()
        let service: ServiceType
        let value: String
        let task: CanonicalTask
    }
}

// MARK: - Match Confidence

enum MatchConfidence: Comparable {
    case exact      // title matches exactly
    case high       // title very similar + other signals
    case medium     // fuzzy title match
    case low        // weak signals only

    var label: String {
        switch self {
        case .exact: "Exact match"
        case .high: "High confidence"
        case .medium: "Medium confidence"
        case .low: "Low confidence"
        }
    }
}

// MARK: - Merge Session

/// Represents a complete merge session -- all proposals from one pull cycle.
struct MergeSession: Identifiable {
    let id: UUID
    let createdDate: Date
    var proposals: [MergeProposal]
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

    /// Count of proposals that actually need pushing (excludes auto-approved exact synced items).
    var pushableCount: Int {
        proposals.filter { proposal in
            switch proposal.decision {
            case .modified: return true
            case .approved:
                // Auto-approved exact duplicates don't need pushing
                if case .duplicate(let match) = proposal.action, match.confidence == .exact {
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

    init(proposals: [MergeProposal], servicesSynced: [ServiceType]) {
        self.id = UUID()
        self.createdDate = Date()
        self.proposals = proposals
        self.servicesSynced = servicesSynced
    }
}
