import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "MicrosoftToDo")

final class MicrosoftToDoService: TaskServiceProtocol {
    let serviceType: ServiceType = .microsoftToDo

    private static let baseURL = "https://graph.microsoft.com/v1.0/me/todo"
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

    // MARK: - Pull Tasks

    func pullTasks() async throws -> [CanonicalTask] {
        let token = try await auth.validAccessToken()

        let listsResponse: MSTaskListsResponse = try await apiGet(
            path: "/lists", token: token
        )
        logger.info("Found \(listsResponse.value.count) task lists")

        var allTasks: [CanonicalTask] = []

        for taskList in listsResponse.value {
            let tasksResponse: MSTasksResponse = try await apiGet(
                path: "/lists/\(taskList.id)/tasks?$filter=status ne 'completed'",
                token: token
            )
            let tasks = tasksResponse.value.map { mapToCanonical($0, listID: taskList.id, listName: taskList.displayName) }
            logger.info("Pulled \(tasks.count) tasks from list '\(taskList.displayName)'")
            allTasks.append(contentsOf: tasks)
        }

        logger.info("Total: \(allTasks.count) tasks from Microsoft To Do")
        return allTasks
    }

    // MARK: - Push Task

    func pushTask(_ task: CanonicalTask) async throws {
        let token = try await auth.validAccessToken()

        logger.debug("pushTask '\(task.title)' — origins: \(task.serviceOrigins.map { "\($0.service.rawValue):\($0.nativeID)" })")

        if let origin = task.serviceOrigins.first(where: { $0.service == .microsoftToDo }) {
            let parts = origin.nativeID.split(separator: "/")
            guard parts.count == 2, !parts[0].isEmpty else {
                logger.error("Invalid Microsoft native ID: '\(origin.nativeID)' — creating new")
                try await createNewMSTask(task, token: token)
                return
            }
            let body = mapToMSTask(task)
            logger.info("Updating existing MS task: listID=\(parts[0]) taskID=\(parts[1])")
            let _: MSTask = try await apiPatch(
                path: "/lists/\(parts[0])/tasks/\(parts[1])", body: body, token: token
            )
            logger.info("Updated task '\(task.title)' in Microsoft To Do")
        } else {
            logger.info("No Microsoft origin — creating new task")
            try await createNewMSTask(task, token: token)
        }
    }

    private func createNewMSTask(_ task: CanonicalTask, token: String) async throws {
        let listsResponse: MSTaskListsResponse = try await apiGet(
            path: "/lists", token: token
        )
        guard let firstList = listsResponse.value.first else {
            throw TaskServiceError.mappingError("No task lists found in Microsoft To Do")
        }
        let body = mapToMSTask(task)
        let _: MSTask = try await apiPost(
            path: "/lists/\(firstList.id)/tasks", body: body, token: token
        )
        logger.info("Created task '\(task.title)' in Microsoft To Do")
    }

    // MARK: - Complete / Delete

    func completeTask(nativeID: String) async throws {
        let token = try await auth.validAccessToken()
        let parts = nativeID.split(separator: "/")
        guard parts.count == 2 else {
            throw TaskServiceError.taskNotFound(nativeID)
        }
        let body: [String: Any] = ["status": "completed"]
        let _: MSTask = try await apiPatch(
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

    private func mapToCanonical(_ task: MSTask, listID: String, listName: String) -> CanonicalTask {
        logger.debug("Mapping MS task: id=\(task.id) title='\(task.title)' status=\(task.status)")

        let origin = ServiceOrigin(
            service: .microsoftToDo,
            nativeID: "\(listID)/\(task.id)",
            listName: listName,
            lastSyncedDate: Date()
        )

        let priority: CanonicalTask.Priority = switch task.importance {
        case "high": .high
        case "low": .low
        default: .none // "normal" is MS default, treat as no priority set
        }

        let dueDate: Date? = task.dueDateTime.flatMap { parseMSDate($0.dateTime, timeZone: $0.timeZone) }
        let createdDate: Date? = task.createdDateTime.flatMap { ISO8601DateFormatter().date(from: $0) }
        let modifiedDate: Date? = task.lastModifiedDateTime.flatMap { ISO8601DateFormatter().date(from: $0) }

        return CanonicalTask(
            title: task.title,
            notes: task.body.flatMap { Self.cleanBodyContent($0) },
            isCompleted: task.status == "completed",
            dueDate: dueDate,
            priority: priority,
            createdDate: createdDate,
            lastModifiedDate: modifiedDate,
            serviceOrigins: [origin]
        )
    }

    private func mapToMSTask(_ task: CanonicalTask) -> [String: Any] {
        var body: [String: Any] = [
            "title": task.title,
            "status": task.isCompleted ? "completed" : "notStarted",
            "importance": msImportance(from: task.priority),
        ]

        if let notes = task.notes, !notes.isEmpty {
            body["body"] = [
                "content": notes,
                "contentType": "text",
            ]
        }

        if let due = task.dueDate {
            let cal = Calendar.current
            let components = cal.dateComponents([.year, .month, .day], from: due)
            let dateString = String(format: "%04d-%02d-%02d",
                                    components.year!, components.month!, components.day!)
            body["dueDateTime"] = [
                "dateTime": "\(dateString)T00:00:00.0000000",
                "timeZone": "UTC",
            ]
        }

        logger.debug("Microsoft To Do request body keys: \(Array(body.keys))")
        return body
    }

    private func msImportance(from priority: CanonicalTask.Priority) -> String {
        switch priority {
        case .high: "high"
        case .medium: "normal"
        case .low: "low"
        case .none: "normal"
        }
    }

    private func parseMSDate(_ dateTime: String, timeZone: String) -> Date? {
        let dateOnly = String(dateTime.prefix(10))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        return formatter.date(from: dateOnly)
    }

    // MARK: - HTML Stripping

    private static func cleanBodyContent(_ body: MSTaskBody) -> String? {
        guard let content = body.content, !content.isEmpty else { return nil }
        if body.contentType?.lowercased() == "html" {
            let stripped = content
                .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? nil : stripped
        }
        return content
    }

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
                throw TaskServiceError.notAuthorized
            }
            throw TaskServiceError.networkError(
                NSError(domain: "MicrosoftToDo", code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            )
        }
    }
}

// MARK: - API Response Models

private struct MSTaskListsResponse: Decodable {
    let value: [MSTaskList]
}

private struct MSTaskList: Decodable {
    let id: String
    let displayName: String
}

private struct MSTasksResponse: Decodable {
    let value: [MSTask]
}

private struct MSTask: Decodable {
    let id: String
    let title: String
    let status: String
    let importance: String
    let body: MSTaskBody?
    let dueDateTime: MSDateTime?
    let createdDateTime: String?
    let lastModifiedDateTime: String?
}

private struct MSTaskBody: Decodable {
    let content: String?
    let contentType: String?
}

private struct MSDateTime: Decodable {
    let dateTime: String
    let timeZone: String
}
