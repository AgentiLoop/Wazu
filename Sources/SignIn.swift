//
//  SignIn.swift
//  Wazu
//
//  Signing in happens on hulu.com itself, in a web view; the cookies it ends up with are the
//  session the API client uses (HTTPCookieStorage.shared).
//

import SwiftUI
import WebKit

struct SignInView: View {
    let onSignedIn: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Hulu").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
            SignInWebView {
                onSignedIn()
                dismiss()
            }
        }
        .frame(width: 900, height: 700)
    }
}

private struct SignInWebView: NSViewRepresentable {
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Hulu checks the browser: WebKit's default UA has no "Version/… Safari/…" tail, so add Safari's.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://www.hulu.com/login")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: () -> Void
        init(onSignedIn: @escaping () -> Void) { self.onSignedIn = onSignedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Copy the web view's cookies (incl. HttpOnly ones) to the client's storage, then
            // treat landing on hulu.com proper with a session cookie as signed in.
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
                let onSite = webView.url?.host == "www.hulu.com" && webView.url?.path.hasPrefix("/login") == false
                if onSite, HuluClient.isSignedIn { self.onSignedIn() }
            }
        }
    }
}
