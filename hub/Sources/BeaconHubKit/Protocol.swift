import Foundation

// The FROZEN hub<->device protocol (tech.md §7.1/§7.2), Swift side. Mirrors the device records.h /
// hub_proto.cpp. Status frames (hub->device) and commands (device->hub) are newline-delimited JSON,
// every frame carrying "v":1. Encoders omit nil windows; the device treats an absent/null window as
// "unavailable" (pct -1, shown as "--").

public struct UsageWindow: Codable, Equatable {
    public var pct: Int?     // 0...100, or nil => unavailable (omitted from JSON / device reads -1)
    public var reset: Int    // Unix epoch seconds; 0 = unknown
    public init(pct: Int?, reset: Int) { self.pct = pct; self.reset = reset }
}

public struct ProviderUsage: Codable, Equatable {
    public var h5: UsageWindow
    public var d7: UsageWindow
    // true => the windows carry last-known-good held through a transient failure (device dims them).
    // MUST be nil (not false) on live: synthesized Codable encodes `false` but omits nil, and §A only
    // ever carries `"stale":true`. Additive v:1 ext (issue #108), mirrors qlen/loc.
    public var stale: Bool?
    public init(h5: UsageWindow, d7: UsageWindow, stale: Bool? = nil) {
        self.h5 = h5; self.d7 = d7; self.stale = stale
    }
    public static var unavailable: ProviderUsage {
        ProviderUsage(h5: UsageWindow(pct: nil, reset: 0), d7: UsageWindow(pct: nil, reset: 0))
    }
}

// One provider's usage entry on the wire (design 2026-07-19). Replaces the old fixed claude/codex
// slots; the hub now sends 0..4 entries, one per usage-enabled provider, in hub display order.
// `stale` mirrors ProviderUsage.stale (emitted ONLY when true). `id`/`label` name the provider so the
// device renders whatever it is sent instead of hardcoding provider names.
public struct UsageEntry: Codable, Equatable {
    public var id: String       // stable lowercase ascii, <=12 chars
    public var label: String    // display string, <=10 chars, uppercase preferred
    public var h5: UsageWindow
    public var d7: UsageWindow
    public var stale: Bool?     // true => last-known-good held through a transient failure; else omitted
    public init(id: String, label: String, h5: UsageWindow, d7: UsageWindow, stale: Bool? = nil) {
        self.id = id; self.label = label; self.h5 = h5; self.d7 = d7; self.stale = stale
    }
}

public struct Usage: Codable, Equatable {
    public var providers: [UsageEntry]   // 0..4 entries, hub display order (StatusFrame.usage type name unchanged)
    public init(providers: [UsageEntry] = []) { self.providers = providers }
}

public struct BuddyPrompt: Codable, Equatable {
    public var id: String
    public var tool: String
    public var hint: String
    public var qlen: Int?   // total pending prompts incl. this front one; nil/<=1 => lone prompt (omitted)
    public var agent: String?   // owning provider id (additive, design 2026-07-19); encoded only when non-nil
    public init(id: String, tool: String, hint: String, qlen: Int? = nil, agent: String? = nil) {
        self.id = id; self.tool = tool; self.hint = hint; self.qlen = qlen; self.agent = agent
    }
}

public struct BuddyState: Codable, Equatable {
    public var running: Int
    public var waiting: Int
    public var tokens: Int
    public var contextPct: Int
    public var entries: [String]
    public var prompt: BuddyPrompt?   // nil => idle (absence of prompt, tech.md §7.1)
    public init(running: Int = 0, waiting: Int = 0, tokens: Int = 0, contextPct: Int = 0,
                entries: [String] = [], prompt: BuddyPrompt? = nil) {
        self.running = running; self.waiting = waiting; self.tokens = tokens
        self.contextPct = contextPct; self.entries = entries; self.prompt = prompt
    }
    enum CodingKeys: String, CodingKey {
        case running, waiting, tokens, entries, prompt
        case contextPct = "context_pct"
    }
}

