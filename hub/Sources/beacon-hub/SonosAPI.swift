import Foundation

// Pure parsers for the Sonos Control API response shapes (design 2026-07-26-sonos-now-playing-plan).
// Isolated the same way UsageNormalizer/ProviderCredentials isolate their providers' JSON: what breaks
// when Sonos changes a field is the shape, so keep it here, fixture-tested, and NEVER let the raw JSON
// leak past SonosProvider -- only the small normalized SonosNowPlaying struct crosses that boundary
// (AGENTS.md: credentials never reach the device, and neither does anything else provider-shaped).
enum SonosAPI {
    static let base = "https://api.ws.sonos.com/control/api/v1"

    struct Household: Equatable { let id: String }

    // GET /households -> { "households": [ { "id": "Sonos_xxx" } ] }. Only the first household is used
    // (phase 1 targets a single-household account, the common case); a multi-household account would need
    // its own picker, out of scope here same as the room picker.
    static func parseHouseholds(_ data: Data) -> [Household]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["households"] as? [[String: Any]]
        else { return nil }
        return list.compactMap { d in
            guard let id = d["id"] as? String, !id.isEmpty else { return nil }
            return Household(id: id)
        }
    }

    struct Group: Equatable { let id: String; let name: String; let playerIds: [String] }
    struct Player: Equatable { let id: String; let name: String }
    struct GroupsResponse: Equatable { let groups: [Group]; let players: [Player] }

    // GET /households/{id}/groups -> { "groups": [ { id, name, playerIds, ... } ], "players": [ { id, name, ... } ] }.
    static func parseGroups(_ data: Data) -> GroupsResponse? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let groupsRaw = obj["groups"] as? [[String: Any]] ?? []
        let playersRaw = obj["players"] as? [[String: Any]] ?? []
        // Both arrays absent/empty => the body did not have the shape we expect (vs. a household that
        // genuinely has zero groups, which the Sonos API does not produce -- every household has at
        // least one player/group once set up).
        guard obj["groups"] != nil || obj["players"] != nil else { return nil }
        let groups = groupsRaw.compactMap { d -> Group? in
            guard let id = d["id"] as? String, !id.isEmpty, let name = d["name"] as? String else { return nil }
            return Group(id: id, name: name, playerIds: (d["playerIds"] as? [String]) ?? [])
        }
        let players = playersRaw.compactMap { d -> Player? in
            guard let id = d["id"] as? String, !id.isEmpty, let name = d["name"] as? String else { return nil }
            return Player(id: id, name: name)
        }
        return GroupsResponse(groups: groups, players: players)
    }

    // Finds the group that best matches a user-selected room name: an exact (case-insensitive) group-name
    // match first (covers a standalone room, and Sonos's own "Room A + Room B" join naming when the whole
    // join was selected), else a group that CONTAINS a player with that name (covers a room the user
    // picked while it happened to be grouped under a different group name).
    static func findGroup(room: String, in response: GroupsResponse) -> Group? {
        let target = room.lowercased()
        if let exact = response.groups.first(where: { $0.name.lowercased() == target }) { return exact }
        guard let player = response.players.first(where: { $0.name.lowercased() == target }) else { return nil }
        return response.groups.first { $0.playerIds.contains(player.id) }
    }

    struct TrackMetadata: Equatable { let track: String?; let artist: String?; let album: String?; let imageUrl: String? }

    // GET /groups/{id}/playbackMetadata -> { "container": {...}, "currentItem": { "track": { "name",
    // "artist": {"name"}, "album": {"name"}, "imageUrl" } } }. A stream with nothing loaded still returns
    // a parseable body (container present, currentItem absent) -- that is "nothing playing", not shape
    // drift, so it falls back to the container's name rather than failing to parse.
    //
    // imageUrl (design 2026-07-27-sonos-album-art §6.1): both `track` and `container` carry their own
    // direct `imageUrl` string field per the Sonos Control API's playback-objects schema
    // (developer.sonos.com/reference/types/playback-objects -- confirmed 2026-07-27, not assumed) --
    // neither is nested under anything else. Same currentItem-then-container precedence
    // parsePlaybackMetadata already uses for the *name*: a specific track's art wins when present, and a
    // station/playlist container's art (its logo) is the fallback for a stream with no per-track art of
    // its own -- exactly the radio/podcast case the design's risk 1 calls out. Public Sonos-developer
    // reports (community thread "Cloud Control API: Missing imageUrl in metadataStatus when playing a
    // radio station") corroborate that risk: imageUrl is reported to come back empty, or as a
    // LAN-only `http://<player-ip>:1400/getaa?...` URL, for some services through this endpoint -- which
    // is exactly why SonosArtRenderer must not assume a fetch will succeed.
    static func parsePlaybackMetadata(_ data: Data) -> TrackMetadata? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let container = obj["container"] as? [String: Any]
        guard obj["currentItem"] != nil || container != nil else { return nil }
        let track = (obj["currentItem"] as? [String: Any])?["track"] as? [String: Any]
        let name = (track?["name"] as? String) ?? (container?["name"] as? String)
        let artist = (track?["artist"] as? [String: Any])?["name"] as? String
        let album = (track?["album"] as? [String: Any])?["name"] as? String
        let imageUrl = (track?["imageUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (container?["imageUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TrackMetadata(track: name, artist: artist, album: album, imageUrl: imageUrl)
    }

    // GET /groups/{id}/playback -> { "playbackState": "PLAYBACK_STATE_PLAYING" | "_PAUSED" | "_IDLE" |
    // "_BUFFERING" }. BUFFERING counts as playing (about to resume, and flapping playing/not-playing
    // during a brief rebuffer would be a worse device-side experience than a one-beat-early "playing").
    static func parsePlaybackState(_ data: Data) -> Bool? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = obj["playbackState"] as? String
        else { return nil }
        return state == "PLAYBACK_STATE_PLAYING" || state == "PLAYBACK_STATE_BUFFERING"
    }
}
