import Foundation
import BeaconHubKit

// Classifies a non-200 Sonos Control API response into the shared ProviderOutcome vocabulary (design
// 2026-07-26-sonos-now-playing-plan step 4). Pure over (status, retryAfter) so it is table-tested without
// a network stack -- see SonosOutcomeClassifierTests.
//
// 401/403 are .terminal, not .transient: this is the single most important correctness requirement in
// this file. A token that is genuinely revoked (401 after re-auth attempts) or a credential missing the
// required scope (403) will fail identically on every retry -- as .transient it would be re-issued every
// poll tick forever, which is exactly the shape of bug that earned this project an hour-long 429 from
// Anthropic against the (structurally similar) Claude oauth/usage endpoint (issue #7, see
// UsagePollDecision.classifyClaudeUsageFailure for the sibling case). SonosProvider.noteOutcome gates the
// next poll behind a fixed cooldown specifically so a terminal here cannot re-fire on the very next tick.
//
// 404 is treated differently from Claude's endpoint: a Sonos group id goes stale whenever the user groups
// or ungroups speakers in the Sonos app, which is normal and frequent, not a broken credential -- so it
// stays .transient, and SonosProvider additionally drops its cached group id on a 404 so the NEXT poll
// re-resolves topology instead of repeating a request against a group that no longer exists.
enum SonosOutcomeClassifier {
    static func classify(status: Int, retryAfter: TimeInterval?) -> ProviderOutcome {
        switch status {
        case 401:
            return .terminal(reason: "Sonos session invalid - re-run sonos-authorize", kind: .staleToken)
        case 403:
            return .terminal(reason: "Sonos not authorized for this scope (HTTP 403)", kind: .other)
        case 404:
            return .transient(retryAfter: retryAfter, reason: "Sonos group not found - refreshing topology")
        default:
            return .transient(retryAfter: retryAfter, reason: "Sonos unavailable (HTTP \(status))")
        }
    }
}
