import SwiftUI

/// Detail view for a synced item showing which services it lives in,
/// with the ability to remove it from specific services.
struct SyncedTaskDetailView: View {
    let task: CanonicalTask
    let services: [ServiceOrigin]
    let onDelete: (ServiceType, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete: ServiceType?
    @State private var removedServices: Set<ServiceType> = []

    private var visibleServices: [ServiceOrigin] {
        services.filter { !removedServices.contains($0.service) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Task") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title)
                            .font(.headline)
                        if let notes = task.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            if let due = task.dueDate {
                                Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                                    .font(.caption)
                            }
                            if task.priority != .none {
                                Label(task.priority.label, systemImage: "flag.fill")
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Synced To") {
                    ForEach(visibleServices, id: \.service) { origin in
                        HStack {
                            Image(systemName: origin.service.iconSystemName)
                                .foregroundStyle(serviceColor(origin.service))
                                .frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(origin.service.displayName)
                                    .font(.body)
                                if let listName = origin.listName, !listName.isEmpty {
                                    Text(listName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if visibleServices.count > 1 {
                                Button(role: .destructive) {
                                    confirmingDelete = origin.service
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }

                if visibleServices.count <= 1 {
                    Section {
                        Text("This task only exists in one service and cannot be removed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Synced Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Remove from \(confirmingDelete?.displayName ?? "")?",
                isPresented: Binding(
                    get: { confirmingDelete != nil },
                    set: { if !$0 { confirmingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let service = confirmingDelete,
                   let origin = services.first(where: { $0.service == service }) {
                    Button("Remove from \(service.displayName)", role: .destructive) {
                        onDelete(service, origin.nativeID)
                        removedServices.insert(service)
                    }
                }
                Button("Cancel", role: .cancel) { confirmingDelete = nil }
            } message: {
                Text("This will delete the task from this service. It will remain in your other connected services.")
            }
            .animation(.default, value: removedServices)
        }
    }

    private func serviceColor(_ service: ServiceType) -> Color {
        switch service {
        case .appleReminders, .appleCalendar: .blue
        case .googleTasks, .googleCalendar: .green
        case .microsoftToDo, .microsoftCalendar: .orange
        }
    }
}

struct SyncedEventDetailView: View {
    let event: CanonicalEvent
    let services: [ServiceOrigin]
    let onDelete: (ServiceType, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete: ServiceType?
    @State private var removedServices: Set<ServiceType> = []

    private var visibleServices: [ServiceOrigin] {
        services.filter { !removedServices.contains($0.service) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Event") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title)
                            .font(.headline)
                        if event.isAllDay {
                            Text("All day")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(event.startDate.formatted(date: .abbreviated, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let location = event.location, !location.isEmpty {
                            Label(location, systemImage: "mappin")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let notes = event.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Synced To") {
                    ForEach(visibleServices, id: \.service) { origin in
                        HStack {
                            Image(systemName: origin.service.iconSystemName)
                                .foregroundStyle(serviceColor(origin.service))
                                .frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(origin.service.displayName)
                                    .font(.body)
                                if let listName = origin.listName, !listName.isEmpty {
                                    Text(listName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if visibleServices.count > 1 {
                                Button(role: .destructive) {
                                    confirmingDelete = origin.service
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }

                if visibleServices.count <= 1 {
                    Section {
                        Text("This event only exists in one service and cannot be removed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Synced Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Remove from \(confirmingDelete?.displayName ?? "")?",
                isPresented: Binding(
                    get: { confirmingDelete != nil },
                    set: { if !$0 { confirmingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let service = confirmingDelete,
                   let origin = services.first(where: { $0.service == service }) {
                    Button("Remove from \(service.displayName)", role: .destructive) {
                        onDelete(service, origin.nativeID)
                        removedServices.insert(service)
                    }
                }
                Button("Cancel", role: .cancel) { confirmingDelete = nil }
            } message: {
                Text("This will delete the event from this service. It will remain in your other connected services.")
            }
            .animation(.default, value: removedServices)
        }
    }

    private func serviceColor(_ service: ServiceType) -> Color {
        switch service {
        case .appleReminders, .appleCalendar: .blue
        case .googleTasks, .googleCalendar: .green
        case .microsoftToDo, .microsoftCalendar: .orange
        }
    }
}
