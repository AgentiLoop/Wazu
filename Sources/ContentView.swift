//
//  ContentView.swift
//  Wazu
//
//  Sidebar of places on hulu.com beside the web view; back/forward/reload in the toolbar. The
//  window's title is whatever is playing.
//

import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject var web: WebController

    var body: some View {
        NavigationSplitView {
            // The sidebar follows navigation: a selection is just the place whose path the
            // current page is under, and picking one loads it.
            List(Place.allCases, selection: Binding(
                get: { Place.containing(web.url) },
                set: { if let place = $0 { web.go(place) } }
            )) { place in
                Label(place.title, systemImage: place.icon)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            HuluWebView(webView: web.webView)
                .navigationTitle(web.nowPlaying ?? "Wazu")
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button { web.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                            .disabled(!web.canGoBack)
                        Button { web.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                            .disabled(!web.canGoForward)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if web.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { web.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        }
                    }
                }
        }
        .frame(minWidth: 900, minHeight: 540)
    }
}

/// The controller's one WKWebView, as a view.
struct HuluWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
