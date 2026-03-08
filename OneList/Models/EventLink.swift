import Foundation
import SwiftData

/// Persistent link between events across services.
/// Stores the native ID for each service so we can identify the same event
/// even after title changes.
@Model
final class EventLink {
    var id: UUID
    var appleNativeID: String?
    var googleNativeID: String?
    var microsoftNativeID: String?
    var lastKnownTitle: String
    var lastKnownStartDate: Date?
    var lastSyncDate: Date

    init(id: UUID = UUID(), lastKnownTitle: String, lastKnownStartDate: Date? = nil) {
        self.id = id
        self.lastKnownTitle = lastKnownTitle
        self.lastKnownStartDate = lastKnownStartDate
        self.lastSyncDate = Date()
    }

    func nativeID(for service: ServiceType) -> String? {
        switch service {
        case .appleCalendar: appleNativeID
        case .googleCalendar: googleNativeID
        case .microsoftCalendar: microsoftNativeID
        default: nil
        }
    }

    func setNativeID(_ nativeID: String, for service: ServiceType) {
        switch service {
        case .appleCalendar: appleNativeID = nativeID
        case .googleCalendar: googleNativeID = nativeID
        case .microsoftCalendar: microsoftNativeID = nativeID
        default: break
        }
        lastSyncDate = Date()
    }
}
