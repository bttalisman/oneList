import Foundation

// MARK: - Canonical Event

/// The unified internal representation of a calendar event, independent of any service.
/// Each service adapter maps to/from this format.
struct CanonicalEvent: Identifiable, Hashable, Codable {
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

    // Custom Codable for TimeZone (not Codable by default)
    enum CodingKeys: String, CodingKey {
        case id, title, notes, startDate, endDate, isAllDay, location
        case timeZoneIdentifier, createdDate, lastModifiedDate, serviceOrigins
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encode(isAllDay, forKey: .isAllDay)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encodeIfPresent(timeZone?.identifier, forKey: .timeZoneIdentifier)
        try container.encodeIfPresent(createdDate, forKey: .createdDate)
        try container.encodeIfPresent(lastModifiedDate, forKey: .lastModifiedDate)
        try container.encode(serviceOrigins, forKey: .serviceOrigins)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        if let tzID = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) {
            timeZone = TimeZone(identifier: tzID)
        } else {
            timeZone = nil
        }
        createdDate = try container.decodeIfPresent(Date.self, forKey: .createdDate)
        lastModifiedDate = try container.decodeIfPresent(Date.self, forKey: .lastModifiedDate)
        serviceOrigins = try container.decode([ServiceOrigin].self, forKey: .serviceOrigins)
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CanonicalEvent, rhs: CanonicalEvent) -> Bool {
        lhs.id == rhs.id
    }
}
