import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "Todoist")

final class TodoistService: TaskServiceProtocol {
    let serviceType: ServiceType = .todoistTasks

    private static let baseURL = "https://api.todoist.com/api/v1"
    private let auth = TodoistAuthManager.shared

    var isConnected: Bool {
        get async { await auth.isConnected }
    }

    func disconnect() {
        auth.disconnect()
    }

    func connect() async throws {
        try await auth.connect()
    }

    // MARK: - Pull Tasks

    func pullTasks() async throws -> [CanonicalTask] {
        let token = try await auth.validAccessToken()

        // Fetch projects for list name mapping (paginated)
        let projects = try await fetchAllProjects(token: token)
        let projectNames = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        logger.info("Found \(projects.count) projects")

        // Fetch all active (incomplete) tasks (paginated)
        let tasks = try await fetchAllTasks(token: token)
        let canonicalTasks = tasks.map { mapToCanonical($0, projectName: projectNames[$0.project_id]) }

        logger.info("Pulled \(canonicalTasks.count) tasks from Todoist")
        return canonicalTasks
    }

    private func fetchAllTasks(token: String) async throws -> [TodoistTask] {
        var allTasks: [TodoistTask] = []
        var cursor: String? = nil

        repeat {
            var query: [URLQueryItem] = []
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }

            let page: PaginatedResponse<TodoistTask> = try await apiGet(
                path: "/tasks", query: query, token: token
            )
            allTasks.append(contentsOf: page.results)
            cursor = page.next_cursor
        } while cursor != nil

