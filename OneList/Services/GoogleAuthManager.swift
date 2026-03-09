import AuthenticationServices
import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "com.onelist", category: "GoogleAuth")

/// Shared OAuth manager for all Google services (Tasks + Calendar).
/// Performs a single OAuth flow with combined scopes and stores one set of tokens.
final class GoogleAuthManager: NSObject {
    static let shared = GoogleAuthManager()

    private static let clientID = "1092815336579-bj59dpgfcbaevhipnea5gdpdf9ndfa8f.apps.googleusercontent.com"
    private static let redirectURI = "com.googleusercontent.apps.1092815336579-bj59dpgfcbaevhipnea5gdpdf9ndfa8f:/oauth2callback"
    private static let callbackScheme = "com.googleusercontent.apps.1092815336579-bj59dpgfcbaevhipnea5gdpdf9ndfa8f"
    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let scope = "https://www.googleapis.com/auth/tasks https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/userinfo.email"

    private static let accessTokenKey = "google_unified_access_token"
    private static let refreshTokenKey = "google_unified_refresh_token"
    private static let expirationKey = "google_unified_token_expiration"
    private static let userEmailKey = "google_unified_user_email"

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
        logger.info("Starting unified Google OAuth2 flow (Tasks + Calendar)...")

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
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
                    continuation.resume(throwing: GoogleAuthError.authFailed)
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            logger.error("No auth code in callback URL")
            throw GoogleAuthError.authFailed
        }

        logger.info("Got auth code, exchanging for tokens...")
        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
        logger.info("Google connected successfully (Tasks + Calendar)")

        // Fetch user info
        await fetchUserEmail()
    }

    func disconnect() {
        logger.info("Disconnecting Google — clearing all tokens")
        accessToken = nil
        refreshToken = nil
        tokenExpiration = nil
        userEmail = nil
        // Also clear legacy separate token keys in case they exist
        for key in ["google_access_token", "google_refresh_token", "google_token_expiration",
                     "google_calendar_access_token", "google_calendar_refresh_token", "google_calendar_token_expiration"] {
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
        guard let refreshToken else { throw GoogleAuthError.notAuthorized }

        logger.info("Refreshing Google access token...")
        let body = [
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        let tokenResponse: TokenResponse = try await postForm(url: Self.tokenURL, body: body)
        accessToken = tokenResponse.accessToken
        tokenExpiration = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        logger.info("Token refreshed. Expires in \(tokenResponse.expiresIn)s")
        return tokenResponse.accessToken
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        let body = [
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI,
        ]

        let tokenResponse: TokenResponse = try await postForm(url: Self.tokenURL, body: body)
        accessToken = tokenResponse.accessToken
        refreshToken = tokenResponse.refreshToken ?? refreshToken
        tokenExpiration = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        logger.info("Tokens saved. Expires in \(tokenResponse.expiresIn)s")

        // Extract email from ID token (JWT) if present
        if let idToken = tokenResponse.idToken {
            extractEmailFromIDToken(idToken)
        }
    }

    /// Decode the payload of a JWT ID token (no signature verification needed for email extraction).
    private func extractEmailFromIDToken(_ idToken: String) {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return }
        var payload = String(parts[1])
        // Pad base64 if needed
        while payload.count % 4 != 0 { payload += "=" }
        let base64 = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64) else { return }
        struct IDTokenPayload: Decodable { let email: String? }
        if let decoded = try? JSONDecoder().decode(IDTokenPayload.self, from: data), let email = decoded.email {
            userEmail = email
            logger.info("Extracted email from ID token: \(email)")
        }
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
            throw GoogleAuthError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - User Info

    func fetchUserEmail() async {
        do {
            let token = try await validAccessToken()
            var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                logger.warning("Failed to fetch Google user info: HTTP \(status) — \(body)")
                return
            }
            struct UserInfo: Decodable { let email: String? }
            let info = try JSONDecoder().decode(UserInfo.self, from: data)
            userEmail = info.email
            logger.info("Google user: \(info.email ?? "unknown")")
        } catch {
            logger.warning("Could not fetch Google user info: \(error.localizedDescription)")
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

extension GoogleAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

// MARK: - Errors

enum GoogleAuthError: LocalizedError {
    case authFailed
    case notAuthorized
    case tokenExchangeFailed

    var errorDescription: String? {
        switch self {
        case .authFailed: "Google authentication failed."
        case .notAuthorized: "Not authorized. Please connect Google first."
        case .tokenExchangeFailed: "Failed to exchange Google auth code for tokens."
        }
    }
}

// MARK: - Response Model

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
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
