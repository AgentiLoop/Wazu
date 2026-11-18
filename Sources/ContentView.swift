//
//  ContentView.swift
//  Wazu
//
//  Sidebar of places beside a browse stack of hubs (rows of artwork), the live guide, and search.
//  Playing something switches to the TV tab at the bottom of the sidebar, which holds the player
//  (WazKit's PlayerView); the player can split the movie out into its own window.
//

import SwiftUI
import AVKit
import Combine
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
    /// A hub opened from the iPhone's Browse list: it gets the search field.
    var searchable = false
}

/// The last episode or movie played and how far in, kept between launches.
struct LastPlayed: Codable {
    let id: String
    let title: String
    let subtitle: String?
    let eab: String
    /// Seconds into the episode or movie itself (a bumper before it is not counted).
    var position: Double
    /// The player was still up when this was saved (not stopped): the next launch carries straight on.
    var open = true

    /// The EAB's entity part ("EAB::<entity>::<asset>::<bundle>"): the same episode whatever row it was picked from.
    var entity: String { Self.entity(eab) }
    static func entity(_ eab: String) -> String { eab.components(separatedBy: "::").dropFirst().first ?? eab }
}

@MainActor
final class AppModel: ObservableObject {
    let client = HuluClient()
    let player: PlayerController

    @Published var place: Place = .home { didSet { if place != .tv { path = [] }; if place != oldValue { liveSearch.text = "" } } }
    @Published var path: [Destination] = []
    @Published var showSignIn = false
    /// Live TV's search text; the field lives in the window toolbar, left of Sign Out. Kept in its own
    /// object so typing does not re-render the window (and the toolbar), which would drop the field's focus.
    let liveSearch = LiveSearch()
    /// The search field shows on Live TV and on every hub page (Home, TV Shows, Movies, Sports, My Stuff).
    var searchVisible: Bool { place == .live || place.hub != nil }
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
        player.onEnd = { [weak self] in self?.playNext(atEnd: true) }
        player.onClose = { [weak self] in self?.closePlayer() }
        // Once a second of playback: how far in the remembered episode or movie is, and whether its end
        // credits have started (then the next episode plays).
        timeObserver = player.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                // Not while a stream is loading: a time that arrives then belongs to the one before it.
                guard let self, !self.player.isLoading, self.player.current?.id == self.last?.id, time.seconds >= 1 else { return }
                self.last?.position = self.breaks.contentTime(time.seconds)
                if let credits = self.credits, credits.id == self.player.current?.id, time.seconds >= credits.start {
                    self.credits = nil
                    self.playNext(atEnd: false)
                }
            }
        }
        // The TV tab draws from this model, so it hears when what is playing changes. Stopped (Stop, a
        // sign-out, an error) also means the next launch does not start it again.
        currentWatch = player.$current.dropFirst().sink { [weak self] current in
            if current == nil { self?.last?.open = false }
            self?.objectWillChange.send()
        }
        // Signed in (or signed in again with the saved credentials): if the app was quit with the player
        // still up, carry straight on with what was playing.
        Task {
            if !HuluClient.isSignedIn {
                guard await HuluAuth.recover() else { showSignIn = true; return }
                session += 1
            }
            if last?.open == true { resume() }
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

    /// The iPhone's full-screen player is up.
    @Published var showPlayer = false

    /// The last episode or movie played, saved as it plays so it can carry on after the player or the app is quit.
    private(set) var last: LastPlayed? = UserDefaults.standard.data(forKey: "lastPlayed")
        .flatMap({ try? JSONDecoder().decode(LastPlayed.self, from: $0) }) {
        didSet { UserDefaults.standard.set(last.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastPlayed") }
    }
    /// Where the user was when they picked what is playing: the app goes back there when nothing is left to play.
    private var origin: (place: Place, path: [Destination])?
    private var timeObserver: Any?
    private var currentWatch: AnyCancellable?

    /// Starts playback and shows it on the TV tab (or in the split-out window, if that is open);
    /// on iPhone, in the full-screen player. `guideChannel`: the channel, when it was picked in the TV guide.
    func play(_ item: Item, guideChannel: String? = nil) {
        guard let eab = item.eab else { return }
        self.guideChannel = guideChannel
        play(NowPlaying(id: item.id, title: item.title, subtitle: item.subtitle), eab: eab,
             channelId: item.isLive ? item.channelId : nil, show: true)
    }

    /// Carries on with the last episode or movie from where it was left.
    func resume() {
        guard let last else { return }
        guideChannel = nil
        play(NowPlaying(id: last.id, title: last.title, subtitle: last.subtitle), eab: last.eab, channelId: nil, show: true)
    }

    /// The channel last played from the TV guide: the guide highlights it and opens scrolled to it.
    @Published private(set) var guideChannel: String?

    /// The player's ✕. A live channel picked in the TV guide is paused and the app is back on the guide, which
    /// opens at that channel and keeps it highlighted. Anything else stops.
    private func closePlayer() {
        guard guideChannel != nil, player.current != nil else { player.stop(); return }
        player.pause()
        #if os(macOS)
        if place == .tv, let origin {
            place = origin.place
            path = origin.path
        }
        #else
        showPlayer = false
        #endif
    }

    /// An episode or movie becomes the remembered one; played again, it carries on from where it was left.
    /// `show` brings the player up and notes where the user was.
    private func play(_ what: NowPlaying, eab: String, channelId: String?, show: Bool) {
        let position = last?.entity == LastPlayed.entity(eab) ? last?.position ?? 0 : 0
        if channelId != nil {
            last?.open = false
        } else {
            last = LastPlayed(id: what.id, title: what.title, subtitle: what.subtitle, eab: eab, position: position)
        }
        credits = nil
        breaks = Breaks()
        player.play(what) { [client, weak self] in
            let answer = try await client.playback(eab: eab, channelId: channelId, resume: position > 0 ? position : nil)
            await MainActor.run { [weak self] in
                self?.credits = answer.credits.map { (what.id, $0) }
                self?.breaks = answer.breaks
            }
            return answer.playback
        }
        guard show else { return }
        #if os(macOS)
        if place != .tv {
            origin = (place, path)
            place = .tv
        }
        #else
        showPlayer = true
        #endif
    }

    /// Where the end credits of what is playing start, in the player's seconds (from the playlist answer).
    /// Cleared once the playhead has reached it, so the next episode is asked for once.
    private var credits: (id: String, start: Double)?
    /// The breaks in the stream that is playing: what turns the player's time into the time in the episode.
    private var breaks = Breaks()

    /// The next episode plays: the next in the season, or the next season's first. This is called when the
    /// end credits start, and again at the very end (`atEnd`) for anything that has no credits time. With no
    /// episode left the credits play on, and at the end the player closes and the app is back where the user
    /// picked what was playing.
    private func playNext(atEnd: Bool) {
        guard let finished = player.current else { return }
        let eab = last?.id == finished.id ? last?.eab : nil
        Task {
            var next: Item?
            if let eab {
                // The question could not be asked (no network, say): the player stays as it is.
                do { next = try await client.nextEpisode(after: eab) } catch { return }
            }
            guard player.current == finished else { return }
            if let next, let eab = next.eab {
                play(NowPlaying(id: next.id, title: next.title, subtitle: next.subtitle), eab: eab, channelId: nil, show: false)
                return
            }
            guard atEnd else { return }
            last = nil
            player.stop()
            #if os(macOS)
            if place == .tv, let origin {
                place = origin.place
                path = origin.path
            }
            origin = nil
            #else
            showPlayer = false
            #endif
        }
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
        last = nil
        HuluClient.signOut()
        path = []
        session += 1
        showSignIn = true
    }
}

#if os(macOS)
struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @State private var columns = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
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
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    if app.searchVisible, app.path.isEmpty {
                        LiveSearchField(search: app.liveSearch)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    if app.searchVisible, app.path.isEmpty {
                        LiveSearchField(search: app.liveSearch)
                    }
                }
            }
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
        .background(FullScreenCapable())
        .fullScreenSidebar($columns)
        .hidesToolbarInFullScreen()
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
        case .live: LiveView(search: app.liveSearch)
        case .search: SearchView()
        case .tv: ZStack {
            Color.black
            if let error = app.player.error {
                ContentUnavailableView(error, systemImage: "play.slash")
                    .foregroundStyle(.white)
            } else if app.player.current == nil {
                ContentUnavailableView {
                    Label("Nothing Playing", systemImage: "tv")
                } description: {
                    Text("Pick something to watch.")
                } actions: {
                    if let last = app.last { Button("Resume \(last.title)") { app.resume() } }
                }
                .foregroundStyle(.white)
            } else {
                PlayerContainer(controller: app.player)
            }
        }
        .navigationTitle(app.player.current?.title ?? "Wazu")
        default: HubView(url: URL(string: "https://discover.hulu.com/content/v5/hubs/\(app.place.hub!)?schema=1&limit=30")!,
                         title: app.place.title, searchable: true, search: app.liveSearch)
        }
    }
}
#endif

