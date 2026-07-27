import Foundation

// Pure, host-testable depth for the Sonos room picker (design 2026-07-27-hub-visual-system, WS-0b: "the
// Sonos room seam"). The picker used to carry `SonosRoomListResult.rooms([String])` -- names only -- so
// no amount of restyling could give a row anything true to say. This widens the seam: a room's summary
// carries whatever `SonosAPI.parseGroups` already decodes for free (player count, member names) plus
// playback state IF the fan-out in `SonosProvider.fetchAvailableRooms` learned it within its deadline.
//
// Built from primitives, never `SonosAPI` types -- `SonosAPI.swift`'s file header states that raw Sonos
// response shapes stop at `SonosProvider`; that rule would break the moment this took a `SonosAPI.Group`.
// The precedent is `ChartInstrument.swift`: the rules live in the kit, the view (or, here, the not-yet-
// -built WS-2 menu row) renders what they decide.
public struct SonosRoomSummary: Equatable {
    public let name: String
    public let playerCount: Int
    public let memberNames: [String]
    /// nil == NOT KNOWN. A row that never learned the playback state (the fan-out's HTTP call did not
    /// land within the 1.5s deadline, the household has too many groups to enrich, or the request itself
    /// failed) must say nothing about playback rather than claim "paused" -- that would be a
    /// truer-LOOKING lie than silence. See `SonosRoomListTests.testPlayingNilAppendsNothing`.
    public let playing: Bool?

    public init(name: String, playerCount: Int, memberNames: [String], playing: Bool?) {
        self.name = name
        self.playerCount = playerCount
        self.memberNames = memberNames
        self.playing = playing
    }
}

public enum SonosRoomList {
    /// One summary per group. `players` resolves `playerIds` to display names, in the API's own order --
    /// a `playerIds` entry with no matching `players` row (a topology race between the two calls that
    /// produced them) is simply skipped rather than forcing a crash or dropping the room; `playerCount`
    /// still reflects the true id count regardless of how many of those ids resolved to a name.
    ///
    /// `playing` is keyed by GROUP NAME, not group id: the `groups` tuple below deliberately carries no id
    /// (id is an HTTP-fetch concern that stops at `SonosProvider`, same reasoning as "no `SonosAPI`
    /// types"), so name is the only correlator available here. A caller that never fetched a group's
    /// playback state (or never got an answer back inside the deadline) simply omits that name from the
    /// dictionary, which reads back below as `nil` -- never `false`.
    public static func summarize(groups: [(name: String, playerIds: [String])],
                                  players: [(id: String, name: String)],
                                  playing: [String: Bool]) -> [SonosRoomSummary] {
        guard !groups.isEmpty else { return [] }
        // `uniquingKeysWith:` (rather than `uniqueKeysWithValues:`) so a malformed/duplicate player id in
        // the response degrades to "first one wins" instead of a fatalError -- this is best-effort UI
        // data, not a contract SonosAPI's parser already enforces.
        let namesByID = Dictionary(players.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return groups.map { group in
            let memberNames = group.playerIds.compactMap { namesByID[$0] }
            return SonosRoomSummary(name: group.name, playerCount: group.playerIds.count,
                                     memberNames: memberNames, playing: playing[group.name])
        }
    }

    /// "2 players" + "Kitchen, Dining" + "playing", joined with U+00B7, or nil when there is nothing true
    /// to add beyond the name
    /// (a lone speaker whose playback state was never learned). Player count and member names are
    /// suppressed together for a single-player room -- with one member, a name/count phrase only repeats
    /// what the room's own name already says. Playback state (`playing`/`paused`) is independent of
    /// player count: it renders whenever known, on a room of any size.
    public static func secondary(_ room: SonosRoomSummary) -> String? {
        var parts: [String] = []
        if room.playerCount > 1 {
            parts.append("\(room.playerCount) players")
            if !room.memberNames.isEmpty { parts.append(room.memberNames.joined(separator: ", ")) }
        }
        if let playing = room.playing { parts.append(playing ? "playing" : "paused") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// One line, because a macOS `Menu` item renders one label (AppKit flattens a `VStack` label to its
    /// first `Text`) -- so depth rides in a single `\u{2014}`-joined line rather than the two-line row the
    /// design first assumed. Exists so WS-2 composes nothing itself; the string is unit-tested here
    /// instead of eyeballed there.
    public static func menuTitle(_ room: SonosRoomSummary) -> String {
        guard let secondary = secondary(room) else { return room.name }
        return "\(room.name) \u{2014} \(secondary)"
    }
}
