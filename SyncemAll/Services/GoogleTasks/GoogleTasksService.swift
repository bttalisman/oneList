import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "GoogleTasks")

final class GoogleTasksService: TaskServiceProtocol {
    let serviceType: ServiceType = .googleTasks

    private static let baseURL = "https://tasks.googleapis.com/tasks/v1"
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

    // MARK: - Pull Tasks

    func pullTasks() async throws -> [CanonicalTask] {
        let token = try await auth.validAccessToken()

        let listsResponse: TaskListsResponse = try await apiGet(
            path: "/users/@me/lists", token: token
        )
        logger.info("Found \(listsResponse.items?.count ?? 0) task lists")

        var allTasks: [CanonicalTask] = []

        for taskList in listsResponse.items ?? [] {
            let tasksResponse: TasksResponse = try await apiGet(
                path: "/lists/\(taskList.id)/tasks",
                query: [URLQueryItem(name: "showCompleted", value: "false")],
                token: token
            )
            let tasks = (tasksResponse.items ?? []).map { task -> CanonicalTask in
                var t = task
                t.listID = taskList.id
                return mapToCanonical(t, listName: taskList.title)
            }
            logger.info("Pulled \(tasks.count) tasks from list '\(taskList.title)'")
            allTasks.append(contentsOf: tasks)
        }

        logger.info("Total: \(allTasks.count) tasks from Google Tasks")
        return allTasks
    }

    // MARK: - Push Task

    func pushTask(_ task: CanonicalTask) async throws {
        let token = try await auth.validAccessToken()

        logger.debug("pushTask '\(task.title)' — origins: \(task.serviceOrigins.map { "\($0.service.rawValue):\($0.nativeID)" })")

        if let origin = task.serviceOrigins.first(where: { $0.service == .googleTasks }) {
            let parts = origin.nativeID.split(separator: "/")
            guard parts.count == 2, !parts[0].isEmpty else {
                logger.error("Invalid Google Tasks native ID: '\(origin.nativeID)' — creating new instead")
                try await createNewGoogleTask(task, token: token)
                return
            }
            let body = mapToGoogleTask(task)
            logger.info("Updating existing Google task: listID=\(parts[0]) taskID=\(parts[1])")
            let _: GoogleTask = try await apiPatch(
                path: "/lists/\(parts[0])/tasks/\(parts[1])", body: body, token: token
            )
            logger.info("Updated task '\(task.title)' in Google Tasks")
        } else {
            logger.info("No Google origin — creating new task")
            try await createNewGoogleTask(task, token: token)
        }
    }

    private func createNewGoogleTask(_ task: CanonicalTask, token: String) async throws {
        let listsResponse: TaskListsResponse = try await apiGet(
            path: "/users/@me/lists", token: token
        )
        guard let firstList = listsResponse.items?.first else {
            throw TaskServiceError.mappingError("No task lists found in Google Tasks")
        }
        let body = mapToGoogleTask(task)
        let _: GoogleTask = try await apiPost(
            path: "/lists/\(firstList.id)/tasks", body: body, token: token
        )
        logger.info("Created task '\(task.title)' in Google Tasks")
    }

    // MARK: - Complete / Delete

    func completeTask(nativeID: String) async throws {
        let token = try await auth.validAccessToken()
        let parts = nativeID.split(separator: "/")
        guard parts.count == 2 else {
            throw TaskServiceError.taskNotFound(nativeID)
        }
        let body = ["status": "completed"]
        let _: GoogleTask = try await apiPatch(
            path: "/lists/\(parts[0])/tasks/\(parts[1])", body: body, token: token
        )
        logger.info("Completed task \(nativeID)")
    }

    func deleteTask(nativeID: String) async throws {
        let token = try await auth.validAccessToken()
        let parts = nativeID.split(separator: "/")
        guard parts.count == 2 else {
            throw TaskServiceError.taskNotFound(nativeID)
        }
        try await apiDelete(path: "/lists/\(parts[0])/tasks/\(parts[1])", token: token)
        logger.info("Deleted task \(nativeID)")
    }

    // MARK: - Mapping

    private func mapToCanonical(_ task: GoogleTask, listName: String) -> CanonicalTask {
        logger.debug("Mapping Google task: id=\(task.id) title='\(task.title ?? "nil")' status=\(task.status ?? "nil") due='\(task.due ?? "nil")'")
        if let due = task.due {
            let parsed = Self.parseGoogleDate(due)
            logger.debug("  Parsed due: raw='\(due)' -> \(parsed?.description ?? "nil")")
        }
        let origin = ServiceOrigin(
            service: .googleTasks,
            nativeID: "\(task.listID ?? "")/\(task.id)",
            listName: listName,
            lastSyncedDate: Date()
        )

        return CanonicalTask(
            title: task.title ?? "",
            notes: task.notes,
            isCompleted: task.status == "completed",
            dueDate: task.due.flatMap { Self.parseGoogleDate($0) },
            priority: .none,
            createdDate: task.updated.flatMap { Self.googleDateTimeFormatter.date(from: $0) },
            lastModifiedDate: task.updated.flatMap { Self.googleDateTimeFormatter.date(from: $0) },
            serviceOrigins: [origin]
        )
    }

    private func mapToGoogleTask(_ task: CanonicalTask) -> [String: Any] {
        var body: [String: Any] = [
            "title": task.title,
            "status": task.isCompleted ? "completed" : "needsAction",
        ]
        if let notes = task.notes, !notes.isEmpty {
            body["notes"] = notes
        }
        if let due = task.dueDate {
            let cal = Calendar.current
            let components = cal.dateComponents([.year, .month, .day], from: due)
            let dateString = String(format: "%04d-%02d-%02dT12:00:00.000Z",
                                    components.year!, components.month!, components.day!)
            body["due"] = dateString
        }
        logger.debug("Google Tasks request body: \(body)")
        return body
    }

    private static func parseGoogleDate(_ string: String) -> Date? {
        let dateOnly = String(string.prefix(10))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        return formatter.date(from: dateOnly)
    }

    private static let googleDateTimeFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
                throw TaskServiceError.notAuthorized
            }
            throw TaskServiceError.networkError(
                NSError(domain: "GoogleTasks", code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            )
        }
    }
}

// MARK: - API Response Models

private struct TaskListsResponse: Decodable {
    let items: [GoogleTaskList]?
}

private struct GoogleTaskList: Decodable {
    let id: String
    let title: String
}

private struct TasksResponse: Decodable {
    let items: [GoogleTask]?
}

private struct GoogleTask: Decodable {
    let id: String
    let title: String?
    let notes: String?
    let status: String?
    let due: String?
    let updated: String?
    var listID: String?
}
