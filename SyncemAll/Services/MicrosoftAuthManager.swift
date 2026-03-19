import AuthenticationServices
import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "com.syncemall", category: "MicrosoftAuth")

/// Shared OAuth manager for all Microsoft services (To Do + Calendar).
/// Performs a single OAuth flow with combined scopes and stores one set of tokens.
final class MicrosoftAuthManager: NSObject {
    static let shared = MicrosoftAuthManager()

    private static let clientID = "5df4e8fd-a671-4f38-a3c9-2d9b7f652599"
    private static let redirectURI = "msauth.com.syncemall://auth"
    private static let callbackScheme = "msauth.com.syncemall"
    private static let authorizeURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    private static let tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    private static let scope = "Tasks.ReadWrite Calendars.ReadWrite User.Read offline_access"

    private static let accessTokenKey = "microsoft_unified_access_token"
    private static let refreshTokenKey = "microsoft_unified_refresh_token"
    private static let expirationKey = "microsoft_unified_token_expiration"
    private static let userEmailKey = "microsoft_unified_user_email"

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

    private var refreshToken: String? {
        get { KeychainHelper.loadString(key: Self.refreshTokenKey) }
        set {
            if let newValue {
                KeychainHelper.saveString(newValue, for: Self.refreshTokenKey)
            } else {
                KeychainHelper.delete(key: Self.refreshTokenKey)
            }
        }
    }

    private var tokenExpiration: Date? {
        get {
            guard let data = KeychainHelper.load(key: Self.expirationKey) else { return nil }
            return try? JSONDecoder().decode(Date.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                KeychainHelper.save(data, for: Self.expirationKey)
            } else {
                KeychainHelper.delete(key: Self.expirationKey)
            }
        }
    }

