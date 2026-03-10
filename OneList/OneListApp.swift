import SwiftData
import SwiftUI

@main
struct OneListApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await SubscriptionManager.shared.refreshEntitlement()
                }
        }
        .modelContainer(for: [TaskLink.self, EventLink.self])
    }
}
