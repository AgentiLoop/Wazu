//
//  SignIn.swift
//  Wazu
//
//  Signing in happens on hulu.com itself, in a web view (WazKit's WebSignInView); the cookies it
//  ends up with are the session the API client uses (HTTPCookieStorage.shared).
//

import SwiftUI
import WebKit
import WazKit

struct SignInView: View {
    let onSignedIn: () -> Void

    var body: some View {
        WebSignInView(title: "Sign in to Hulu", url: URL(string: "https://www.hulu.com/login")!,
                      size: CGSize(width: 900, height: 700), isSignedIn: { webView in
            // Copy the web view's cookies (incl. HttpOnly ones) to the client's storage, then
            // treat landing on hulu.com proper with a session cookie as signed in.
            for cookie in await webView.configuration.websiteDataStore.httpCookieStore.allCookies() {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            let onSite = webView.url?.host == "www.hulu.com" && webView.url?.path.hasPrefix("/login") == false
            return onSite && HuluClient.isSignedIn
        }, onSignedIn: onSignedIn)
    }
}
