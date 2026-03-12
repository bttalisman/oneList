import SwiftUI

struct MergeReviewView: View {
    @Bindable var viewModel: MergeReviewViewModel
    @State private var selectedProposal: MergeProposal?
    @State private var selectedSyncedTask: CanonicalTask?
    @State private var showSkipped = false
    @State private var showSynced = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.session == nil {
                    ProgressView("Syncing...")
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
                                description: Text("Everything is in sync across your connected services.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 400)
                        }
                    } else {
                        mergeList(session)
                    }
                } else {
                    ScrollView {
                        emptyState
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
            .navigationTitle("Tasks")
            .sheet(item: $selectedProposal) { proposal in
                ConflictDetailView(proposal: proposal) { decision in
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
            .overlay {
                if viewModel.showPushSuccess {
                    ConfettiOverlay(isPresented: $viewModel.showPushSuccess)
                }
            }
            .sheet(isPresented: $viewModel.showPaywall) {
                PaywallView()
            }
            .sheet(item: $selectedSyncedTask, onDismiss: {
                Task { await viewModel.pullAndPropose() }
            }) { task in
                SyncedTaskDetailView(
                    task: task,
                    services: task.serviceOrigins
                ) { serviceType, nativeID in
                    Task { await viewModel.deleteTaskFromService(serviceType: serviceType, nativeID: nativeID) }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 56))
                .foregroundStyle(.blue.opacity(0.7))

            VStack(spacing: 8) {
                Text("Welcome to OneList")
                    .font(.title2.weight(.bold))
                Text("Connect your task services, then pull to find duplicates and conflicts across them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: 1, text: "Connect services in the Accounts tab")
                stepRow(number: 2, text: "Tap Pull & Merge to compare tasks")
                stepRow(number: 3, text: "Review and approve merge proposals")
                stepRow(number: 4, text: "Push to sync changes back")
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.blue, in: .circle)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Merge List

    @ViewBuilder
    private func mergeList(_ session: MergeSession) -> some View {
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

    private func isAutoSynced(_ proposal: MergeProposal) -> Bool {
        if case .approved = proposal.decision,
           case .duplicate(let match) = proposal.action,
           match.confidence == .exact {
            return true
        }
        return false
    }

    private func isRejected(_ proposal: MergeProposal) -> Bool {
        if case .rejected = proposal.decision { return true }
        return false
    }

    // MARK: - Status Header

    private func statusSection(_ session: MergeSession) -> some View {
        let syncedCount = session.proposals.filter { isAutoSynced($0) }.count
        let actionableApproved = session.approvedCount - syncedCount

        return Section {
            HStack {
                StatBadge(count: syncedCount, label: "Synced", color: .blue)
                Spacer()
                StatBadge(count: session.pendingCount, label: "Pending", color: .orange)
                Spacer()
                StatBadge(count: actionableApproved, label: "Approved", color: .green)
                Spacer()
                StatBadge(count: session.rejectedCount, label: "Skipped", color: .red)
            }
            .padding(.vertical, 4)

            if session.pendingCount > 0 {
                Button("Approve All Remaining") {
                    viewModel.approveAll()
                }
                .frame(maxWidth: .infinity)
            }

            if session.pushableCount > 0 {
                Button {
                    viewModel.showingPushConfirmation = true
                } label: {
                    Label("Push \(session.pushableCount) Change\(session.pushableCount == 1 ? "" : "s")", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Push \(session.pushableCount) changes to connected services")
            }

            trialBanner
        }
    }

    @ViewBuilder
    private var trialBanner: some View {
        let sub = SubscriptionManager.shared
        if !sub.isPro {
            Button {
                viewModel.showPaywall = true
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    Text("\(sub.freeTrialRemaining) free sync\(sub.freeTrialRemaining == 1 ? "" : "s") remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Upgrade")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Proposal Row

    @ViewBuilder
    private func proposalRow(_ proposal: MergeProposal) -> some View {
        let title = proposalTitle(proposal)
        let taskTitle = proposalTaskTitle(proposal)
        let decision = proposalDecisionLabel(proposal.decision)

        Section {
            proposalContent(proposal)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title): \(taskTitle), \(decision)")
            .accessibilityHint(hasConflictDetails(proposal) ? "Double tap to resolve conflict" : "Double tap to view details. Swipe right to approve, swipe left to skip.")
            .onTapGesture {
                if hasConflictDetails(proposal) {
                    selectedProposal = proposal
                } else if let syncedTask = syncedTask(from: proposal) {
                    selectedSyncedTask = syncedTask
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !isAutoSynced(proposal) {
                    Button {
                        viewModel.approveProposal(id: proposal.id)
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .tint(.green)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !isAutoSynced(proposal) {
                    Button {
                        viewModel.rejectProposal(id: proposal.id)
                    } label: {
                        Label("Skip", systemImage: "xmark")
                    }
                    .tint(.red)
                }
            }
        }
    }

    private func proposalTaskTitle(_ proposal: MergeProposal) -> String {
        switch proposal.action {
        case .duplicate(let match): match.mergedResult.title
        case .missingFrom(let missing): missing.task.title
        case .completionConflict(let conflict): conflict.task.title
        case .fieldConflict(let conflict): conflict.tasks.first?.title ?? ""
        }
    }

    private func proposalDecisionLabel(_ decision: MergeProposal.Decision) -> String {
        switch decision {
        case .pending: "Pending"
        case .approved: "Approved"
        case .rejected: "Skipped"
        case .modified: "Modified"
        }
    }

    private func hasConflictDetails(_ proposal: MergeProposal) -> Bool {
        switch proposal.action {
        case .fieldConflict, .completionConflict: true
        case .duplicate: false
        case .missingFrom: false
        }
    }

    private func syncedTask(from proposal: MergeProposal) -> CanonicalTask? {
        switch proposal.action {
        case .duplicate(let match):
            return match.mergedResult
        case .missingFrom(let missing):
            return missing.task
        case .completionConflict(let conflict):
            return conflict.task
        default:
            return nil
        }
    }

    @ViewBuilder
    private func proposalContent(_ proposal: MergeProposal) -> some View {
        switch proposal.action {
        case .duplicate(let match):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(match.taskA.title)
                        .font(.body.weight(.medium))
                    Spacer()
                    decisionBadge(proposal.decision)
                }
                dueDateLabel(match.mergedResult.dueDate)
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
            }

        case .missingFrom(let missing):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(missing.task.title.isEmpty ? "(untitled)" : missing.task.title)
                        .font(.body.weight(.medium))
                    Spacer()
                    decisionBadge(proposal.decision)
                }
                dueDateLabel(missing.task.dueDate)
                HStack(spacing: 4) {
                    Text("In:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(missing.presentIn) { service in
                        serviceTag(service)
                    }
                    Text("Missing from:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(missing.missingFrom) { service in
                        serviceTag(service)
                    }
                }
            }

        case .completionConflict(let conflict):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conflict.task.title)
                        .font(.body.weight(.medium))
                    Spacer()
                    decisionBadge(proposal.decision)
                }
                dueDateLabel(conflict.task.dueDate)
                Text("Done in \(conflict.completedIn.displayName), open in \(conflict.openIn.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .fieldConflict(let conflict):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conflict.tasks.first?.title ?? "")
                        .font(.body.weight(.medium))
                    Spacer()
                    decisionBadge(proposal.decision)
                }
                dueDateLabel(conflict.mergedResult.dueDate)
                ForEach(conflict.conflictingFields, id: \.fieldName) { field in
                    HStack(spacing: 4) {
                        Text(field.fieldName)
                            .font(.caption.weight(.medium))
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
                Text("Tap to resolve")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Helper Views

    private static let dueDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    @ViewBuilder
    private func dueDateLabel(_ date: Date?) -> some View {
        if let date {
            Text("Due \(Self.dueDateFormatter.string(from: date))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func proposalTitle(_ proposal: MergeProposal) -> String {
        switch proposal.action {
        case .duplicate(let match):
            match.confidence == .exact ? "Synced" : "Possible Match"
        case .missingFrom: "Missing"
        case .completionConflict: "Completion Conflict"
        case .fieldConflict: "Field Conflict"
        }
    }

    private func serviceColor(_ service: ServiceType) -> Color {
        service.color
    }

    private func confidenceColor(_ confidence: MatchConfidence) -> Color {
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
    private func decisionBadge(_ decision: MergeProposal.Decision) -> some View {
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

private struct StatBadge: View {
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