        return allTasks
    }

    private func fetchAllProjects(token: String) async throws -> [TodoistProject] {
        var allProjects: [TodoistProject] = []
        var cursor: String? = nil

        repeat {
            var query: [URLQueryItem] = []
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }

            let page: PaginatedResponse<TodoistProject> = try await apiGet(
                path: "/projects", query: query, token: token
            )
            allProjects.append(contentsOf: page.results)
            cursor = page.next_cursor
        } while cursor != nil

        return allProjects
    }

    // MARK: - Push Task

    func pushTask(_ task: CanonicalTask) async throws {
        let token = try await auth.validAccessToken()

        logger.debug("pushTask '\(task.title)' — origins: \(task.serviceOrigins.map { "\($0.service.rawValue):\($0.nativeID)" })")

        if let origin = task.serviceOrigins.first(where: { $0.service == .todoistTasks }) {
            let parts = origin.nativeID.split(separator: "/")
            guard parts.count == 2, !parts[1].isEmpty else {
                logger.error("Invalid Todoist native ID: '\(origin.nativeID)' — creating new instead")
                try await createNewTask(task, token: token)
                return
            }
            let taskID = String(parts[1])
            let body = mapToTodoistUpdate(task)
            logger.info("Updating existing Todoist task: \(taskID)")
            try await apiPost(path: "/tasks/\(taskID)", body: body, token: token)
            logger.info("Updated task '\(task.title)' in Todoist")
        } else {
            logger.info("No Todoist origin — creating new task")
            try await createNewTask(task, token: token)
        }
    }

    private func createNewTask(_ task: CanonicalTask, token: String) async throws {
        let body = mapToTodoistCreate(task)
        try await apiPost(path: "/tasks", body: body, token: token)
        logger.info("Created task '\(task.title)' in Todoist")
    }

    // MARK: - Complete / Delete

    func completeTask(nativeID: String) async throws {
        let token = try await auth.validAccessToken()
        let taskID = extractTaskID(from: nativeID)
        try await apiPostEmpty(path: "/tasks/\(taskID)/close", token: token)
        logger.info("Completed task \(nativeID)")
    }

    func deleteTask(nativeID: String) async throws {
        let token = try await auth.validAccessToken()
        let taskID = extractTaskID(from: nativeID)
        try await apiDelete(path: "/tasks/\(taskID)", token: token)
        logger.info("Deleted task \(nativeID)")
    }

    private func extractTaskID(from nativeID: String) -> String {
        let parts = nativeID.split(separator: "/")
        return parts.count == 2 ? String(parts[1]) : nativeID
    }

    // MARK: - Mapping

    private func mapToCanonical(_ task: TodoistTask, projectName: String?) -> CanonicalTask {
        let origin = ServiceOrigin(
            service: .todoistTasks,
            nativeID: "\(task.project_id)/\(task.id)",
            listName: projectName,
            lastSyncedDate: Date()
        )

        let createdDate = task.added_at.flatMap { Self.parseTodoistDateTime($0) }
        let modifiedDate = task.updated_at.flatMap { Self.parseTodoistDateTime($0) } ?? createdDate

        return CanonicalTask(
            title: task.content,
            notes: task.description.isEmpty ? nil : task.description,
            isCompleted: task.checked,
            dueDate: task.due?.date.flatMap { Self.parseTodoistDate($0) },
            priority: mapPriority(from: task.priority),
            createdDate: createdDate,
            lastModifiedDate: modifiedDate,
            serviceOrigins: [origin]
        )
    }

    private func mapToTodoistCreate(_ task: CanonicalTask) -> [String: Any] {
        var body: [String: Any] = [
            "content": task.title,
            "priority": mapPriorityToTodoist(task.priority),
        ]
        if let notes = task.notes, !notes.isEmpty {
            body["description"] = notes
        }
        if let due = task.dueDate {
            body["due_date"] = Self.formatDateOnly(due)
        }
        return body
    }

    private func mapToTodoistUpdate(_ task: CanonicalTask) -> [String: Any] {
        var body: [String: Any] = [
            "content": task.title,
            "priority": mapPriorityToTodoist(task.priority),
        ]
        if let notes = task.notes, !notes.isEmpty {
            body["description"] = notes
        }
        if let due = task.dueDate {
            body["due_date"] = Self.formatDateOnly(due)
        }
        return body
    }

    /// Todoist priority is inverted: API 4 = UI p1 (urgent), API 1 = UI p4 (normal/none).
    private func mapPriority(from todoistPriority: Int) -> CanonicalTask.Priority {
        switch todoistPriority {
        case 4: .high
        case 3: .medium
        case 2: .low
        default: .none
        }
    }

    private func mapPriorityToTodoist(_ priority: CanonicalTask.Priority) -> Int {
        switch priority {
        case .high: 4
        case .medium: 3
        case .low: 2
        case .none: 1
        }
    }

    private static func parseTodoistDate(_ string: String) -> Date? {
        let dateOnly = String(string.prefix(10))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        return formatter.date(from: dateOnly)
    }

    private static func parseTodoistDateTime(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func formatDateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        return formatter.string(from: date)
    }

    // MARK: - Network Helpers

    private func apiGet<T: Decodable>(
        path: String, query: [URLQueryItem] = [], token: String
    ) async throws -> T {
        var components = URLComponents(string: Self.baseURL + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func apiPost(
        path: String, body: [String: Any], token: String
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)
        return data
    }

    private func apiPostEmpty(path: String, token: String) async throws {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)
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
            if http.statusCode == 401 || http.statusCode == 403 {
                throw TaskServiceError.notAuthorized
            }
            throw TaskServiceError.networkError(
                NSError(domain: "Todoist", code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            )
        }
    }
}

// MARK: - API Response Models

private struct PaginatedResponse<T: Decodable>: Decodable {
    let results: [T]
    let next_cursor: String?
}

private struct TodoistTask: Decodable {
    let id: String
    let project_id: String
    let content: String
    let description: String
    let checked: Bool
    let priority: Int
    let due: TodoistDue?
    let added_at: String?
    let updated_at: String?
}

private struct TodoistDue: Decodable {
    let date: String?
    let datetime: String?
    let string: String?
}

private struct TodoistProject: Decodable {
    let id: String
    let name: String
}
