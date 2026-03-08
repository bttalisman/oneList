import Foundation
import os

private let logger = Logger(subsystem: "com.onelist", category: "MergeEngine")

/// Generates merge proposals by comparing tasks across services.
/// Uses persistent TaskLinks for known relationships, falls back to title matching for new tasks.
struct MergeEngine {

    /// Compare tasks from multiple services and generate proposals.
    /// Uses linkStore (if available) to identify previously-linked tasks regardless of title changes.
    @MainActor
    func generateProposals(
        tasksByService: [ServiceType: [CanonicalTask]],
        linkStore: TaskLinkStore?
    ) -> [MergeProposal] {
        let services = Array(tasksByService.keys)
        guard services.count >= 2 else { return [] }

        // Step 1: Build clusters — group tasks that represent the same item
        let clusters = buildClusters(
            tasksByService: tasksByService,
            services: services,
            linkStore: linkStore
        )

        // Step 2: Persist any new/updated links
        if let linkStore {
            persistLinks(clusters: clusters, linkStore: linkStore)
        }

        // Step 3: Generate one proposal per cluster
        var proposals: [MergeProposal] = []
        let allServices = Set(services)

        for cluster in clusters {
            let presentIn = Set(cluster.tasksByService.keys)
            let missingFrom = allServices.subtracting(presentIn)

            if cluster.tasksByService.count == 1 {
                let (service, tasks) = cluster.tasksByService.first!
                proposals.append(MergeProposal(
                    id: UUID(),
                    action: .missingFrom(MissingTask(
                        task: tasks[0],
                        presentIn: service,
                        missingFrom: Array(missingFrom)
                    )),
                    decision: .pending
                ))
            } else {
                let allTasks = cluster.allTasks
                let proposal = buildClusterProposal(
                    tasks: allTasks,
                    confidence: cluster.confidence,
                    missingFrom: Array(missingFrom)
                )
                proposals.append(proposal)
            }
        }

        proposals.sort { a, b in sortOrder(a) < sortOrder(b) }
        return proposals
    }

    // MARK: - Clustering

    private struct TaskCluster {
        var tasksByService: [ServiceType: [CanonicalTask]]
        var confidence: MatchConfidence
        var linkID: UUID? // associated TaskLink ID, if any

        var allTasks: [CanonicalTask] {
            tasksByService.values.flatMap { $0 }
        }

        mutating func add(task: CanonicalTask, service: ServiceType, confidence: MatchConfidence) {
            tasksByService[service, default: []].append(task)
            if confidence < self.confidence {
                self.confidence = confidence
            }
        }
    }

