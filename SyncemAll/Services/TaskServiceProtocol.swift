import Foundation

// MARK: - Task Service Protocol

/// Abstract interface that every todo service adapter must implement.
/// Each adapter handles mapping between the service's native format and CanonicalTask.
protocol TaskServiceProtocol {
    var serviceType: ServiceType { get }

    /// Whether the service is currently connected and authorized.
    var isConnected: Bool { get async }

    /// Request access / authenticate with the service.
    func connect() async throws

    /// Clear stored tokens / disconnect the service.
    func disconnect()

    /// Pull all incomplete tasks from the service, mapped to canonical format.
    func pullTasks() async throws -> [CanonicalTask]

    /// Push a canonical task to the service. Creates it if new, updates if it has a
    /// ServiceOrigin matching this service.
    func pushTask(_ task: CanonicalTask) async throws

    /// Mark a task as completed in the service.
    func completeTask(nativeID: String) async throws

    /// Delete a task from the service.
    func deleteTask(nativeID: String) async throws
}

// MARK: - Service Errors

enum TaskServiceError: LocalizedError {
    case notAuthorized
    case accessDenied
    case taskNotFound(String)
    case networkError(Error)
    case mappingError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Not authorized. Please connect this service first."
        case .accessDenied:
            "Access denied. Please check permissions in Settings."
        case .taskNotFound(let id):
            "Task not found: \(id)"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .mappingError(let detail):
            "Failed to map task data: \(detail)"
        }
    }
}
