import SwiftUI

struct CalendarView: View {
    @Bindable var viewModel: CalendarViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                monthHeader
                weekdayHeader
                monthGrid
                Divider()
                dayDetailList
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CalendarViewModel.SourceFilter.allCases) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.filter = filter
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background {
                                if viewModel.filter == filter {
                                    Capsule().fill(.blue)
                                } else {
                                    Capsule().stroke(.secondary.opacity(0.4), lineWidth: 1)
                                }
                            }
                            .foregroundStyle(viewModel.filter == filter ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Month Header

    private var monthHeader: some View {
        HStack {
            Button { viewModel.previousMonth() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
            }

            Spacer()

            Text(viewModel.monthTitle)
                .font(.title3.weight(.semibold))

            Button {
                withAnimation { viewModel.goToToday() }
            } label: {
                Text("Today")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().stroke(.blue, lineWidth: 1))
            }

            Spacer()

            Button { viewModel.nextMonth() } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Weekday Header

    private var weekdayHeader: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Month Grid

    private var monthGrid: some View {
        let days = viewModel.daysInMonth
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
            ForEach(days, id: \.self) { date in
                DayCell(date: date, viewModel: viewModel)
                    .id("\(date)_\(viewModel.filter.rawValue)")
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.selectedDate = Calendar.current.startOfDay(for: date)
                        }
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Day Detail List

    private var dayDetailList: some View {
        Group {
            if let selectedDate = viewModel.selectedDate {
                let events = viewModel.eventsForDate(selectedDate)
                let tasks = viewModel.tasksForDate(selectedDate)

                if events.isEmpty && tasks.isEmpty {
                    ContentUnavailableView {
                        Label("No Items", systemImage: "calendar")
                    } description: {
                        Text("Nothing scheduled for this day.")
                    }
                } else {
                    List {
                        if !events.isEmpty {
                            Section("Events") {
                                ForEach(events) { event in
                                    EventRow(event: event)
                                }
                            }
                        }
                        if !tasks.isEmpty {
                            Section("Tasks") {
                                ForEach(tasks) { task in
                                    TaskRow(task: task)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            } else {
                ContentUnavailableView {
                    Label("Select a Day", systemImage: "hand.tap")
                } description: {
                    Text("Tap a day to see events and tasks.")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Day Cell

private struct DayCell: View {
    let date: Date
    var viewModel: CalendarViewModel

    private var isSelected: Bool {
        viewModel.selectedDate.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false
    }

    var body: some View {
        let isToday = viewModel.isToday(date)
        let isCurrentMonth = viewModel.isCurrentMonth(date)
        let dots = viewModel.dotsForDate(date)
        let hasTask = viewModel.hasTasksOnDate(date)

        VStack(spacing: 2) {
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(.body, design: .rounded))
                .fontWeight(isToday || isSelected ? .bold : .regular)
                .foregroundColor(isSelected ? .white : isCurrentMonth ? .primary : .secondary.opacity(0.4))
                .frame(width: 32, height: 32)
                .background {
                    if isSelected {
                        Circle().fill(.blue)
                    } else if isToday {
                        Circle().stroke(.blue, lineWidth: 1.5)
                    }
                }

            HStack(spacing: 2) {
                ForEach(dots.indices, id: \.self) { i in
                    Circle().fill(dots[i]).frame(width: 5, height: 5)
                }
                if hasTask {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

// MARK: - Event Row

private struct EventRow: View {
    let event: CanonicalEvent

    var body: some View {
        HStack(spacing: 10) {
            // Service color bar
            RoundedRectangle(cornerRadius: 2)
                .fill(primaryColor)
                .frame(width: 4, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title.isEmpty ? "(untitled)" : event.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Text(timeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Service dots
            HStack(spacing: 3) {
                ForEach(event.serviceOrigins.sorted(by: { $0.service < $1.service }), id: \.service) { origin in
                    Circle()
                        .fill(origin.service.color)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var primaryColor: Color {
        event.serviceOrigins.first?.service.color ?? .gray
    }

    private var timeLabel: String {
        if event.isAllDay {
            return "All day"
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: event.startDate)) – \(formatter.string(from: event.endDate))"
    }
}

// MARK: - Task Row

private struct TaskRow: View {
    let task: CanonicalTask

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(task.isCompleted ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .strikethrough(task.isCompleted)

                if task.priority != .none {
                    Text(task.priority.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 3) {
                ForEach(task.serviceOrigins.sorted(by: { $0.service < $1.service }), id: \.service) { origin in
                    Circle()
                        .fill(origin.service.color)
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