    /// The logged-in user's email, fetched after connect.
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
            guard Self.clientID != "YOUR_MICROSOFT_CLIENT_ID" else { return false }
            if let token = accessToken, !token.isEmpty {
                if let expiration = tokenExpiration, Date() >= expiration {
                    if refreshToken != nil {
                        return (try? await refreshAccessToken()) != nil
                    }
                    return false
                }
                return true
            }
            return false
        }
    }

    // MARK: - Connect / Disconnect

    @MainActor
    func connect() async throws {
        guard Self.clientID != "YOUR_MICROSOFT_CLIENT_ID" else {
            throw MicrosoftAuthError.notConfigured
        }

        logger.info("Starting unified Microsoft OAuth2 flow (To Do + Calendar)...")
        logger.info("[MS-DEBUG] clientID: \(Self.clientID)")
        logger.info("[MS-DEBUG] redirectURI: \(Self.redirectURI)")
        logger.info("[MS-DEBUG] callbackScheme: \(Self.callbackScheme)")
        logger.info("[MS-DEBUG] scope: \(Self.scope)")

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]

        let authURL = components.url!
        logger.debug("Auth URL: \(authURL.absoluteString)")

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callback: .customScheme(Self.callbackScheme)
            ) { url, error in
                if let error {
                    logger.error("[MS-DEBUG] OAuth session error: \(error.localizedDescription) (code: \((error as NSError).code), domain: \((error as NSError).domain))")
                    continuation.resume(throwing: error)
                } else if let url {
                    logger.info("[MS-DEBUG] OAuth callback URL: \(url.absoluteString)")
                    continuation.resume(returning: url)
                } else {
                    logger.error("[MS-DEBUG] OAuth session returned nil URL and nil error")
                    continuation.resume(throwing: MicrosoftAuthError.authFailed)
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.start()
        }

        let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        logger.info("[MS-DEBUG] Callback query items: \(callbackComponents?.queryItems?.map { "\($0.name)=\($0.value ?? "nil")" }.joined(separator: ", ") ?? "none")")

        if let errorDesc = callbackComponents?.queryItems?.first(where: { $0.name == "error" })?.value {
            let errorDetail = callbackComponents?.queryItems?.first(where: { $0.name == "error_description" })?.value ?? "no detail"
            logger.error("[MS-DEBUG] OAuth error response: \(errorDesc) — \(errorDetail)")
            throw MicrosoftAuthError.authFailed
        }

        guard let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value else {
            logger.error("[MS-DEBUG] No auth code in callback URL: \(callbackURL.absoluteString)")
            throw MicrosoftAuthError.authFailed
        }

        logger.info("Got auth code, exchanging for tokens...")
        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
        logger.info("Microsoft connected successfully (To Do + Calendar)")

        // Fetch user info
        await fetchUserEmail()
    }

    func disconnect() {
        logger.info("Disconnecting Microsoft — clearing all tokens")
        accessToken = nil
        refreshToken = nil
        tokenExpiration = nil
        userEmail = nil
        // Also clear legacy separate token keys in case they exist
        for key in ["microsoft_access_token", "microsoft_refresh_token", "microsoft_token_expiration",
                     "microsoft_calendar_access_token", "microsoft_calendar_refresh_token", "microsoft_calendar_token_expiration"] {
            KeychainHelper.delete(key: key)
        }
    }

    // MARK: - Token Management

    func validAccessToken() async throws -> String {
        if let token = accessToken, let exp = tokenExpiration, Date() < exp {
            return token
        }
        return try await refreshAccessToken()
    }

    @discardableResult
    private func refreshAccessToken() async throws -> String {
        guard let refreshToken else { throw MicrosoftAuthError.notAuthorized }

        logger.info("Refreshing Microsoft access token...")
        let body = [
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "scope": Self.scope,
        ]

        let tokenResponse: TokenResponse = try await postForm(url: Self.tokenURL, body: body)
        accessToken = tokenResponse.accessToken
        self.refreshToken = tokenResponse.refreshToken ?? refreshToken
        tokenExpiration = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        logger.info("Token refreshed. Expires in \(tokenResponse.expiresIn)s")
        return tokenResponse.accessToken
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        logger.info("[MS-DEBUG] Exchanging auth code for tokens...")
        logger.info("[MS-DEBUG] Token exchange redirectURI: \(Self.redirectURI)")
        let body = [
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI,
            "scope": Self.scope,
        ]

        let tokenResponse: TokenResponse = try await postForm(url: Self.tokenURL, body: body)
        logger.info("[MS-DEBUG] Token exchange succeeded, got access token")
        accessToken = tokenResponse.accessToken
        refreshToken = tokenResponse.refreshToken ?? refreshToken
        tokenExpiration = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        logger.info("Tokens saved. Expires in \(tokenResponse.expiresIn)s")
    }

    // MARK: - Network

    private func postForm<T: Decodable>(url: String, body: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Token request failed: \(body)")
            throw MicrosoftAuthError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - User Info

    func fetchUserEmail() async {
        do {
            let token = try await validAccessToken()
            var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                logger.warning("Failed to fetch Microsoft user info: HTTP \(status) — \(body)")
                return
            }
            struct UserInfo: Decodable {
                let mail: String?
                let userPrincipalName: String?
            }
            let info = try JSONDecoder().decode(UserInfo.self, from: data)
            userEmail = info.mail ?? info.userPrincipalName
            logger.info("Microsoft user: \(self.userEmail ?? "unknown")")
        } catch {
            logger.warning("Could not fetch Microsoft user info: \(error.localizedDescription)")
        }
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded
    }
}

// MARK: - ASWebAuthenticationSession Presentation

extension MicrosoftAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

// MARK: - Errors

enum MicrosoftAuthError: LocalizedError {
    case authFailed
    case notAuthorized
    case notConfigured
    case tokenExchangeFailed

    var errorDescription: String? {
        switch self {
        case .authFailed: "Microsoft authentication failed."
        case .notAuthorized: "Not authorized. Please connect Microsoft first."
        case .notConfigured: "Microsoft not configured. Set your Client ID."
        case .tokenExchangeFailed: "Failed to exchange Microsoft auth code for tokens."
        }
    }
}

// MARK: - Response Model

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - Base64URL

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
