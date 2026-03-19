import Foundation
import os
import SwiftData

private let logger = Logger(subsystem: "com.syncemall", category: "EventLinkStore")

/// Manages persistent event links using SwiftData.
@MainActor
final class EventLinkStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Find an existing link that contains the given native ID for the given service.
    func findLink(nativeID: String, service: ServiceType) -> EventLink? {
        let predicate: Predicate<EventLink>
        switch service {
        case .appleCalendar:
            predicate = #Predicate<EventLink> { $0.appleNativeID == nativeID }
        case .googleCalendar:
            predicate = #Predicate<EventLink> { $0.googleNativeID == nativeID }
        case .microsoftCalendar:
            predicate = #Predicate<EventLink> { $0.microsoftNativeID == nativeID }
        default:
            return nil
        }
        let descriptor = FetchDescriptor(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }

    /// Find a link by its UUID.
    func findLink(id: UUID) -> EventLink? {
        let descriptor = FetchDescriptor<EventLink>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    /// Save a new link.
    func insert(_ link: EventLink) {
        modelContext.insert(link)
        save()
    }

    /// Save pending changes.
    func save() {
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save EventLinks: \(error.localizedDescription)")
        }
    }

    /// Fetch all links.
    func allLinks() -> [EventLink] {
        let descriptor = FetchDescriptor<EventLink>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Delete a link.
    func delete(_ link: EventLink) {
        modelContext.delete(link)
        save()
    }

    /// Clear native IDs for a specific service (used when reconnecting to a different account).
    func clearLinks(for services: [ServiceType]) {
        let links = allLinks()
        for link in links {
            for service in services {
                switch service {
                case .googleCalendar: link.googleNativeID = nil
                case .microsoftCalendar: link.microsoftNativeID = nil
                default: break
                }
            }
            if link.appleNativeID == nil && link.googleNativeID == nil && link.microsoftNativeID == nil {
                modelContext.delete(link)
            }
        }
        save()
        logger.info("Cleared event links for \(services.map { $0.displayName })")
    }
}
