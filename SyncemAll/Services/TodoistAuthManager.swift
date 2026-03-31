import AuthenticationServices
import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "TodoistAuth")

/// OAuth manager for Todoist. Todoist access tokens do not expire, so there is no refresh flow.
final class TodoistAuthManager: NSObject {
    static let shared = TodoistAuthManager()

    // TODO: Replace with your Todoist App credentials from https://developer.todoist.com/appconsole.html
    private static let clientID = "4f925bf1e51147c99e69b7aa216ae16d"
    private static let clientSecret = "2bbbc98fff0d4939a80fe006b4c4f826"
    private static let redirectURI = "syncemall-todoist://callback"
    private static let callbackScheme = "syncemall-todoist"
    private static let authURL = "https://todoist.com/oauth/authorize"
    private static let tokenURL = "https://todoist.com/oauth/access_token"
    private static let scope = "data:read_write"

    private static let accessTokenKey = "todoist_access_token"
    private static let userEmailKey = "todoist_user_email"

    // MARK: - Token Storage

    private(set) var accessToken: String? {
        get { KeychainHelper.loadString(key: Self.accessTokenKey) }
        set {
            if let newValue {
                KeychainHelper.saveString(newValue, for: Self.accessTokenKey)
            } else {
                KeychainHelper.delete(key: Self.accessTokenKey)
            }
        }
    }

    var userEmail: String? {
        get { KeychainHelper.loadString(key: Self.userEmailKey) }
        set {
            if let newValue {
                KeychainHelper.saveString(newValue, for: Self.userEmailKey)
            } else {
                KeychainHelper.delete(key: Self.userEmailKey)
            }
        }
    }

    // MARK: - Connection Status

    var isConnected: Bool {
        get async {
            if let token = accessToken, !token.isEmpty {
                return true
            }
            return false
        }
    }

    // MARK: - Connect / Disconnect

    @MainActor
    func connect() async throws {
        logger.info("Starting Todoist OAuth2 flow...")

        let state = UUID().uuidString

        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state),
        ]

        let authURL = components.url!
        logger.debug("Auth URL: \(authURL.absoluteString)")

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callback: .customScheme(Self.callbackScheme)
            ) { url, error in
                if let error {
                    logger.error("OAuth session error: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                } else if let url {
                    logger.info("OAuth callback received")
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: TodoistAuthError.authFailed)
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.start()
        }

        let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        guard let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value else {
            logger.error("No auth code in callback URL")
            throw TodoistAuthError.authFailed
        }

        // Verify state parameter
        let returnedState = callbackComponents?.queryItems?.first(where: { $0.name == "state" })?.value
        guard returnedState == state else {
            logger.error("State mismatch in OAuth callback")
            throw TodoistAuthError.authFailed
        }

        logger.info("Got auth code, exchanging for token...")
        try await exchangeCodeForToken(code: code)
        logger.info("Todoist connected successfully")

        await fetchUserEmail()
    }

    func disconnect() {
        logger.info("Disconnecting Todoist — clearing token")
        accessToken = nil
        userEmail = nil
    }

    // MARK: - Token Management

    func validAccessToken() async throws -> String {
        guard let token = accessToken, !token.isEmpty else {
            throw TodoistAuthError.notAuthorized
        }
        return token
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String) async throws {
        let body = [
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
            "code": code,
        ]

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            logger.error("Token exchange failed: \(responseBody)")
            throw TodoistAuthError.tokenExchangeFailed
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let token_type: String
        }
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = tokenResponse.access_token
        logger.info("Token saved")
    }

    // MARK: - User Info

    func fetchUserEmail() async {
        do {
            let token = try await validAccessToken()
            var request = URLRequest(url: URL(string: "https://api.todoist.com/api/v1/user")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                logger.warning("Failed to fetch Todoist user info")
                return
            }

            struct UserResponse: Decodable {
                let email: String?
            }
            let userResponse = try JSONDecoder().decode(UserResponse.self, from: data)
            userEmail = userResponse.email
            logger.info("Todoist user: \(userResponse.email ?? "unknown")")
        } catch {
            logger.warning("Could not fetch Todoist user info: \(error.localizedDescription)")
        }
    }
}

// MARK: - ASWebAuthenticationSession Presentation

extension TodoistAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

// MARK: - Errors

enum TodoistAuthError: LocalizedError {
    case authFailed
    case notAuthorized
    case tokenExchangeFailed

    var errorDescription: String? {
        switch self {
        case .authFailed: "Todoist authentication failed."
        case .notAuthorized: "Not authorized. Please connect Todoist first."
        case .tokenExchangeFailed: "Failed to exchange Todoist auth code for token."
        }
    }
}
