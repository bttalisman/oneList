import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "DevDataStore")

/// Development-only utility for saving and loading pulled service data as JSON snapshots.
/// Saves to the app's Documents directory so data persists across launches.
struct DevDataStore {
    private static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private static let tasksFile = "dev_tasks_snapshot.json"
    private static let eventsFile = "dev_events_snapshot.json"

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Tasks

    static func saveTasks(_ tasksByService: [ServiceType: [CanonicalTask]]) throws {
        let wrapper = tasksByService.map { (key, value) in
            ServiceSnapshot(serviceType: key.rawValue, items: value)
        }
        let data = try encoder.encode(wrapper)
        let url = documentsDir.appendingPathComponent(tasksFile)
        try data.write(to: url)
        logger.info("Saved \(tasksByService.values.flatMap { $0 }.count) tasks to \(url.path)")
    }

    static func loadTasks(from url: URL? = nil) throws -> [ServiceType: [CanonicalTask]] {
        let url = url ?? documentsDir.appendingPathComponent(tasksFile)
        let data = try Data(contentsOf: url)
        let wrapper = try decoder.decode([ServiceSnapshot<CanonicalTask>].self, from: data)
        var result: [ServiceType: [CanonicalTask]] = [:]
        for snapshot in wrapper {
            if let serviceType = ServiceType(rawValue: snapshot.serviceType) {
                result[serviceType] = snapshot.items
            }
        }
        logger.info("Loaded \(result.values.flatMap { $0 }.count) tasks from snapshot")
        return result
    }

    // MARK: - Events

    static func saveEvents(_ eventsByService: [ServiceType: [CanonicalEvent]]) throws {
        let wrapper = eventsByService.map { (key, value) in
            ServiceSnapshot(serviceType: key.rawValue, items: value)
        }
        let data = try encoder.encode(wrapper)
        let url = documentsDir.appendingPathComponent(eventsFile)
        try data.write(to: url)
        logger.info("Saved \(eventsByService.values.flatMap { $0 }.count) events to \(url.path)")
    }

    static func loadEvents(from url: URL? = nil) throws -> [ServiceType: [CanonicalEvent]] {
        let url = url ?? documentsDir.appendingPathComponent(eventsFile)
        let data = try Data(contentsOf: url)
        let wrapper = try decoder.decode([ServiceSnapshot<CanonicalEvent>].self, from: data)
        var result: [ServiceType: [CanonicalEvent]] = [:]
        for snapshot in wrapper {
            if let serviceType = ServiceType(rawValue: snapshot.serviceType) {
                result[serviceType] = snapshot.items
            }
        }
        logger.info("Loaded \(result.values.flatMap { $0 }.count) events from snapshot")
        return result
    }

    // MARK: - Info

    static var tasksSnapshotURL: URL {
        documentsDir.appendingPathComponent(tasksFile)
    }

    static var eventsSnapshotURL: URL {
        documentsDir.appendingPathComponent(eventsFile)
    }

    static var hasTasksSnapshot: Bool {
        FileManager.default.fileExists(atPath: tasksSnapshotURL.path)
    }

    static var hasEventsSnapshot: Bool {
        FileManager.default.fileExists(atPath: eventsSnapshotURL.path)
    }
}

// MARK: - Helper

private struct ServiceSnapshot<T: Codable>: Codable {
    let serviceType: String
    let items: [T]
}
