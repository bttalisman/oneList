import SwiftUI

struct EventConflictDetailView: View {
    let proposal: EventMergeProposal
    let onSave: (EventMergeProposal.Decision) -> Void

    @State private var editableEvent: CanonicalEvent
    @Environment(\.dismiss) private var dismiss

    init(proposal: EventMergeProposal, onSave: @escaping (EventMergeProposal.Decision) -> Void) {
        self.proposal = proposal
        self.onSave = onSave

        switch proposal.action {
        case .synced(let match):
            _editableEvent = State(initialValue: match.mergedResult)
        case .fieldConflict(let conflict):
            _editableEvent = State(initialValue: conflict.mergedResult)
        case .missingFrom(let missing):
            _editableEvent = State(initialValue: missing.event)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                titleSection
                missingFromSection
                fieldPickerSections
                previewSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Resolve Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(.modified(editableEvent))
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Title

    private var titleSection: some View {
        Section("Event") {
            TextField("Title", text: $editableEvent.title)
                .font(.headline)
        }
    }

    // MARK: - Missing From

    @ViewBuilder
    private var missingFromSection: some View {
        if case .fieldConflict(let conflict) = proposal.action, !conflict.missingFrom.isEmpty {
            Section("Will Be Added To") {
                ForEach(conflict.missingFrom) { service in
                    HStack {
                        ServiceLogo(service: service, size: 16)
                            .frame(width: 24)
                        Text(service.displayName)
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    private func serviceColor(_ service: ServiceType) -> Color {
        service.color
    }

    // MARK: - Field Pickers

    @ViewBuilder
    private var fieldPickerSections: some View {
        switch proposal.action {
        case .fieldConflict(let conflict):
            ForEach(conflict.conflictingFields, id: \.fieldName) { field in
                Section(field.fieldName) {
                    fieldEntryPickers(field: field)
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func fieldEntryPickers(field: EventConflictingField) -> some View {
        ForEach(field.entries) { entry in
            Button {
                applyField(field.fieldName, from: entry.event)
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.service.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.value)
                            .font(.body)
                    }
                    Spacer()
                    if isFieldFrom(field.fieldName, matching: entry.event) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .tint(.primary)
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section("Result Preview") {
            VStack(alignment: .leading, spacing: 6) {
                Text(editableEvent.title)
                    .font(.headline)
                if editableEvent.isAllDay {
                    Text("All day")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(editableEvent.startDate.formatted(date: .abbreviated, time: .shortened)) – \(editableEvent.endDate.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let location = editableEvent.location, !location.isEmpty {
                    Label(location, systemImage: "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notes = editableEvent.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Field Application

    private func applyField(_ fieldName: String, from source: CanonicalEvent) {
        switch fieldName {
        case "Title":
            editableEvent.title = source.title
        case "Location":
            editableEvent.location = source.location
        case "Notes":
            editableEvent.notes = source.notes
        case "End Time":
            editableEvent.endDate = source.endDate
        default:
            break
        }
    }

    private func isFieldFrom(_ fieldName: String, matching source: CanonicalEvent) -> Bool {
        switch fieldName {
        case "Title":
            return editableEvent.title == source.title
        case "Location":
            return editableEvent.location == source.location
        case "Notes":
            return editableEvent.notes == source.notes
        case "End Time":
            return abs(editableEvent.endDate.timeIntervalSince(source.endDate)) < 60
        default:
            return false
        }
    }
}
