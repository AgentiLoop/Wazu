//
//  WazuiOSApp.swift
//  Wazu (iPhone)
//
//  The iPhone app: tabs for Browse (the hubs), Live TV and Search over the same app model, hubs,
//  guide and search the Mac app uses. Playing something opens the full-screen player (AVKit's, with
//  Picture in Picture).
//

import SwiftUI
import WazKit

@main
struct WazuiOSApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            PhoneContentView().environmentObject(app)
        }
    }
}

struct PhoneContentView: View {
    @EnvironmentObject var app: AppModel
    @State private var tab = Tab.browse

    enum Tab { case browse, live, search }

    var body: some View {
        TabView(selection: $tab) {
            stack(.browse) { BrowseList() }
                .tabItem { Label("Browse", systemImage: "house") }
                .tag(Tab.browse)
            stack(.live) {
                LiveView(search: app.liveSearch)
                    .searchable(text: searchText, prompt: "Search channels and shows")
            }
            .tabItem { Label("Live TV", systemImage: "antenna.radiowaves.left.and.right") }
            .tag(Tab.live)
            stack(.search) { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
        }
        .onChange(of: tab) { app.path = []; app.liveSearch.text = "" }
        .id(app.session)
        .sheet(isPresented: $app.showSignIn) {
            SignInView { app.session += 1 }
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $app.showPlayer) {
            PhonePlayer()
        }
        .alert("Could Not Sign Out", isPresented: Binding(
            get: { app.signOutError != nil },
            set: { if !$0 { app.signOutError = nil } }
        )) {
            Button("OK") { app.signOutError = nil }
        } message: {
            Text(app.signOutError ?? "")
        }
    }

    private var searchText: Binding<String> {
        Binding(get: { app.liveSearch.text }, set: { app.liveSearch.text = $0 })
    }

    /// Tiles push onto the app's one path; only the selected tab's stack shows it.
    private func stack(_ which: Tab, @ViewBuilder _ root: () -> some View) -> some View {
        NavigationStack(path: Binding(get: { tab == which ? app.path : [] },
                                      set: { if tab == which { app.path = $0 } })) {
            root()
                .navigationDestination(for: Destination.self) { destination in
                    if destination.searchable {
                        HubView(url: destination.url, title: destination.title, searchable: true, search: app.liveSearch)
                            .searchable(text: searchText, prompt: "Search shows and movies")
                    } else {
                        HubView(url: destination.url, title: destination.title)
                    }
                }
        }
    }
}

/// The hubs (Home, TV Shows, Movies, Sports, My Stuff) as a list; each opens its hub.
private struct BrowseList: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        List {
            ForEach(Place.allCases.filter { $0.hub != nil }) { place in
                NavigationLink(value: Destination(url: URL(string: "https://discover.hulu.com/content/v5/hubs/\(place.hub!)?schema=1&limit=30")!,
                                                  title: place.title, searchable: true)) {
                    Label(place.title, systemImage: place.icon)
                }
            }
            Section {
                Button(role: .destructive) { app.signOut() } label: {
                    Label("Sign Out of Hulu", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Wazu")
    }
}

/// The movie, in AVKit's full screen from the start; AVKit's own ✕ stops it and closes this.
/// Picture in Picture keeps it going over other apps. A ✕ of ours shows only when there is no video
/// (an error), since then AVKit's controls are not there.
private struct PhonePlayer: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        PlayerView(player: app.player, inWindow: true, title: "Wazu", onClose: close)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if app.player.current == nil || app.player.error != nil {
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .padding()
                }
            }
            .statusBarHidden()
    }

    private func close() {
        app.player.stop()
        app.showPlayer = false
    }
}
