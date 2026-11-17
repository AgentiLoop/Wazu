//
//  SignIn.swift
//  Wazu
//
//  Native credential and profile authentication; website sign-in is an explicit fallback.
//

import SwiftUI
import WebKit
import WazKit
import Security

@MainActor
final class HuluAuth: CredentialSignIn {
    let name = "Hulu"
    private var pending: HuluTokens?
    /// The two-step login waiting for its emailed code.
    private var twofaToken: String?
    /// Signed in with the code: the session is the website's cookie, and Hulu's site keeps the profile.
    private var signedInOnWeb = false
    private var credentials: Credentials?
    private let automatic: Bool
    private static var attemptedRecovery = false
    private static var recoveryTask: Task<Bool, Never>?
    static let signInRequired = Notification.Name("HuluSignInRequired")

    init(automatic: Bool = false) { self.automatic = automatic }

    private struct Credentials: Codable {
        let email: String
        let password: String
        var profileID: String?
    }

    private static var credentialKey: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.starplayrx.wazu.credentials",
         kSecAttrAccount as String: "hulu"]
    }

    private static func savedCredentials() -> Credentials? {
        var query = credentialKey
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(credentialKey as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = credentialKey
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw HuluError.signIn("Could not save Hulu credentials in Keychain (\(status)).")
        }
    }

    static func deleteCredentials() throws {
        let status = SecItemDelete(credentialKey as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HuluError.signIn("Could not remove Hulu credentials from Keychain (\(status)).")
        }
    }

    static func stopRecovery() {
        attemptedRecovery = true
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    static func requireSignIn() {
        stopRecovery()
        NotificationCenter.default.post(name: signInRequired, object: nil)
    }

    static var isReview: Bool { savedCredentials()?.profileID == "iwaz-review" }

    static func reviewLogin(email: String, password: String) async throws {
        var request = URLRequest(url: URL(string: "https://iwaz.xcf.ai/v1/review/hulu/session")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": email, "password": password])
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        let (data, response) = try await client.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw HuluError.signIn(status == 401 ? "Incorrect App Review credentials." :
                status == 429 ? "Too many attempts. Wait a minute." : "App Review session unavailable. Contact the developer.")
        }
        struct ReviewSession: Decodable {
            let userToken: String
            let serial: String
            let profileID: String
            let expiresAt: Double
        }
        let result = try JSONDecoder().decode(ReviewSession.self, from: data)
        let remaining = result.expiresAt - Date().timeIntervalSince1970
        guard !result.userToken.isEmpty, !result.serial.isEmpty, !result.profileID.isEmpty, remaining > 0 else {
            throw HuluError.badResponse("review session")
        }
        let tokens = try HuluTokens(json: ["user_token": result.userToken, "device_token": "iwaz-review",
                                         "profile_id": result.profileID, "expires_in": remaining], serial: result.serial)
        try Task.checkCancellation()
        try save(Credentials(email: email, password: password, profileID: "iwaz-review"))
        try HuluSession.shared.install(tokens)
        HuluClient.signOut()
    }

    static func renewReview() async throws {
        guard let saved = savedCredentials(), saved.profileID == "iwaz-review" else {
            throw HuluError.signIn("Please sign in to App Review again.")
        }
        try await reviewLogin(email: saved.email, password: saved.password)
    }

    static func recover() async -> Bool {
        if isReview {
            do { try await renewReview(); return true }
            catch { return false }
        }
        if let recoveryTask { return await recoveryTask.value }
        guard !attemptedRecovery else { return false }
        attemptedRecovery = true
        let task = Task { @MainActor in
            guard let saved = savedCredentials() else { return false }
            let auth = HuluAuth(automatic: true)
            do {
                let profiles = try await auth.login(email: saved.email, password: saved.password)
                try Task.checkCancellation()
                guard let profile = profiles.first(where: { $0.id == saved.profileID }),
                      !profile.isPinProtected else { return false }
                try await auth.pick(profile, pin: nil)
                return true
            } catch { return false }
        }
        recoveryTask = task
        let result = await task.value
        recoveryTask = nil
        return result
    }

    func login(email: String, password: String) async throws -> [SignInProfile] {
        pending = nil
        credentials = nil
        if !automatic { Self.stopRecovery() }
        let tokens: HuluTokens
        do {
            tokens = try await HuluSession.shared.login(email: email, password: password)
        } catch let twofa as HuluTwoFactor {
            // The automatic sign-in must not email a code on every launch.
            guard !automatic, !twofa.token.isEmpty else {
                throw HuluError.signIn("Hulu wants an emailed code. Sign in again, or use Sign In with Hulu Website below.")
            }
            HuluClient.signOut() // A fresh cookie jar for the web session the code creates.
            try await HuluSession.shared.sendCode(token: twofa.token)
            twofaToken = twofa.token
            throw SignInCodeSent(email: email)
        }
        let result = try await HuluSession.shared.profiles(tokens: tokens)
        let pinEnabled = result["pin_enabled"] as? Bool ?? false
        let profiles = (result["profiles"] as? [[String: Any]] ?? []).compactMap { json -> SignInProfile? in
            guard let id = json["id"] as? String, let name = json["name"] as? String else { return nil }
            let kids = json["is_kids"] as? Bool ?? false
            return SignInProfile(id: id, name: name, isPinProtected: pinEnabled && !kids, isKids: kids)
        }
        guard !profiles.isEmpty else { throw HuluError.badResponse("native profiles") }
        pending = tokens
        credentials = Credentials(email: email, password: password)
        return profiles
    }

    /// The emailed code → a website session; the form then "picks" the one entry and is done.
    func verify(email: String, code: String) async throws -> [SignInProfile] {
        guard let twofaToken else { throw HuluError.signIn("Please sign in again.") }
        try await HuluSession.shared.verifyCode(code, token: twofaToken)
        self.twofaToken = nil
        signedInOnWeb = true
        return [SignInProfile(id: "web", name: email)]
    }

    func pick(_ profile: SignInProfile, pin: String?) async throws {
        if signedInOnWeb {
            // The web cookie is the session; a stale native session would take precedence over it.
            try HuluSession.shared.clear()
            if !automatic { Self.attemptedRecovery = false }
            return
        }
        guard let pending else { throw HuluError.signIn("Please sign in again.") }
        let selected = try await HuluSession.shared.select(profileID: profile.id, pin: pin, tokens: pending)
        try Task.checkCancellation()
        if !automatic, var credentials {
            credentials.profileID = profile.id
            try Self.save(credentials)
        }
        try HuluSession.shared.install(selected)
        HuluClient.signOut() // Clear browser cookies without clearing the newly installed native session.
        self.pending = nil
        credentials = nil
        if !automatic { Self.attemptedRecovery = false }
    }
}

