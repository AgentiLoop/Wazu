//
//  SignIn.swift
//  Wazu
//
//  Native sign-in: the same calls hulu.com's login page makes, no web view. A CSRF token from
//  auth.hulu.com, then email and password to /v4/web/password/authenticate, which answers with the
//  session cookies (_hulu_session and friends on .hulu.com); picking a profile is another CSRF'd
//  post. The cookies land in HTTPCookieStorage.shared, where HuluClient reads them. The form is WazKit's.
//

import SwiftUI
import WazKit

@MainActor
final class HuluAuth: CredentialSignIn {
    private static let auth = "https://auth.hulu.com"
    private static let loginPath = "/v4/web/password/authenticate"
    private static let switchPath = "/v1/web/profiles/switch"
    private static let profilesURL = URL(string: "https://home.hulu.com/v1/users/self/profiles")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            "Accept": "application/json",
            "Origin": "https://www.hulu.com",
            "Referer": "https://www.hulu.com/",
        ]
        return URLSession(configuration: config)
    }()

    let name = "Hulu"

    /// Email and password → the session cookies, then the account's profiles.
    func login(email: String, password: String) async throws -> [SignInProfile] {
        let answer = try await Self.post(Self.loginPath, form: ["user_email": email, "password": password, "scenario": "web_password_login"])
        if (answer["data"] as? [String: Any])?["twofa_authentication"] != nil {
            throw HuluError.signIn("This account asks for a two-factor code, which Wazu does not support yet.")
        }
        guard HuluClient.isSignedIn else { throw HuluError.badResponse("session") }
        let (data, _) = try await Self.session.data(from: Self.profilesURL)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let profiles = (object?["profiles"] as? [[String: Any]] ?? []).compactMap { json -> SignInProfile? in
            guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
            return SignInProfile(id: id, name: name, isKids: json["is_kids"] as? Bool ?? false)
        }
        guard !profiles.isEmpty else { throw HuluError.badResponse("profiles") }
        return profiles
    }

    /// Picks the profile; the answer re-sets the profile cookies.
    func pick(_ profile: SignInProfile, pin: String?) async throws {
        var form = ["profile_id": profile.id]
        if let pin { form["pin"] = pin }
        _ = try await Self.post(Self.switchPath, form: form)
    }

    /// A CSRF'd form post to auth.hulu.com; the error message is Hulu's own.
    private static func post(_ path: String, form: [String: String]) async throws -> [String: Any] {
        let (csrfData, _) = try await session.data(from: URL(string: "\(auth)/v2/csrf?path=\(path)")!)
        guard let csrf = ((try? JSONSerialization.jsonObject(with: csrfData) as? [String: Any])?["data"] as? [String: Any])?["csrf"] as? String else {
            throw HuluError.badResponse("csrf")
        }
        var request = URLRequest(url: URL(string: auth + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Form encoding by hand: URLComponents leaves "+" alone, which the server would read as a space.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form.merging(["csrf": csrf]) { $1 }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            let error = object["error"] as? [String: Any] ?? object
            throw HuluError.signIn(error["message"] as? String ?? "Hulu answered \(status).")
        }
        return object
    }
}

struct SignInView: View {
    let onSignedIn: () -> Void

    var body: some View {
        CredentialSignInView(service: HuluAuth(), onSignedIn: onSignedIn)
    }
}