// Device location block (issue #54). The hub sources lat/lon + place name from CoreLocation/CLGeocoder
// and tz from TimeZone.current; the device persists it (precedence hub > cached > IP). Sent ONLY in the
// (re)connect full frame and in a loc-only frame on meaningful change -- never on the 30s heartbeat.
public struct Loc: Codable, Equatable {
    public var lat: Double
    public var lon: Double
    public var tz: String
    public var name: String
    public init(lat: Double, lon: Double, tz: String, name: String) {
        self.lat = lat; self.lon = lon; self.tz = tz; self.name = name
    }
}

public enum SessionLimits { public static let maxCount = 5; public static let labelMaxChars = 28; public static let idMaxChars = 6 }

public enum SessionState: String, Codable, Equatable {
    case working, waiting, attention, idle, question
    case waitingQueued = "waiting_queued"
}

public struct Session: Codable, Equatable {
    public var id: String
    public var label: String
    public var state: SessionState
    public var ts: Int            // Unix epoch seconds of last update
    public var agent: String?     // owning provider id (additive, design 2026-07-19); encoded only when non-nil
    public init(id: String, label: String, state: SessionState, ts: Int, agent: String? = nil) {
        self.id = id; self.label = label; self.state = state; self.ts = ts; self.agent = agent
    }
}

// Standalone hub->device frame (design §4). NOT embedded in `buddy`: the combined status frame
// (usage+buddy+loc) already nears HUB_FRAME_MAX; a separate frame keeps the budget independent and
// lets old firmware ignore it (it still reads the unchanged `buddy`/`entries` frame).
public struct SessionsFrame: Codable {
    public var sessions: [Session]
    public let v: Int
    // Defensive cap/truncation at the wire boundary even though SessionRegistry is the sole producer:
    // guarantees the frame can never exceed the frozen caps regardless of caller.
    public init(_ sessions: [Session]) {
        self.sessions = sessions.prefix(SessionLimits.maxCount).map {
            Session(id: String($0.id.prefix(SessionLimits.idMaxChars)),
                    label: String($0.label.prefix(SessionLimits.labelMaxChars)),
                    state: $0.state, ts: $0.ts,
                    // agent capped at 12 chars (USAGE_ID_LEN-1); nil stays nil (omitted on the wire).
                    agent: $0.agent.map { String($0.prefix(12)) })
        }
        self.v = 1
    }
    public func encoded() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        var d = try enc.encode(self); d.append(0x0A); return d
    }
}

public enum SessionDetailLimits {
    /// Matches SESSION_ROWS in the device's session view: detail for a row that does not render would
    /// only cost frame budget.
    public static let maxCount = 4
    public static let projectMaxChars = 20
    public static let titleMaxChars = 28
    public static let msgMaxChars = 48
    /// HUB_FRAME_MAX in firmware/src/core/hub_proto.h. The device DROPS a longer frame outright, so this
    /// is a hard ceiling, not a guideline.
    public static let frameMaxBytes = 1024
}

