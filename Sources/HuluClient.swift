//
//  HuluClient.swift
//  Wazu
//
//  Hulu's discovery, guide and FairPlay APIs, using native bearer tokens when available
//  and the browser's cookies for explicit website sign-in.
//

import Foundation
import ImageIO
import Vision
import WazKit

actor HuluClient: StreamingService {
    nonisolated var name: String { "Hulu" }

    private static let discover = "https://discover.hulu.com/content/v5"
    private static let guide = "https://guide.hulu.com/guide"
    private static let playlist = "https://play.hulu.com/v6/playlist"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    /// play.hulu.com's id for the Safari web player (the one that gets FairPlay).
    private static let deejayDeviceId = 215

    private let session: URLSession
    private var certificates = [URL: Data]()

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: config)
    }

    // MARK: Session

    nonisolated static var isSignedIn: Bool {
        HuluSession.stored() != nil || hasWebSession
    }

    nonisolated static var hasWebSession: Bool {
        HTTPCookieStorage.shared.cookies?.contains {
            $0.name == "_hulu_session" && ($0.domain == "hulu.com" || $0.domain.hasSuffix(".hulu.com"))
                && ($0.expiresDate.map { $0 > Date() } ?? true)
        } ?? false
    }

    nonisolated static func signOut() {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.hasSuffix("hulu.com") {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    // MARK: Browse

    func hub(_ id: String) async throws -> Hub {
        try await hub(url: URL(string: "\(Self.discover)/hubs/\(id)?schema=1&limit=30")!)
    }

    func hub(url: URL) async throws -> Hub {
        var hub = Hub(json: try await json("GET", url))
        // Hub links (Leagues & Events) come without artwork; the hub they open has a tile.
        let links = Set(hub.collections.flatMap(\.items).filter { $0.kind == "hub_link" && $0.artwork == nil }.compactMap(\.browse))
        guard !links.isEmpty else { return hub }
        var tiles = [URL: URL]()
        await withTaskGroup(of: (URL, URL?).self) { group in
            for link in links { group.addTask { (link, await self.tile(of: link)) } }
            for await (link, tile) in group { tiles[link] = tile }
        }
        for c in hub.collections.indices {
            for i in hub.collections[c].items.indices where hub.collections[c].items[i].artwork == nil {
                hub.collections[c].items[i].artwork = hub.collections[c].items[i].browse.flatMap { tiles[$0] }
            }
        }
        return hub
    }

    private func tile(of hub: URL) async -> URL? {
        try? Hub(json: await json("GET", hub)).artwork
    }

    /// A collection page (a season, or the `next` of a collection).
    func collection(url: URL) async throws -> Collection? {
        Collection(json: try await json("GET", url))
    }

    func search(_ query: String) async throws -> [Item] {
        var c = URLComponents(string: "https://discover.hulu.com/content/v4/search/entity")!
        c.queryItems = [.init(name: "language", value: "en"), .init(name: "schema", value: "1"),
                        .init(name: "search_query", value: query), .init(name: "limit", value: "40")]
        let result = try await json("GET", c.url!)
        let groups = result["groups"] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["results"] as? [[String: Any]] ?? []).compactMap(Item.init(json:)) }
    }

    // MARK: Live

    /// Every live channel in the guide, with what is on right now.
    func channels() async throws -> [Channel] {
        let views = try await json("GET", URL(string: "\(Self.guide)/views")!)
        let all = (views["views"] as? [[String: Any]] ?? []).first { $0["id"] as? String == "hulu:guide:all-channels" }
        var channels = ((all?["details"] as? [String: Any])?["channels"] as? [[String: Any]] ?? []).compactMap { c -> Channel? in
            guard let id = c["id"] as? String else { return nil }
            return Channel(id: id, name: c["name"] as? String ?? c["callSign"] as? String ?? "",
                           logo: (c["logoUrl"] as? String).flatMap(URL.init(string:)), program: nil)
        }
        guard !channels.isEmpty else { return [] }
        let listing = try await json("POST", URL(string: "\(Self.guide)/listing")!, body: ["channels": channels.map(\.id)])
        let now = Date()
        let formatter = ISO8601DateFormatter()
        for entry in listing["channels"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String, let index = channels.firstIndex(where: { $0.id == id }) else { continue }
            let programs = (entry["programs"] as? [[String: Any]] ?? []).compactMap { p -> Program? in
                guard let eab = p["eab"] as? String, let headline = p["headline"] as? String,
                      let start = (p["airingStart"] as? String).flatMap(formatter.date(from:)),
                      let end = (p["airingEnd"] as? String).flatMap(formatter.date(from:)) else { return nil }
                return Program(eab: eab, headline: headline, start: start, end: end)
            }
            channels[index].program = programs.first { $0.start <= now && now < $0.end } ?? programs.first
        }
        return channels
    }

    // MARK: Playback

    /// The episode that follows the one with this EAB in its series: the next one in the season, or the next
    /// season's first after a season's last. Nil when none is left. The up-next list starts with the episode
    /// itself; what follows it is the next episode when it is of the same series, and a suggestion from
    /// another series otherwise (after a series' last episode, and after a movie).
    func nextEpisode(after eab: String) async throws -> Item? {
        var c = URLComponents(string: "\(Self.discover)/browse/upnext")!
        c.queryItems = [.init(name: "current_eab", value: eab), .init(name: "schema", value: "1"), .init(name: "language", value: "en")]
        let items = try await json("GET", c.url!)["items"] as? [[String: Any]] ?? []
        guard items.count > 1, let series = items[0]["series_id"] as? String, items[1]["series_id"] as? String == series,
              let next = Item(json: items[1]), next.eab != nil else { return nil }
        return next
    }

    /// `resume`: seconds into the episode or movie to carry on from (nil: where Hulu has it).
    /// `credits`: seconds into the stream at which the end credits start, when Hulu says.
    func playback(eab: String, channelId: String?, resume: Double?) async throws -> (playback: Playback, credits: Double?, breaks: Breaks) {
        let guid = HuluSession.stored()?.serial
            ?? HTTPCookieStorage.shared.cookies?.first { $0.name == "guid" && $0.domain.hasSuffix("hulu.com") }?.value
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var body: [String: Any] = [
            "device_identifier": guid, "guid": guid, "deejay_device_id": Self.deejayDeviceId, "version": 1,
            "all_cdn": true, "region": "US", "language": "en", "unencrypted": true, "network_mode": "wifi",
            "is_html5_player": true, "content_eab_id": eab, "play_intent": channelId == nil ? "RESUME" : "LIVE",
            "playback": [
                "version": 2,
                "video": ["codecs": ["values": [["type": "H264", "width": 1920, "height": 1080, "framerate": 60, "level": "4.2", "profile": "HIGH"]], "selection_mode": "ONE"]],
                "audio": ["codecs": ["values": [["type": "EC3"], ["type": "AAC"]], "selection_mode": "ONE"]],
                "drm": ["values": [["type": "FAIRPLAY"]], "selection_mode": "ONE"],
                "manifest": ["type": "HLS", "https": true, "multiple_cdns": false, "patch_updates": true, "hulu_types": true,
                             "live_dai": false, "multiple_periods": true, "xlink": false, "secondary_audio": true,
                             "unified_asset_signaling": true],
                "segments": ["values": [["type": "FMP4", "encryption": ["mode": "CBCS", "type": "CENC"], "muxed": false, "https": true],
                                        ["type": "MPEGTS", "encryption": ["mode": "CBCS", "type": "SAMPLE_AES"], "muxed": true, "https": true]],
                             "selection_mode": "ONE"],
            ],
        ]
        if let channelId { body["channel_id"] = channelId }
        let result = try await json("POST", URL(string: Self.playlist)!, body: body)
        guard let stream = (result["stream_url"] as? String).flatMap(URL.init(string:)),
              let license = (result["fp_server"] as? String).flatMap(URL.init(string:)),
              let cert = (result["fp_cert"] as? String).flatMap(URL.init(string:)) else {
            throw HuluError.badResponse(result["message"] as? String ?? "playlist")
        }
        let position = result["initial_position"] as? Double ?? 0
        let breaks = Breaks(breaks: (result["breaks"] as? [[String: Any]] ?? []).compactMap {
            guard let position = $0["pos"] as? Double, let duration = $0["duration"] as? Double else { return nil }
            return (position / 1000, duration / 1000)
        })
        let metadata = result["video_metadata"] as? [String: Any]
        let frameRate = metadata?["frame_rate"] as? Double ?? 24
        /// Seconds into the stream of one of Hulu's timecodes ("00:21:32;17": hours, minutes, seconds, frames).
        func time(_ code: Any?) -> Double? {
            let parts = (code as? String ?? "").split(whereSeparator: { ":;".contains($0) }).compactMap { Double($0) }
            guard parts.count == 4 else { return nil }
            return breaks.streamTime(parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / frameRate)
        }
        // A recap ("Previously on…") and the opening credits are each marked with a start and an end.
        let markers = (metadata?["markers"] as? [[String: Any]] ?? []).compactMap { marker -> Skip? in
            let titles = ["Recap": "Skip Recap", "Opening Credit": "Skip Intro"]
            guard let title = titles[marker["type"] as? String ?? ""],
                  let start = time(marker["start"]), let end = time(marker["end"]), end > start else { return nil }
            return Skip(title: title, start: start, end: end)
        }
        let isLive = result["asset_playback_type"] as? String == "LIVE"
        let findSkips: (@Sendable () async -> [Skip])? = isLive ? nil : (result["thumbnail_endpoint"] as? String).flatMap(URL.init(string:)).map { thumbnails in
            { [self] in await self.marvelIntro(eab: eab, thumbnails: thumbnails, breaks: breaks, after: markers.map(\.end)) }
        }
        return (Playback(streamURL: stream, licenseURL: license, certificateURL: cert,
                         resume: resume.map { isLive ? 0 : breaks.streamTime($0) } ?? (position > 0 ? position / 1000 : 0),
                         isLive: isLive, skips: markers, findSkips: findSkips),
                time(metadata?["end_credits_time"]), breaks)
    }

    /// The times (seconds into the episode or movie) at which "MARVEL STUDIOS" was read in the thumbnails of
    /// those already looked at, by EAB (empty: looked, not there).
    private var marvelLogos: [String: [Double]] = [:]

    /// The Marvel Studios logo near the front of a Marvel title ("Skip Marvel Intro"). The playlist answer marks
    /// at most the first part of it (WandaVision's "Opening Credit" ends 6 to 15 seconds before the logo's words
    /// are read), so it is found by reading: the thumbnails of the first five minutes, ten seconds apart, go
    /// through text recognition, and the logo is where "MARVEL STUDIOS" is read, which is near its end. The
    /// button shows from the end of a marked part that ended up to 45 seconds before the words (`after`: those
    /// ends, in the player's seconds), else from 30 seconds before them. It jumps to the last thumbnail that
    /// shows the words: how long after that thumbnail the logo ends cannot be told, and this way it never lands
    /// inside the show.
    private func marvelIntro(eab: String, thumbnails: URL, breaks: Breaks, after ends: [Double]) async -> [Skip] {
        if marvelLogos[eab] == nil { marvelLogos[eab] = await marvelStudios(inThumbnails: thumbnails) }
        guard let shown = marvelLogos[eab]?.first else { return [] }
        // The words stay up for a thumbnail or two.
        let first = breaks.streamTime(shown), end = breaks.streamTime(marvelLogos[eab]?.last { $0 <= shown + 20 } ?? shown)
        let start = ends.filter { $0 <= first && first - $0 <= 45 }.max() ?? max(0, first - 30)
        return end > start ? [Skip(title: "Skip Marvel Intro", start: start, end: end)] : []
    }

    /// The times of the thumbnails in which "MARVEL STUDIOS" is read, among the first five minutes (nil: the
    /// thumbnails could not be fetched). Hulu's thumbnails are one file, "thumbs" under the playlist answer's
    /// thumbnail link: the number of pictures in 8 bytes, that many 8-byte offsets (big-endian), then the
    /// pictures (JPEGs, each up to the next offset). There is a picture for every second of the episode, but
    /// the picture only changes every ten, so every tenth is fetched (a range request each, 10 to 20 KB).
    private func marvelStudios(inThumbnails thumbnails: URL) async -> [Double]? {
        let file = thumbnails.appendingPathComponent("thumbs")
        func bytes(_ range: Range<Int>) async -> Data? {
            var request = URLRequest(url: file)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 206 else { return nil }
            return data
        }
        // The count, and the offsets of the first five minutes' pictures.
        guard let table = await bytes(0..<8 * 303) else { return nil }
        func number(_ at: Int) -> Int { at + 8 <= table.count ? table[at..<at + 8].reduce(0) { $0 << 8 | Int($1) } : 0 }
        var pictures: [(time: Double, jpeg: Data)] = []
        for second in stride(from: 0, through: 300, by: 10) where second + 1 < number(0) {
            let from = number(8 + 8 * second), to = number(16 + 8 * second)
            guard from < to, to - from < 1_000_000, let jpeg = await bytes(from..<to) else { return nil }
            pictures.append((Double(second), jpeg))
        }
        return await Task.detached(priority: .utility) { [pictures] in
            pictures.filter { Self.showsMarvelStudios($0.jpeg) }.map(\.time)
        }.value
    }

    /// Is "MARVEL STUDIOS" all a picture shows? The logo is also read while it is still forming ("PARVEL STUDIO",
    /// "MARVEL STUD"), so this much of it in any of the reader's guesses counts. A title card that has the words
    /// among others ("MARVEL STUDIOS' WandaVision" in a recap) is not the logo.
    nonisolated static func showsMarvelStudios(_ jpeg: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let request = VNRecognizeTextRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = request.results ?? []
        return lines.count == 1 && lines[0].topCandidates(10).contains { $0.string.uppercased().contains("ARVEL STUD") }
    }

    /// The FairPlay application certificate (DER), cached.
    func certificate(_ url: URL) async throws -> Data {
        if let data = certificates[url] { return data }
        let (data, _) = try await session.data(from: url)
        certificates[url] = data
        return data
    }

    /// SPC in, CKC out: the server takes and returns base64 text.
    func license(_ url: URL, spc: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = spc.base64EncodedData()
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let ckc = Data(base64Encoded: data) else {
            throw HuluError.http(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return ckc
    }

    /// The license server wants the whole "skd://hulu/<kid>" URI as the content identifier.
    nonisolated func contentIdentifier(forKeyURI uri: String) -> Data {
        Data(uri.utf8)
    }

    // MARK: HTTP

    private func json(_ method: String, _ url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard url.scheme == "https", let host = url.host,
              ["discover.hulu.com", "guide.hulu.com", "play.hulu.com"].contains(host) else {
            throw HuluError.badResponse("untrusted API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let token = try await HuluSession.shared.token()
        if let token {
            request.httpShouldHandleCookies = false
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        var (data, response) = try await session.data(for: request)
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let token, status == 401 {
            var refreshed = try? await HuluSession.shared.token(rejected: token)
            if refreshed == nil, await HuluAuth.recover() {
                refreshed = try? await HuluSession.shared.token()
            }
            guard let refreshed else {
                await HuluAuth.requireSignIn()
                throw HuluError.signIn("Your Hulu session ended. Please sign in again.")
            }
            request.setValue("Bearer \(refreshed)", forHTTPHeaderField: "Authorization")
            (data, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { await HuluAuth.requireSignIn() }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HuluError.http(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard (200..<300).contains(status) else {
            throw HuluError.http(status, object["message"] as? String ?? object["code"] as? String ?? "")
        }
        return object
    }
}

enum HuluError: LocalizedError {
    case http(Int, String)
    case badResponse(String)
    /// The sign-in API's own message ("We couldn't log you in. Please check your email and password…").
    case signIn(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): status == 401 || status == 403 ? "Not signed in to Hulu." : "Hulu answered \(status): \(message)"
        case .badResponse(let what): "Unexpected answer from Hulu (\(what))."
        case .signIn(let message): message
        }
    }
}

/// What a stream carries besides the episode or movie itself: where in it each break starts and how long the
/// break is, in seconds. Hulu's own times (the markers, the end credits) count the episode alone; the player's
/// times count the breaks too. Seen so far: a 5-second network bumper at the very start, on a plan without ads.
struct Breaks: Sendable {
    var breaks: [(position: Double, duration: Double)] = []

    /// The player's time for a time in the episode.
    func streamTime(_ content: Double) -> Double {
        content + breaks.filter { $0.position <= content }.reduce(0) { $0 + $1.duration }
    }

    /// The time in the episode for one of the player's times (a time inside a break is where the break starts).
    func contentTime(_ stream: Double) -> Double {
        var content = stream
        for part in breaks.sorted(by: { $0.position < $1.position }) where content >= part.position {
            content = max(part.position, content - part.duration)
        }
        return content
    }
}
