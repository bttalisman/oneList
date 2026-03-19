import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "GoogleCalendar")

final class GoogleCalendarService: EventServiceProtocol {
    let serviceType: ServiceType = .googleCalendar

    private static let baseURL = "https://www.googleapis.com/calendar/v3"
    private let auth = GoogleAuthManager.shared

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

        let timeMin = Self.rfc3339Formatter.string(from: startDate)
        let timeMax = Self.rfc3339Formatter.string(from: endDate)
        logger.info("Pulling events from \(timeMin) to \(timeMax)")

        let calListResponse: GCalCalendarListResponse = try await apiGet(
            path: "/users/me/calendarList", token: token
        )
        let allCalendars = calListResponse.items ?? []
        for cal in allCalendars {
            logger.info("  Calendar '\(cal.summary ?? cal.id)' accessRole=\(cal.accessRole ?? "nil")")
        }
        // Only include calendars the user can write to (excludes holidays, birthdays, etc.)
        let calendars = allCalendars.filter { $0.accessRole == "owner" || $0.accessRole == "writer" }
        logger.info("Found \(calendars.count) writable calendars (skipped \(allCalendars.count - calendars.count) read-only)")

        var allEvents: [CanonicalEvent] = []

        for calendar in calendars {
            logger.debug("Fetching events from calendar '\(calendar.summary ?? calendar.id)'")
            let eventsResponse: GCalEventsResponse = try await apiGet(
                path: "/calendars/\(calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendar.id)/events",
                query: [
                    URLQueryItem(name: "timeMin", value: timeMin),
                    URLQueryItem(name: "timeMax", value: timeMax),
                    URLQueryItem(name: "singleEvents", value: "true"),
                    URLQueryItem(name: "orderBy", value: "startTime"),
                ],
                token: token
            )

            let events = (eventsResponse.items ?? []).compactMap { gEvent -> CanonicalEvent? in
                mapToCanonical(gEvent, calendarId: calendar.id, calendarName: calendar.summary ?? calendar.id)
            }
            logger.info("Pulled \(events.count) events from calendar '\(calendar.summary ?? calendar.id)'")
            allEvents.append(contentsOf: events)
        }

