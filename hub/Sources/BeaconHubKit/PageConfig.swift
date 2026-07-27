import Foundation

// Which pages the device shows, and in what order (design 2026-07-26-hub-as-controller-and-sonos).
// Mirrors firmware/src/core/page_config.h. Pages are identified by a STABLE STRING ID, never an index:
// the device's old positional constant was wrong or moved four times as screens came and went.

public enum PageLimits {
    /// PAGES_MAX in page_config.h (the device's s_pages[]/s_dots[] are fixed at 8).
    public static let maxCount = 8
    /// HUB_FRAME_MAX. The device drops a longer frame outright.
    public static let frameMaxBytes = 1024
    /// The device force-appends this if it is missing, so no config can strand the user without
    /// settings. The hub pins it too, so the UI never implies it is removable.
    public static let alwaysID = "settings"
}

/// One page the firmware can show. `removable == false` pins it in the UI.
public struct PageCatalogEntry: Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let removable: Bool
    public init(id: String, title: String, detail: String, removable: Bool = true) {
        self.id = id; self.title = title; self.detail = detail; self.removable = removable
    }
}

public enum PageCatalog {
    /// Must stay in sync with REGISTRY in firmware/src/ui/carousel.cpp. An id the device does not carry
    /// is dropped there rather than rejected, so a hub ahead of its firmware degrades quietly.
    public static let all: [PageCatalogEntry] = [
        .init(id: "home",     title: "Home",     detail: "Clock, S&P, RINs and the newest Claude session"),
        .init(id: "markets",  title: "Markets",  detail: "The configured ticker list"),
        .init(id: "chart",    title: "Chart",    detail: "One symbol with an intraday graph"),
        .init(id: "ice",      title: "ICE RINs", detail: "D4 RIN contracts"),
        .init(id: "agents",   title: "Agents",   detail: "Claude sessions and permission prompts"),
        .init(id: "settings", title: "Settings", detail: "On-device settings", removable: false),
    ]
    public static func entry(_ id: String) -> PageCatalogEntry? { all.first { $0.id == id } }
    public static let defaultOrder = ["home", "chart", "ice", "agents", "settings"]
}

public struct PageSpec: Codable, Equatable, Sendable {
    public var id: String
    /// Reserved for per-page settings. Parsed and ignored by the device today, so it can start carrying
    /// real options without a wire break.
    public var opts: [String: String]?
    public init(id: String, opts: [String: String]? = nil) { self.id = id; self.opts = opts }
}

public struct PagesFrame: Codable {
    public struct Body: Codable {
        public var rev: Int
        public var list: [PageSpec]
    }
    public var pages: Body
    public let v: Int

    /// Normalizes at the wire boundary so the device never has to defend against the hub: duplicates
    /// collapse (first wins), the count is capped, and `settings` is appended when missing -- the same
    /// rules page_list_resolve applies, so both ends agree on what was sent.
    public init(rev: Int, _ specs: [PageSpec]) {
        var seen = Set<String>()
        var list: [PageSpec] = []
        for s in specs where !s.id.isEmpty && !seen.contains(s.id) {
            seen.insert(s.id)
            list.append(s)
            if list.count == PageLimits.maxCount { break }
        }
        if !seen.contains(PageLimits.alwaysID) {
            if list.count >= PageLimits.maxCount { list.removeLast() }
            list.append(PageSpec(id: PageLimits.alwaysID))
        }
        self.pages = Body(rev: rev, list: list)
        self.v = 1
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        var d = try enc.encode(self)
        d.append(0x0A)
        return d
    }

    /// True when the frame fits the device's hard ceiling. Ids are short and bounded, so this only bites
    /// once `opts` carries real content -- at which point the frame needs chunking like the ticker config
    /// rather than silent truncation.
    public func fitsFrame() -> Bool {
        ((try? encoded().count) ?? .max) < PageLimits.frameMaxBytes
    }
}
