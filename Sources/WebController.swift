//
//  WebController.swift
//  Wazu
//
//  The one web view that hosts Hulu's player, plus the bridge into it: a user script watches
//  the page's <video> and reports play/pause and the title; the app drives it (play/pause,
//  skip, Picture in Picture) through window.__wazu. The keyboard's media keys arrive through
//  MPRemoteCommandCenter and go the same way.
//

import WebKit
import MediaPlayer
import Combine

/// Where the sidebar can take you on hulu.com.
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

    var path: String {
        switch self {
        case .home: "/hub/home"
        case .tv: "/hub/tv"
        case .movies: "/hub/movies"
        case .live: "/live"
        case .myStuff: "/my-stuff"
        case .search: "/search"
        }
    }

    var url: URL { URL(string: "https://www.hulu.com" + path)! }

    /// The place a page belongs to, by its path — so the sidebar follows navigation.
    static func containing(_ url: URL?) -> Place? {
        guard let url, url.host?.hasSuffix("hulu.com") == true else { return nil }
        return allCases.first { url.path == $0.path || url.path.hasPrefix($0.path + "/") }
    }
}

@MainActor
final class WebController: NSObject, ObservableObject {
    let webView: WKWebView

    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    /// The page title while a video is playing or paused, else nil.
    @Published private(set) var nowPlaying: String?

    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        // Hulu checks the browser: WebKit's default UA has no "Version/… Safari/…" tail, so
        // add Safari's. The default (persistent) data store keeps the sign-in between launches.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addUserScript(
            WKUserScript(source: Self.playerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(Bridge(self), name: "wazu")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.url, options: .new) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.url = view.url }
            },
            webView.observe(\.canGoBack, options: .new) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: .new) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: .new) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
        ]
        installRemoteCommands()
        go(.home)
    }

    // MARK: Navigation

    func go(_ place: Place) { webView.load(URLRequest(url: place.url)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    /// Forgets the Hulu sign-in (cookies, storage) and starts over at Home.
    func signOut() {
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            MainActor.assumeIsolated { self.go(.home) }
        }
    }

    // MARK: Playback

    func playPause() { call("playPause()") }
    func skip(_ seconds: Double) { call("skip(\(seconds))") }
    func pictureInPicture() { call("pictureInPicture()") }

    private func call(_ function: String) {
        webView.evaluateJavaScript("window.__wazu && window.__wazu.\(function)") { _, _ in }
    }

    /// Runs in the page. Polls for the <video> (Hulu is a single-page app, so it comes and goes),
    /// reports play/pause changes, and exposes the controls the menus and media keys use.
    private static let playerScript = """
    (() => {
      if (window.__wazu) return;
      const video = () => document.querySelector('video');
      let hooked = null, last = '';
      const report = () => {
        const v = video();
        const playing = !!v && !v.paused && !v.ended;
        const title = document.title || '';
        const state = JSON.stringify({ hasVideo: !!v, playing, title });
        if (state !== last) { last = state; window.webkit.messageHandlers.wazu.postMessage(state); }
      };
      setInterval(() => {
        const v = video();
        if (v && v !== hooked) {
          hooked = v;
          ['play', 'pause', 'ended', 'emptied', 'loadedmetadata'].forEach(e => v.addEventListener(e, report));
        }
        report();
      }, 1000);
      window.__wazu = {
        playPause() { const v = video(); if (v) { v.paused ? v.play() : v.pause(); } },
        skip(s) { const v = video(); if (v) { v.currentTime = Math.max(0, v.currentTime + s); } },
        pictureInPicture() {
          const v = video();
          if (!v || !v.webkitSetPresentationMode) return;
          v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
        },
      };
    })();
    """

    private struct PlayerState: Decodable {
        var hasVideo: Bool
        var playing: Bool
        var title: String
    }

    fileprivate func received(_ body: Any) {
        guard let json = body as? String, let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(PlayerState.self, from: data) else { return }
        isPlaying = state.playing
        nowPlaying = state.hasVideo ? Self.showTitle(state.title) : nil
        updateNowPlayingInfo()
    }

    /// "Watch Foo Streaming Online | Hulu" → "Foo". Only the parts that are surely boilerplate.
    private static func showTitle(_ pageTitle: String) -> String? {
        var title = pageTitle
        if let bar = title.range(of: " | Hulu") { title = String(title[..<bar.lowerBound]) }
        if title.hasPrefix("Watch ") { title.removeFirst("Watch ".count) }
        if title.hasSuffix(" Streaming Online") { title.removeLast(" Streaming Online".count) }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title == "Hulu" ? nil : title
    }

    // MARK: Media keys

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.playPause(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.playPause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.playPause(); return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.skip(10); return .success }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-10); return .success }
    }

    /// The system only routes media keys to an app that is "now playing", so say so.
    private func updateNowPlayingInfo() {
        let info = MPNowPlayingInfoCenter.default()
        guard let nowPlaying else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: nowPlaying, MPMediaItemPropertyArtist: "Hulu"]
        info.playbackState = isPlaying ? .playing : .paused
    }
}

/// WKUserContentController retains its handlers; this keeps that from being a cycle.
private final class Bridge: NSObject, WKScriptMessageHandler {
    weak var controller: WebController?
    init(_ controller: WebController) { self.controller = controller }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { controller?.received(message.body) }
    }
}

extension WebController: WKNavigationDelegate, WKUIDelegate {
    /// Links that want a new window (target=_blank) open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
