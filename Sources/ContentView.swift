//
//  ContentView.swift
//  Wazu
//
//  Sidebar of places beside a browse stack of hubs (rows of artwork), the live guide, and search.
//  Playing something switches to the TV tab at the bottom of the sidebar, which holds the player
//  (WazKit's PlayerView); the player can split the movie out into its own window.
//

import SwiftUI
import WazKit

/// Where the sidebar can take you; TV is last: the player.
enum Place: String, CaseIterable, Identifiable {
    case home, shows, movies, sports, live, myStuff, search, tv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .shows: "TV Shows"
        case .movies: "Movies"
        case .sports: "Sports"
        case .live: "Live TV"
        case .myStuff: "My Stuff"
        case .search: "Search"
        case .tv: "TV"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .shows: "tv"
        case .movies: "film"
        case .sports: "sportscourt"
        case .live: "antenna.radiowaves.left.and.right"
        case .myStuff: "plus.square.on.square"
        case .search: "magnifyingglass"
        case .tv: "play.tv"
        }
    }

    /// The discover hub behind the place (live, search and TV are not hubs).
    var hub: String? {
        switch self {
        case .home: "home"
        case .shows: "tv"
        case .movies: "movies"
        case .sports: "sports"
        case .myStuff: "watch-later"
        case .live, .search, .tv: nil
        }
    }
}

/// A hub pushed on the browse stack.
struct Destination: Hashable {
    let url: URL
    let title: String
}

@MainActor
final class AppModel: ObservableObject {
    let client = HuluClient()
    let player: PlayerController

    @Published var place: Place = .home { didSet { if place != .tv { path = [] } } }
    @Published var path: [Destination] = []
    @Published var showSignIn = false
    /// Playback > Float on Top: the split-out player window stays above other windows.
    @Published var playerFloats = false { didSet { player.floatsOnTop = playerFloats } }
    /// Bumped on sign-in/out so the views reload.
    @Published var session = 0
    private var signInObserver: NSObjectProtocol?

    init() {
        player = PlayerController(service: client)
        signInObserver = NotificationCenter.default.addObserver(forName: HuluAuth.signInRequired, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSignIn = true }
        }
        if !HuluClient.isSignedIn {
            Task {
                if await HuluAuth.recover() { session += 1 } else { showSignIn = true }
            }
        }
    }

    /// What a click on an item does: episodes and airings play; everything else opens its page.
    func open(_ item: Item) {
        let playable = item.isLive || ["episode", "sports_episode", "extra", "live"].contains(item.kind)
        if item.browse != nil, !playable || item.eab == nil {
            showDetails(item)
        } else {
            play(item)
        }
    }

    /// Starts playback and shows it on the TV tab (or in the split-out window, if that is open).
    func play(_ item: Item) {
        guard let eab = item.eab else { return }
        let channelId = item.isLive ? item.channelId : nil
        player.play(NowPlaying(id: item.id, title: item.title, subtitle: item.subtitle)) { [client] in
            try await client.playback(eab: eab, channelId: channelId)
        }
        place = .tv
    }

    /// Opens an item's page; shows and movies open under the TV Shows and Movies places so the sidebar follows.
    func showDetails(_ item: Item) {
        guard let browse = item.browse else { return }
        follow(item)
        path.append(Destination(url: browse, title: item.title))
    }

    /// Moves the sidebar to the place an item belongs to: TV Shows for shows and episodes, Movies for movies,
    /// Live TV for airings. Hulu's kind strings vary, so the browse URL (…/hubs/series/…, …/hubs/movie/…) counts too.
    private func follow(_ item: Item) {
        let kind = item.kind.lowercased()
        let hub = item.browse?.path.lowercased() ?? ""
        let target: Place?
        if item.isLive || kind == "live" {
            target = .live
        } else if kind.contains("movie") || hub.contains("/hubs/movie") {
            target = .movies
        } else if kind.contains("series") || kind.contains("episode") || hub.contains("/hubs/series") {
            target = .shows
        } else {
            target = nil
        }
        // Only switch when it changes the place: setting it clears the stack.
        if let target, place != target { place = target }
    }

    @Published var signOutError: String?

    func signOut() {
        do {
            try HuluSession.shared.clear()
            try HuluAuth.deleteCredentials()
            HuluAuth.stopRecovery()
        } catch {
            signOutError = error.localizedDescription
            return
        }
        player.stop()
        HuluClient.signOut()
        path = []
        session += 1
        showSignIn = true
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationSplitView {
            List(Place.allCases, selection: $app.place) { place in
                Label(place.title, systemImage: place.icon).tag(place)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            NavigationStack(path: $app.path) {
                root
                    .navigationDestination(for: Destination.self) { destination in
                        HubView(url: destination.url, title: destination.title)
                    }
            }
            .id(app.session)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .help("Sign out of Hulu")
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: $app.showSignIn) {
            SignInView { app.session += 1 }
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

    @ViewBuilder private var root: some View {
        switch app.place {
        case .live: LiveView()
        case .search: SearchView()
        case .tv: PlayerView(player: app.player, inWindow: false, title: "Wazu")
        default: HubView(url: URL(string: "https://discover.hulu.com/content/v5/hubs/\(app.place.hub!)?schema=1&limit=30")!,
                         title: app.place.title)
        }
    }
}

// MARK: - Hubs

struct HubView: View {
    @EnvironmentObject var app: AppModel
    let url: URL
    let title: String
    @State private var hub: Hub?
    @State private var error: String?

    var body: some View {
        Group {
            if let hub {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if hub.focus != nil || hub.description != nil {
                            header(hub)
                        }
                        ForEach(hub.collections) { collection in
                            CollectionRow(collection: collection)
                        }
                    }
                    .padding(.vertical, 20)
                }
            } else if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else {
                Color.clear
            }
        }
        .navigationTitle(title)
        .task(id: url) { await load() }
    }

    private func header(_ hub: Hub) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = hub.description {
                Text(description).foregroundStyle(.secondary).lineLimit(4)
            }
            if let focus = hub.focus {
                Button {
                    app.play(focus)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Artwork(url: focus.artwork(width: 960, height: 540), title: focus.title, tint: .teal)
                            .frame(width: 480, height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                Image(systemName: "play.circle.fill").font(.system(size: 56))
                                    .foregroundStyle(.white).shadow(radius: 6)
                            }
                        Text([focus.subtitle, focus.title].compactMap { $0 }.joined(separator: " · ")).font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(focus.eab == nil)
            }
        }
        .padding(.horizontal, 20)
    }

    private func load() async {
        hub = nil
        error = nil
        do { hub = try await app.client.hub(url: url) } catch { self.error = error.localizedDescription }
    }
}