// MARK: - Hubs

struct HubView: View {
    @EnvironmentObject var app: AppModel
    let url: URL
    let title: String
    /// Shows the toolbar search: filters the hub's tiles by title or subtitle.
    var searchable = false
    @ObservedObject var search = LiveSearch()
    @State private var hub: Hub?
    @State private var error: String?

    private var filter: String { searchable ? search.text.trimmingCharacters(in: .whitespaces) : "" }

    var body: some View {
        Group {
            if let hub {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if hub.focus != nil || hub.description != nil {
                            header(hub)
                        }
                        ForEach(hub.collections) { collection in
                            CollectionRow(collection: collection, filter: filter)
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
                    app.play(focus)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Group {
                            #if os(macOS)
                            Artwork(url: focus.artwork(width: 960, height: 540), title: focus.title, tint: .teal)
                                .frame(width: 480, height: 270)
                            #else
                            // A 16:9 box the artwork fills: the image alone would grow to any height offered (landscape).
                            Color.clear
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .frame(maxWidth: 480)
                                .overlay { Artwork(url: focus.artwork(width: 960, height: 540), title: focus.title, tint: .teal) }
                            #endif
                        }
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
    /// Only tiles whose title or subtitle contains this text are shown (empty shows all).
    var filter = ""
    @State private var loadingMore = false

    private var vertical: Bool { collection.theme.contains("vertical") }

    private var visibleItems: [Item] {
        guard !filter.isEmpty else { return collection.items }
        return collection.items.filter {
            $0.title.localizedCaseInsensitiveContains(filter) || ($0.subtitle?.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    var body: some View {
        if filter.isEmpty || !visibleItems.isEmpty {
            row
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(collection.name).font(.title3.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(visibleItems) { item in
                        ItemCard(item: item, vertical: vertical)
                    }
                    if collection.next != nil {
                        ProgressView()
                            .frame(width: 120, height: vertical ? 240 : 135)
                            .task(id: collection.items.count) { await loadMore() }
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

/// Live TV has two faces: the guide (channels down the side, the next hours across) and the plain list
/// of channels with what is on now. The one last picked is the one shown next time.
struct LiveView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var search: LiveSearch
    @AppStorage("liveGuide") private var showsGuide = true

    var body: some View {
        VStack(spacing: 0) {
            Picker("Live TV", selection: $showsGuide) {
                Text("Channels").tag(false)
                Text("Guide").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            .padding(.vertical, 10)
            if showsGuide {
                GuideView(search: search, tint: .teal, playing: app.guideChannel) { start, end in
                    try await app.client.channels(from: start, to: end).map { channel in
                        // An airing's EAB is its own (it ends in the airing's id), so it names the programme.
                        GuideChannel(id: channel.id, name: channel.name, logo: channel.logoImage, programs: channel.programs.map {
                            GuideProgram(id: $0.eab, title: $0.headline, start: $0.start, end: $0.end)
                        })
                    }
                } onSelect: { channel, program in
                    app.play(Item(id: channel.id, kind: "live", title: program.title, subtitle: channel.name,
                                  artwork: nil, eab: program.id, channelId: channel.id), guideChannel: channel.id)
                }
                .id(app.session)
            } else {
                ChannelList(search: search)
            }
        }
        .navigationTitle("Live TV")
    }
}

/// Every channel with what is on now; a click plays it.
private struct ChannelList: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var search: LiveSearch
    @State private var channels: [Channel] = []
    @State private var error: String?
    @State private var loaded = false

    private var query: String { search.text }

    private var filtered: [Channel] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return channels }
        return channels.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.program?.headline.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else if channels.isEmpty {
                // The spinner is for the guide loading only: a guide that came back empty shows nothing.
                if loaded { Color.clear } else { ProgressView() }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { channel in
                            Button {
                                guard let program = channel.program else { return }
                                app.play(Item(id: channel.id, kind: "live", title: program.headline, subtitle: channel.name,
                                              artwork: nil, eab: program.eab, channelId: channel.id))
                            } label: {
                                HStack(spacing: 12) {
                                    ChannelLogo(url: channel.logoImage)
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
        .task(id: app.session) {
            do { channels = try await app.client.channels() } catch { self.error = error.localizedDescription }
            loaded = true
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
                .roundedFields()
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
