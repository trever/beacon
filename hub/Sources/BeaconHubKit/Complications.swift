import Foundation

// The Home-screen "complication" assignment: which small renderers occupy the six-slot grid, and in
// what order (design docs/specs/2026-07-27-hub-app-and-home-complications-design.md §4, §6). Mirrors
// firmware/src/core/complications.h + core/comp_state.h. `size`/`takesArg` live ONLY in
// ComplicationCatalog here (plan §13 item 1, settled) -- never duplicated onto any per-instance type.

public enum CompLimits {
    /// COMP_SLOTS_MAX in complications.h -- the geometry cap derived in design §5.3.
    public static let slotsPerFace = 6
    /// COMP_FACES_MAX -- a wire cap; only "home" exists today.
    public static let maxFaces = 2
    /// COMP_ID_LEN - 1.
    public static let idMax = 11
    /// COMP_ARG_LEN - 1.
    public static let argMax = 15
    /// HUB_FRAME_MAX. The device drops a longer frame outright.
    public static let frameMaxBytes = 1024
    public static let homeFace = "home"
    /// [a-z0-9_-]. Neither id nor arg may contain a character outside this set -- both ends validate
    /// the same alphabet (device: comp_entry_valid). No character in it is JSON-escapable, which is why
    /// character caps bound the wire frame's bytes exactly (design §6.2).
    public static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
}

/// One row of the catalog the hub renders as choices in the slot editor. Mirrors `comp_def_t` +
/// `complication_t`'s `owner`/`label` (the device splits these across two files -- COMP_CATALOG for
/// size/takesArg, ui/comps/comp_registry.h for owner/label/renderer -- but the hub has no LVGL-coupled
/// half to keep separate, so one Swift type carries all of it).
public struct ComplicationCatalogEntry: Equatable, Sendable {
    public let id: String
    /// Page id that provides it; "" for core (clock/weather). HUB METADATA -- the device never
    /// consults this, and neither does anything in this file; it exists purely so the hub UI can group
    /// complications by the page that owns them.
    public let owner: String
    public let label: String
    /// Slot units: 1 or 2. THE single source of truth on the hub side -- never re-derive or duplicate
    /// this elsewhere (plan §13 item 1).
    public let size: Int
    public let takesArg: Bool
    public let detail: String

    public init(id: String, owner: String, label: String, size: Int, takesArg: Bool, detail: String) {
        self.id = id; self.owner = owner; self.label = label
        self.size = size; self.takesArg = takesArg; self.detail = detail
    }
}

public enum ComplicationCatalog {
    /// Must stay in sync with COMP_CATALOG in firmware/src/core/complications.cpp (design §4.2, verbatim
    /// -- do not re-derive it). `chart`'s renderer is Phase 2: it is still catalogued so the hub can
    /// offer it in the editor, but no Phase 1 firmware's `comp_find` answers a renderer for it -- an
    /// older firmware degrades quietly (the id is simply dropped, same as any other unknown id).
    public static let all: [ComplicationCatalogEntry] = [
        .init(id: "clock", owner: "", label: "Clock", size: 2, takesArg: false,
              detail: "Hero time, meridiem and date"),
        .init(id: "fin", owner: "markets", label: "Ticker", size: 1, takesArg: true,
              detail: "One ticker: name, value, trend"),
        .init(id: "ice", owner: "ice", label: "ICE RINs", size: 1, takesArg: false,
              detail: "D4 RIN front contract"),
        .init(id: "agents", owner: "agents", label: "Agents", size: 1, takesArg: false,
              detail: "Newest Claude/Codex session"),
        .init(id: "usage", owner: "agents", label: "Usage", size: 1, takesArg: true,
              detail: "One provider's usage bar"),
        .init(id: "weather", owner: "", label: "Weather", size: 1, takesArg: false,
              detail: "Condition, temp, humidity"),
        .init(id: "sonos", owner: "sonos", label: "Sonos", size: 1, takesArg: false,
              detail: "Now playing: track, artist, room"),
        .init(id: "chart", owner: "chart", label: "Chart", size: 2, takesArg: true,
              detail: "One instrument with a sparkline (Phase 2)"),
    ]
    public static func entry(_ id: String) -> ComplicationCatalogEntry? { all.first { $0.id == id } }
    /// Reproduces today's Home exactly (design §7): clock at 1-2, fin.sp500 at 3, ice at 4, agents at 5,
    /// slot 6 free.
    public static let defaultHome = [CompPlacement(id: "clock")!, CompPlacement(id: "fin", arg: "sp500")!,
                                     CompPlacement(id: "ice")!, CompPlacement(id: "agents")!]
}