struct CollectionRow: View {
    @EnvironmentObject var app: AppModel
    @State var collection: Collection
    @State private var loadingMore = false

    private var vertical: Bool { collection.theme.contains("vertical") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(collection.name).font(.title3.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(collection.items) { item in
                        ItemCard(item: item, vertical: vertical)
                    }
                    if collection.next != nil {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                        .frame(width: 120, height: vertical ? 240 : 135)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func loadMore() async {
        guard let next = collection.next, !loadingMore else { return }
        loadingMore = true
        if let page = try? await app.client.collection(url: next) {
            collection.items += page.items
            collection.next = page.next
        } else {
            collection.next = nil
        }
        loadingMore = false
    }
}

struct ItemCard: View {
    @EnvironmentObject var app: AppModel
    let item: Item
    var vertical = false

    var body: some View {
        TileCard(item, vertical: vertical, tint: .teal) {
            app.open(item)
        } menu: {
            if item.eab != nil { Button("Play") { app.play(item) } }
            if item.browse != nil { Button("Show Details") { app.showDetails(item) } }
        }
    }
}


// MARK: - Live

struct LiveView: View {
    @EnvironmentObject var app: AppModel
    @State private var channels: [Channel] = []
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if channels.isEmpty {
                Color.clear
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(channels) { channel in
                            Button {
                                guard let program = channel.program else { return }
                                app.play(Item(id: channel.id, kind: "live", title: program.headline, subtitle: channel.name,
                                              artwork: nil, eab: program.eab, channelId: channel.id))
                            } label: {
                                HStack(spacing: 12) {
                                    ChannelLogo(url: URL(string: (channel.logo?.absoluteString ?? "") + "&size=240x80%7Cmax&format=png"))
                                        .frame(width: 120, height: 40)
                                    VStack(alignment: .leading) {
                                        Text(channel.name).font(.headline)
                                        if let program = channel.program {
                                            Text(program.headline).foregroundStyle(.secondary)
                                            Text("\(program.start, style: .time) – \(program.end, style: .time)").font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "play.fill").foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(channel.program == nil)
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
        .navigationTitle("Live TV")
        .task(id: app.session) {
            do { channels = try await app.client.channels() } catch { self.error = error.localizedDescription }
        }
    }
}

/// img.hulu.com answers a not-yet-rendered size with 200 "Submitted for processing"
/// (which URLCache keeps for 30 days), so drop that response and retry until the PNG is ready.
struct ChannelLogo: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "tv")
            }
        }
        .task(id: url) {
            guard let url else { return }
            let request = URLRequest(url: url)
            for _ in 0..<5 {
                if let (data, _) = try? await URLSession.shared.data(for: request) {
                    if let loaded = NSImage(data: data) { image = loaded; return }
                    URLCache.shared.removeCachedResponse(for: request)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var results: [Item] = []
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Hulu", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .padding(20)
                .onSubmit { Task { await search() } }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], alignment: .leading, spacing: 16) {
                    ForEach(results) { item in ItemCard(item: item) }
                }
                .padding(.horizontal, 20)
            }
        }
        .navigationTitle("Search")
    }

    private func search() async {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        results = (try? await app.client.search(query)) ?? []
        searching = false
    }
}