/// Shared trim step behind every frame whose only defense against JSON-escaping/grapheme blowup is
/// encode-measure-shrink (`SessionDetailsFrame`, `SonosFrame`): a pure decision over caller-supplied
/// values grouped by priority (highest first), so both an ARRAY-OF-ROWS case (many slots at one priority
/// level -- `SessionDetailsFrame` has one `msg` slot per row) and a SINGLE-RECORD case (one slot per
/// priority level -- `SonosFrame` has exactly one `album`) are the same shape: `[[String?]]`.
///
/// Finds the longest non-empty string in the highest-priority group that still has one, and returns its
/// `(group, slot)` location plus the value with one Character dropped -- never a byte or Unicode scalar,
/// so a multi-byte or multi-scalar extended grapheme cluster (e.g. a ZWJ emoji sequence) is never split
/// into invalid UTF-8. A group with nothing left to trim is skipped in favor of the next one. `nil` means
/// every group is exhausted, which is what bounds the caller's measure-shrink `while` loop.
///
/// Deliberately returns a location rather than mutating: closures capturing an `inout` array-of-rows
/// parameter across heterogeneous call shapes fight Swift's escaping/exclusivity rules, while a pure
/// function over snapshotted values does not, and is trivially unit-testable on its own.
private enum FrameShrink {
    static func trim(priority groups: [[String?]]) -> (group: Int, slot: Int, value: String)? {
        for (g, group) in groups.enumerated() {
            var bestIdx = -1, best = 0
            for (i, v) in group.enumerated() {
                if let v, v.count > best { best = v.count; bestIdx = i }
            }
            if bestIdx >= 0 { return (g, bestIdx, String(group[bestIdx]!.dropLast())) }
        }
        return nil
    }
}

/// Per-session row content, joined to `Session` by `id`. Kept in its OWN frame rather than added to the
/// frozen `sessions` entry: those caps are declared frozen in CONTRACT.md, and title+msg would push the
/// 5-row worst case to ~987/1024 B BEFORE JSON escaping -- one quote-heavy message would silently drop
/// the whole frame.
public struct SessionDetail: Codable, Equatable {
    public var id: String
    public var project: String?
    public var title: String?
    public var msg: String?
    public init(id: String, project: String? = nil, title: String? = nil, msg: String? = nil) {
        self.id = id; self.project = project; self.title = title; self.msg = msg
    }
}

public struct SessionDetailsFrame: Codable {
    public var sdetail: [SessionDetail]
    public let v: Int

    public init(_ details: [SessionDetail]) {
        self.sdetail = details.prefix(SessionDetailLimits.maxCount).map {
            SessionDetail(id: String($0.id.prefix(SessionLimits.idMaxChars)),
                          project: $0.project.map { String($0.prefix(SessionDetailLimits.projectMaxChars)) },
                          title: $0.title.map { String($0.prefix(SessionDetailLimits.titleMaxChars)) },
                          msg: $0.msg.map { String($0.prefix(SessionDetailLimits.msgMaxChars)) })
        }
        self.v = 1
    }

    /// Character caps do NOT bound bytes: JSON escaping turns one `"` into two bytes and a `\` into two,
    /// and an emoji is 4 bytes per character. `msg` is free-form human/model prose, so the only safe
    /// guarantee is to encode, measure, and shrink until it fits under the device's ceiling.
    public func encoded() throws -> Data {
        var rows = sdetail
        var data = try Self.encode(rows)
        while data.count >= SessionDetailLimits.frameMaxBytes, Self.shrink(&rows) {
            data = try Self.encode(rows)
        }
        return data
    }

    private static func encode(_ rows: [SessionDetail]) throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        var d = try enc.encode(SessionDetailsFrame(rows))
        d.append(0x0A)
        return d
    }

    /// Drop one character from the longest text field across all rows, preferring `msg` (the least
    /// load-bearing) over `title`. Delegates to `FrameShrink.trim`, shared with `SonosFrame.shrink`.
    /// Returns false once nothing is left to trim, which bounds the loop.
    private static func shrink(_ rows: inout [SessionDetail]) -> Bool {
        guard let hit = FrameShrink.trim(priority: [rows.map { $0.msg }, rows.map { $0.title }])
        else { return false }
        if hit.group == 0 { rows[hit.slot].msg = hit.value } else { rows[hit.slot].title = hit.value }
        return true
    }
}

public enum SonosLimits {
    public static let roomMaxChars = 20
    public static let trackMaxChars = 40
    public static let artistMaxChars = 32
    public static let albumMaxChars = 32
    /// HUB_FRAME_MAX in firmware/src/core/hub_proto.h. The device DROPS a longer frame outright, so this
    /// is a hard ceiling, not a guideline (same contract as SessionDetailLimits.frameMaxBytes).
    public static let frameMaxBytes = 1024
}