struct SignInView: View {
    let onSignedIn: () -> Void
    @State private var onWeb = false
    @State private var error: String?
    @State private var review = false
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        if onWeb {
            WebSignInView(title: "Sign in to Hulu", url: URL(string: "https://www.hulu.com/login")!,
                          size: CGSize(width: 900, height: 700), isSignedIn: { webView in
                for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                let onSite = webView.url?.host == "www.hulu.com" && webView.url?.path.hasPrefix("/login") == false
                return onSite && HuluClient.hasWebSession
            }, onSignedIn: onSignedIn)
        } else if review {
            VStack(spacing: 16) {
                Text("App Review Sign In").font(.title2)
                Text("Use the demo credentials supplied in App Store Connect. Access is provided by iwaz.xcf.ai.")
                TextField("Review username", text: $username).textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Review password", text: $password).textContentType(.password)
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView() }
                Button("Sign In") {
                    busy = true
                    error = nil
                    HuluAuth.stopRecovery()
                    Task { @MainActor in
                        defer { busy = false }
                        do {
                            try await HuluAuth.reviewLogin(email: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                            password = ""
                            onSignedIn()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(busy || username.isEmpty || password.isEmpty)
                Button("Back") { password = ""; error = nil; review = false }.disabled(busy)
            }
            .textFieldStyle(.roundedBorder)
            .padding(24)
            .frame(maxWidth: 400)
        } else {
            VStack(spacing: 0) {
                CredentialSignInView(service: HuluAuth(), onSignedIn: onSignedIn)
                Button("Sign In with Hulu Website") {
                    do {
                        HuluAuth.stopRecovery()
                        try HuluAuth.deleteCredentials()
                        try HuluSession.shared.clear()
                        HuluClient.signOut()
                        onWeb = true
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .padding(.bottom, 20)
                Button("App Review Sign In") { HuluAuth.stopRecovery(); error = nil; review = true }
                    .padding(.bottom, 20)
                if let error {
                    Text(error).foregroundStyle(.red).padding(.horizontal).padding(.bottom)
                }
            }
        }
    }
}
