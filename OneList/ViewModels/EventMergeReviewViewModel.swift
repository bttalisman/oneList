import Foundation
import os
import SwiftUI

private let logger = Logger(subsystem: "com.onelist", category: "EventMergeReview")

@MainActor
@Observable
final class EventMergeReviewViewModel {
    var session: EventMergeSession?
    var isLoading = false
    var errorMessage: String?
    var showingPushConfirmation = false

    private let services: [any EventServiceProtocol]
    private let engine = EventMergeEngine()
    var linkStore: EventLinkStore?

    /// Default date range: 2 weeks back, 4 weeks forward
    var pullStartDate: Date = Calendar.current.date(byAdding: .weekOfYear, value: -2, to: Date())!
    var pullEndDate: Date = Calendar.current.date(byAdding: .weekOfYear, value: 4, to: Date())!

    private static let skippedKey = "OneList_SkippedEventTitles"

    private var persistedSkippedTitles: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.skippedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.skippedKey) }
    }

    init(services: [any EventServiceProtocol]) {
        self.services = services
    }

    // MARK: - Pull & Generate Proposals

    func pullAndPropose() async {
        isLoading = true
        errorMessage = nil
        logger.info("Starting event pull & propose with \(self.services.count) registered services...")
        logger.info("Date range: \(self.pullStartDate) to \(self.pullEndDate)")
        logger.info("LinkStore available: \(self.linkStore != nil)")

        do {
            var eventsByService: [ServiceType: [CanonicalEvent]] = [:]

            for service in services {
                logger.info("Checking \(service.serviceType.displayName)...")
                let connected = await service.isConnected
                logger.info("  \(service.serviceType.displayName) connected: \(connected)")
                guard connected else {
                    logger.info("  Skipping \(service.serviceType.displayName) — not connected")
                    continue
                }
                do {
                    let events = try await service.pullEvents(from: pullStartDate, to: pullEndDate)
                    logger.info("  Pulled \(events.count) events from \(service.serviceType.displayName)")
                    for event in events.prefix(5) {
                        logger.debug("    Event: '\(event.title)' at \(event.startDate)")
                    }
                    if events.count > 5 {
                        logger.debug("    ... and \(events.count - 5) more")
                    }
                    eventsByService[service.serviceType] = events
                } catch {
                    logger.error("  Failed to pull from \(service.serviceType.displayName): \(error.localizedDescription)")
                    // Continue with other services instead of failing entirely
                }
            }

            logger.info("Connected services with events: \(eventsByService.keys.map(\.displayName))")

            guard eventsByService.count >= 2 else {
                let msg = "Connect at least two calendar services to start merging. (\(eventsByService.count) connected)"
                logger.warning("\(msg)")
                errorMessage = msg
                isLoading = false
                return
            }

            var proposals = engine.generateProposals(
                eventsByService: eventsByService,
                linkStore: linkStore
            )

            let skippedTitles = persistedSkippedTitles
            for i in proposals.indices {
                if let title = proposalTitle(proposals[i]), skippedTitles.contains(title) {
                    proposals[i].decision = .rejected
                }
            }

            logger.info("Generated \(proposals.count) event merge proposals")
            let connectedServices = Array(eventsByService.keys)
            session = EventMergeSession(proposals: proposals, servicesSynced: connectedServices)
        } catch {
            logger.error("Event pull failed: \(error.localizedDescription)")
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

    func resolveProposal(id: UUID, decision: EventMergeProposal.Decision) {
        guard session != nil,
              let idx = session!.proposals.firstIndex(where: { $0.id == id })
        else { return }
        session!.proposals[idx].decision = decision
    }

    // MARK: - Push

    func pushApproved() async {
        guard let session else { return }
        isLoading = true
        logger.info("Pushing \(session.approvedCount) approved event proposals...")

        for proposal in session.proposals {
            switch proposal.decision {
            case .approved:
                if case .synced(let match) = proposal.action, match.confidence == .exact {
                    continue
                }
                await pushProposal(proposal)
            case .modified(let customEvent):
                await pushEventToAllServices(customEvent)
            default:
                continue
            }
        }

        logger.info("Event push complete, re-pulling...")
        await pullAndPropose()
    }

    private func pushProposal(_ proposal: EventMergeProposal) async {
        switch proposal.action {
        case .synced(let match):
            logger.info("Pushing synced event merge: '\(match.mergedResult.title)'")
            await pushEventToAllServices(match.mergedResult)

        case .missingFrom(let missing):
            for targetService in missing.missingFrom {
                logger.info("Pushing '\(missing.event.title)' to \(targetService.displayName)")
                if let service = services.first(where: { $0.serviceType == targetService }) {
                    do {
                        try await service.pushEvent(missing.event)
                    } catch {
                        logger.error("Failed to push '\(missing.event.title)' to \(targetService.displayName): \(error.localizedDescription)")
                        errorMessage = "Failed to push '\(missing.event.title)': \(error.localizedDescription)"
                    }
                }
            }

        case .fieldConflict(let conflict):
            logger.info("Pushing field conflict merge: '\(conflict.mergedResult.title)'")
            await pushEventToAllServices(conflict.mergedResult)
        }
    }

    private func pushEventToAllServices(_ event: CanonicalEvent) async {
        for service in services {
            do {
                try await service.pushEvent(event)
                logger.info("Pushed '\(event.title)' to \(service.serviceType.displayName)")
            } catch {
                logger.error("Failed to push '\(event.title)' to \(service.serviceType.displayName): \(error.localizedDescription)")
            }
        }
    }

    private func proposalTitle(_ proposal: EventMergeProposal) -> String? {
        switch proposal.action {
        case .synced(let match): match.events.first?.title
        case .missingFrom(let missing): missing.event.title
        case .fieldConflict(let conflict): conflict.events.first?.title
        }
    }
}
