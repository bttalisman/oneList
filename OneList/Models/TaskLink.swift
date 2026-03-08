import Foundation
import SwiftData

/// Persistent link between tasks across services.
/// Stores the native ID for each service so we can identify the same task
/// even after title changes.
@Model
final class TaskLink {
    var id: UUID
    var appleNativeID: String?
    var googleNativeID: String?
    var microsoftNativeID: String?
    var lastKnownTitle: String
    var lastSyncDate: Date

    init(id: UUID = UUID(), lastKnownTitle: String) {
        self.id = id
        self.lastKnownTitle = lastKnownTitle
        self.lastSyncDate = Date()
    }

    func nativeID(for service: ServiceType) -> String? {
        switch service {
        case .appleReminders: appleNativeID
        case .googleTasks: googleNativeID
        case .microsoftToDo: microsoftNativeID
        default: nil
        }
    }

    func setNativeID(_ nativeID: String, for service: ServiceType) {
        switch service {
        case .appleReminders: appleNativeID = nativeID
        case .googleTasks: googleNativeID = nativeID
        case .microsoftToDo: microsoftNativeID = nativeID
        default: break
        }
        lastSyncDate = Date()
    }
}
