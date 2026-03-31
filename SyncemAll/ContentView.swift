import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var taskViewModel: MergeReviewViewModel
    @State private var eventViewModel: EventMergeReviewViewModel
    @State private var calendarViewModel: CalendarViewModel

    private let taskServices: [any TaskServiceProtocol]
    private let eventServices: [any EventServiceProtocol]

    init() {
        let taskServices: [any TaskServiceProtocol] = [
            AppleRemindersService(),
            GoogleTasksService(),
            MicrosoftToDoService(),
            TodoistService(),
        ]
        let eventServices: [any EventServiceProtocol] = [
            AppleCalendarService(),
            GoogleCalendarService(),
            MicrosoftCalendarService(),
        ]
        self.taskServices = taskServices
        self.eventServices = eventServices
        let taskVM = MergeReviewViewModel(services: taskServices)
        let eventVM = EventMergeReviewViewModel(services: eventServices)
        self._taskViewModel = State(initialValue: taskVM)
        self._eventViewModel = State(initialValue: eventVM)
        self._calendarViewModel = State(initialValue: CalendarViewModel(eventViewModel: eventVM, taskViewModel: taskVM))
    }

    var body: some View {
        TabView {
            Tab("Tasks", systemImage: "checklist") {
                MergeReviewView(viewModel: taskViewModel)
            }

            Tab("Events", systemImage: "calendar") {
                EventMergeReviewView(viewModel: eventViewModel)
            }

            Tab("Calendar", systemImage: "calendar.day.timeline.left") {
                CalendarView(viewModel: calendarViewModel)
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

            #if DEBUG
            Tab("Dev", systemImage: "hammer") {
                NavigationStack {
                    DevSnapshotView(
                        taskViewModel: taskViewModel,
                        eventViewModel: eventViewModel
                    )
                }
            }
            #endif
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
        taskViewModel.linkStore?.clearLinks(for: [provider.taskServiceType])
        if let eventType = provider.eventServiceType {
            eventViewModel.linkStore?.clearLinks(for: [eventType])
        }
    }
}
