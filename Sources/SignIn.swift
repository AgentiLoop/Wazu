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

    static func recover() async -> Bool {
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
        let tokens = try await HuluSession.shared.login(email: email, password: password)
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

    func pick(_ profile: SignInProfile, pin: String?) async throws {
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
        } else {
            VStack(spacing: 0) {
                CredentialSignInView(service: HuluAuth(), onSignedIn: onSignedIn)
                Button("Sign In with Hulu Website") {
                    do {
                        try HuluSession.shared.clear()
                        HuluClient.signOut()
                        onWeb = true
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .padding(.bottom, 20)
                if let error {
                    Text(error).foregroundStyle(.red).padding(.horizontal).padding(.bottom)
                }
            }
        }
    }
}
