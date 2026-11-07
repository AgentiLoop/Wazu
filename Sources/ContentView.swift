//
//  ContentView.swift
//  Wazu
//
//  Sidebar of places beside a browse stack of hubs (rows of artwork), the live guide, and search.
//  Playing something covers the browse area with the player until it is closed.
//

import SwiftUI
import AVKit

/// Where the sidebar can take you.
enum Place: String, CaseIterable, Identifiable {
    case home, tv, movies, live, myStuff, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .tv: "TV"
        case .movies: "Movies"
        case .live: "Live TV"
        case .myStuff: "My Stuff"
        case .search: "Search"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .tv: "tv"
        case .movies: "film"
        case .live: "antenna.radiowaves.left.and.right"
        case .myStuff: "plus.square.on.square"
        case .search: "magnifyingglass"
        }
    }

    /// The discover hub behind the place (live and search are not hubs).
    var hub: String? {
        switch self {
        case .home: "home"
        case .tv: "tv"
        case .movies: "movies"
        case .myStuff: "watch-later"
        case .live, .search: nil
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

    @Published var place: Place = .home { didSet { path = [] } }
    @Published var path: [Destination] = []
    @Published var showSignIn = !HuluClient.isSignedIn
    /// Bumped on sign-in/out so the views reload.
    @Published var session = 0

    init() { player = PlayerController(client: client) }

    /// What a click on an item does: episodes and airings play; everything else opens its page.
    func open(_ item: Item) {
        let playable = item.isLive || ["episode", "sports_episode", "extra", "live"].contains(item.kind)
        if let browse = item.browse, !playable || item.eab == nil {
            path.append(Destination(url: browse, title: item.title))
        } else {
            player.play(item)
        }
    }

    func signOut() {
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
            ZStack {
                NavigationStack(path: $app.path) {
                    root
                        .navigationDestination(for: Destination.self) { destination in
                            HubView(url: destination.url, title: destination.title)
                        }
                }
                .id(app.session)
                if app.player.current != nil || app.player.error != nil {
                    PlayerView()
                }
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: $app.showSignIn) {
            SignInView { app.session += 1 }
        }
    }

    @ViewBuilder private var root: some View {
        switch app.place {
        case .live: LiveView()
        case .search: SearchView()
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
                ProgressView()
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
                    app.player.play(focus)
                } label: {
                    Label([focus.subtitle, focus.title].compactMap { $0 }.joined(separator: " · "), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
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
                            if loadingMore { ProgressView() } else { Label("More", systemImage: "ellipsis") }
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

    private var size: CGSize { vertical ? CGSize(width: 160, height: 240) : CGSize(width: 240, height: 135) }

    var body: some View {
        Button {
            app.open(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                AsyncImage(url: item.artwork(width: Int(size.width) * 2, height: Int(size.height) * 2)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if item.isLive {
                        Text("LIVE").font(.caption2.bold()).padding(4).background(.red, in: RoundedRectangle(cornerRadius: 3)).padding(6)
                    }
                }
                Text(item.title).font(.callout.bold()).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: size.width)
        }
        .buttonStyle(.plain)
        .help(item.description ?? item.title)
        .contextMenu {
            if item.eab != nil { Button("Play") { app.player.play(item) } }
            if let browse = item.browse { Button("Show Details") { app.path.append(Destination(url: browse, title: item.title)) } }
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
                ProgressView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(channels) { channel in
                            Button {
                                guard let program = channel.program else { return }
                                app.player.play(Item(id: channel.id, kind: "live", title: program.headline, subtitle: channel.name,
                                                     artwork: nil, eab: program.eab, channelId: channel.id))
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: URL(string: (channel.logo?.absoluteString ?? "") + "&size=120x120&format=png")) { image in
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    } placeholder: {
                                        Image(systemName: "tv")
                                    }
                                    .frame(width: 60, height: 40)
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
                if searching { ProgressView().padding() }
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

// MARK: - Player

struct PlayerView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let error = app.player.error {
                ContentUnavailableView(error, systemImage: "play.slash")
                    .foregroundStyle(.white)
            } else {
                VideoPlayerView(player: app.player.player)
                if app.player.isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            Button {
                app.player.stop()
                app.player.error = nil
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .padding(12)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .navigationTitle(app.player.current?.title ?? "Wazu")
    }
}

/// AVKit's player view: its floating controls include full screen and Picture in Picture.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
