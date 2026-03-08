import EventKit
import Foundation
import os

private let logger = Logger(subsystem: "com.onelist", category: "AppleCalendar")

/// Adapter for Apple Calendar via EventKit.
/// Runs entirely on-device, no OAuth needed.
final class AppleCalendarService: EventServiceProtocol {
    let serviceType: ServiceType = .appleCalendar

    private let store = EKEventStore()

    var isConnected: Bool {
        get async {
            let status = EKEventStore.authorizationStatus(for: .event)
            logger.info("Apple Calendar authorization status: \(String(describing: status)) (rawValue: \(status.rawValue))")
            if status == .fullAccess {
                return true
            }
            // Fallback: some iOS versions report .notDetermined even after granting.
            // Try accessing calendars as a connectivity test.
            let calendars = store.calendars(for: .event)
            if !calendars.isEmpty {
                logger.info("Apple Calendar status is \(String(describing: status)) but found \(calendars.count) calendars — treating as connected")
                return true
            }
            logger.info("Apple Calendar not connected — status: \(String(describing: status)), no accessible calendars")
            return false
        }
    }

    func disconnect() {
        // Apple Calendar permissions are managed in system Settings — nothing to clear here
        logger.info("Apple Calendar disconnect — permissions managed in Settings")
    }

    func connect() async throws {
        let statusBefore = EKEventStore.authorizationStatus(for: .event)
        logger.info("Requesting Calendar access... (status before: \(String(describing: statusBefore)) rawValue: \(statusBefore.rawValue))")
        do {
            let granted = try await store.requestFullAccessToEvents()
            let statusAfter = EKEventStore.authorizationStatus(for: .event)
            logger.info("Calendar requestFullAccessToEvents returned: \(granted), status after: \(String(describing: statusAfter)) rawValue: \(statusAfter.rawValue)")
            guard statusAfter == .fullAccess else {
                logger.error("Calendar access not actually granted. Status: \(String(describing: statusAfter)). Make sure NSCalendarsFullAccessUsageDescription is in Info.plist.")
                throw EventServiceError.accessDenied
            }
        } catch {
            logger.error("Calendar connect failed: \(error.localizedDescription)")
            throw error
        }
    }

    func pullEvents(from startDate: Date, to endDate: Date) async throws -> [CanonicalEvent] {
        guard await isConnected else {
            logger.warning("Pull attempted but not authorized")
            throw EventServiceError.notAuthorized
        }

        let allCalendars = store.calendars(for: .event)
        // Exclude read-only/subscription calendars (holidays, birthdays, etc.)
        let calendars = allCalendars.filter { $0.allowsContentModifications }
        logger.info("Fetching events from \(calendars.count) editable calendars (skipped \(allCalendars.count - calendars.count) read-only) between \(startDate) and \(endDate)")

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = store.events(matching: predicate)

        logger.info("Pulled \(events.count) events from Apple Calendar")
        for event in events {
            logger.debug("Event: title='\(event.title ?? "nil")' calendar='\(event.calendar?.title ?? "nil")' allDay=\(event.isAllDay)")
        }

        return events.map { mapToCanonical($0) }
    }

    func pushEvent(_ event: CanonicalEvent) async throws {
        guard await isConnected else { throw EventServiceError.notAuthorized }

        let ekEvent: EKEvent

        let appleOrigin = event.serviceOrigins.first(where: { $0.service == .appleCalendar })
        logger.debug("pushEvent '\(event.title)' — origins: \(event.serviceOrigins.map { "\($0.service.rawValue):\($0.nativeID)" })")

        if let origin = appleOrigin,
           let existing = store.event(withIdentifier: origin.nativeID) {
            logger.info("Updating existing event: \(origin.nativeID)")
            ekEvent = existing
        } else {
            if let origin = appleOrigin {
                logger.warning("Apple origin found (\(origin.nativeID)) but event lookup failed — creating new")
            } else {
                logger.info("No Apple origin — creating new event")
            }
            ekEvent = EKEvent(eventStore: store)
            ekEvent.calendar = store.defaultCalendarForNewEvents
        }

        applyCanonicalFields(event, to: ekEvent)
        try store.save(ekEvent, span: .thisEvent, commit: true)
        logger.info("Saved event: \(ekEvent.eventIdentifier ?? "nil")")
    }

    func deleteEvent(nativeID: String) async throws {
        guard await isConnected else { throw EventServiceError.notAuthorized }
        guard let event = store.event(withIdentifier: nativeID) else {
            throw EventServiceError.eventNotFound(nativeID)
        }
        try store.remove(event, span: .thisEvent, commit: true)
        logger.info("Deleted event: \(nativeID)")
    }

    // MARK: - Mapping

    private func mapToCanonical(_ event: EKEvent) -> CanonicalEvent {
        let origin = ServiceOrigin(
            service: .appleCalendar,
            nativeID: event.eventIdentifier,
            listName: event.calendar?.title,
            lastSyncedDate: Date()
        )

        return CanonicalEvent(
            title: event.title ?? "",
            notes: event.notes,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location,
            timeZone: event.timeZone,
            createdDate: event.creationDate,
            lastModifiedDate: event.lastModifiedDate,
            serviceOrigins: [origin]
        )
    }

    private func applyCanonicalFields(_ canonical: CanonicalEvent, to event: EKEvent) {
        event.title = canonical.title
        event.notes = canonical.notes
        event.startDate = canonical.startDate
        event.endDate = canonical.endDate
        event.isAllDay = canonical.isAllDay
        event.location = canonical.location
        event.timeZone = canonical.timeZone
    }
}
