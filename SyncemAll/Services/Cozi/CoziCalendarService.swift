import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "CoziCalendar")

/// Read-only calendar service that fetches events from a Cozi ICS feed URL.
/// Cozi does not have a public API, so push and delete are not supported.
final class CoziCalendarService: EventServiceProtocol {
    let serviceType: ServiceType = .coziCalendar

    private static let feedURLKey = "cozi_ics_feed_url"

    var feedURL: String? {
        get { KeychainHelper.loadString(key: Self.feedURLKey) }
        set {
            if let newValue {
                KeychainHelper.saveString(newValue, for: Self.feedURLKey)
            } else {
                KeychainHelper.delete(key: Self.feedURLKey)
            }
        }
    }

    var isConnected: Bool {
        get async {
            guard let url = feedURL, !url.isEmpty else { return false }
            return true
        }
    }

    func connect() async throws {
        // Connection is handled by the UI setting the feedURL.
        // If called without a URL set, throw an error.
        guard let url = feedURL, !url.isEmpty else {
            throw EventServiceError.notAuthorized
        }
        guard let parsedURL = URL(string: url) else {
            throw EventServiceError.mappingError("Invalid Cozi feed URL")
        }
        // Validate by fetching the feed (some servers reject HEAD requests)
        let request = URLRequest(url: parsedURL)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("Cozi feed validation failed: HTTP \(statusCode)")
            throw EventServiceError.networkError(
                NSError(domain: "Cozi", code: statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Could not reach Cozi feed URL (HTTP \(statusCode))"])
            )
        }
        // Sanity check that it looks like an ICS file
        let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
        guard preview.contains("BEGIN:VCALENDAR") else {
            logger.error("Feed does not appear to be valid ICS data")
            throw EventServiceError.mappingError("URL does not appear to be a valid ICS calendar feed")
        }
        logger.info("Cozi feed URL validated successfully (\(data.count) bytes)")
    }

    func disconnect() {
        logger.info("Disconnecting Cozi — clearing feed URL")
        feedURL = nil
    }

    // MARK: - Pull Events

    func pullEvents(from startDate: Date, to endDate: Date) async throws -> [CanonicalEvent] {
        guard let urlString = feedURL, let url = URL(string: urlString) else {
            throw EventServiceError.notAuthorized
        }

        logger.info("Fetching Cozi ICS feed...")
        let request = URLRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EventServiceError.networkError(
                NSError(domain: "Cozi", code: statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode) fetching Cozi feed"])
            )
        }

        guard let icsString = String(data: data, encoding: .utf8) else {
            throw EventServiceError.mappingError("Could not decode Cozi feed as UTF-8")
        }

        let allEvents = parseICS(icsString)
        let filtered = allEvents.filter { event in
            event.endDate >= startDate && event.startDate <= endDate
        }