/// Normalized Sonos now-playing snapshot (design `docs/specs/2026-07-26-hub-as-controller-and-sonos-design.md`
/// §3). All fields are independently optional -- absent means "not known", and the device reads an
/// absent `playing` as false; there is no separate wire state for "unknown".
public struct SonosNowPlaying: Codable, Equatable {
    public var room: String?
    public var track: String?
    public var artist: String?
    public var album: String?
    public var playing: Bool?
    public init(room: String? = nil, track: String? = nil, artist: String? = nil, album: String? = nil,
                playing: Bool? = nil) {
        self.room = room; self.track = track; self.artist = artist; self.album = album; self.playing = playing
    }
}

/// Standalone hub->device frame (CONTRACT.md "Optional `sonos` block"), NOT embedded in `StatusFrame` or
/// `PagesFrame` -- same reasoning as `sdetail`: keeps this frame's budget independent of the others and
/// lets old firmware ignore the whole thing.
///
/// `track`/`artist`/`album` are free-form text off the Sonos API, so -- exactly like `sdetail`'s
/// `msg`/`title` -- character caps do NOT bound the wire size: one `"` costs two bytes escaped, an emoji
/// four, a control character six as `\uXXXX`, and a single Swift `Character` can itself be an extended
/// grapheme cluster (e.g. a ZWJ emoji sequence) that alone runs to dozens of bytes. This reuses
/// `SessionDetailsFrame`'s encode-measure-shrink loop rather than a second implementation of it.
public struct SonosFrame: Codable {
    public var sonos: SonosNowPlaying
    public let v: Int

    public init(_ np: SonosNowPlaying) {
        self.sonos = SonosNowPlaying(
            room: np.room.map { String($0.prefix(SonosLimits.roomMaxChars)) },
            track: np.track.map { String($0.prefix(SonosLimits.trackMaxChars)) },
            artist: np.artist.map { String($0.prefix(SonosLimits.artistMaxChars)) },
            album: np.album.map { String($0.prefix(SonosLimits.albumMaxChars)) },
            playing: np.playing)
        self.v = 1
    }

    /// Encode, measure, shrink until the frame is under `HUB_FRAME_MAX` -- the only thing that actually
    /// guarantees the ceiling for arbitrary human/API text (see `shrink` for the trim order).
    public func encoded() throws -> Data {
        var np = sonos
        var data = try Self.encode(np)
        while data.count >= SonosLimits.frameMaxBytes, Self.shrink(&np) {
            data = try Self.encode(np)
        }
        return data
    }

    private static func encode(_ np: SonosNowPlaying) throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        var d = try enc.encode(SonosFrame(np))
        d.append(0x0A)
        return d
    }

    /// Drop one character from the least-identifying field first: `album`, then `artist`, then `track`,
    /// then `room` last -- room is what tells a multi-speaker household's pages apart, so it is the last
    /// thing sacrificed. Delegates to `FrameShrink.trim` (shared with `SessionDetailsFrame.shrink`) with
    /// each field as its own single-slot priority group, which reduces to "trim the first non-empty field
    /// in order" -- the same behavior as the field-by-field checks this replaced. Returns false once every
    /// field is empty, which bounds the loop.
    private static func shrink(_ np: inout SonosNowPlaying) -> Bool {
        guard let hit = FrameShrink.trim(priority: [[np.album], [np.artist], [np.track], [np.room]])
        else { return false }
        switch hit.group {
        case 0: np.album = hit.value
        case 1: np.artist = hit.value
        case 2: np.track = hit.value
        default: np.room = hit.value
        }
        return true
    }
}

