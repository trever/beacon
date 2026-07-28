import Foundation

// Injectable seam for macOS sleep assertions (design 2026-07-27-sonos-album-art-design.md §7.2, plan §3
// D-5). The one behavioural fact this buys: "the album-art LAN path never disables idle sleep" becomes
// a real, swappable-spy test rather than a grep for `beginActivity` a future refactor could defeat.
//
// LanAssetServer.swift MUST NOT import Foundation's ProcessInfo activity APIs through this type, and in
// fact never references `PowerAssertions` at all -- that absence is itself the compile-time fact the
// behavioural test in LanAssetServerTests relies on (D-5). OTA's later firmware-update caller is the
// one and only place expected to call `PowerAssertions.shared` from this codebase.
protocol PowerAsserting: AnyObject {
    func begin(_ reason: String) -> UUID
    func end(_ token: UUID)
}

enum PowerAssertions {
    static var shared: PowerAsserting = ProcessInfoPowerAssertion()
}

// The real implementation: NSProcessInfo activity tokens keyed by UUID so overlapping callers (there
// are none in this codebase today, but nothing here assumes there won't be) can each end only their own.
final class ProcessInfoPowerAssertion: PowerAsserting {
    private let lock = NSLock()
    private var activities: [UUID: NSObjectProtocol] = [:]

    func begin(_ reason: String) -> UUID {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: reason)
        let token = UUID()
        lock.lock()
        activities[token] = activity
        lock.unlock()
        return token
    }

    func end(_ token: UUID) {
        lock.lock()
        let activity = activities.removeValue(forKey: token)
        lock.unlock()
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }
}