        logger.info("Parsed \(allEvents.count) total events, \(filtered.count) in date range from Cozi")
        return filtered
    }

    // MARK: - Push / Delete (not supported)

    func pushEvent(_ event: CanonicalEvent) async throws {
        logger.info("Push not supported for Cozi (read-only)")
    }

    func deleteEvent(nativeID: String) async throws {
        logger.info("Delete not supported for Cozi (read-only)")
    }

    // MARK: - ICS Parser

    private func parseICS(_ ics: String) -> [CanonicalEvent] {
        var events: [CanonicalEvent] = []
        let lines = unfoldICSLines(ics)

        var inEvent = false
        var eventProps: [(key: String, value: String)] = []

        for line in lines {
            if line == "BEGIN:VEVENT" {
                inEvent = true
                eventProps = []
            } else if line == "END:VEVENT" {
                inEvent = false
                if let event = buildEvent(from: eventProps) {
                    events.append(event)
                }
            } else if inEvent {
                if let colonIndex = line.firstIndex(of: ":") {
                    let key = String(line[line.startIndex..<colonIndex])
                    let value = String(line[line.index(after: colonIndex)...])
                    eventProps.append((key: key, value: value))
                }
            }
        }

        return events
    }

    /// ICS long lines are folded with CRLF + whitespace. Unfold them.
    private func unfoldICSLines(_ ics: String) -> [String] {
        let raw = ics.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix(" ") || s.hasPrefix("\t") {
                // Continuation of previous line
                if !lines.isEmpty {
                    lines[lines.count - 1] += String(s.dropFirst())
                }
            } else {
                lines.append(s)
            }
        }
        return lines
    }

    private func buildEvent(from props: [(key: String, value: String)]) -> CanonicalEvent? {
        var title = ""
        var notes: String?
        var location: String?
        var startDate: Date?
        var endDate: Date?
        var isAllDay = false
        var uid: String?
        var created: Date?
        var modified: Date?

        for (key, value) in props {
            let baseKey = key.split(separator: ";").first.map(String.init) ?? key

            switch baseKey {
            case "SUMMARY":
                title = unescapeICS(value)
            case "DESCRIPTION":
                let desc = unescapeICS(value)
                if !desc.isEmpty { notes = desc }
            case "LOCATION":
                let loc = unescapeICS(value)
                if !loc.isEmpty { location = loc }
            case "DTSTART":
                let params = extractParams(from: key)
                if params["VALUE"] == "DATE" || value.count == 8 {
                    isAllDay = true
                    startDate = parseICSDateOnly(value)
                } else {
                    startDate = parseICSDateTime(value, tzid: params["TZID"])
                }
            case "DTEND":
                let params = extractParams(from: key)
                if params["VALUE"] == "DATE" || value.count == 8 {
                    endDate = parseICSDateOnly(value)
                } else {
                    endDate = parseICSDateTime(value, tzid: params["TZID"])
                }
            case "DURATION":
                if let start = startDate, let duration = parseICSPeriod(value) {
                    endDate = start.addingTimeInterval(duration)
                }
            case "UID":
                uid = value
            case "CREATED":
                created = parseICSDateTime(value, tzid: nil)
            case "LAST-MODIFIED":
                modified = parseICSDateTime(value, tzid: nil)
            default:
                break
            }
        }

        guard !title.isEmpty, let start = startDate else {
            logger.debug("Skipping event with missing title or start date")
            return nil
        }

        let end = endDate ?? (isAllDay ? Calendar.current.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(3600))

        let origin = ServiceOrigin(
            service: .coziCalendar,
            nativeID: uid ?? UUID().uuidString,
            listName: "Cozi",
            lastSyncedDate: Date()
        )

        return CanonicalEvent(
            title: title,
            notes: notes,
            startDate: start,
            endDate: end,
            isAllDay: isAllDay,
            location: location,
            createdDate: created,
            lastModifiedDate: modified,
            serviceOrigins: [origin]
        )
    }

    // MARK: - ICS Date Parsing

    private func parseICSDateOnly(_ value: String) -> Date? {
        // Format: YYYYMMDD
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = Calendar.current.timeZone
        return formatter.date(from: String(value.prefix(8)))
    }

    private func parseICSDateTime(_ value: String, tzid: String?) -> Date? {
        let cleaned = value.trimmingCharacters(in: .whitespaces)

        // Format: YYYYMMDDTHHMMSS or YYYYMMDDTHHMMSSZ
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if cleaned.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else if let tzid, let tz = TimeZone(identifier: tzid) {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = tz
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = Calendar.current.timeZone
        }

        return formatter.date(from: cleaned)
    }

    /// Parse ICS DURATION values like P1D, PT1H30M, P1W.
    private func parseICSPeriod(_ value: String) -> TimeInterval? {
        var remaining = value.trimmingCharacters(in: .whitespaces)
        guard remaining.hasPrefix("P") else { return nil }
        remaining = String(remaining.dropFirst())

        var seconds: TimeInterval = 0
        var inTime = false

        var numStr = ""
        for char in remaining {
            if char == "T" {
                inTime = true
            } else if char.isNumber {
                numStr.append(char)
            } else {
                guard let num = Double(numStr) else { return nil }
                numStr = ""
                switch (inTime, char) {
                case (false, "W"): seconds += num * 604800
                case (false, "D"): seconds += num * 86400
                case (true, "H"): seconds += num * 3600
                case (true, "M"): seconds += num * 60
                case (true, "S"): seconds += num
                default: break
                }
            }
        }
        return seconds > 0 ? seconds : nil
    }

    private func extractParams(from key: String) -> [String: String] {
        var params: [String: String] = [:]
        let parts = key.split(separator: ";")
        for part in parts.dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                params[String(kv[0])] = String(kv[1])
            }
        }
        return params
    }

    private func unescapeICS(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
