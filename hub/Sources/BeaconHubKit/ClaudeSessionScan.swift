import Foundation

// Reads Claude Code's own session transcripts (~/.claude/projects/**/*.jsonl) into session state.
//
// WHY THIS EXISTS: the hooks + statusline surfaces Beacon was built on are terminal-shaped. Under
// `entrypoint: claude-desktop` the statusline command is never invoked, so the hub receives no
// SessionStart/Stop and no rate_limits -- the device shows no sessions and stale usage. The transcripts
// are written regardless of entrypoint, so scanning them makes the session plane work for Desktop and
// CLI alike. Hooks still work when they fire: both paths key on the same `sessionId`, and
// SessionRegistry.touchActivity is idempotent per key, so a CLI session touched by both is not
// double-counted.
//
// LIMIT: transcripts carry per-message token counts but NOT the 5h/7d rate-limit windows. Usage
// percentages still come from statusline rate_limits or the oauth endpoint -- this file cannot and
// does not try to synthesize them.
//
// Pure + Foundation-only so the whole parse is host-tested; the app target owns directory walking,
// tailing and scheduling.

// One transcript's distilled state.
public struct ScannedSession: Equatable, Sendable {
    public var sessionId: String
    public var cwd: String?
    public var gitBranch: String?
    public var lastActivity: Date
    /// The last assistant record ended the turn (`stop_reason` != tool_use/pause_turn) with no user
    /// record after it => Claude is waiting on the human (SessionState.attention).
    ///
    /// `stop_reason` is load-bearing here, not decoration: a tool-using turn also ENDS on an assistant
    /// record, so "assistant spoke last" alone marks every actively-working session as needing
    /// attention -- verified against live transcripts, where an in-flight session read as `attention`
    /// at age=3s. Only `stop_reason` separates "finished, your move" from "mid-turn, tools running".
    public var turnFinished: Bool
    /// Cumulative output + input tokens seen in this transcript (cache reads excluded -- they are not
    /// new spend and would wildly inflate the figure the device shows).
    public var tokens: Int
    /// Claude Code's own session title (`type:"custom-title"` -> `customTitle`). Absent on most
    /// transcripts, so `displayTitle` falls back to the opening prompt, which reads like a title anyway.
    public var title: String?
    /// The first human turn, kept solely as the title fallback.
    public var firstPrompt: String?
    /// Newest human-or-assistant prose in the transcript, whitespace-collapsed. Tool results and
    /// attachments are excluded: they are machine chatter, not "the last message".
    public var lastMessage: String?
    public init(sessionId: String, cwd: String? = nil, gitBranch: String? = nil,
                lastActivity: Date, turnFinished: Bool = false, tokens: Int = 0,
                title: String? = nil, firstPrompt: String? = nil, lastMessage: String? = nil) {
        self.sessionId = sessionId; self.cwd = cwd; self.gitBranch = gitBranch
        self.lastActivity = lastActivity; self.turnFinished = turnFinished; self.tokens = tokens
        self.title = title; self.firstPrompt = firstPrompt; self.lastMessage = lastMessage
    }

    /// Fallback project name: the working directory's basename. Prefer
    /// `ClaudeSessionScan.projectName(cwd:transcriptDirName:)` where the transcript's path is known --
    /// `cwd` follows the agent into subdirectories, so this reads "hub" for a session rooted at "beacon".
    public var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// What the device labels the session: Claude Code's title when it has one, else the opening prompt.
    public var displayTitle: String? { title ?? firstPrompt }
}

