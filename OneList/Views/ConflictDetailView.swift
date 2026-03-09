import SwiftUI

struct ConflictDetailView: View {
    let proposal: MergeProposal
    let onSave: (MergeProposal.Decision) -> Void

    @State private var editableTask: CanonicalTask
    @Environment(\.dismiss) private var dismiss

    init(proposal: MergeProposal, onSave: @escaping (MergeProposal.Decision) -> Void) {
        self.proposal = proposal
        self.onSave = onSave

        switch proposal.action {
        case .duplicate(let match):
            _editableTask = State(initialValue: match.mergedResult)
        case .fieldConflict(let conflict):
            _editableTask = State(initialValue: conflict.mergedResult)
        case .completionConflict(let conflict):
            _editableTask = State(initialValue: conflict.task)
        case .missingFrom(let missing):
            _editableTask = State(initialValue: missing.task)
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
                        onSave(.modified(editableTask))
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Title

    private var titleSection: some View {
        Section("Task") {
            TextField("Title", text: $editableTask.title)
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
                        Image(systemName: service.iconSystemName)
                            .foregroundStyle(serviceColor(service))
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
        case .duplicate(let match):
            let fields = diffFields(match.taskA, match.taskB)
            if !fields.isEmpty {
                ForEach(fields, id: \.fieldName) { field in
                    Section(field.fieldName) {
                        fieldEntryPickers(field: field)
                    }
                }
            }
        case .completionConflict:
            completionPicker
        case .missingFrom:
            EmptyView()
        }
    }

    @ViewBuilder
    private func fieldEntryPickers(field: ConflictingField) -> some View {
        ForEach(field.entries) { entry in
            Button {
                applyField(field.fieldName, from: entry.task)
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
                    if isFieldFrom(field.fieldName, matching: entry.task) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .tint(.primary)
        }
    }

    @ViewBuilder
    private var completionPicker: some View {
        Section("Completion Status") {
            Button {
                editableTask.isCompleted = true
            } label: {
                HStack {
                    Label("Mark completed", systemImage: "checkmark.circle.fill")
                    Spacer()
                    if editableTask.isCompleted {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.blue)
                    }
                }
            }
            .tint(.primary)

            Button {
                editableTask.isCompleted = false
            } label: {
                HStack {
                    Label("Keep open", systemImage: "circle")
                    Spacer()
                    if !editableTask.isCompleted {
                        Image(systemName: "checkmark")
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
                Text(editableTask.title)
                    .font(.headline)
                if let notes = editableTask.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    if let due = editableTask.dueDate {
                        Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .font(.caption)
                    }
                    if editableTask.priority != .none {
                        Label(editableTask.priority.label, systemImage: "flag.fill")
                            .font(.caption)
                    }
                    Label(
                        editableTask.isCompleted ? "Completed" : "Open",
                        systemImage: editableTask.isCompleted ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Field Application

    private func applyField(_ fieldName: String, from source: CanonicalTask) {
        switch fieldName {
        case "Title":
            editableTask.title = source.title
        case "Priority":
            editableTask.priority = source.priority
        case "Notes":
            editableTask.notes = source.notes
        case "Due Date":
            editableTask.dueDate = source.dueDate
        default:
            break
        }
    }

    private func isFieldFrom(_ fieldName: String, matching source: CanonicalTask) -> Bool {
        switch fieldName {
        case "Title":
            return editableTask.title == source.title
        case "Priority":
            return editableTask.priority == source.priority
        case "Notes":
            return editableTask.notes == source.notes
        case "Due Date":
            if let a = editableTask.dueDate, let b = source.dueDate {
                return Calendar.current.isDate(a, inSameDayAs: b)
            }
            return editableTask.dueDate == nil && source.dueDate == nil
        default:
            return false
        }
    }

    // MARK: - Diff Helper (for duplicates)

    private func diffFields(_ a: CanonicalTask, _ b: CanonicalTask) -> [ConflictingField] {
        var fields: [ConflictingField] = []
        let serviceA = a.serviceOrigins.first?.service ?? .appleReminders
        let serviceB = b.serviceOrigins.first?.service ?? .googleTasks

        if a.priority != b.priority {
            fields.append(ConflictingField(
                fieldName: "Priority",
                entries: [
                    .init(service: serviceA, value: a.priority.label, task: a),
                    .init(service: serviceB, value: b.priority.label, task: b),
                ]
            ))
        }
        let notesA = a.notes ?? ""
        let notesB = b.notes ?? ""
        if notesA != notesB && !(notesA.isEmpty && notesB.isEmpty) {
            fields.append(ConflictingField(
                fieldName: "Notes",
                entries: [
                    .init(service: serviceA, value: notesA.isEmpty ? "(empty)" : String(notesA.prefix(50)), task: a),
                    .init(service: serviceB, value: notesB.isEmpty ? "(empty)" : String(notesB.prefix(50)), task: b),
                ]
            ))
        }
        if !sameDayOrBothNil(a.dueDate, b.dueDate) {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fields.append(ConflictingField(
                fieldName: "Due Date",
                entries: [
                    .init(service: serviceA, value: a.dueDate.map { fmt.string(from: $0) } ?? "(none)", task: a),
                    .init(service: serviceB, value: b.dueDate.map { fmt.string(from: $0) } ?? "(none)", task: b),
                ]
            ))
        }
        return fields
    }

    private func sameDayOrBothNil(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let d1?, let d2?):
            return Calendar.current.isDate(d1, inSameDayAs: d2)
        }
    }
}
