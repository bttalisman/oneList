import Foundation
import os

private let logger = Logger(subsystem: "com.onelist", category: "MicrosoftCalendar")

final class MicrosoftCalendarService: EventServiceProtocol {
    let serviceType: ServiceType = .microsoftCalendar

    private static let baseURL = "https://graph.microsoft.com/v1.0/me"
    private let auth = MicrosoftAuthManager.shared

    var isConnected: Bool {
        get async { await auth.isConnected }
    }

    func disconnect() {
        auth.disconnect()
    }

    func connect() async throws {
        try await auth.connect()
    }

    // MARK: - Pull Events

    func pullEvents(from startDate: Date, to endDate: Date) async throws -> [CanonicalEvent] {
        let token = try await auth.validAccessToken()

        let startStr = Self.iso8601Formatter.string(from: startDate)
        let endStr = Self.iso8601Formatter.string(from: endDate)
        logger.info("Pulling events from \(startStr) to \(endStr)")

        let response: MSCalEventsResponse = try await apiGet(
            path: "/calendarView?startDateTime=\(startStr)&endDateTime=\(endStr)&$top=500",
            token: token
        )

        let events = response.value.compactMap { mapToCanonical($0) }
        logger.info("Pulled \(events.count) events from Microsoft Calendar")
        return events
    }

    // MARK: - Push Event

    func pushEvent(_ event: CanonicalEvent) async throws {
        let token = try await auth.validAccessToken()

        if let origin = event.serviceOrigins.first(where: { $0.service == .microsoftCalendar }) {
            logger.info("Updating existing MS event: \(origin.nativeID)")
            let body = mapToMSEventBody(event)
            let _: MSCalEvent = try await apiPatch(
                path: "/events/\(origin.nativeID)", body: body, token: token
            )
            logger.info("Updated event '\(event.title)' in Microsoft Calendar")
        } else {
            logger.info("No Microsoft Calendar origin — creating new event")
            let body = mapToMSEventBody(event)
            let _: MSCalEvent = try await apiPost(
                path: "/calendars/\(try await defaultCalendarId(token: token))/events",
                body: body, token: token
            )
            logger.info("Created event '\(event.title)' in Microsoft Calendar")
        }
    }

    // MARK: - Delete Event

    func deleteEvent(nativeID: String) async throws {
        let token = try await auth.validAccessToken()
        try await apiDelete(path: "/events/\(nativeID)", token: token)
        logger.info("Deleted event \(nativeID)")
    }

    // MARK: - Helpers

    private func defaultCalendarId(token: String) async throws -> String {
        let response: MSCalCalendarsResponse = try await apiGet(
            path: "/calendars?$filter=isDefaultCalendar eq true", token: token
        )
        guard let cal = response.value.first else {
            let allCals: MSCalCalendarsResponse = try await apiGet(path: "/calendars", token: token)
            guard let first = allCals.value.first else {
                throw EventServiceError.mappingError("No calendars found")
            }
            return first.id
        }
        return cal.id
    }

    // MARK: - Mapping (MS -> Canonical)

    private func mapToCanonical(_ msEvent: MSCalEvent) -> CanonicalEvent? {
        if msEvent.isCancelled == true { return nil }

        let isAllDay = msEvent.isAllDay ?? false

        let startDate: Date
        let endDate: Date

        if let start = msEvent.start {
            if let d = parseMSDateTime(start) {
                startDate = d
            } else {
                logger.error("Failed to parse start date for event '\(msEvent.subject ?? "nil")'")
                return nil
            }
        } else {
            return nil
        }

        if let end = msEvent.end {
            if let d = parseMSDateTime(end) {
                endDate = d
            } else {
                logger.error("Failed to parse end date for event '\(msEvent.subject ?? "nil")'")
                return nil
            }
        } else {
            return nil
        }

        let eventTimeZone: TimeZone?
        if let tzString = msEvent.start?.timeZone {
            eventTimeZone = TimeZone(identifier: tzString)
                ?? TimeZone(abbreviation: tzString)
        } else {
            eventTimeZone = nil
        }

        let origin = ServiceOrigin(
            service: .microsoftCalendar,
            nativeID: msEvent.id,
            listName: nil,
            lastSyncedDate: Date()
        )

        let createdDate = msEvent.createdDateTime.flatMap { Self.iso8601Formatter.date(from: $0) }
            ?? msEvent.createdDateTime.flatMap { Self.iso8601FractionalFormatter.date(from: $0) }
        let modifiedDate = msEvent.lastModifiedDateTime.flatMap { Self.iso8601Formatter.date(from: $0) }
            ?? msEvent.lastModifiedDateTime.flatMap { Self.iso8601FractionalFormatter.date(from: $0) }

        return CanonicalEvent(
            title: msEvent.subject ?? "(No title)",
            notes: msEvent.body?.content,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: msEvent.location?.displayName,
            timeZone: eventTimeZone,
            createdDate: createdDate,
            lastModifiedDate: modifiedDate,
            serviceOrigins: [origin]
        )
    }

