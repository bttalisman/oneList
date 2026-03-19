import Foundation
import os
import SwiftData

private let logger = Logger(subsystem: "com.syncemall", category: "TaskLinkStore")

/// Manages persistent task links using SwiftData.
@MainActor
final class TaskLinkStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Find an existing link that contains the given native ID for the given service.
    func findLink(nativeID: String, service: ServiceType) -> TaskLink? {
        let predicate: Predicate<TaskLink>
        switch service {
        case .appleReminders:
            predicate = #Predicate<TaskLink> { $0.appleNativeID == nativeID }
        case .googleTasks:
            predicate = #Predicate<TaskLink> { $0.googleNativeID == nativeID }
        case .microsoftToDo:
            predicate = #Predicate<TaskLink> { $0.microsoftNativeID == nativeID }
        default:
            return nil
        }
        let descriptor = FetchDescriptor(predicate: predicate)
        return try? modelContext.fetch(descriptor).first
    }

    /// Find a link by its UUID.
    func findLink(id: UUID) -> TaskLink? {
        let descriptor = FetchDescriptor<TaskLink>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    /// Save a new link.
    func insert(_ link: TaskLink) {
        modelContext.insert(link)
        save()
    }

    /// Save pending changes.
    func save() {
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save TaskLinks: \(error.localizedDescription)")
        }
    }

    /// Fetch all links.
    func allLinks() -> [TaskLink] {
        let descriptor = FetchDescriptor<TaskLink>()
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Delete a link.
    func delete(_ link: TaskLink) {
        modelContext.delete(link)
        save()
    }

    /// Clear native IDs for a specific service (used when reconnecting to a different account).
    /// For Apple services, deletes links entirely since there's no multi-account scenario.
    /// For Google/Microsoft, nulls out the service-specific native ID.
    func clearLinks(for services: [ServiceType]) {
        let links = allLinks()
        for link in links {
            for service in services {
                switch service {
                case .googleTasks: link.googleNativeID = nil
                case .microsoftToDo: link.microsoftNativeID = nil
                default: break
                }
            }
            // If all native IDs are nil, delete the orphaned link
            if link.appleNativeID == nil && link.googleNativeID == nil && link.microsoftNativeID == nil {
                modelContext.delete(link)
            }
        }
        save()
        logger.info("Cleared task links for \(services.map { $0.displayName })")
    }
}
