//
//  SignIn.swift
//  Wazu
//
//  Native credential and profile authentication; website sign-in is an explicit fallback.
//

import SwiftUI
import WebKit
import WazKit

@MainActor
final class HuluAuth: CredentialSignIn {
    let name = "Hulu"
    private var pending: HuluTokens?

    func login(email: String, password: String) async throws -> [SignInProfile] {
        pending = nil
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
        return profiles
    }

    func pick(_ profile: SignInProfile, pin: String?) async throws {
        guard let pending else { throw HuluError.signIn("Please sign in again.") }
        let selected = try await HuluSession.shared.select(profileID: profile.id, pin: pin, tokens: pending)
        try HuluSession.shared.install(selected)
        HuluClient.signOut() // Clear browser cookies without clearing the newly installed native session.
        self.pending = nil
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
