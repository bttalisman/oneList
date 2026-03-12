import Foundation
import os
import SwiftUI

private let logger = Logger(subsystem: "com.onelist", category: "CalendarView")

@MainActor
@Observable
final class CalendarViewModel {
    var eventViewModel: EventMergeReviewViewModel
    var taskViewModel: MergeReviewViewModel

    var displayedMonth: Date
    var selectedDate: Date? = nil
    var filter: SourceFilter = .all

    private let calendar = Calendar.current

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case apple = "Apple"
        case google = "Google"
        case microsoft = "Microsoft"
        case matched = "Matched"

        var id: String { rawValue }

        var serviceTypes: [ServiceType] {
            switch self {
            case .all, .matched: ServiceType.allCases
            case .apple: [.appleCalendar, .appleReminders]
            case .google: [.googleCalendar, .googleTasks]
            case .microsoft: [.microsoftCalendar, .microsoftToDo]
            }
        }
    }

    init(eventViewModel: EventMergeReviewViewModel, taskViewModel: MergeReviewViewModel) {
        self.eventViewModel = eventViewModel
        self.taskViewModel = taskViewModel
        self.displayedMonth = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: Date())
        ) ?? Date()
    }

    // MARK: - Deduplicated Events

    /// Union of all pulled events, deduplicated by (normalizedTitle, startOfDay).
    /// Events from multiple services with the same key get their serviceOrigins merged.
    var deduplicatedEvents: [CanonicalEvent] {
        let allEvents = eventViewModel.lastPulledEventsByService.values.flatMap { $0 }

        var grouped: [String: CanonicalEvent] = [:]
        for event in allEvents {
            let key = deduplicationKey(for: event)
            if var existing = grouped[key] {
                // Merge service origins
                for origin in event.serviceOrigins where !existing.serviceOrigins.contains(where: { $0.service == origin.service }) {
                    existing.serviceOrigins.append(origin)
                }
                grouped[key] = existing
            } else {
                grouped[key] = event
            }
        }
        return Array(grouped.values)
    }

    /// Filtered events based on the current source filter.
    var filteredEvents: [CanonicalEvent] {
        let events = deduplicatedEvents
        switch filter {
        case .all:
            return events
        case .matched:
            let uniqueServices = { (origins: [ServiceOrigin]) -> Int in
                Set(origins.map(\.service)).count
            }
            return events.filter { uniqueServices($0.serviceOrigins) >= 2 }
        case .apple, .google, .microsoft:
            let types = filter.serviceTypes
            return events.filter { event in
                event.serviceOrigins.contains { types.contains($0.service) }
            }
        }
    }

    /// Deduplicated tasks with due dates.
    var deduplicatedTasks: [CanonicalTask] {
        let allTasks = taskViewModel.lastPulledTasksByService.values.flatMap { $0 }
        var grouped: [String: CanonicalTask] = [:]
        for task in allTasks {
            guard let dueDate = task.dueDate else { continue }
            let key = "\(task.title.lowercased().trimmingCharacters(in: .whitespaces))|\(calendar.startOfDay(for: dueDate).timeIntervalSince1970)"
            if var existing = grouped[key] {
                for origin in task.serviceOrigins where !existing.serviceOrigins.contains(where: { $0.service == origin.service }) {
                    existing.serviceOrigins.append(origin)
                }
                grouped[key] = existing
            } else {
                grouped[key] = task
            }
        }
        return Array(grouped.values)
    }

    /// Filtered tasks based on the current source filter.
    var filteredTasks: [CanonicalTask] {
        let tasks = deduplicatedTasks
        switch filter {
        case .all:
            return tasks
        case .matched:
            return tasks.filter { Set($0.serviceOrigins.map(\.service)).count >= 2 }
        case .apple, .google, .microsoft:
            let types = filter.serviceTypes
            return tasks.filter { task in
                task.serviceOrigins.contains { types.contains($0.service) }
            }
        }
    }

    // MARK: - Date Queries

    /// A UTC calendar for interpreting all-day event dates, which are stored as UTC midnight.
    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    func eventsForDate(_ date: Date) -> [CanonicalEvent] {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let result = filteredEvents
            .filter { event in
                if event.isAllDay {
                    // All-day dates are calendar dates stored as UTC midnight.
                    // Extract the date components in UTC, then reconstruct in local timezone.
                    let utcCal = CalendarViewModel.utcCalendar
                    let startComps = utcCal.dateComponents([.year, .month, .day], from: event.startDate)
                    let endComps = utcCal.dateComponents([.year, .month, .day], from: event.endDate)
                    let eventDay = calendar.date(from: startComps)!
                    let eventEndDay = calendar.date(from: endComps)!
                    // End date is exclusive for all-day events (Google/Microsoft convention)
                    return eventDay <= dayStart && dayStart < eventEndDay
                } else {
                    return event.startDate < dayEnd && event.endDate > dayStart
                }
            }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
        logger.debug("eventsForDate(\(date.formatted(.dateTime.month().day()))): filter=\(self.filter.rawValue), filteredEvents=\(self.filteredEvents.count), result=\(result.count)")
        for event in result {
            let services = event.serviceOrigins.map(\.service.displayName).joined(separator: ", ")
            logger.debug("  → \(event.title) [\(services)]")
        }
        return result
    }

    func tasksForDate(_ date: Date) -> [CanonicalTask] {
        let dayStart = calendar.startOfDay(for: date)
        let result = filteredTasks.filter { task in
            guard let dueDate = task.dueDate else { return false }
            return calendar.startOfDay(for: dueDate) == dayStart
        }
        logger.debug("tasksForDate(\(date.formatted(.dateTime.month().day()))): filter=\(self.filter.rawValue), count=\(result.count)")
        return result
    }

    func dotsForDate(_ date: Date) -> [Color] {
        let events = eventsForDate(date)
        let tasks = tasksForDate(date)
        var serviceSet = Set<ServiceType>()
        for event in events {
            for origin in event.serviceOrigins {
                serviceSet.insert(origin.service)
            }
        }
        for task in tasks {
            for origin in task.serviceOrigins {
                serviceSet.insert(origin.service)
            }
        }
        // Return up to 3 distinct provider colors, in consistent order
        return serviceSet
            .sorted()
            .map(\.color)
            .reduce(into: [Color]()) { result, color in
                if !result.contains(color) { result.append(color) }
            }
            .prefix(3)
            .map { $0 }
    }

    func hasTasksOnDate(_ date: Date) -> Bool {
        !tasksForDate(date).isEmpty
    }

    // MARK: - Month Grid

    var daysInMonth: [Date] {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        guard let firstOfMonth = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        // Sunday = 1, so leading days = firstWeekday - 1
        let leadingDays = firstWeekday - calendar.firstWeekday
        let adjustedLeading = leadingDays < 0 ? leadingDays + 7 : leadingDays

        var days: [Date] = []

        // Leading days from previous month
        for i in (0..<adjustedLeading).reversed() {
            if let date = calendar.date(byAdding: .day, value: -(i + 1), to: firstOfMonth) {
                days.append(date)
            }
        }

        // Days of current month
        for day in range {
            if let date = calendar.date(bySetting: .day, value: day, of: firstOfMonth) {
                days.append(date)
            }
        }

        // Trailing days to fill 6 rows of 7
        let totalCells = 42
        let lastOfMonth = days.last ?? firstOfMonth
        let trailing = totalCells - days.count
        for i in 1...max(trailing, 1) {
            if let date = calendar.date(byAdding: .day, value: i, to: lastOfMonth) {
                days.append(date)
            }
        }

        return Array(days.prefix(totalCells))
    }

    var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    // MARK: - Navigation

    func previousMonth() {
        if let date = calendar.date(byAdding: .month, value: -1, to: displayedMonth) {
            displayedMonth = date
        }
    }

    func nextMonth() {
        if let date = calendar.date(byAdding: .month, value: 1, to: displayedMonth) {
            displayedMonth = date
        }
    }

    func goToToday() {
        displayedMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) ?? Date()
        selectedDate = calendar.startOfDay(for: Date())
    }

    // MARK: - Helpers

    func isCurrentMonth(_ date: Date) -> Bool {
        calendar.component(.month, from: date) == calendar.component(.month, from: displayedMonth)
    }

    func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    private func deduplicationKey(for event: CanonicalEvent) -> String {
        let normalizedTitle = event.title.lowercased().trimmingCharacters(in: .whitespaces)
        let day: Date
        if event.isAllDay {
            // All-day dates are stored as UTC midnight — extract calendar date in UTC
            let comps = CalendarViewModel.utcCalendar.dateComponents([.year, .month, .day], from: event.startDate)
            day = calendar.date(from: comps) ?? calendar.startOfDay(for: event.startDate)
        } else {
            day = calendar.startOfDay(for: event.startDate)
        }
        return "\(normalizedTitle)|\(day.timeIntervalSince1970)"
    }
}