    private func parseMSDateTime(_ dt: MSCalDateTime) -> Date? {
        let dateTime = dt.dateTime
        let tz = TimeZone(identifier: dt.timeZone)
            ?? TimeZone(abbreviation: dt.timeZone)
            ?? .current

        if let d = Self.iso8601Formatter.date(from: dateTime) { return d }
        if let d = Self.iso8601FractionalFormatter.date(from: dateTime) { return d }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz

        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: dateTime) { return d }
        }

        return nil
    }

    // MARK: - Mapping (Canonical -> MS)

    private func mapToMSEventBody(_ event: CanonicalEvent) -> [String: Any] {
        var body: [String: Any] = [
            "subject": event.title,
            "isAllDay": event.isAllDay,
        ]

        if let notes = event.notes, !notes.isEmpty {
            body["body"] = [
                "contentType": "text",
                "content": notes,
            ]
        }

        if let location = event.location, !location.isEmpty {
            body["location"] = ["displayName": location]
        }

        let tz = event.timeZone ?? .current
        let tzId = tz.identifier

        if event.isAllDay {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = tz
            body["start"] = ["dateTime": "\(formatter.string(from: event.startDate))T00:00:00", "timeZone": tzId]
            body["end"] = ["dateTime": "\(formatter.string(from: event.endDate))T00:00:00", "timeZone": tzId]
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            formatter.timeZone = tz
            formatter.locale = Locale(identifier: "en_US_POSIX")
            body["start"] = ["dateTime": formatter.string(from: event.startDate), "timeZone": tzId]
            body["end"] = ["dateTime": formatter.string(from: event.endDate), "timeZone": tzId]
        }

        return body
    }

    // MARK: - Date Formatters

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Network Helpers

    private func apiGet<T: Decodable>(path: String, token: String) async throws -> T {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func apiPost<T: Decodable>(
        path: String, body: [String: Any], token: String
    ) async throws -> T {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func apiPatch<T: Decodable>(
        path: String, body: [String: Any], token: String
    ) async throws -> T {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func apiDelete(path: String, token: String) async throws {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)
    }

    private func checkHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("HTTP \(http.statusCode): \(body)")
            if http.statusCode == 401 {
                throw EventServiceError.notAuthorized
            }
            throw EventServiceError.networkError(
                NSError(domain: "MicrosoftCalendar", code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            )
        }
    }
}

// MARK: - API Response Models

private struct MSCalCalendarsResponse: Decodable {
    let value: [MSCalCalendar]
}

private struct MSCalCalendar: Decodable {
    let id: String
    let name: String?
    let isDefaultCalendar: Bool?
}

private struct MSCalEventsResponse: Decodable {
    let value: [MSCalEvent]
}

struct MSCalEvent: Decodable {
    let id: String
    let subject: String?
    let body: MSCalEventBody?
    let start: MSCalDateTime?
    let end: MSCalDateTime?
    let location: MSCalLocation?
    let isAllDay: Bool?
    let isCancelled: Bool?
    let createdDateTime: String?
    let lastModifiedDateTime: String?
}

struct MSCalEventBody: Decodable {
    let contentType: String?
    let content: String?
}

struct MSCalDateTime: Decodable {
    let dateTime: String
    let timeZone: String
}

struct MSCalLocation: Decodable {
    let displayName: String?
}
