//
//  ContentView.swift
//  Wazu
//
//  Sidebar of places beside a browse stack of hubs (rows of artwork), the live guide, and search.
//  Playing something switches to the TV tab at the bottom of the sidebar, which holds the player; its
//  split-out button moves the movie into its own window (PlayerWindow.swift).
//

import SwiftUI
import AVKit

/// Where the sidebar can take you; TV is last: the player.
enum Place: String, CaseIterable, Identifiable {
    case home, shows, movies, live, myStuff, search, tv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .shows: "TV Shows"
        case .movies: "Movies"
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
    private lazy var playerWindow = PlayerWindowController(app: self)

    @Published var place: Place = .home { didSet { if place != .tv { path = [] } } }
    @Published var path: [Destination] = []
    @Published var showSignIn = !HuluClient.isSignedIn
    /// The split-out button on the TV tab: the movie plays in its own window instead of the tab.
    @Published var splitOut = false
    /// Playback > Float on Top: the split-out player window stays above other windows.
    @Published var playerFloats = false { didSet { playerWindow.isFloating = playerFloats } }
    /// Bumped on sign-in/out so the views reload.
    @Published var session = 0

    init() { player = PlayerController(client: client) }

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
        _ = playerWindow
        player.play(item)
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
            NavigationStack(path: $app.path) {
                root
                    .navigationDestination(for: Destination.self) { destination in
                        HubView(url: destination.url, title: destination.title)
                    }
            }
            .id(app.session)
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
        case .tv: PlayerView(player: app.player, inWindow: false)
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

    private var size: CGSize { vertical ? CGSize(width: 160, height: 240) : CGSize(width: 240, height: 135) }

    var body: some View {
        Button {
            app.open(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Artwork(url: item.artwork(width: Int(size.width) * 2, height: Int(size.height) * 2), title: item.title)
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
            if item.eab != nil { Button("Play") { app.play(item) } }
            if item.browse != nil { Button("Show Details") { app.showDetails(item) } }
        }
    }
}

/// A tile's image. img.hulu.com answers 408 while it renders a size it hasn't made yet, and AsyncImage
/// never asks again, which left blank tiles; this retries until the image is ready, and reloads when a
/// tile comes back on screen. Items with no artwork (genre links) get their name on a plain tile.
struct Artwork: View {
    let url: URL?
    let title: String
    @State private var image: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if url == nil {
                LinearGradient(colors: [.indigo.opacity(0.8), .teal.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(title).font(.title3.bold()).multilineTextAlignment(.center).padding(12)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
            image = nil
            for attempt in 0..<6 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(attempt)) }
                guard !Task.isCancelled else { return }
                if let (data, _) = try? await URLSession.shared.data(from: url), let loaded = NSImage(data: data) {
                    Self.cache.setObject(loaded, forKey: url as NSURL)
                    image = loaded
                    return
                }
            }
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

/// The TV tab and the split-out window share this: the movie, or why there is none. On the tab a
/// floating split-out button moves the movie to its own window; while it is there the tab says so.
struct PlayerView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var player: PlayerController
    let inWindow: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if let error = player.error {
                ContentUnavailableView(error, systemImage: "play.slash")
                    .foregroundStyle(.white)
            } else if player.current == nil {
                ContentUnavailableView("Nothing Playing", systemImage: "tv", description: Text("Pick something to watch."))
                    .foregroundStyle(.white)
            } else if app.splitOut && !inWindow {
                ContentUnavailableView {
                    Label("Playing in Its Own Window", systemImage: "rectangle.on.rectangle")
                } description: {
                    Text("Close that window to bring the movie back here.")
                } actions: {
                    Button("Bring Back") { app.splitOut = false }
                }
                .foregroundStyle(.white)
            } else {
                VideoPlayerView(player: player.player)
                if !inWindow {
                    Button {
                        app.splitOut = true
                    } label: {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.title2)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Split Out: play in a separate window")
                    .padding(16)
                }
            }
        }
        .navigationTitle(player.current?.title ?? "Wazu")
    }
}

/// AVKit's player view: its floating controls include full screen and Picture in Picture.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = FocusingPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

/// Takes keyboard focus as soon as it is on screen, so space/arrows drive playback instead of the sidebar.
/// SwiftUI hands focus back to the sidebar after the first attempt, so it keeps claiming it on every
/// layout pass until it actually holds it, and again whenever the window becomes key.
final class FocusingPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { true }
    private var keyObserver: NSObjectProtocol?
    private var claimsLeft = 0

    private var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    private func claimFocus() {
        guard let window, !hasFocus else { return }
        window.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        claimsLeft = 10
        claimFocus()
        DispatchQueue.main.async { [weak self] in self?.claimFocus() }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.claimFocus()
        }
    }

    override func layout() {
        super.layout()
        hideLoadingIndicators(in: self)
        guard claimsLeft > 0 else { return }
        claimFocus()
        if hasFocus { claimsLeft = 0 } else { claimsLeft -= 1 }
    }

    /// AVKit draws its own buffering spinner inside the player view; walk the hierarchy and hide it.
    private func hideLoadingIndicators(in view: NSView) {
        for sub in view.subviews {
            let name = String(describing: type(of: sub))
            if sub is NSProgressIndicator || name.contains("Loading") || name.contains("Spinner") || name.contains("ProgressIndicator") {
                sub.isHidden = true
            } else {
                hideLoadingIndicators(in: sub)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        claimFocus()
        super.mouseDown(with: event)
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }
}