        logger.info("Total: \(allEvents.count) events from Google Calendar")
        return allEvents
    }

    // MARK: - Push Event

    func pushEvent(_ event: CanonicalEvent) async throws {
        let token = try await auth.validAccessToken()

        logger.debug("pushEvent '\(event.title)' — origins: \(event.serviceOrigins.map { "\($0.service.rawValue):\($0.nativeID)" })")

        if let origin = event.serviceOrigins.first(where: { $0.service == .googleCalendar }) {
            let parts = origin.nativeID.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty else {
                logger.error("Invalid Google Calendar native ID: '\(origin.nativeID)' — creating new instead")
                try await createNewGoogleEvent(event, token: token)
                return
            }
            let calendarId = String(parts[0])
            let eventId = String(parts[1])
            let body = mapToGoogleEventBody(event)
            let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
            let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
            logger.info("Updating existing Google event: calendarId=\(calendarId) eventId=\(eventId)")
            let _: GCalEvent = try await apiPatch(
                path: "/calendars/\(encodedCalId)/events/\(encodedEventId)", body: body, token: token
            )
            logger.info("Updated event '\(event.title)' in Google Calendar")
        } else {
            logger.info("No Google Calendar origin — creating new event")
            try await createNewGoogleEvent(event, token: token)
        }
    }

    private func createNewGoogleEvent(_ event: CanonicalEvent, token: String) async throws {
        let body = mapToGoogleEventBody(event)
        let _: GCalEvent = try await apiPost(
            path: "/calendars/primary/events", body: body, token: token
        )
        logger.info("Created event '\(event.title)' in Google Calendar")
    }

    // MARK: - Delete Event

    func deleteEvent(nativeID: String) async throws {
        let token = try await auth.validAccessToken()
        let parts = nativeID.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else {
            throw EventServiceError.eventNotFound(nativeID)
        }
        let calendarId = String(parts[0])
        let eventId = String(parts[1])
        let encodedCalId = calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId
        let encodedEventId = eventId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventId
        try await apiDelete(path: "/calendars/\(encodedCalId)/events/\(encodedEventId)", token: token)
        logger.info("Deleted event \(nativeID)")
    }

    // MARK: - Mapping (Google -> Canonical)

    private func mapToCanonical(_ gEvent: GCalEvent, calendarId: String, calendarName: String) -> CanonicalEvent? {
        logger.debug("Mapping Google event: id=\(gEvent.id) summary='\(gEvent.summary ?? "nil")' status=\(gEvent.status ?? "nil") eventType=\(gEvent.eventType ?? "nil")")

        if gEvent.status == "cancelled" {
            logger.debug("  Skipping cancelled event \(gEvent.id)")
            return nil
        }

        // Skip non-default event types (focusTime = Google Tasks with dates, outOfOffice, etc.)
        if let eventType = gEvent.eventType, eventType != "default" {
            logger.debug("  Skipping non-default eventType '\(eventType)' for '\(gEvent.summary ?? gEvent.id)'")
            return nil
        }

        let isAllDay: Bool
        let startDate: Date
        let endDate: Date

        if let startDateStr = gEvent.start?.date, let endDateStr = gEvent.end?.date {
            isAllDay = true
            guard let start = Self.dateOnlyFormatter.date(from: startDateStr),
                  let end = Self.dateOnlyFormatter.date(from: endDateStr) else {
                logger.error("  Failed to parse all-day dates: start='\(startDateStr)' end='\(endDateStr)'")
                return nil
            }
            startDate = start
            endDate = end
        } else if let startDT = gEvent.start?.dateTime, let endDT = gEvent.end?.dateTime {
            isAllDay = false
            guard let start = Self.rfc3339Formatter.date(from: startDT) ?? Self.iso8601FractionalFormatter.date(from: startDT),
                  let end = Self.rfc3339Formatter.date(from: endDT) ?? Self.iso8601FractionalFormatter.date(from: endDT) else {
                logger.error("  Failed to parse dateTime: start='\(startDT)' end='\(endDT)'")
                return nil
            }
            startDate = start
            endDate = end
        } else {
            logger.error("  Event \(gEvent.id) has no valid start/end — skipping")
            return nil
        }

        let eventTimeZone: TimeZone?
        if let tzString = gEvent.start?.timeZone {
            eventTimeZone = TimeZone(identifier: tzString)
        } else {
            eventTimeZone = nil
        }

        let origin = ServiceOrigin(
            service: .googleCalendar,
            nativeID: "\(calendarId)/\(gEvent.id)",
            listName: calendarName,
            lastSyncedDate: Date()
        )

        let createdDate = gEvent.created.flatMap { Self.rfc3339Formatter.date(from: $0) }
            ?? gEvent.created.flatMap { Self.iso8601FractionalFormatter.date(from: $0) }
        let updatedDate = gEvent.updated.flatMap { Self.rfc3339Formatter.date(from: $0) }
            ?? gEvent.updated.flatMap { Self.iso8601FractionalFormatter.date(from: $0) }

        return CanonicalEvent(
            title: gEvent.summary ?? "(No title)",
            notes: gEvent.description,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: gEvent.location,
            timeZone: eventTimeZone,
            createdDate: createdDate,
            lastModifiedDate: updatedDate,
            serviceOrigins: [origin]
        )
    }

    // MARK: - Mapping (Canonical -> Google)

    private func mapToGoogleEventBody(_ event: CanonicalEvent) -> [String: Any] {
        var body: [String: Any] = [
            "summary": event.title,
        ]

        if let notes = event.notes, !notes.isEmpty {
            body["description"] = notes
        }

        if let location = event.location, !location.isEmpty {
            body["location"] = location
        }

        if event.isAllDay {
            let startStr = Self.dateOnlyFormatter.string(from: event.startDate)
            // Google uses exclusive end dates for all-day events (end = day after last day).
            // Apple EventKit already uses exclusive end dates (midnight of day after last day),
            // so only add a day if the end date is NOT already at midnight.
            let endComponents = Calendar.current.dateComponents([.hour, .minute, .second], from: event.endDate)
            let isAlreadyExclusive = endComponents.hour == 0 && endComponents.minute == 0 && endComponents.second == 0
            logger.info("All-day push '\(event.title)': startDate=\(event.startDate) endDate=\(event.endDate) endH=\(endComponents.hour ?? -1) endM=\(endComponents.minute ?? -1) endS=\(endComponents.second ?? -1) isAlreadyExclusive=\(isAlreadyExclusive)")
            let exclusiveEnd: Date
            if isAlreadyExclusive {
                exclusiveEnd = event.endDate
            } else {
                exclusiveEnd = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: event.endDate))!
            }
            let endStr = Self.dateOnlyFormatter.string(from: exclusiveEnd)
            logger.info("All-day push '\(event.title)': sending start=\(startStr) end=\(endStr) exclusiveEnd=\(exclusiveEnd)")
            body["start"] = ["date": startStr]
            body["end"] = ["date": endStr]
        } else {
            let tz = event.timeZone ?? .current
            let tzIdentifier = tz.identifier
            let startStr = Self.rfc3339Formatter.string(from: event.startDate)
            let endStr = Self.rfc3339Formatter.string(from: event.endDate)
            body["start"] = ["dateTime": startStr, "timeZone": tzIdentifier] as [String: String]
            body["end"] = ["dateTime": endStr, "timeZone": tzIdentifier] as [String: String]
        }

        return body
    }

    // MARK: - Date Formatters

    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = Calendar.current.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Network Helpers

    private func apiGet<T: Decodable>(
        path: String, query: [URLQueryItem] = [], token: String
    ) async throws -> T {
        var components = URLComponents(string: Self.baseURL + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logger.debug("GET \(components.url?.absoluteString ?? path)")
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
                NSError(domain: "GoogleCalendar", code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            )
        }
    }
}

// MARK: - API Response Models

struct GCalCalendarListResponse: Decodable {
    let items: [GCalCalendar]?
}

struct GCalCalendar: Decodable {
    let id: String
    let summary: String?
    let accessRole: String?
}

struct GCalEventsResponse: Decodable {
    let items: [GCalEvent]?
}

struct GCalEvent: Decodable {
    let id: String
    let summary: String?
    let description: String?
    let location: String?
    let start: GCalDateTime?
    let end: GCalDateTime?
    let status: String?
    let created: String?
    let updated: String?
    let eventType: String?
}

struct GCalDateTime: Decodable {
    let dateTime: String?
    let date: String?
    let timeZone: String?
}
