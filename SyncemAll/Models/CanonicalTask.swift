import Foundation
import SwiftUI

// MARK: - Canonical Task

/// The unified internal representation of a task, independent of any service.
/// Each service adapter maps to/from this format.
struct CanonicalTask: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var notes: String?
    var isCompleted: Bool
    var dueDate: Date?
    var priority: Priority
    var createdDate: Date?
    var lastModifiedDate: Date?

    /// Tracks where this task came from and its native ID in that service.
    var serviceOrigins: [ServiceOrigin]

    enum Priority: Int, Comparable, CaseIterable, Hashable, Codable {
        case none = 0
        case low = 1
        case medium = 2
        case high = 3

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .none: "None"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        notes: String? = nil,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        priority: Priority = .none,
        createdDate: Date? = nil,
        lastModifiedDate: Date? = nil,
        serviceOrigins: [ServiceOrigin] = []
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.priority = priority
        self.createdDate = createdDate
        self.lastModifiedDate = lastModifiedDate
        self.serviceOrigins = serviceOrigins
    }
}

// MARK: - Service Origin

/// Links a canonical task back to its native representation in a specific service.
struct ServiceOrigin: Hashable, Codable {
    let service: ServiceType
    /// The native identifier in the originating service (e.g., EKReminder calendarItemIdentifier).
    let nativeID: String
    /// The list/calendar name in the originating service.
    let listName: String?
    /// Snapshot of the last-known modified date in the service, for conflict detection.
    var lastSyncedDate: Date?
}

// MARK: - Service Type

enum ServiceType: String, CaseIterable, Identifiable, Hashable, Comparable, Codable {
    case appleReminders = "apple_reminders"
    case googleTasks = "google_tasks"
    case microsoftToDo = "microsoft_todo"
    case appleCalendar = "apple_calendar"
    case googleCalendar = "google_calendar"
    case microsoftCalendar = "microsoft_calendar"

    var id: String { rawValue }

    private var sortOrder: Int {
        switch self {
        case .appleReminders: 0
        case .googleTasks: 1
        case .microsoftToDo: 2
        case .appleCalendar: 3
        case .googleCalendar: 4
        case .microsoftCalendar: 5
        }
    }

    static func < (lhs: ServiceType, rhs: ServiceType) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    var displayName: String {
        switch self {
        case .appleReminders: "Apple Reminders"
        case .googleTasks: "Google Tasks"
        case .microsoftToDo: "Microsoft To Do"
        case .appleCalendar: "Apple Calendar"
        case .googleCalendar: "Google Calendar"
        case .microsoftCalendar: "Microsoft Calendar"
        }
    }

    var shortName: String {
        switch self {
        case .appleReminders: "Apple"
        case .googleTasks: "Google"
        case .microsoftToDo: "Microsoft"
        case .appleCalendar: "Apple"
        case .googleCalendar: "Google"
        case .microsoftCalendar: "Microsoft"
        }
    }

    /// SF Symbol name for provider logo. `nil` for Google (use `providerLogoLetter` instead).
    var iconSystemName: String? {
        switch self {
        case .appleReminders, .appleCalendar: "apple.logo"
        case .googleTasks, .googleCalendar: nil
        case .microsoftToDo, .microsoftCalendar: "square.grid.2x2.fill"
        }
    }

    /// Letter glyph for providers without an SF Symbol (Google).
    var providerLogoLetter: String? {
        switch self {
        case .googleTasks, .googleCalendar: "G"
        default: nil
        }
    }

    /// Whether this service natively supports task priority.
    var supportsPriority: Bool {
        switch self {
        case .appleReminders: true
        case .googleTasks: false
        case .microsoftToDo: true
        case .appleCalendar: false
        case .googleCalendar: false
        case .microsoftCalendar: false
        }
    }

    /// Canonical color for this service (by provider).
    var color: Color {
        switch self {
        case .appleReminders, .appleCalendar: .blue
        case .googleTasks, .googleCalendar: .orange
        case .microsoftToDo, .microsoftCalendar: .green
        }
    }

    /// Which provider this service belongs to.
    var provider: ServiceProvider {
        switch self {
        case .appleReminders, .appleCalendar: .apple
        case .googleTasks, .googleCalendar: .google
        case .microsoftToDo, .microsoftCalendar: .microsoft
        }
    }
}

/// Groups related task + calendar services under a single provider identity.
enum ServiceProvider: String, CaseIterable, Identifiable {
    case apple
    case google
    case microsoft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        case .microsoft: "Microsoft"
        }
    }

    var iconSystemName: String? {
        switch self {
        case .apple: "apple.logo"
        case .google: nil
        case .microsoft: "square.grid.2x2.fill"
        }
    }

    var providerLogoLetter: String? {
        switch self {
        case .google: "G"
        default: nil
        }
    }

    var taskServiceType: ServiceType {
        switch self {
        case .apple: .appleReminders
        case .google: .googleTasks
        case .microsoft: .microsoftToDo
        }
    }

    var eventServiceType: ServiceType {
        switch self {
        case .apple: .appleCalendar
        case .google: .googleCalendar
        case .microsoft: .microsoftCalendar
        }
    }

    var serviceTypes: [ServiceType] {
        [taskServiceType, eventServiceType]
    }
}
