import SwiftUI

struct EventMergeReviewView: View {
    @Bindable var viewModel: EventMergeReviewViewModel
    @State private var selectedProposal: EventMergeProposal?
    @State private var selectedSyncedEvent: CanonicalEvent?
    @State private var showSkipped = false
    @State private var showSynced = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.session == nil {
                    ProgressView("Syncing calendars...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    ScrollView {
                        ContentUnavailableView(
                            "Something went wrong",
                            systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                        .frame(maxWidth: .infinity, minHeight: 400)
                    }
                } else if let session = viewModel.session {
                    if session.proposals.isEmpty {
                        ScrollView {
                            ContentUnavailableView(
                                "All Synced",
                                systemImage: "checkmark.circle",
                                description: Text("Your calendar events are in sync across connected services.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 400)
                        }
                    } else {
                        mergeList(session)
                    }
                } else {
                    ScrollView {
                        eventEmptyState
                    }
                }
            }
            .task {
                if viewModel.session == nil {
                    await viewModel.pullAndPropose()
                }
            }
            .refreshable {
                await viewModel.pullAndPropose()
            }
            .navigationTitle("Events")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let session = viewModel.session, session.pushableCount > 0 {
                        Button("Push Changes") {
                            viewModel.showingPushConfirmation = true
                        }
                    }
                }
            }
            .sheet(item: $selectedProposal) { proposal in
                EventConflictDetailView(proposal: proposal) { decision in
                    viewModel.resolveProposal(id: proposal.id, decision: decision)
                }
            }
            .sheet(isPresented: $viewModel.showingPushConfirmation) {
                PushOptionsView(
                    changeCount: viewModel.session?.pushableCount ?? 0
                ) { providers in
                    Task { await viewModel.pushApproved(to: providers) }
                }
            }
            .sheet(item: $selectedSyncedEvent, onDismiss: {
                Task { await viewModel.pullAndPropose() }
            }) { event in
                SyncedEventDetailView(
                    event: event,
                    services: event.serviceOrigins
                ) { serviceType, nativeID in
                    Task { await viewModel.deleteEventFromService(serviceType: serviceType, nativeID: nativeID) }
                }
            }
        }
    }

    // MARK: - Empty State

    private var eventEmptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 56))
                .foregroundStyle(.purple.opacity(0.7))

            VStack(spacing: 8) {
                Text("Calendar Sync")
                    .font(.title2.weight(.bold))
                Text("Connect your calendar services, then pull to find differences across them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Merge List

    @ViewBuilder
    private func mergeList(_ session: EventMergeSession) -> some View {
        List {
            statusSection(session)

            ForEach(session.proposals) { proposal in
                if isAutoSynced(proposal) || isRejected(proposal) {
                    // shown in collapsed sections below
                } else {
                    proposalRow(proposal)
                }
            }

            let syncedProposals = session.proposals.filter { isAutoSynced($0) }
            if !syncedProposals.isEmpty {
                Section {
                    DisclosureGroup(
                        "Synced (\(syncedProposals.count))",
                        isExpanded: $showSynced
                    ) {
                        ForEach(syncedProposals) { proposal in
                            proposalRow(proposal)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            let skippedCount = session.rejectedCount
            if skippedCount > 0 {
                Section {
                    DisclosureGroup(
                        "Skipped (\(skippedCount))",
                        isExpanded: $showSkipped
                    ) {
                        ForEach(session.proposals) { proposal in
                            if isRejected(proposal) {
                                proposalRow(proposal)
                                    .opacity(0.5)
                            }
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: session.rejectedCount)
    }

    private func isAutoSynced(_ proposal: EventMergeProposal) -> Bool {
        if case .approved = proposal.decision,
           case .synced(let match) = proposal.action,
           match.confidence == .exact {
            return true
        }
        return false
    }

    private func isRejected(_ proposal: EventMergeProposal) -> Bool {
        if case .rejected = proposal.decision { return true }
        return false
    }

    // MARK: - Status Header

    private func statusSection(_ session: EventMergeSession) -> some View {
        let syncedCount = session.proposals.filter { isAutoSynced($0) }.count
        let actionableApproved = session.approvedCount - syncedCount

        return Section {
            HStack {
                EventStatBadge(count: syncedCount, label: "Synced", color: .blue)
                Spacer()
                EventStatBadge(count: session.pendingCount, label: "Pending", color: .orange)
                Spacer()
                EventStatBadge(count: actionableApproved, label: "Approved", color: .green)
                Spacer()
                EventStatBadge(count: session.rejectedCount, label: "Skipped", color: .red)
            }
            .padding(.vertical, 4)

            if session.pendingCount > 0 {
                Button("Approve All Remaining") {
                    viewModel.approveAll()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Proposal Row

    @ViewBuilder
    private func proposalRow(_ proposal: EventMergeProposal) -> some View {
        let title = proposalTitle(proposal)
        let eventTitle = proposalEventTitle(proposal)
        let decision = proposalDecisionLabel(proposal.decision)

        Section {
            VStack(alignment: .leading, spacing: 8) {
                proposalHeader(proposal)
                proposalDetail(proposal)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title): \(eventTitle), \(decision)")
            .accessibilityHint(hasConflictDetails(proposal) ? "Double tap to resolve conflict" : "Double tap to view details. Swipe right to approve, swipe left to skip.")
            .onTapGesture {
                if hasConflictDetails(proposal) {
                    selectedProposal = proposal
                } else if let syncedEvent = syncedEvent(from: proposal) {
                    selectedSyncedEvent = syncedEvent
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    viewModel.approveProposal(id: proposal.id)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .tint(.green)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    viewModel.rejectProposal(id: proposal.id)
                } label: {
                    Label("Skip", systemImage: "xmark")
                }
                .tint(.red)
            }
        }
    }

    private func proposalEventTitle(_ proposal: EventMergeProposal) -> String {
        switch proposal.action {
        case .synced(let match): match.mergedResult.title
        case .missingFrom(let missing): missing.event.title
        case .fieldConflict(let conflict): conflict.events.first?.title ?? ""
        }
    }

    private func proposalDecisionLabel(_ decision: EventMergeProposal.Decision) -> String {
        switch decision {
        case .pending: "Pending"
        case .approved: "Approved"
        case .rejected: "Skipped"
        case .modified: "Modified"
        }
    }

    private func hasConflictDetails(_ proposal: EventMergeProposal) -> Bool {
        switch proposal.action {
        case .fieldConflict: true
        case .synced: false
        case .missingFrom: false
        }
    }

    private func syncedEvent(from proposal: EventMergeProposal) -> CanonicalEvent? {
        switch proposal.action {
        case .synced(let match):
            return match.mergedResult
        case .missingFrom(let missing):
            return missing.event
        default:
            return nil
        }
    }

    @ViewBuilder
    private func proposalHeader(_ proposal: EventMergeProposal) -> some View {
        HStack {
            proposalIcon(proposal)
            Text(proposalTitle(proposal))
                .font(.subheadline.weight(.medium))
            Spacer()
            decisionBadge(proposal.decision)
        }
    }

    @ViewBuilder
    private func proposalDetail(_ proposal: EventMergeProposal) -> some View {
        switch proposal.action {
        case .synced(let match):
            VStack(alignment: .leading, spacing: 4) {
                Text(match.events.first?.title ?? "")
                    .font(.body)
                eventTimeLabel(match.mergedResult)
                HStack(spacing: 4) {
                    let uniqueServices = match.mergedResult.serviceOrigins
                        .map(\.service)
                        .reduce(into: [ServiceType]()) { if !$0.contains($1) { $0.append($1) } }
                        .sorted()
                    ForEach(uniqueServices) { service in
                        serviceTag(service)
                    }
                }
                if match.confidence != .exact {
                    Text(match.confidence.label)
                        .font(.caption)
                        .foregroundStyle(confidenceColor(match.confidence))
                }
                Text("Tap to manage")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }

        case .missingFrom(let missing):
            VStack(alignment: .leading, spacing: 6) {
                Text(missing.event.title.isEmpty ? "(untitled)" : missing.event.title)
                    .font(.body)
                eventTimeLabel(missing.event)
                HStack(spacing: 4) {
                    Text("In:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(missing.presentIn) { service in
                        serviceTag(service)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Missing from:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(missing.missingFrom) { service in
                            serviceTag(service)
                        }
                    }
                }
                Text("Tap to view")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }

        case .fieldConflict(let conflict):
            VStack(alignment: .leading, spacing: 4) {
                Text(conflict.events.first?.title ?? "")
                    .font(.body)
                if let first = conflict.events.first {
                    eventTimeLabel(first)
                }
                ForEach(conflict.conflictingFields, id: \.fieldName) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.fieldName)
                            .font(.caption.weight(.medium))
                        HStack(spacing: 4) {
                            ForEach(Array(field.entries.enumerated()), id: \.offset) { index, entry in
                                if index > 0 {
                                    Text("vs")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.value)
                                    .font(.caption)
                                    .foregroundStyle(serviceColor(entry.service))
                            }
                        }
                    }
                }
                Text("Tap to resolve")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func eventTimeLabel(_ event: CanonicalEvent) -> some View {
        if event.isAllDay {
            Text("All day")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("\(event.startDate.formatted(date: .abbreviated, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func proposalIcon(_ proposal: EventMergeProposal) -> some View {
        let (name, color): (String, Color) = switch proposal.action {
        case .synced: ("checkmark.seal", .blue)
        case .missingFrom: ("plus.circle", .green)
        case .fieldConflict: ("arrow.left.arrow.right", .purple)
        }
        return Image(systemName: name)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func proposalTitle(_ proposal: EventMergeProposal) -> String {
        switch proposal.action {
        case .synced(let match):
            match.confidence == .exact ? "Synced" : "Possible Match"
        case .missingFrom: "Missing"
        case .fieldConflict: "Field Conflict"
        }
    }

    private func serviceColor(_ service: ServiceType) -> Color {
        service.color
    }

    private func confidenceColor(_ confidence: EventMatchConfidence) -> Color {
        switch confidence {
        case .exact: .green
        case .high: .blue
        case .medium: .orange
        case .low: .red
        }
    }

    @ViewBuilder
    private func serviceTag(_ service: ServiceType?) -> some View {
        if let service {
            Image(systemName: service.iconSystemName)
                .font(.caption)
                .foregroundStyle(serviceColor(service))
                .frame(width: 22, height: 22)
                .background(.quaternary, in: .circle)
                .help(service.displayName)
                .accessibilityLabel(service.displayName)
        }
    }

    @ViewBuilder
    private func decisionBadge(_ decision: EventMergeProposal.Decision) -> some View {
        switch decision {
        case .pending:
            Text("Pending")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .accessibilityLabel("Status: Pending")
        case .approved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Status: Approved")
        case .rejected:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Status: Skipped")
        case .modified:
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityLabel("Status: Modified")
        }
    }
}

// MARK: - Stat Badge

private struct EventStatBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
