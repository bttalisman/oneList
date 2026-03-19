#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

struct DevSnapshotView: View {
    var taskViewModel: MergeReviewViewModel
    var eventViewModel: EventMergeReviewViewModel

    @State private var statusMessage: String?
    @State private var showFilePicker = false
    @State private var filePickerMode: SnapshotType = .tasks

    enum SnapshotType {
        case tasks, events
    }

    var body: some View {
        List {
            Section(footer: Text("Snapshots are saved automatically every time you pull.")) {
                Button("Share Tasks Snapshot") {
                    presentShareSheet(urls: [DevDataStore.tasksSnapshotURL])
                }
                .disabled(!DevDataStore.hasTasksSnapshot)

                Button("Share Events Snapshot") {
                    presentShareSheet(urls: [DevDataStore.eventsSnapshotURL])
                }
                .disabled(!DevDataStore.hasEventsSnapshot)

                Button("Share Both") {
                    let urls = [DevDataStore.tasksSnapshotURL, DevDataStore.eventsSnapshotURL]
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !urls.isEmpty {
                        presentShareSheet(urls: urls)
                    }
                }
                .disabled(!DevDataStore.hasTasksSnapshot && !DevDataStore.hasEventsSnapshot)
            }

            Section("Load Snapshot") {
                Button("Load Tasks from File…") {
                    filePickerMode = .tasks
                    showFilePicker = true
                }

                Button("Load Events from File…") {
                    filePickerMode = .events
                    showFilePicker = true
                }
            }

            Section("Subscription") {
                Toggle("Pro Mode", isOn: Binding(
                    get: { SubscriptionManager.shared.devProOverride },
                    set: { SubscriptionManager.shared.devProOverride = $0 }
                ))

                HStack {
                    Text("Syncs Used")
                    Spacer()
                    Text("\(SubscriptionManager.shared.syncCount) / \(SubscriptionManager.freeSyncLimit)")
                        .foregroundStyle(.secondary)
                }

                Button("Reset Sync Count") {
                    SubscriptionManager.shared.syncCount = 0
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Dev Tools")
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let accessing = url.startAccessingSecurityScopedResource()
                let mode = filePickerMode
                Task {
                    switch mode {
                    case .tasks:
                        await taskViewModel.loadSnapshot(from: url)
                        statusMessage = "Task snapshot loaded from file"
                    case .events:
                        await eventViewModel.loadSnapshot(from: url)
                        statusMessage = "Event snapshot loaded from file"
                    }
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
            case .failure(let error):
                statusMessage = "Failed to pick file: \(error.localizedDescription)"
            }
        }
    }

    private func presentShareSheet(urls: [URL]) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }

        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = root.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
        vc.popoverPresentationController?.permittedArrowDirections = []

        root.present(vc, animated: true)
    }
}
#endif
