import Foundation

// MARK: - Event Service Protocol

/// Abstract interface that every calendar service adapter must implement.
/// Each adapter handles mapping between the service's native format and CanonicalEvent.
protocol EventServiceProtocol {
    var serviceType: ServiceType { get }

    /// Whether the service is currently connected and authorized.
    var isConnected: Bool { get async }

    /// Request access / authenticate with the service.
    func connect() async throws

    /// Clear stored tokens / disconnect the service.
    func disconnect()

    /// Pull all events within the given date range from the service, mapped to canonical format.
    func pullEvents(from startDate: Date, to endDate: Date) async throws -> [CanonicalEvent]

    /// Push a canonical event to the service. Creates it if new, updates if it has a
    /// ServiceOrigin matching this service.
    func pushEvent(_ event: CanonicalEvent) async throws

    /// Delete an event from the service.
    func deleteEvent(nativeID: String) async throws
}

// MARK: - Service Errors

enum EventServiceError: LocalizedError {
    case notAuthorized
    case accessDenied
    case eventNotFound(String)
    case networkError(Error)
    case mappingError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Not authorized. Please connect this service first."
        case .accessDenied:
            "Access denied. Please check permissions in Settings."
        case .eventNotFound(let id):
            "Event not found: \(id)"
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .mappingError(let detail):
            "Failed to map event data: \(detail)"
        }
    }
}
