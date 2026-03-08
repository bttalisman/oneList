import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var taskViewModel: MergeReviewViewModel
    @State private var eventViewModel: EventMergeReviewViewModel

    private let taskServices: [any TaskServiceProtocol]
    private let eventServices: [any EventServiceProtocol]

    init() {
        let taskServices: [any TaskServiceProtocol] = [
            AppleRemindersService(),
            GoogleTasksService(),
            MicrosoftToDoService(),
        ]
        let eventServices: [any EventServiceProtocol] = [
            AppleCalendarService(),
            GoogleCalendarService(),
            MicrosoftCalendarService(),
        ]
        self.taskServices = taskServices
        self.eventServices = eventServices
        self._taskViewModel = State(initialValue: MergeReviewViewModel(services: taskServices))
        self._eventViewModel = State(initialValue: EventMergeReviewViewModel(services: eventServices))
    }

    var body: some View {
        TabView {
            Tab("Tasks", systemImage: "checklist") {
                MergeReviewView(viewModel: taskViewModel)
            }

            Tab("Events", systemImage: "calendar") {
                EventMergeReviewView(viewModel: eventViewModel)
            }

            Tab("Accounts", systemImage: "person.crop.circle") {
                NavigationStack {
                    AccountsView(
                        taskServices: taskServices,
                        eventServices: eventServices,
                        onReconnect: { provider in handleReconnect(provider) }
                    )
                }
            }
        }
        .onAppear {
            if taskViewModel.linkStore == nil {
                taskViewModel.linkStore = TaskLinkStore(modelContext: modelContext)
            }
            if eventViewModel.linkStore == nil {
                eventViewModel.linkStore = EventLinkStore(modelContext: modelContext)
            }
        }
    }

    private func handleReconnect(_ provider: ServiceProvider) {
        // Clear sessions so stale data doesn't persist
        taskViewModel.session = nil
        eventViewModel.session = nil

        // Clear persistent links for this provider's services
        let taskServiceTypes = [provider.taskServiceType]
        let eventServiceTypes = [provider.eventServiceType]
        taskViewModel.linkStore?.clearLinks(for: taskServiceTypes)
        eventViewModel.linkStore?.clearLinks(for: eventServiceTypes)
    }
}
