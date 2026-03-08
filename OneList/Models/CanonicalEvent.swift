import Foundation

// MARK: - Canonical Event

/// The unified internal representation of a calendar event, independent of any service.
/// Each service adapter maps to/from this format.
struct CanonicalEvent: Identifiable, Hashable {
    let id: UUID
    var title: String
    var notes: String?
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var location: String?
    var timeZone: TimeZone?
    var createdDate: Date?
    var lastModifiedDate: Date?

    /// Tracks where this event came from and its native ID in that service.
    var serviceOrigins: [ServiceOrigin]

    init(
        id: UUID = UUID(),
        title: String,
        notes: String? = nil,
        startDate: Date = Date(),
        endDate: Date = Date().addingTimeInterval(3600),
        isAllDay: Bool = false,
        location: String? = nil,
        timeZone: TimeZone? = nil,
        createdDate: Date? = nil,
        lastModifiedDate: Date? = nil,
        serviceOrigins: [ServiceOrigin] = []
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.timeZone = timeZone
        self.createdDate = createdDate
        self.lastModifiedDate = lastModifiedDate
        self.serviceOrigins = serviceOrigins
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CanonicalEvent, rhs: CanonicalEvent) -> Bool {
        lhs.id == rhs.id
    }
}
