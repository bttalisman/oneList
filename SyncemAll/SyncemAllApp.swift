import SwiftData
import SwiftUI

@main
struct SyncemAllApp: App {
    var body: some Scene {
        WindowGroup {
            SplashView()
                .task {
                    await SubscriptionManager.shared.refreshEntitlement()
                }
        }
        .modelContainer(for: [TaskLink.self, EventLink.self])
    }
}