// One hub->device status frame. usage/buddy/loc are independently optional (send what changed; the
// device keeps an absent block's last values). encoded() emits the §7.1 wire form with "v":1 + a \n.
public struct StatusFrame: Codable {
    public var usage: Usage?
    public var buddy: BuddyState?
    public var loc: Loc?
    public let v: Int
    public init(usage: Usage? = nil, buddy: BuddyState? = nil, loc: Loc? = nil) {
        self.usage = usage; self.buddy = buddy; self.loc = loc; self.v = 1
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]   // deterministic for tests; device is key-order-agnostic
        var data = try enc.encode(self)
        data.append(0x0A)                       // newline-delimited framing
        return data
    }
}

// device->hub commands (tech.md §7.1). Parsed from a reassembled RX line.
public enum DeviceCommand: Equatable {
    case permission(id: String, approve: Bool)
    // One ack per completed config snapshot (issue #92). Echoes the pushed `rev`; on ok carries the
    // applied ticker count, on reject the first `err` (see TickerConfig / CONTRACT.md §C for the enum).
    case configAck(rev: UInt32, ok: Bool, count: Int?, err: String?)
    // Per-chunk snapshot of its running ticker list (issue #105). Per-chunk; the caller
    // reassembles. rev is always 0 (the device does not persist the hub's rev). Used so a fresh hub
    // can adopt the list the device already holds.
    case report(what: String, rev: UInt32, part: Int, parts: Int, rows: [TickerRow])
    // Tap-to-open: device asks hub to focus the terminal/editor for session `id` (issue #110, P2-b).
    case open(id: String)
    // One ack per pushed page list. Echoes the `rev`; on ok carries the resolved page count, on reject
    // an `err` ("malformed" / "too_many_pages" / "empty"). The device restarts right after acking, so
    // the link drops immediately -- an absent ack is normal if the reset beat the flush.
    case pagesAck(rev: UInt32, ok: Bool, count: Int?, err: String?)
    // One ack per pushed complication assignment (design §6.1). Echoes the `rev`; on ok carries the
    // applied PLACEMENT count (not slot units -- 4 placements can occupy 5 when one is the clock), on
    // reject an `err` ("malformed" only -- there is deliberately no "too_many_slots", design §4.3 rule 4).
    // Unlike `pagesAck`, the device does NOT restart, so the link stays up and the ack is reliable.
    case compsAck(rev: UInt32, ok: Bool, count: Int?, err: String?)

    public static func parse(_ data: Data) -> DeviceCommand? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["v"] as? Int) == 1, let cmd = obj["cmd"] as? String else { return nil }
        switch cmd {
        case "permission":
            guard let id = obj["id"] as? String, let dec = obj["decision"] as? String else { return nil }
            return .permission(id: id, approve: dec == "approve")
        case "open":
            guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
            return .open(id: id)
        case "pages_ack":
            guard let rev = obj["rev"] as? Int, rev >= 0, let ok = obj["ok"] as? Bool else { return nil }
            return .pagesAck(rev: UInt32(rev), ok: ok, count: obj["count"] as? Int, err: obj["err"] as? String)
        case "comps_ack":
            guard let rev = obj["rev"] as? Int, rev >= 0, let ok = obj["ok"] as? Bool else { return nil }
            return .compsAck(rev: UInt32(rev), ok: ok, count: obj["count"] as? Int, err: obj["err"] as? String)
        case "config_ack":
            guard let rev = obj["rev"] as? Int, rev >= 0, let ok = obj["ok"] as? Bool else { return nil }
            return .configAck(rev: UInt32(rev), ok: ok, count: obj["count"] as? Int, err: obj["err"] as? String)
        case "report":
            guard (obj["what"] as? String) == "tickers",
                  let rev = obj["rev"] as? Int, rev >= 0,
                  let part = obj["part"] as? Int, let parts = obj["parts"] as? Int,
                  parts > 0, part >= 0, part < parts,
                  let arr = obj["tickers"] as? [[String: Any]] else { return nil }
            var rows = [TickerRow]()
            for r in arr {
                guard let id = r["id"] as? String, !id.isEmpty,
                      id.utf8.count <= TickerLimits.idMaxBytes,
                      let src = (r["src"] as? String).flatMap(TickerSource.init(rawValue:)),
                      let sym = r["sym"] as? String, sym.utf8.count <= TickerLimits.symMaxBytes,
                      let name = r["name"] as? String, name.utf8.count <= TickerLimits.nameMaxBytes,
                      let kind = (r["kind"] as? String).flatMap(TickerKind.init(rawValue:)),
                      let cadence = r["cadence"] as? Int, let stale = r["stale"] as? Int,
                      let basis = (r["basis"] as? String).flatMap(ChangeBasis.init(rawValue:))
                else { return nil }   // any malformed / over-cap row drops the whole chunk (parity with config)
                rows.append(TickerRow(id: id, src: src, sym: sym, name: name,
                                      kind: kind, cadence: cadence, stale: stale, basis: basis))
            }
            return .report(what: "tickers", rev: UInt32(rev), part: part, parts: parts, rows: rows)
        default:
            return nil
        }
    }
}

