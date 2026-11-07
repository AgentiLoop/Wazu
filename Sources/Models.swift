//
//  Models.swift
//  Wazu
//
//  What the discover API hands back, reduced to what the UI shows: hubs of collections of items.
//  Hub "home" and search return "view" items (visuals.headline…); the other hubs return entities
//  (name, description, artwork…). Both end up as the same Item.
//

import Foundation
import WazKit

struct Hub {
    let id: String
    let name: String
    /// The series' description etc. when this is an entity-detail hub.
    let description: String?
    /// The episode to play from the Play button on a series/movie page (details.vod_items.focus).
    let focus: Item?
    var collections: [Collection]

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        name = json["name"] as? String ?? ""
        let details = json["details"] as? [String: Any]
        description = ((details?["entity"] as? [String: Any])?["description"] as? String)
        let focusEntity = ((details?["vod_items"] as? [String: Any])?["focus"] as? [String: Any])?["entity"] as? [String: Any]
        focus = focusEntity.flatMap(Item.init(json:))
        var collections = [Collection]()
        for component in json["components"] as? [[String: Any]] ?? [] {
            // Seasons: the "Episodes" component holds one collection per season.
            if component["theme"] as? String == "collection_theme_groupings" {
                for season in component["items"] as? [[String: Any]] ?? [] where season["_type"] as? String == "collection" {
                    if let c = Collection(json: season) { collections.append(c) }
                }
            } else if let c = Collection(json: component), !c.items.isEmpty {
                collections.append(c)
            }
        }
        self.collections = collections
    }
}

struct Collection: Identifiable {
    let id: String
    let name: String
    let theme: String
    var items: [Item]
    /// The next page, when the API says there is more.
    var next: URL?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String ?? (json["id"] as? Int).map(String.init) else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        theme = json["theme"] as? String ?? ""
        items = (json["items"] as? [[String: Any]] ?? []).compactMap(Item.init(json:))
        let pagination = json["pagination"] as? [String: Any]
        if let total = pagination?["total_count"] as? Int, total > items.count,
           let nextString = pagination?["next"] as? String {
            next = URL(string: nextString)
        }
    }
}

struct Item: Identifiable, Hashable, Tile {
    let id: String
    /// series, movie, episode, sports_episode, hub_link, network, sports_team…
    let kind: String
    let title: String
    let subtitle: String?
    let description: String?
    /// img.hulu.com artwork; `size=WxH&format=jpeg` must be appended to get an image.
    let artwork: URL?
    /// Poster-shaped artwork for vertical rows, when Hulu has one.
    let verticalArtwork: URL?
    /// Playable when present: "EAB::<id>::<asset>::<bundle>" (never the "::NULL::NULL" placeholder).
    let eab: String?
    /// For live airings, the channel the playlist call needs.
    let channelId: String?
    let isLive: Bool
    /// The hub to open for this item (series page, genre hub…).
    let browse: URL?

    init?(json: [String: Any]) {
        let type = json["_type"] as? String ?? ""
        guard type != "collection" else { return nil }
        let visuals = json["visuals"] as? [String: Any]
        let actions = json["actions"] as? [String: Any]
        let playback = actions?["playback"] as? [String: Any]
        let bundle = playback?["bundle"] as? [String: Any] ?? json["bundle"] as? [String: Any]
        // A "view" says what it stands for in its metadata (episode, series, movie, sports_episode…).
        kind = type == "view"
            ? (json["entity_metadata"] as? [String: Any])?["entity_type"] as? String
                ?? (json["metrics_info"] as? [String: Any])?["target_type"] as? String ?? type
            : type

        id = json["id"] as? String ?? UUID().uuidString
        title = Self.text(visuals?["headline"]) ?? json["name"] as? String ?? ""
        description = Self.text(visuals?["body"]) ?? json["description"] as? String
        if let s = Self.text(visuals?["subtitle"]) ?? Self.text(visuals?["short_subtitle"]) {
            subtitle = s
        } else if let season = json["season_short_display_name"] as? String, let number = json["number"] as? String {
            subtitle = "\(season) E\(number)"
        } else if let series = json["series_name"] as? String {
            subtitle = series
        } else {
            subtitle = Self.text(visuals?["short_descriptor"])
        }

        // Artwork: a view has visuals.artwork.<orientation>.image.path (search: .path); an entity has artwork.<type>.path.
        // Genre links ("standard_text" rows) come with no artwork at all.
        var art: String?
        var tall: String?
        if let orientations = visuals?["artwork"] as? [String: Any] {
            for key in ["horizontal_tile", "horizontal", "horizontal_video"] {
                if let o = orientations[key] as? [String: Any] {
                    art = (o["image"] as? [String: Any])?["path"] as? String ?? o["path"] as? String
                    if art != nil { break }
                }
            }
            for key in ["vertical_tile", "vertical"] where tall == nil {
                if let o = orientations[key] as? [String: Any] {
                    tall = (o["image"] as? [String: Any])?["path"] as? String ?? o["path"] as? String
                }
            }
        }
        if let artworks = json["artwork"] as? [String: Any] {
            if art == nil {
                for key in ["program.tile", "video.horizontal.hero", "detail.horizontal.hero", "network.tile", "brand.logo"] {
                    if let path = (artworks[key] as? [String: Any])?["path"] as? String { art = path; break }
                }
                if art == nil, let first = artworks.values.first as? [String: Any] { art = first["path"] as? String }
            }
            if tall == nil { tall = (artworks["detail.vertical.hero"] as? [String: Any])?["path"] as? String }
        }
        artwork = art.flatMap(URL.init(string:))
        verticalArtwork = tall.flatMap(URL.init(string:))

        let eab = playback?["eab"] as? String ?? bundle?["eab_id"] as? String
            ?? (json["personalization"] as? [String: Any])?["eab"] as? String
        self.eab = eab.flatMap { $0.contains("::NULL") ? nil : $0 }
        channelId = bundle?["channel_id"] as? String
        isLive = bundle?["bundle_type"] as? String == "LIVE"

        let browseAction = actions?["browse"] as? [String: Any] ?? actions?["browse.0"] as? [String: Any]
            ?? json["browse"] as? [String: Any]
        browse = (browseAction?["href"] as? String)
            .map { $0.replacingOccurrences(of: "/content/v4/hubs/", with: "/content/v5/hubs/") }
            .flatMap(URL.init(string:))
    }

    init(id: String, kind: String, title: String, subtitle: String?, artwork: URL?, eab: String?, channelId: String?) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.description = nil
        self.artwork = artwork; self.verticalArtwork = nil
        self.eab = eab; self.channelId = channelId; self.isLive = channelId != nil; self.browse = nil
    }

    /// Search results wrap strings as {"text": …}.
    private static func text(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let d = value as? [String: Any], let s = d["text"] as? String { return s.isEmpty ? nil : s }
        return nil
    }

    /// Sized artwork; a portrait size picks the poster when there is one.
    func artwork(width: Int, height: Int) -> URL? {
        guard let art = height > width ? verticalArtwork ?? artwork : artwork else { return nil }
        return URL(string: art.absoluteString + "&size=\(width)x\(height)&format=jpeg")
    }
}

/// A live channel from the guide, with what is on now.
struct Channel: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: URL?
    var program: Program?
}

struct Program: Hashable {
    let eab: String
    let headline: String
    let start: Date
    let end: Date
}