/// One wire entry: `id` or `id.arg`. `.` is the only separator (chosen because it is outside the
/// alphabet both ends already validate -- the id/arg charset itself never contains it).
public struct CompPlacement: Equatable, Sendable {
    public let id: String
    public let arg: String?

    /// Validates against `CompLimits.allowed` + length caps; nil on anything out of alphabet or over
    /// length -- the hub must not be able to STORE an out-of-alphabet id/arg in the first place (design
    /// §10.7: the device-side drop is a defence, not the first line).
    public init?(id: String, arg: String? = nil) {
        guard Self.isValid(id, max: CompLimits.idMax) else { return nil }
        if let arg, !arg.isEmpty {
            guard Self.isValid(arg, max: CompLimits.argMax) else { return nil }
            self.arg = arg
        } else {
            self.arg = nil
        }
        self.id = id
    }

    /// Parse a wire token ("fin.sp500" or "clock"). nil when it does not split into a valid id (+arg).
    public init?(_ wire: String) {
        guard let dot = wire.firstIndex(of: ".") else {
            self.init(id: wire)
            return
        }
        let id = String(wire[wire.startIndex..<dot])
        let rest = String(wire[wire.index(after: dot)...])
        guard !rest.isEmpty, !rest.contains(".") else { return nil }   // trailing/second dot: malformed
        self.init(id: id, arg: rest)
    }

    public var wire: String { arg.map { "\(id).\($0)" } ?? id }

    private static func isValid(_ s: String, max: Int) -> Bool {
        !s.isEmpty && s.utf8.count <= max && s.unicodeScalars.allSatisfy(CompLimits.allowed.contains)
    }
}

/// `{"v":1,"comps":{"rev":R,"slots":{"home":[...]}}}`. Mirrors `PagesFrame`: normalizes at the wire
/// boundary so the device never has to defend against the hub -- one instance per id (first wins, same
/// as the device's dedup rule), slot-unit capacity honoured using the catalog's `size` (a 2-slot
/// complication counts double against `CompLimits.slotsPerFace`), out-of-alphabet entries already
/// impossible (`CompPlacement.init?` refused them at construction).
public struct CompsFrame: Codable {
    public struct Body: Codable {
        public var rev: Int
        public var slots: [String: [String]]   // face id -> wire strings
    }
    public var comps: Body
    public let v: Int

    public init(rev: Int, slots: [String: [CompPlacement]]) {
        var wireSlots: [String: [String]] = [:]
        for (face, placements) in slots.prefix(CompLimits.maxFaces) {   // defensive cap; only "home" exists today
            var seen = Set<String>()
            var units = 0
            var wire: [String] = []
            for p in placements {
                guard !seen.contains(p.id) else { continue }               // one instance per id, first wins
                let size = ComplicationCatalog.entry(p.id)?.size ?? 1
                guard units + size <= CompLimits.slotsPerFace else { continue }
                seen.insert(p.id)
                units += size
                wire.append(p.wire)
            }
            wireSlots[face] = wire
        }
        self.comps = Body(rev: rev, slots: wireSlots)
        self.v = 1
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        var d = try enc.encode(self)
        d.append(0x0A)
        return d
    }

    /// True when the frame fits the device's hard ceiling. The alphabet is not JSON-escapable, so
    /// character caps bound bytes exactly (design §6.2) -- there is no encode-measure-shrink loop here,
    /// unlike SessionDetailsFrame's free-form text fields. Assert the worst case instead of adding a
    /// shrink path.
    public func fitsFrame() -> Bool {
        ((try? encoded().count) ?? .max) < CompLimits.frameMaxBytes
    }
}
