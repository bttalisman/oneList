import Foundation
import os
import SwiftUI

private let logger = Logger(subsystem: "com.onelist", category: "MergeReview")

@MainActor
@Observable
final class MergeReviewViewModel {
    var session: MergeSession?
    var isLoading = false
    var errorMessage: String?
    var showingPushConfirmation = false

    private let services: [any TaskServiceProtocol]
    private let engine = MergeEngine()
    var linkStore: TaskLinkStore?

    private static let skippedKey = "OneList_SkippedTitles"

    private var persistedSkippedTitles: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.skippedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.skippedKey) }
    }

    init(services: [any TaskServiceProtocol]) {
        self.services = services
    }

    // MARK: - Pull & Generate Proposals

    func pullAndPropose() async {
        isLoading = true
        errorMessage = nil
        logger.info("Starting pull & propose...")

        do {
            var tasksByService: [ServiceType: [CanonicalTask]] = [:]

            for service in services {
                let connected = await service.isConnected
                logger.info("\(service.serviceType.displayName) connected: \(connected)")
                guard connected else { continue }
                let tasks = try await service.pullTasks()
                logger.info("Pulled \(tasks.count) tasks from \(service.serviceType.displayName)")
                tasksByService[service.serviceType] = tasks
            }

            guard tasksByService.count >= 2 else {
                let msg = "Connect at least two services to start merging. (\(tasksByService.count) connected)"
                logger.warning("\(msg)")
                errorMessage = msg
                isLoading = false
                return
            }

            var proposals = engine.generateProposals(
                tasksByService: tasksByService,
                linkStore: linkStore
            )

            // Restore skipped decisions from persisted storage
            let skippedTitles = persistedSkippedTitles
            for i in proposals.indices {
                if let title = proposalTitle(proposals[i]), skippedTitles.contains(title) {
                    proposals[i].decision = .rejected
                }
            }

            logger.info("Generated \(proposals.count) merge proposals")
            let connectedServices = Array(tasksByService.keys)
            session = MergeSession(proposals: proposals, servicesSynced: connectedServices)
        } catch {
            logger.error("Pull failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Bulk Actions

    func approveAll() {
        guard session != nil else { return }
        for i in session!.proposals.indices {
            if case .pending = session!.proposals[i].decision {
                session!.proposals[i].decision = .approved
            }
        }
    }

    func approveProposal(id: UUID) {
        guard session != nil,
              let idx = session!.proposals.firstIndex(where: { $0.id == id })
        else { return }
        session!.proposals[idx].decision = .approved
        if let title = proposalTitle(session!.proposals[idx]) {
            persistedSkippedTitles.remove(title)
        }
    }

    func rejectProposal(id: UUID) {
        guard session != nil,
              let idx = session!.proposals.firstIndex(where: { $0.id == id })
        else { return }
        session!.proposals[idx].decision = .rejected
        if let title = proposalTitle(session!.proposals[idx]) {
            persistedSkippedTitles.insert(title)
        }
    }

    func resolveProposal(id: UUID, decision: MergeProposal.Decision) {
        guard session != nil,
              let idx = session!.proposals.firstIndex(where: { $0.id == id })
        else { return }
        session!.proposals[idx].decision = decision
    }

    // MARK: - Push

    func pushApproved() async {
        guard let session else { return }
        isLoading = true
        logger.info("Pushing \(session.approvedCount) approved proposals...")

        for proposal in session.proposals {
            switch proposal.decision {
            case .approved:
                // Skip auto-approved exact synced items — nothing to push
                if case .duplicate(let match) = proposal.action, match.confidence == .exact {
                    continue
                }
                await pushProposal(proposal)
            case .modified(let customTask):
                await pushTaskToAllServices(customTask)
            default:
                continue
            }
        }

        logger.info("Push complete, re-pulling to verify...")
        await pullAndPropose()
    }

    private func pushProposal(_ proposal: MergeProposal) async {
        switch proposal.action {
        case .duplicate(let match):
            logger.info("Pushing duplicate merge: '\(match.mergedResult.title)'")
            await pushTaskToAllServices(match.mergedResult)

        case .missingFrom(let missing):
            for targetService in missing.missingFrom {
                logger.info("Pushing '\(missing.task.title)' to \(targetService.displayName)")
                if let service = services.first(where: { $0.serviceType == targetService }) {
                    do {
                        try await service.pushTask(missing.task)
                        logger.info("Successfully pushed '\(missing.task.title)' to \(targetService.displayName)")
                    } catch {
                        logger.error("Failed to push '\(missing.task.title)' to \(targetService.displayName): \(error.localizedDescription)")
                        errorMessage = "Failed to push '\(missing.task.title)': \(error.localizedDescription)"
                    }
                } else {
                    logger.error("No service found for \(targetService.displayName)")
                }
            }

        case .completionConflict(let conflict):
            for service in services {
                if let origin = conflict.task.serviceOrigins.first(where: { $0.service == service.serviceType }) {
                    do {
                        try await service.completeTask(nativeID: origin.nativeID)
                        logger.info("Completed '\(conflict.task.title)' in \(service.serviceType.displayName)")
                    } catch {
                        logger.error("Failed to complete task: \(error.localizedDescription)")
                    }
                }
            }

        case .fieldConflict(let conflict):
            logger.info("Pushing field conflict merge: '\(conflict.mergedResult.title)'")
            await pushTaskToAllServices(conflict.mergedResult)
        }
    }

    private func pushTaskToAllServices(_ task: CanonicalTask) async {
        for service in services {
            do {
                try await service.pushTask(task)
                logger.info("Pushed '\(task.title)' to \(service.serviceType.displayName)")
            } catch {
                logger.error("Failed to push '\(task.title)' to \(service.serviceType.displayName): \(error.localizedDescription)")
            }
        }
    }

    /// Extract the primary task title from any proposal type.
    private func proposalTitle(_ proposal: MergeProposal) -> String? {
        switch proposal.action {
        case .duplicate(let match): match.taskA.title
        case .missingFrom(let missing): missing.task.title
        case .completionConflict(let conflict): conflict.task.title
        case .fieldConflict(let conflict): conflict.tasks.first?.title
        }
    }
}
