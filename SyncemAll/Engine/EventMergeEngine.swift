import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "EventMergeEngine")

/// Generates merge proposals by comparing calendar events across services.
/// Uses composite-key matching: title + start time + duration.
struct EventMergeEngine {

    /// Compare events from multiple services and generate proposals.
    @MainActor
    func generateProposals(
        eventsByService: [ServiceType: [CanonicalEvent]],
        linkStore: EventLinkStore?
    ) -> [EventMergeProposal] {
        let services = Array(eventsByService.keys)
        guard services.count >= 2 else { return [] }

        let clusters = buildClusters(
            eventsByService: eventsByService,
            services: services,
            linkStore: linkStore
        )

        if let linkStore {
            persistLinks(clusters: clusters, linkStore: linkStore)
        }

        var proposals: [EventMergeProposal] = []
        let allServices = Set(services)

        for (i, cluster) in clusters.enumerated() {
            let presentIn = Set(cluster.eventsByService.keys)
            let missingFrom = allServices.subtracting(presentIn)
            let title = cluster.allEvents.first?.title ?? "?"
            logger.info("Cluster \(i) '\(title)': services=\(presentIn.map { $0.rawValue }) missingFrom=\(missingFrom.map { $0.rawValue }) confidence=\(String(describing: cluster.confidence)) linkID=\(cluster.linkID?.uuidString ?? "nil")")

            if cluster.eventsByService.count == 1 {
                let (service, events) = cluster.eventsByService.first!
                proposals.append(EventMergeProposal(
                    id: UUID(),
                    action: .missingFrom(MissingEvent(
                        event: events[0],
                        presentIn: [service],
                        missingFrom: Array(missingFrom)
                    )),
                    decision: .pending
                ))
            } else {
                let allEvents = cluster.allEvents
                let proposal = buildClusterProposal(
                    events: allEvents,
                    confidence: cluster.confidence,
                    missingFrom: Array(missingFrom)
                )
                logger.info("  → Proposal for '\(title)': \(String(describing: proposal.action).prefix(60)) decision=\(String(describing: proposal.decision))")
                proposals.append(proposal)
            }
        }

        proposals.sort { a, b in sortOrder(a) < sortOrder(b) }
        return proposals
    }

    // MARK: - Clustering

    private struct EventCluster {
        var eventsByService: [ServiceType: [CanonicalEvent]]
        var confidence: EventMatchConfidence
        var linkID: UUID?

        var allEvents: [CanonicalEvent] {
            eventsByService.values.flatMap { $0 }
        }

        mutating func add(event: CanonicalEvent, service: ServiceType, confidence: EventMatchConfidence) {
            eventsByService[service, default: []].append(event)
            if confidence < self.confidence {
                self.confidence = confidence
            }
        }
    }

