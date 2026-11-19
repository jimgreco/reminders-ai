import AuthenticationServices
import Foundation
import Observation

enum APIError: LocalizedError {
    case signedOut
    case forbidden
    case notFound
    case server(Int, String?)
    case offline

    var errorDescription: String? {
        switch self {
        case .signedOut: "Your session ended. Sign in again."
        case .forbidden: "This app only accepts its owner's account."
        case .notFound: "Not found."
        case .server(let status, let message): message ?? "The server returned \(status)."
        case .offline: "You're offline. Your reminders still work; the assistant needs a connection."
        }
    }
}

struct AuthResponse: Decodable {
    struct User: Decodable { let id: String; let email: String }
    let accessToken: String
    let refreshToken: String
    let user: User
}

struct EmptyResponse: Decodable {}

/// Signed-in state and the authenticated HTTP client.
@MainActor
@Observable
final class Session {
    private(set) var isSignedIn: Bool
    private(set) var email: String?
    var lastError: String?

    let baseURL: URL
    private let urlSession: URLSession
    private var refreshTask: Task<Void, Error>?

    init(baseURL: URL = Session.configuredBaseURL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        isSignedIn = Keychain.read("refreshToken") != nil
        email = Keychain.read("email")
    }

    nonisolated static var configuredBaseURL: URL {
        let value = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String ?? ""
        return URL(string: value) ?? URL(string: "http://127.0.0.1:8792")!
    }

    // MARK: Sign in

    func signIn(with credential: ASAuthorizationAppleIDCredential) async {
        guard let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
            lastError = "Apple didn't return a sign-in token. Try again."
            return
        }
        await authenticate(path: "/auth/apple", body: ["identityToken": token])
    }

    func signInWithGoogle(idToken: String) async {
        await authenticate(path: "/auth/google", body: ["idToken": idToken])
    }

    #if DEBUG
    func devSignIn() async {
        await authenticate(path: "/auth/dev", body: ["email": "dev@example.test"])
    }
    #endif

    private func authenticate(path: String, body: [String: String]) async {
        do {
            let response: AuthResponse = try await raw("POST", path, body: body, token: nil)
            store(response)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func store(_ response: AuthResponse) {
        Keychain.write(response.accessToken, key: "accessToken")
        Keychain.write(response.refreshToken, key: "refreshToken")
        Keychain.write(response.user.email, key: "email")
        email = response.user.email
        isSignedIn = true
    }

    func signOut() async {
        if let refresh = Keychain.read("refreshToken") {
            let _: EmptyResponse? = try? await raw("POST", "/auth/signout", body: ["refreshToken": refresh], token: nil)
        }
        clearTokens()
    }

    func clearTokens() {
        Keychain.delete("accessToken")
        Keychain.delete("refreshToken")
        Keychain.delete("email")
        email = nil
        isSignedIn = false
    }

    // MARK: Authenticated requests

    /// Sends an authenticated request, refreshing the access token once on 401.
    func request<T: Decodable>(_ method: String, _ path: String, body: (some Encodable)? = nil as String?,
                               timeout: TimeInterval = 45) async throws -> T {
        do {
            return try await raw(method, path, body: body, token: Keychain.read("accessToken"), timeout: timeout)
        } catch APIError.signedOut {
            try await refresh()
            return try await raw(method, path, body: body, token: Keychain.read("accessToken"), timeout: timeout)
        }
    }

    private func refresh() async throws {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { @MainActor in
            defer { self.refreshTask = nil }
            guard let refresh = Keychain.read("refreshToken") else {
                self.clearTokens()
                throw APIError.signedOut
            }
            do {
                let response: AuthResponse = try await self.raw("POST", "/auth/refresh", body: ["refreshToken": refresh], token: nil)
                self.store(response)
            } catch APIError.signedOut {
                self.clearTokens()
                throw APIError.signedOut
            }
        }
        refreshTask = task
        try await task.value
    }

    /// Bytes of an authenticated GET (a photo), refreshing the access token once on 401.
    func data(_ path: String) async throws -> Data {
        do {
            return try await rawData(path, token: Keychain.read("accessToken"))
        } catch APIError.signedOut {
            try await refresh()
            return try await rawData(path, token: Keychain.read("accessToken"))
        }
    }

    private func rawData(_ path: String, token: String?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.server(0, "Bad URL") }
        var request = URLRequest(url: url, timeoutInterval: 45)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw APIError.offline
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data
        case 401: throw APIError.signedOut
        case 404: throw APIError.notFound
        case let status: throw APIError.server(status, nil)
        }
    }

    private func raw<T: Decodable>(_ method: String, _ path: String, body: (some Encodable)?, token: String?,
                                   timeout: TimeInterval = 45) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError.server(0, "Bad URL") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONCoding.encoder.encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw APIError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try JSONCoding.decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        case 401: throw APIError.signedOut
        case 403: throw APIError.forbidden
        case 404: throw APIError.notFound
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.server(status, message)
        }
    }
}