    @MainActor
    private func buildClusters(
        tasksByService: [ServiceType: [CanonicalTask]],
        services: [ServiceType],
        linkStore: TaskLinkStore?
    ) -> [TaskCluster] {
        var clusters: [TaskCluster] = []
        var assignedTaskIDs: Set<UUID> = []
        // Map from TaskLink.id to cluster index for link-based grouping
        var linkToCluster: [UUID: Int] = [:]

        // Flatten all tasks with their service
        var allTasks: [(task: CanonicalTask, service: ServiceType)] = []
        for service in services {
            for task in tasksByService[service] ?? [] {
                allTasks.append((task, service))
            }
        }

        for (task, service) in allTasks {
            guard !assignedTaskIDs.contains(task.id) else { continue }

            // First: try to find an existing link by native ID
            if let linkStore, let nativeID = task.serviceOrigins.first?.nativeID {
                if let link = linkStore.findLink(nativeID: nativeID, service: service) {
                    if let clusterIdx = linkToCluster[link.id] {
                        // Add to existing cluster
                        clusters[clusterIdx].add(task: task, service: service, confidence: .exact)
                        assignedTaskIDs.insert(task.id)
                        logger.debug("Linked '\(task.title)' to existing cluster via link '\(link.lastKnownTitle)'")
                        continue
                    } else {
                        // Start a new cluster from this link
                        var cluster = TaskCluster(tasksByService: [:], confidence: .exact, linkID: link.id)
                        cluster.add(task: task, service: service, confidence: .exact)
                        let idx = clusters.count
                        clusters.append(cluster)
                        linkToCluster[link.id] = idx
                        assignedTaskIDs.insert(task.id)
                        logger.debug("Started cluster from link for '\(task.title)'")
                        continue
                    }
                }
            }

            // Second: try to match by title against existing clusters
            var matchedClusterIndex: Int?
            var matchConfidence: MatchConfidence = .exact

            for (index, cluster) in clusters.enumerated() {
                for existingTask in cluster.allTasks {
                    let titleA = normalize(task.title)
                    let titleB = normalize(existingTask.title)
                    guard !titleA.isEmpty, !titleB.isEmpty else { continue }

                    if titleA == titleB {
                        matchedClusterIndex = index
                        matchConfidence = .exact
                        break
                    } else if let confidence = fuzzyMatch(titleA, titleB) {
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
                clusters[clusterIndex].add(task: task, service: service, confidence: matchConfidence)
            } else {
                var cluster = TaskCluster(tasksByService: [:], confidence: .exact, linkID: nil)
                cluster.add(task: task, service: service, confidence: .exact)
                clusters.append(cluster)
            }
            assignedTaskIDs.insert(task.id)
        }

        return clusters
    }

    // MARK: - Link Persistence

    @MainActor
    private func persistLinks(clusters: [TaskCluster], linkStore: TaskLinkStore) {
        for cluster in clusters {
            guard cluster.tasksByService.count >= 2 else { continue }

            // Find or create a link for this cluster
            let link: TaskLink
            if let linkID = cluster.linkID, let existing = linkStore.findLink(id: linkID) {
                link = existing
            } else {
                let title = cluster.allTasks.first?.title ?? "Unknown"
                link = TaskLink(lastKnownTitle: title)
                linkStore.insert(link)
                logger.info("Created new TaskLink for '\(title)'")
            }

            // Update native IDs from all tasks in the cluster
            for (service, tasks) in cluster.tasksByService {
                if let nativeID = tasks.first?.serviceOrigins.first?.nativeID {
                    link.setNativeID(nativeID, for: service)
                }
            }
            link.lastKnownTitle = cluster.allTasks.first?.title ?? link.lastKnownTitle
        }

        linkStore.save()
    }

    // MARK: - Cluster Proposal Building

    private func buildClusterProposal(
        tasks: [CanonicalTask],
        confidence: MatchConfidence,
        missingFrom: [ServiceType]
    ) -> MergeProposal {
        // Check completion conflict across all copies
        let completedTasks = tasks.filter { $0.isCompleted }
        let openTasks = tasks.filter { !$0.isCompleted }
        if !completedTasks.isEmpty && !openTasks.isEmpty {
            let completedService = completedTasks[0].serviceOrigins.first?.service ?? .appleReminders
            let openService = openTasks[0].serviceOrigins.first?.service ?? .googleTasks
            return MergeProposal(
                id: UUID(),
                action: .completionConflict(CompletionConflict(
                    task: tasks[0], completedIn: completedService, openIn: openService
                )),
                decision: .pending
            )
        }

        // Check field conflicts across all unique service pairs
        let allConflicts = detectClusterConflicts(tasks: tasks)

        if !allConflicts.isEmpty {
            for c in allConflicts {
                let values = c.entries.map { "'\($0.value)' (\($0.service.displayName))" }.joined(separator: " vs ")
                logger.info("[MergeEngine] Conflict in '\(tasks[0].title)' field=\(c.fieldName): \(values)")
            }
            let merged = mergeAllTasks(tasks)
            return MergeProposal(
                id: UUID(),
                action: .fieldConflict(FieldConflict(
                    tasks: tasks,
                    conflictingFields: allConflicts,
                    mergedResult: merged
                )),
                decision: .pending
            )
        }

        // Clean duplicate
        let merged = mergeAllTasks(tasks)
        let decision: MergeProposal.Decision = confidence == .exact ? .approved : .pending
        return MergeProposal(
            id: UUID(),
            action: .duplicate(DuplicateMatch(
                taskA: tasks[0],
                taskB: tasks.count > 1 ? tasks[1] : tasks[0],
                mergedResult: merged,
                confidence: confidence
            )),
            decision: decision
        )
    }

    // MARK: - N-Way Conflict Detection

    /// Detect field conflicts across all tasks in a cluster, returning one ConflictingField per field
    /// with entries for each distinct value.
    private func detectClusterConflicts(tasks: [CanonicalTask]) -> [ConflictingField] {
        var conflicts: [ConflictingField] = []

        // Group tasks by service (take first per service)
        var taskPerService: [(service: ServiceType, task: CanonicalTask)] = []
        var seenServices: Set<ServiceType> = []
        for task in tasks {
            if let service = task.serviceOrigins.first?.service, !seenServices.contains(service) {
                taskPerService.append((service, task))
                seenServices.insert(service)
            }
        }

        guard taskPerService.count >= 2 else { return [] }

        // Priority — only compare services that support it
        let priorityEntries = taskPerService.filter { $0.service.supportsPriority }
        if priorityEntries.count >= 2 {
            let distinct = Set(priorityEntries.map { $0.task.priority })
            if distinct.count > 1 {
                // Skip unresolvable conflicts caused by MS To Do mapping medium→normal→none
                let hasMSToDo = priorityEntries.contains { $0.service == .microsoftToDo }
                let isOnlyMediumVsNone = distinct == Set([.medium, .none])
                if hasMSToDo && isOnlyMediumVsNone {
                    logger.info("Skipping priority conflict (medium vs none) — MS To Do cannot represent medium")
                } else {
                    conflicts.append(ConflictingField(
                        fieldName: "Priority",
                        entries: priorityEntries.map { entry in
                            ConflictingField.FieldEntry(
                                service: entry.service,
                                value: entry.task.priority.label,
                                task: entry.task
                            )
                        }
                    ))
                }
            }
        }

        // Notes
        let noteValues = taskPerService.map { ($0, $0.task.notes ?? "") }
        let distinctNotes = Set(noteValues.map { $0.1 })
        if distinctNotes.count > 1 && !(distinctNotes.count == 1 && distinctNotes.first == "") {
            let nonEmpty = noteValues.filter { !$0.1.isEmpty || distinctNotes.count == noteValues.count }
            if Set(nonEmpty.map { $0.1 }).count > 1 || (nonEmpty.count != noteValues.count) {
                conflicts.append(ConflictingField(
                    fieldName: "Notes",
                    entries: taskPerService.map { entry in
                        let notes = entry.task.notes ?? ""
                        return ConflictingField.FieldEntry(
                            service: entry.service,
                            value: notes.isEmpty ? "(empty)" : String(notes.prefix(50)),
                            task: entry.task
                        )
                    }
                ))
            }
        }

        // Due Date
        let dateEntries = taskPerService.map { ($0, $0.task.dueDate) }
        let allSameDay = dateEntries.allSatisfy { entry in
            sameDayOrBothNil(entry.1, dateEntries[0].1)
        }
        if !allSameDay {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            conflicts.append(ConflictingField(
                fieldName: "Due Date",
                entries: taskPerService.map { entry in
                    ConflictingField.FieldEntry(
                        service: entry.service,
                        value: entry.task.dueDate.map { formatter.string(from: $0) } ?? "(none)",
                        task: entry.task
                    )
                }
            ))
        }

        // Title (for link-based clusters where titles may differ)
        let distinctTitles = Set(taskPerService.map { normalize($0.task.title) })
        if distinctTitles.count > 1 {
            conflicts.append(ConflictingField(
                fieldName: "Title",
                entries: taskPerService.map { entry in
                    ConflictingField.FieldEntry(
                        service: entry.service,
                        value: entry.task.title,
                        task: entry.task
                    )
                }
            ))
        }

        return conflicts
    }

    // MARK: - Fuzzy Matching

    private func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func fuzzyMatch(_ a: String, _ b: String) -> MatchConfidence? {
        if a == b { return nil }

        let distance = levenshteinDistance(a, b)
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return nil }

        let similarity = 1.0 - (Double(distance) / Double(maxLen))

        if similarity >= 0.85 { return .high }
        if similarity >= 0.70 { return .medium }
        if similarity >= 0.55 && maxLen >= 8 { return .low }

        return nil
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
                curr[j] = min(
                    prev[j] + 1,
                    curr[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            prev = curr
        }

        return prev[n]
    }

    // MARK: - Merging

    private func mergeAllTasks(_ tasks: [CanonicalTask]) -> CanonicalTask {
        guard var result = tasks.first else { fatalError("Empty task list") }
        for task in tasks.dropFirst() {
            result = mergeTask(taskA: result, taskB: task)
        }
        return result
    }

    private func mergeTask(taskA: CanonicalTask, taskB: CanonicalTask) -> CanonicalTask {
        let newer = newerTask(taskA, taskB)
        let older = (newer.id == taskA.id) ? taskB : taskA

        return CanonicalTask(
            title: newer.title,
            notes: longerString(newer.notes, older.notes),
            isCompleted: newer.isCompleted,
            dueDate: newer.dueDate ?? older.dueDate,
            priority: max(newer.priority, older.priority),
            createdDate: earlierDate(taskA.createdDate, taskB.createdDate),
            lastModifiedDate: laterDate(taskA.lastModifiedDate, taskB.lastModifiedDate),
            serviceOrigins: taskA.serviceOrigins + taskB.serviceOrigins
        )
    }

    private func sameDayOrBothNil(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let d1?, let d2?):
            return Calendar.current.isDate(d1, inSameDayAs: d2)
        }
    }

    private func newerTask(_ a: CanonicalTask, _ b: CanonicalTask) -> CanonicalTask {
        guard let dateA = a.lastModifiedDate, let dateB = b.lastModifiedDate else {
            return a.lastModifiedDate != nil ? a : b
        }
        return dateA >= dateB ? a : b
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

    // MARK: - Sort Helpers

    private func sortOrder(_ proposal: MergeProposal) -> Int {
        switch proposal.action {
        case .duplicate: 0
        case .completionConflict: 1
        case .fieldConflict: 2
        case .missingFrom: 3
        }
    }
}
