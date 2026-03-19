import EventKit
import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "AppleReminders")

/// Adapter for Apple Reminders via EventKit.
/// Runs entirely on-device, no OAuth needed.
final class AppleRemindersService: TaskServiceProtocol {
    let serviceType: ServiceType = .appleReminders

    private let store = EKEventStore()

    var isConnected: Bool {
        get async {
            let status = EKEventStore.authorizationStatus(for: .reminder)
            logger.debug("Authorization status: \(String(describing: status))")
            return status == .fullAccess
        }
    }

    func disconnect() {
        logger.info("Apple Reminders disconnect — permissions managed in Settings")
    }

    func connect() async throws {
        logger.info("Requesting Reminders access...")
        do {
            let granted = try await store.requestFullAccessToReminders()
            logger.info("Reminders access granted: \(granted)")
            guard granted else { throw TaskServiceError.accessDenied }
        } catch {
            logger.error("Reminders connect failed: \(error.localizedDescription)")
            throw error
        }
    }

    func pullTasks() async throws -> [CanonicalTask] {
        guard await isConnected else {
            logger.warning("Pull attempted but not authorized")
            throw TaskServiceError.notAuthorized
        }

        let calendars = store.calendars(for: .reminder)
        logger.info("Fetching reminders from \(calendars.count) calendars")
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )

        let reminders = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[EKReminder], Error>) in
            store.fetchReminders(matching: predicate) { result in
                cont.resume(returning: result ?? [])
            }
        }

        logger.info("Pulled \(reminders.count) reminders from Apple Reminders")
        for r in reminders {
            logger.debug("Reminder: title='\(r.title ?? "nil")' list='\(r.calendar?.title ?? "nil")' completed=\(r.isCompleted)")
        }
        return reminders.map { mapToCanonical($0) }
    }

    func pushTask(_ task: CanonicalTask) async throws {
        guard await isConnected else { throw TaskServiceError.notAuthorized }

        let reminder: EKReminder

        let appleOrigin = task.serviceOrigins.first(where: { $0.service == .appleReminders })
        logger.debug("pushTask '\(task.title)' — origins: \(task.serviceOrigins.map { "\($0.service.rawValue):\($0.nativeID)" })")

        if let origin = appleOrigin,
           let existing = store.calendarItem(withIdentifier: origin.nativeID) as? EKReminder {
            logger.info("Updating existing reminder: \(origin.nativeID)")
            reminder = existing
        } else {
            if let origin = appleOrigin {
                logger.warning("Apple origin found (\(origin.nativeID)) but calendarItem lookup failed — creating new")
            } else {
                logger.info("No Apple origin — creating new reminder")
            }
            reminder = EKReminder(eventStore: store)
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        applyCanonicalFields(task, to: reminder)
        try store.save(reminder, commit: true)
        logger.info("Saved reminder: \(reminder.calendarItemIdentifier)")
    }

    func completeTask(nativeID: String) async throws {
        guard await isConnected else { throw TaskServiceError.notAuthorized }
        guard let reminder = store.calendarItem(withIdentifier: nativeID) as? EKReminder else {
            throw TaskServiceError.taskNotFound(nativeID)
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    func deleteTask(nativeID: String) async throws {
        guard await isConnected else { throw TaskServiceError.notAuthorized }
        guard let reminder = store.calendarItem(withIdentifier: nativeID) as? EKReminder else {
            throw TaskServiceError.taskNotFound(nativeID)
        }
        try store.remove(reminder, commit: true)
    }

    // MARK: - Mapping

    private func mapToCanonical(_ reminder: EKReminder) -> CanonicalTask {
        let priority: CanonicalTask.Priority = switch reminder.priority {
        case 0: .none
        case 1...3: .high
        case 4...6: .medium
        default: .low
        }

        let origin = ServiceOrigin(
            service: .appleReminders,
            nativeID: reminder.calendarItemIdentifier,
            listName: reminder.calendar?.title,
            lastSyncedDate: Date()
        )

        return CanonicalTask(
            title: reminder.title ?? "",
            notes: reminder.notes,
            isCompleted: reminder.isCompleted,
            dueDate: reminder.dueDateComponents?.date,
            priority: priority,
            createdDate: reminder.creationDate,
            lastModifiedDate: reminder.lastModifiedDate,
            serviceOrigins: [origin]
        )
    }

    private func applyCanonicalFields(_ task: CanonicalTask, to reminder: EKReminder) {
        reminder.title = task.title
        reminder.notes = task.notes
        reminder.isCompleted = task.isCompleted

        if let dueDate = task.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        } else {
            reminder.dueDateComponents = nil
        }

        reminder.priority = switch task.priority {
        case .none: 0
        case .low: 9
        case .medium: 5
        case .high: 1
        }
    }
}
