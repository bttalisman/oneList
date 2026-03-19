import Foundation
import os
import SwiftUI

private let logger = Logger(subsystem: "com.syncemall", category: "EventMergeReview")

@MainActor
@Observable
final class EventMergeReviewViewModel {
    var session: EventMergeSession?
    var isLoading = false
    var errorMessage: String?
    var showingPushConfirmation = false
    var showPushSuccess = false
    var showPaywall = false

    private let services: [any EventServiceProtocol]
    private let engine = EventMergeEngine()
    var linkStore: EventLinkStore?

    /// Most recent pull data, retained for dev snapshot saving.
    private(set) var lastPulledEventsByService: [ServiceType: [CanonicalEvent]] = [:]

    /// Default date range: 2 weeks back, 4 weeks forward
    var pullStartDate: Date = Calendar.current.date(byAdding: .weekOfYear, value: -2, to: Date())!
    var pullEndDate: Date = Calendar.current.date(byAdding: .weekOfYear, value: 4, to: Date())!

    private static let skippedKey = "SyncemAll_SkippedEventTitles"

    private var persistedSkippedTitles: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.skippedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.skippedKey) }
    }

    /// Active pull task — used to deduplicate concurrent pulls and prevent cancellation.
    private var activePull: Task<Void, Never>?

    init(services: [any EventServiceProtocol]) {
        self.services = services
    }

    // MARK: - Pull & Generate Proposals

    func pullAndPropose() async {
        let sub = SubscriptionManager.shared
        guard sub.canSync else {
            showPaywall = true
            return
        }

        if let activePull {
            logger.info("Event pull already in progress, waiting for it...")
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
                }
            }

            logger.info("Connected services with events: \(eventsByService.keys.map(\.displayName))")

            lastPulledEventsByService = eventsByService
            try? DevDataStore.saveEvents(eventsByService)

            guard eventsByService.count >= 2 else {
                logger.warning("Only \(eventsByService.count) calendar service(s) connected — need at least 2")
                if eventsByService.count == 1 {
                    let connectedServices = Array(eventsByService.keys)
                    session = EventMergeSession(proposals: [], servicesSynced: connectedServices)
                } else {
                    session = nil
                    errorMessage = "Connect at least two calendar services to start merging."
                }
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
            for (i, p) in proposals.enumerated() {
                let title = proposalTitle(p) ?? "?"
                let actionType: String
                switch p.action {
                case .synced(let m): actionType = "synced(confidence=\(m.confidence))"
                case .missingFrom(let m): actionType = "missingFrom(\(m.missingFrom.map(\.rawValue)))"
                case .fieldConflict: actionType = "fieldConflict"
                }
                logger.info("  Proposal \(i): '\(title)' action=\(actionType) decision=\(String(describing: p.decision))")
            }
            let connectedServices = Array(eventsByService.keys)
            session = EventMergeSession(proposals: proposals, servicesSynced: connectedServices)
            SubscriptionManager.shared.recordSync()
        } catch {
            logger.error("Event pull failed: \(error.localizedDescription) (type: \(type(of: error)))")
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

    func pushApproved(to providers: Set<ServiceProvider> = Set(ServiceProvider.allCases)) async {
        guard let session else { return }
        isLoading = true
        let allowedServices = Set(providers.flatMap { $0.serviceTypes })
        logger.info("Pushing \(session.approvedCount) approved event proposals to \(providers.map { $0.displayName })...")

        for proposal in session.proposals {
            switch proposal.decision {
            case .approved:
                if case .synced(let match) = proposal.action, match.confidence == .exact {
                    continue
                }
                await pushProposal(proposal, allowedServices: allowedServices)
            case .modified(let customEvent):
                await pushEventToServices(customEvent, allowedServices: allowedServices)
            default:
                continue
            }
        }

        logger.info("Event push complete, re-pulling...")
        let pushedSuccessfully = errorMessage == nil
        await pullAndPropose()
        if pushedSuccessfully {
            showPushSuccess = true
        }
    }

    private func pushProposal(_ proposal: EventMergeProposal, allowedServices: Set<ServiceType>) async {
        switch proposal.action {
        case .synced(let match):
            logger.info("Pushing synced event merge: '\(match.mergedResult.title)'")
            await pushEventToServices(match.mergedResult, allowedServices: allowedServices)

        case .missingFrom(let missing):
            for targetService in missing.missingFrom where allowedServices.contains(targetService) {
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
            await pushEventToServices(conflict.mergedResult, allowedServices: allowedServices)
        }
    }

    private func pushEventToServices(_ event: CanonicalEvent, allowedServices: Set<ServiceType>) async {
        for service in services where allowedServices.contains(service.serviceType) {
            do {
                try await service.pushEvent(event)
                logger.info("Pushed '\(event.title)' to \(service.serviceType.displayName)")
            } catch {
                logger.error("Failed to push '\(event.title)' to \(service.serviceType.displayName): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Delete from Service

    func deleteEventFromService(serviceType: ServiceType, nativeID: String) async {
        guard let service = services.first(where: { $0.serviceType == serviceType }) else {
            logger.error("No service found for \(serviceType.displayName)")
            return
        }
        do {
            try await service.deleteEvent(nativeID: nativeID)
            logger.info("Deleted event (nativeID=\(nativeID)) from \(serviceType.displayName)")

            // Clear the stale nativeID from the link store
            if let linkStore {
                if let link = linkStore.findLink(nativeID: nativeID, service: serviceType) {
                    logger.info("Clearing stale nativeID from event link '\(link.lastKnownTitle)' for \(serviceType.displayName)")
                    switch serviceType {
                    case .appleCalendar: link.appleNativeID = nil
                    case .googleCalendar: link.googleNativeID = nil
                    case .microsoftCalendar: link.microsoftNativeID = nil
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

    // MARK: - Dev Snapshots

    func saveSnapshot() {
        guard !lastPulledEventsByService.isEmpty else {
            errorMessage = "No pulled data to save. Pull first."
            return
        }
        do {
            try DevDataStore.saveEvents(lastPulledEventsByService)
            logger.info("Event snapshot saved")
        } catch {
            logger.error("Failed to save event snapshot: \(error.localizedDescription)")
            errorMessage = "Failed to save snapshot: \(error.localizedDescription)"
        }
    }

    func loadSnapshot(from url: URL? = nil) async {
        isLoading = true
        errorMessage = nil
        do {
            let eventsByService = try DevDataStore.loadEvents(from: url)
            lastPulledEventsByService = eventsByService

            guard eventsByService.count >= 2 else {
                errorMessage = "Snapshot has fewer than 2 services."
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

            let connectedServices = Array(eventsByService.keys)
            session = EventMergeSession(proposals: proposals, servicesSynced: connectedServices)
            logger.info("Loaded event snapshot with \(proposals.count) proposals")
        } catch {
            logger.error("Failed to load event snapshot: \(error.localizedDescription)")
            errorMessage = "Failed to load snapshot: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func proposalTitle(_ proposal: EventMergeProposal) -> String? {
        switch proposal.action {
        case .synced(let match): match.events.first?.title
        case .missingFrom(let missing): missing.event.title
        case .fieldConflict(let conflict): conflict.events.first?.title
        }
    }
}