public enum ClaudeSessionScan {
    /// ISO8601 with fractional seconds, which is what the transcripts carry.
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseTimestamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Squeeze a message body onto one display line: runs of whitespace (including the newlines and tabs
    /// that fill code blocks) collapse to single spaces. The device row is one line, and an un-collapsed
    /// body would also waste the frame budget on whitespace. Truncation happens at the frame boundary.
    public static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Human-readable prose from a transcript `message`. Content is either a bare string (early user
    /// records) or an array of blocks; only `text` blocks are taken, which is what excludes `tool_result`
    /// and `tool_use` -- machine chatter that is not "the last message".
    public static func messageText(_ message: Any?) -> String? {
        guard let m = message as? [String: Any] else { return nil }
        if let s = m["content"] as? String {
            let line = oneLine(s)
            return line.isEmpty ? nil : line
        }
        guard let blocks = m["content"] as? [[String: Any]] else { return nil }
        let parts = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .map(oneLine)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Parse a transcript (or its tail) into one session. Tolerates a truncated FIRST line, since the
    /// caller tails the last N bytes of a growing file and will usually land mid-record; every
    /// unparseable line is skipped rather than failing the scan.
    ///
    /// Returns nil when no line yielded a `sessionId` -- i.e. nothing usable, not an error.
    public static func parse(_ text: String) -> ScannedSession? {
        var sessionId: String?
        var cwd: String?
        var branch: String?
        var last: Date?
        var tokens = 0
        var turnFinished = false
        var title: String?
        var firstPrompt: String?
        var lastMessage: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }   // truncated head / partial tail line

            if let s = obj["sessionId"] as? String, !s.isEmpty { sessionId = s }
            // Last non-empty wins: cwd and branch can legitimately change mid-session (a `cd`, a
            // checkout), and the newest value is the one the device should label the row with.
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }

            if let ts = obj["timestamp"] as? String, let d = parseTimestamp(ts) {
                if last == nil || d > last! { last = d }
            }

            let type = obj["type"] as? String

            if type == "custom-title", let t = obj["customTitle"] as? String, !t.isEmpty {
                title = oneLine(t)
            }

            // Prose for the row. Sidechain records are a Task subagent's own conversation: including them
            // would show the device a subagent's chatter as the session's last message. `toolUseResult`
            // records are tool output wearing a user record's clothes.
            let isSidechain = (obj["isSidechain"] as? Bool) ?? false
            let isToolResult = obj["toolUseResult"] != nil
            let isMeta = (obj["isMeta"] as? Bool) ?? false
            if (type == "assistant" || type == "user"), !isSidechain, !isToolResult, !isMeta,
               let text = messageText(obj["message"]) {
                lastMessage = text                       // in file order, so the last one standing is newest
                if type == "user", firstPrompt == nil { firstPrompt = text }
            }

            // Only user/assistant records move the turn state. `attachment`, `last-prompt` and friends
            // are bookkeeping that can trail an assistant turn without meaning work resumed.
            if type == "assistant" {
                let stop = (obj["message"] as? [String: Any])?["stop_reason"] as? String
                // A turn that stopped to run tools is still in flight. An absent stop_reason is treated
                // as in-flight too: falsely showing "working" is harmless, while falsely showing
                // "attention" nags the user about a session that needs nothing.
                turnFinished = (stop != nil) && stop != "tool_use" && stop != "pause_turn"
            } else if type == "user" {
                turnFinished = false
            }

            if let m = obj["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
                // Cache reads are excluded deliberately: they run to hundreds of thousands per message
                // and are not new spend, so including them makes the device's token figure meaningless.
                tokens += (u["input_tokens"] as? Int) ?? 0
                tokens += (u["output_tokens"] as? Int) ?? 0
                tokens += (u["cache_creation_input_tokens"] as? Int) ?? 0
            }
        }

        guard let id = sessionId else { return nil }
        return ScannedSession(sessionId: id, cwd: cwd, gitBranch: branch,
                              lastActivity: last ?? .distantPast,
                              turnFinished: turnFinished, tokens: tokens,
                              title: title, firstPrompt: firstPrompt, lastMessage: lastMessage)
    }

    /// How a scanned transcript maps onto the wire session state.
    /// `idleAfter` mirrors the registry's own idle TTL so a transcript nobody has touched stops
    /// claiming attention forever.
    public static func state(for s: ScannedSession, now: Date,
                             workingWithin: TimeInterval = 90,
                             idleAfter: TimeInterval = 1800) -> SessionState {
        let age = now.timeIntervalSince(s.lastActivity)
        if age >= idleAfter { return .idle }
        if s.turnFinished { return .attention }          // assistant spoke last => waiting on the human
        if age <= workingWithin { return .working }
        return .idle
    }

    /// The project (repo) name for a session row.
    ///
    /// `cwd` alone is wrong: it follows the agent into subdirectories, so a session rooted at
    /// `~/eng-stuff/beacon` reads "hub" the moment a command cds into `hub/` -- observed on a live
    /// transcript. Claude Code names the transcript's parent directory after the session's ROOT cwd with
    /// each "/" replaced by "-", so the root is recoverable: walk `cwd` up until its dashed form equals the
    /// directory name, then take that basename.
    ///
    /// The comparison is against the whole dashed string, never a split on "-", so repo names that
    /// themselves contain dashes ("ice-tracker-bar") resolve correctly. Falls back to the `cwd` basename
    /// when the two cannot be reconciled (the agent cded somewhere unrelated, or a renamed directory).
    public static func projectName(cwd: String?, transcriptDirName: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        guard let dirName = transcriptDirName, !dirName.isEmpty else { return (cwd as NSString).lastPathComponent }
        var path = cwd
        // Bounded by the path depth; each turn drops one component.
        while !path.isEmpty, path != "/" {
            if path.replacingOccurrences(of: "/", with: "-") == dirName {
                let name = (path as NSString).lastPathComponent
                return name.isEmpty ? nil : name
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Transcripts older than this are not worth reading: the file list is walked every tick and a
    /// months-old project directory would otherwise cost a parse forever.
    public static func isRecent(mtime: Date, now: Date, within: TimeInterval = 86_400) -> Bool {
        now.timeIntervalSince(mtime) <= within
    }
}