    @MainActor
    private func buildClusters(
        eventsByService: [ServiceType: [CanonicalEvent]],
        services: [ServiceType],
        linkStore: EventLinkStore?
    ) -> [EventCluster] {
        var clusters: [EventCluster] = []
        var assignedEventIDs: Set<UUID> = []
        var linkToCluster: [UUID: Int] = [:]

        var allEvents: [(event: CanonicalEvent, service: ServiceType)] = []
        for service in services {
            for event in eventsByService[service] ?? [] {
                allEvents.append((event, service))
            }
        }

        // Pass 1: Build clusters from link-matched events first.
        for (event, service) in allEvents {
            guard !assignedEventIDs.contains(event.id) else { continue }

            if let linkStore, let nativeID = event.serviceOrigins.first?.nativeID {
                if let link = linkStore.findLink(nativeID: nativeID, service: service) {
                    if let clusterIdx = linkToCluster[link.id] {
                        clusters[clusterIdx].add(event: event, service: service, confidence: .exact)
                        assignedEventIDs.insert(event.id)
                        logger.debug("Linked '\(event.title)' to existing cluster via link")
                    } else {
                        var cluster = EventCluster(eventsByService: [:], confidence: .exact, linkID: link.id)
                        cluster.add(event: event, service: service, confidence: .exact)
                        let idx = clusters.count
                        clusters.append(cluster)
                        linkToCluster[link.id] = idx
                        assignedEventIDs.insert(event.id)
                        logger.debug("Started cluster from link for '\(event.title)'")
                    }
                }
            }
        }

        // Pass 2: Composite-key match remaining (unlinked) events against existing clusters.
        for (event, service) in allEvents {
            guard !assignedEventIDs.contains(event.id) else { continue }

            logger.debug("Pass 2: matching '\(event.title)' from \(service.rawValue) (allDay=\(event.isAllDay) start=\(event.startDate) end=\(event.endDate))")

            var matchedClusterIndex: Int?
            var matchConfidence: EventMatchConfidence = .exact

            for (index, cluster) in clusters.enumerated() {
                for existingEvent in cluster.allEvents {
                    if let confidence = compositeMatch(event, existingEvent) {
                        logger.debug("  Composite match found: '\(event.title)' ~ '\(existingEvent.title)' confidence=\(String(describing: confidence))")
                        if matchedClusterIndex == nil || confidence > matchConfidence {
                            matchedClusterIndex = index
                            matchConfidence = confidence
                        }
                    }
                }
                if matchedClusterIndex == index && matchConfidence == .exact {
                    break
                }
            }

            if let clusterIndex = matchedClusterIndex {
                logger.debug("  → Joined cluster \(clusterIndex) for '\(event.title)' with confidence=\(String(describing: matchConfidence))")
                clusters[clusterIndex].add(event: event, service: service, confidence: matchConfidence)
            } else {
                logger.debug("  → No match found, creating new cluster for '\(event.title)'")
                var cluster = EventCluster(eventsByService: [:], confidence: .exact, linkID: nil)
                cluster.add(event: event, service: service, confidence: .exact)
                clusters.append(cluster)
            }
            assignedEventIDs.insert(event.id)
        }

        return clusters
    }

    // MARK: - Composite Key Matching

    /// Match events by title + start time + duration.
    private func compositeMatch(_ a: CanonicalEvent, _ b: CanonicalEvent) -> EventMatchConfidence? {
        let titleA = normalize(a.title)
        let titleB = normalize(b.title)
        guard !titleA.isEmpty, !titleB.isEmpty else { return nil }

        let titlesMatch = titleA == titleB
        let titlesFuzzy = !titlesMatch && fuzzyTitleMatch(titleA, titleB)
        guard titlesMatch || titlesFuzzy else { return nil }

        let startDiff = abs(a.startDate.timeIntervalSince(b.startDate))
        let durationA = a.endDate.timeIntervalSince(a.startDate)
        let durationB = b.endDate.timeIntervalSince(b.startDate)
        let durationDiff = abs(durationA - durationB)

        // For all-day events, match on title + same calendar date.
        // Use UTC calendar because services store all-day starts differently:
        // Apple uses midnight local (e.g., 07:00 UTC for Pacific), Microsoft uses 00:00 UTC.
        if a.isAllDay && b.isAllDay {
            var utcCal = Calendar.current
            utcCal.timeZone = TimeZone(identifier: "UTC")!
            let dayA = utcCal.dateComponents([.year, .month, .day], from: a.startDate)
            let dayB = utcCal.dateComponents([.year, .month, .day], from: b.startDate)
            // Allow ±1 day difference to handle timezone edge cases
            let sameDay = dayA == dayB
            let adjacentDay = abs(utcCal.dateComponents([.day], from: a.startDate, to: b.startDate).day ?? 99) <= 1
            if sameDay && titlesMatch { return .exact }
            if adjacentDay && titlesMatch { return .high }
            if sameDay && titlesFuzzy { return .medium }
            if adjacentDay && titlesFuzzy { return .low }
            return nil
        }

        // Exact: same title, start within 1 minute, duration within 5 minutes
        if titlesMatch && startDiff < 60 && durationDiff < 300 {
            return .exact
        }

        // High: same title, start within 5 minutes
        if titlesMatch && startDiff < 300 {
            return .high
        }

        // Medium: fuzzy title or start within 15 minutes
        if titlesMatch && startDiff < 900 {
            return .medium
        }
        if titlesFuzzy && startDiff < 300 {
            return .medium
        }

        // Low: fuzzy title + same day
        if titlesFuzzy && Calendar.current.isDate(a.startDate, inSameDayAs: b.startDate) {
            return .low
        }

        return nil
    }

