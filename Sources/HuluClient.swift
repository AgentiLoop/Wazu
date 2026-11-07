//
//  HuluClient.swift
//  Wazu
//
//  Hulu's web API — the same calls hulu.com's own player makes: discover.hulu.com for browsing,
//  guide.hulu.com for live TV, play.hulu.com for the stream, and bamgrid.com for FairPlay keys.
//  Auth is the browser session: the cookies the sign-in API answers with (SignIn.swift), which
//  live in HTTPCookieStorage.shared.
//

import Foundation
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
        HTTPCookieStorage.shared.cookies?.contains { $0.name == "_hulu_session" && $0.domain.hasSuffix("hulu.com") } ?? false
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
        Hub(json: try await json("GET", url))
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

    func playback(eab: String, channelId: String?) async throws -> Playback {
        let guid = HTTPCookieStorage.shared.cookies?.first { $0.name == "guid" && $0.domain.hasSuffix("hulu.com") }?.value
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
        return Playback(streamURL: stream, licenseURL: license, certificateURL: cert,
                        resume: position > 0 ? position / 1000 : 0,
                        isLive: result["asset_playback_type"] as? String == "LIVE")
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
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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
