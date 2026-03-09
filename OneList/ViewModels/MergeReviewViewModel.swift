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

    /// Active pull task — used to deduplicate concurrent pulls and prevent cancellation.
    private var activePull: Task<Void, Never>?

    init(services: [any TaskServiceProtocol]) {
        self.services = services
    }

    // MARK: - Pull & Generate Proposals

    /// Entry point for pull-to-refresh and .task. Deduplicates concurrent calls
    /// and runs in an unstructured Task so SwiftUI's .refreshable can't cancel
    /// the network requests mid-flight.
    func pullAndPropose() async {
        if let activePull {
            logger.info("Pull already in progress, waiting for it...")
            await activePull.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performPull()
        }
        activePull = task
        await task.value
        activePull = nil
    }

    private func performPull() async {
        isLoading = true
        errorMessage = nil  // Clear stale errors; keep session intact to avoid UI flash
        logger.info("Starting pull & propose...")

        do {
            var tasksByService: [ServiceType: [CanonicalTask]] = [:]

            for service in services {
                let connected = await service.isConnected
                logger.info("\(service.serviceType.displayName) connected: \(connected)")
                guard connected else { continue }
                let tasks = try await service.pullTasks()
                logger.info("Pulled \(tasks.count) tasks from \(service.serviceType.displayName)")
                for task in tasks {
                    logger.debug("  Task: '\(task.title)' due=\(task.dueDate?.description ?? "nil") completed=\(task.isCompleted)")
                }
                tasksByService[service.serviceType] = tasks
            }

            guard tasksByService.count >= 2 else {
                logger.warning("Only \(tasksByService.count) service(s) connected — need at least 2")
                if tasksByService.count == 1 {
                    let connectedServices = Array(tasksByService.keys)
                    session = MergeSession(proposals: [], servicesSynced: connectedServices)
                } else {
                    session = nil
                    errorMessage = "Connect at least two services to start merging."
                }
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
            for (i, p) in proposals.enumerated() {
                let title = proposalTitle(p) ?? "?"
                let actionType: String
                switch p.action {
                case .duplicate(let m): actionType = "duplicate(confidence=\(m.confidence))"
                case .missingFrom(let m): actionType = "missingFrom(\(m.missingFrom.map(\.rawValue)))"
                case .fieldConflict: actionType = "fieldConflict"
                case .completionConflict: actionType = "completionConflict"
                }
                logger.info("  Proposal \(i): '\(title)' action=\(actionType) decision=\(String(describing: p.decision))")
            }
            let connectedServices = Array(tasksByService.keys)
            session = MergeSession(proposals: proposals, servicesSynced: connectedServices)
        } catch {
            logger.error("Pull failed: \(error.localizedDescription) (type: \(type(of: error)))")
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

    func pushApproved(to providers: Set<ServiceProvider> = Set(ServiceProvider.allCases)) async {
        guard let session else { return }
        isLoading = true
        let allowedServices = Set(providers.flatMap { $0.serviceTypes })
        logger.info("Pushing \(session.approvedCount) approved proposals to \(providers.map { $0.displayName })...")

        for proposal in session.proposals {
            switch proposal.decision {
            case .approved:
                // Skip auto-approved exact synced items — nothing to push
                if case .duplicate(let match) = proposal.action, match.confidence == .exact {
                    continue
                }
                await pushProposal(proposal, allowedServices: allowedServices)
            case .modified(let customTask):
                await pushTaskToServices(customTask, allowedServices: allowedServices)
            default:
                continue
            }
        }

        logger.info("Push complete, re-pulling to verify...")
        await pullAndPropose()
    }

    private func pushProposal(_ proposal: MergeProposal, allowedServices: Set<ServiceType>) async {
        switch proposal.action {
        case .duplicate(let match):
            logger.info("Pushing duplicate merge: '\(match.mergedResult.title)'")
            await pushTaskToServices(match.mergedResult, allowedServices: allowedServices)

        case .missingFrom(let missing):
            for targetService in missing.missingFrom where allowedServices.contains(targetService) {
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
            for service in services where allowedServices.contains(service.serviceType) {
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
            await pushTaskToServices(conflict.mergedResult, allowedServices: allowedServices)
        }
    }

    private func pushTaskToServices(_ task: CanonicalTask, allowedServices: Set<ServiceType>) async {
        for service in services where allowedServices.contains(service.serviceType) {
            do {
                try await service.pushTask(task)
                logger.info("Pushed '\(task.title)' to \(service.serviceType.displayName)")
            } catch {
                logger.error("Failed to push '\(task.title)' to \(service.serviceType.displayName): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Delete from Service

    func deleteTaskFromService(serviceType: ServiceType, nativeID: String) async {
        guard let service = services.first(where: { $0.serviceType == serviceType }) else {
            logger.error("No service found for \(serviceType.displayName)")
            return
        }
        do {
            try await service.deleteTask(nativeID: nativeID)
            logger.info("Deleted task (nativeID=\(nativeID)) from \(serviceType.displayName)")

            // Clear the stale nativeID from the link store so it doesn't cause
            // mismatches on the next pull cycle
            if let linkStore {
                if let link = linkStore.findLink(nativeID: nativeID, service: serviceType) {
                    logger.info("Clearing stale nativeID from link '\(link.lastKnownTitle)' for \(serviceType.displayName)")
                    link.setNativeID("", for: serviceType)
                    switch serviceType {
                    case .appleReminders: link.appleNativeID = nil
                    case .googleTasks: link.googleNativeID = nil
                    case .microsoftToDo: link.microsoftNativeID = nil
                    default: break
                    }
                    linkStore.save()
                }
            }
        } catch {
            logger.error("Failed to delete from \(serviceType.displayName): \(error.localizedDescription)")
            errorMessage = "Failed to remove from \(serviceType.displayName): \(error.localizedDescription)"
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
