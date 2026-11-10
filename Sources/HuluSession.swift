//
//  HuluSession.swift
//  Wazu
//
//  Native device authentication. Passwords are never persisted; tokens live in Keychain.
//

import Foundation
import Security

struct HuluTokens: Codable, Equatable {
    let userToken: String
    let deviceToken: String
    let serial: String
    let profileID: String?
    let expiresAt: Date?

    init(json: [String: Any], serial: String, previous: HuluTokens? = nil) throws {
        let data = json["data"] as? [String: Any] ?? json
        guard let user = data["user_token"] as? String, !user.isEmpty,
              let device = data["device_token"] as? String ?? previous?.deviceToken, !device.isEmpty else {
            throw HuluError.badResponse("native session tokens")
        }
        userToken = user
        deviceToken = device
        self.serial = serial
        profileID = data["profile_id"] as? String ?? previous?.profileID
        let lifetime = (data["expires_in"] as? NSNumber)?.doubleValue
            ?? (data["expires_in"] as? String).flatMap(Double.init)
        expiresAt = lifetime.map { Date().addingTimeInterval($0 - 30) }
    }
}

/// The password was right, but Hulu wants an emailed code too; `token` names this login attempt.
struct HuluTwoFactor: Error {
    let token: String
}

@MainActor
final class HuluSession {
    static let shared = HuluSession()
    private var generation = UUID()
    private var refreshTask: Task<HuluTokens, Error>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    nonisolated private static var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.starplayrx.wazu.native-session",
         kSecAttrAccount as String: "hulu"]
    }

    nonisolated static func stored() -> HuluTokens? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(HuluTokens.self, from: data)
    }

    private func save(_ tokens: HuluTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        var status = SecItemUpdate(Self.key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.key
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw HuluError.signIn("Could not save the Hulu session in Keychain (\(status)).")
        }
    }

    func install(_ tokens: HuluTokens) throws {
        try save(tokens)
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
    }

    func clear() throws {
        let status = SecItemDelete(Self.key as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HuluError.signIn("Could not remove the Hulu session from Keychain (\(status)).")
        }
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
    }

    func token(rejected: String? = nil) async throws -> String? {
        guard let current = Self.stored() else { return nil }
        if let rejected, rejected != current.userToken { return current.userToken }
        if rejected == nil, current.expiresAt.map({ $0 > Date() }) ?? true { return current.userToken }
        if let refreshTask { return try await refreshTask.value.userToken }
        let version = generation
        let task = Task<HuluTokens, Error> {
            let answer = try await self.post("/v1/device/device_token/authenticate", form: [
                "action": "token_refresh", "device_token": current.deviceToken,
            ])
            let updated = try HuluTokens(json: answer, serial: current.serial, previous: current)
            guard self.generation == version else { throw CancellationError() }
            try self.save(updated)
            return updated
        }
        refreshTask = task
        defer { if generation == version { refreshTask = nil } }
        return try await task.value.userToken
    }

    func login(email: String, password: String) async throws -> HuluTokens {
        let serial = "0000" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let answer = try await post("/v2/livingroom/password/authenticate", form: [
            "user_email": email, "password": password, "friendly_name": "Wazu",
            "serial_number": serial, "device_id": "166",
        ])
        let data = answer["data"] as? [String: Any]
        if data?["twofa_authentication"] as? Bool == true {
            throw HuluTwoFactor(token: data?["token"] as? String ?? "")
        }
        return try HuluTokens(json: answer, serial: serial)
    }

    // MARK: Emailed code (two-step verification)

    /// Cookies go to the shared store, where the website sign-in keeps its `_hulu_session` too.
    private let web: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"]
        return URLSession(configuration: config)
    }()

    /// Has Hulu email the code for a two-step login, as auth.hulu.com's own login page does.
    func sendCode(token: String) async throws {
        _ = try await webPost("/v1/web/mfa/code", form: ["token": token])
    }

    /// The emailed code → a web session (the `_hulu_session` cookie), like signing in on the website.
    func verifyCode(_ code: String, token: String) async throws {
        _ = try await webPost("/v1/web/mfa/authenticate", form: ["token": token, "code": code])
        guard HuluClient.hasWebSession else { throw HuluError.signIn("The code is incorrect or has expired.") }
    }

    /// auth.hulu.com's web calls want a CSRF value for the path, from /v2/csrf, in the form.
    private func webPost(_ path: String, form: [String: String]) async throws -> [String: Any] {
        var csrfURL = URLComponents(string: "https://auth.hulu.com/v2/csrf")!
        csrfURL.queryItems = [.init(name: "path", value: path)]
        var csrfRequest = URLRequest(url: csrfURL.url!)
        csrfRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (csrfData, _) = try await web.data(for: csrfRequest)
        guard let csrf = ((try? JSONSerialization.jsonObject(with: csrfData) as? [String: Any])?["data"] as? [String: Any])?["csrf"] as? String else {
            throw HuluError.badResponse("csrf")
        }
        var request = URLRequest(url: URL(string: "https://auth.hulu.com" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = form
        form["csrf"] = csrf
        request.httpBody = Self.formBody(form)
        let (data, response) = try await web.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status), object["error"] == nil else {
            let error = object["error"] as? [String: Any]
            if error?["name"] as? String == "TOKEN_EXPIRED" { throw HuluError.signIn("The code request expired. Sign in again.") }
            throw HuluError.signIn(error?["message"] as? String ?? "Hulu refused the code (\(status)).")
        }
        return object
    }

    func profiles(tokens: HuluTokens) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://home.hulu.com/v2/users/self/profiles")!)
        request.setValue("Bearer \(tokens.userToken)", forHTTPHeaderField: "Authorization")
        let result = try await send(request)
        return result["data"] as? [String: Any] ?? result
    }

    func select(profileID: String, pin: String?, tokens: HuluTokens) async throws -> HuluTokens {
        let answer = try await post("/v2/device/profiles/switch", form: [
            "device_token": tokens.deviceToken, "profile_id": profileID, "pin": pin ?? "",
        ])
        let selected = try HuluTokens(json: answer, serial: tokens.serial, previous: tokens)
        guard selected.profileID == profileID else { throw HuluError.badResponse("selected profile") }
        return selected
    }

    nonisolated static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(form.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }

    private func post(_ path: String, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://auth.hulu.com" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HuluError.http(status, "Native authentication returned an unreadable response.")
        }
        let error = object["error"] as? [String: Any]
        guard (200..<300).contains(status), object["error"] == nil,
              object["errorCode"] == nil, object["code"] == nil else {
            throw HuluError.signIn(error?["message"] as? String ?? object["message"] as? String
                ?? "Hulu refused native authentication (\(status)). Use Sign In with Hulu Website if verification is required.")
        }
        return object
    }
}