// hub -> Claude Code permission-hook HTTP response (NOT a BLE frame). PreToolUse and PermissionRequest
// require DIFFERENT decision shapes (CC v2.1.x): PreToolUse uses hookSpecificOutput.permissionDecision;
// PermissionRequest uses hookSpecificOutput.decision.behavior. Emit the one matching the originating
// event, else the device's approve/deny does not gate the tool. Beacon hooks PermissionRequest (fires
// only when permission is actually needed); PreToolUse is kept for back-compat.
public enum HookResponse {
    // `message` names the deny cause in the CC TUI (e.g. "Beacon hub is quitting"); nil falls back to
    // the generic reason. Ignored on allow (CONTRACT.md §C.3: message only on deny).
    public static func permission(event: String, allow: Bool, message: String? = nil) -> Data {
        let denyReason = message ?? "Denied on Beacon device"
        let inner: [String: Any]
        switch event {
        case "PermissionRequest":
            var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
            if !allow { decision["message"] = denyReason }   // message optional; allow needs none
            inner = ["hookEventName": "PermissionRequest", "decision": decision]
        default:   // PreToolUse (and aliases): permissionDecision allow|deny
            inner = ["hookEventName": event,
                     "permissionDecision": allow ? "allow" : "deny",
                     "permissionDecisionReason": allow ? "Approved on Beacon device" : denyReason]
        }
        let payload: [String: Any] = ["hookSpecificOutput": inner]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    // Do NOT gate -- defer to Claude Code's own interactive prompt. Used for AskUserQuestion, which is a
    // multi-option question the device can't (and shouldn't) answer; `allow` here could let an auto-accept
    // mode resolve it with no human pick, so we explicitly hand it to the Mac instead.
    public static func permissionAsk(event: String) -> Data {
        switch event {
        case "PermissionRequest":
            // PermissionRequest's decision.behavior accepts only allow/deny (no "ask", unlike PreToolUse);
            // an unsupported value fails to defer. Emit NO decision -- CC then falls through to its own
            // interactive prompt on the Mac, which is exactly the passthrough we want.
            return Data("{}".utf8)
        default:   // PreToolUse (and aliases): permissionDecision supports "ask" directly.
            let payload = ["hookSpecificOutput": ["hookEventName": event, "permissionDecision": "ask"]]
            return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        }
    }
}

// hub->device ack/err for a received command (tech.md §7.1).
public enum HubAck {
    public static func ack(id: String, ok: Bool) -> Data {
        frame(["v": 1, "ack": id, "ok": ok])
    }
    public static func err(id: String, reason: String) -> Data {
        frame(["v": 1, "err": reason, "id": id])
    }
    private static func frame(_ obj: [String: Any]) -> Data {
        var d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        d.append(0x0A)
        return d
    }
}