    private func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func fuzzyTitleMatch(_ a: String, _ b: String) -> Bool {
        let distance = levenshteinDistance(a, b)
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return false }
        let similarity = 1.0 - (Double(distance) / Double(maxLen))
        return similarity >= 0.80
    }

    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[n]
    }

    // MARK: - Link Persistence

    @MainActor
    private func persistLinks(clusters: [EventCluster], linkStore: EventLinkStore) {
        for cluster in clusters {
            guard cluster.eventsByService.count >= 2 else { continue }

            let link: EventLink
            if let linkID = cluster.linkID, let existing = linkStore.findLink(id: linkID) {
                link = existing
            } else {
                let title = cluster.allEvents.first?.title ?? "Unknown"
                let startDate = cluster.allEvents.first?.startDate
                link = EventLink(lastKnownTitle: title, lastKnownStartDate: startDate)
                linkStore.insert(link)
                logger.info("Created new EventLink for '\(title)'")
            }

            for (service, events) in cluster.eventsByService {
                if let nativeID = events.first?.serviceOrigins.first?.nativeID {
                    link.setNativeID(nativeID, for: service)
                }
            }
            link.lastKnownTitle = cluster.allEvents.first?.title ?? link.lastKnownTitle
            link.lastKnownStartDate = cluster.allEvents.first?.startDate
        }

        linkStore.save()
    }

    // MARK: - Cluster Proposal Building

    private func buildClusterProposal(
        events: [CanonicalEvent],
        confidence: EventMatchConfidence,
        missingFrom: [ServiceType]
    ) -> EventMergeProposal {
        // Check field conflicts
        let allConflicts = detectClusterConflicts(events: events)

        if !allConflicts.isEmpty {
            let merged = mergeAllEvents(events)
            return EventMergeProposal(
                id: UUID(),
                action: .fieldConflict(EventFieldConflict(
                    events: events,
                    conflictingFields: allConflicts,
                    mergedResult: merged,
                    missingFrom: missingFrom
                )),
                decision: .pending
            )
        }

        // If synced across some services but missing from others, show as missing
        let merged = mergeAllEvents(events)
        if !missingFrom.isEmpty {
            let presentServices = events.compactMap { $0.serviceOrigins.first?.service }
            let uniquePresent = presentServices.reduce(into: [ServiceType]()) { if !$0.contains($1) { $0.append($1) } }
            return EventMergeProposal(
                id: UUID(),
                action: .missingFrom(MissingEvent(
                    event: merged,
                    presentIn: uniquePresent,
                    missingFrom: missingFrom
                )),
                decision: .pending
            )
        }

        // Fully synced across all services
        let decision: EventMergeProposal.Decision = confidence == .exact ? .approved : .pending
        return EventMergeProposal(
            id: UUID(),
            action: .synced(EventMatch(
                events: events,
                mergedResult: merged,
                confidence: confidence
            )),
            decision: decision
        )
    }

    // MARK: - N-Way Conflict Detection

    private func detectClusterConflicts(events: [CanonicalEvent]) -> [EventConflictingField] {
        var conflicts: [EventConflictingField] = []

        var eventPerService: [(service: ServiceType, event: CanonicalEvent)] = []
        var seenServices: Set<ServiceType> = []
        for event in events {
            if let service = event.serviceOrigins.first?.service, !seenServices.contains(service) {
                eventPerService.append((service, event))
                seenServices.insert(service)
            }
        }

        guard eventPerService.count >= 2 else { return [] }

        // Title
        let distinctTitles = Set(eventPerService.map { normalize($0.event.title) })
        if distinctTitles.count > 1 {
            conflicts.append(EventConflictingField(
                fieldName: "Title",
                entries: eventPerService.map { entry in
                    EventConflictingField.FieldEntry(
                        service: entry.service, value: entry.event.title, event: entry.event
                    )
                }
            ))
        }

        // Location
        let locations = eventPerService.map { ($0, $0.event.location ?? "") }
        let distinctLocations = Set(locations.map { $0.1 })
        if distinctLocations.count > 1 && !(distinctLocations.count == 1 && distinctLocations.first == "") {
            conflicts.append(EventConflictingField(
                fieldName: "Location",
                entries: eventPerService.map { entry in
                    let loc = entry.event.location ?? ""
                    return EventConflictingField.FieldEntry(
                        service: entry.service,
                        value: loc.isEmpty ? "(none)" : loc,
                        event: entry.event
                    )
                }
            ))
        }

        // Notes
        let notes = eventPerService.map { ($0, $0.event.notes ?? "") }
        let distinctNotes = Set(notes.map { $0.1 })
        if distinctNotes.count > 1 && !(distinctNotes.count == 1 && distinctNotes.first == "") {
            conflicts.append(EventConflictingField(
                fieldName: "Notes",
                entries: eventPerService.map { entry in
                    let n = entry.event.notes ?? ""
                    return EventConflictingField.FieldEntry(
                        service: entry.service,
                        value: n.isEmpty ? "(empty)" : String(n.prefix(50)),
                        event: entry.event
                    )
                }
            ))
        }

        // End time — skip for all-day events (services represent end differently)
        let anyAllDay = eventPerService.contains { $0.event.isAllDay }
        if !anyAllDay {
            let endTimes = eventPerService.map { $0.event.endDate }
            // Use 2-minute tolerance to handle Apple 11:59 PM vs Google 12:00 AM differences
            let allSameEnd = endTimes.allSatisfy { abs($0.timeIntervalSince(endTimes[0])) < 120 }
            if !allSameEnd {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                conflicts.append(EventConflictingField(
                    fieldName: "End Time",
                    entries: eventPerService.map { entry in
                        EventConflictingField.FieldEntry(
                            service: entry.service,
                            value: formatter.string(from: entry.event.endDate),
                            event: entry.event
                        )
                    }
                ))
            }
        }

        return conflicts
    }

    // MARK: - Merging

    private func mergeAllEvents(_ events: [CanonicalEvent]) -> CanonicalEvent {
        guard var result = events.first else { fatalError("Empty event list") }
        for event in events.dropFirst() {
            result = mergeEvent(a: result, b: event)
        }
        return result
    }

    private func mergeEvent(a: CanonicalEvent, b: CanonicalEvent) -> CanonicalEvent {
        let newer = (a.lastModifiedDate ?? .distantPast) >= (b.lastModifiedDate ?? .distantPast) ? a : b
        let older = (newer.id == a.id) ? b : a

        return CanonicalEvent(
            title: newer.title,
            notes: longerString(newer.notes, older.notes),
            startDate: newer.startDate,
            endDate: newer.endDate,
            isAllDay: newer.isAllDay,
            location: newer.location ?? older.location,
            timeZone: newer.timeZone ?? older.timeZone,
            createdDate: earlierDate(a.createdDate, b.createdDate),
            lastModifiedDate: laterDate(a.lastModifiedDate, b.lastModifiedDate),
            serviceOrigins: deduplicateOrigins(a.serviceOrigins + b.serviceOrigins)
        )
    }

    /// Keep only one origin per service (prefer the one with more recent sync date).
    private func deduplicateOrigins(_ origins: [ServiceOrigin]) -> [ServiceOrigin] {
        var seen: [ServiceType: ServiceOrigin] = [:]
        for origin in origins {
            if let existing = seen[origin.service] {
                if (origin.lastSyncedDate ?? .distantPast) > (existing.lastSyncedDate ?? .distantPast) {
                    seen[origin.service] = origin
                }
            } else {
                seen[origin.service] = origin
            }
        }
        return Array(seen.values)
    }

    private func longerString(_ a: String?, _ b: String?) -> String? {
        switch (a, b) {
        case (nil, nil): nil
        case (let s?, nil): s
        case (nil, let s?): s
        case (let s1?, let s2?): s1.count >= s2.count ? s1 : s2
        }
    }

    private func earlierDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (nil, nil): nil
        case (let d?, nil): d
        case (nil, let d?): d
        case (let d1?, let d2?): min(d1, d2)
        }
    }

    private func laterDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (nil, nil): nil
        case (let d?, nil): d
        case (nil, let d?): d
        case (let d1?, let d2?): max(d1, d2)
        }
    }

    // MARK: - Sort

    private func sortOrder(_ proposal: EventMergeProposal) -> Int {
        switch proposal.action {
        case .synced: 0
        case .fieldConflict: 1
        case .missingFrom: 2
        }
    }
}
