import Foundation

// Pure decision logic behind the Home slot editor (design §4.5, §5.3, §10.7, §10.8; plan §6). Kept out of
// ComplicationEditorView (SwiftUI) so capacity, one-instance-per-id, arg validation and the blank-Home
// warning are host-tested -- the precedent is PageCatalog.editorRows / ChartInstrumentSelection: pure
// function in the kit, the view only maps its output onto pixels and never re-derives a rule itself.
//
// What is intentionally NOT here: any notion of a slot INDEX 1...6 with per-slot state. The design is
// explicit that size (the clock's 2-unit span) and per-instance state are different mechanisms -- span is
// arithmetic over an ORDERED LIST of placements, not a fixed-size array of slots. This type mirrors that:
// `[CompPlacement]` is the whole model, in device order, and `unitsUsed` walks it summing each entry's
// catalog size. A two-slot complication is one array element, exactly once, never two.

public enum ComplicationEditor {
    /// COMP_SLOTS_MAX (design §5.3) -- the total slot UNITS a face can hold. Re-exported from CompLimits
    /// only so callers reasoning about the editor don't have to know that name too.
    public static let capacity = CompLimits.slotsPerFace

    /// Slot units currently spent by `placements`, using each id's SIZE from `ComplicationCatalog` -- the
    /// single source of truth for size (plan §13 item 1; never re-derived here). An id this build's
    /// catalog does not know (a stray wire string from a newer firmware, or a hand-edited default) is
    /// charged 1 unit defensively, so capacity arithmetic never depends on an entry that does not exist.
    public static func unitsUsed(_ placements: [CompPlacement]) -> Int {
        placements.reduce(0) { $0 + (ComplicationCatalog.entry($1.id)?.size ?? 1) }
    }

    public static func unitsFree(_ placements: [CompPlacement]) -> Int {
        capacity - unitsUsed(placements)
    }

    /// One instance per id (design §4.5, owner decision) -- true when `id` already occupies a placement
    /// other than the one at `excluding`. `excluding` is the id's OWN current index when the caller is
    /// asking "can I move/re-place this id", so a complication is never seen as a duplicate of itself.
    public static func isAlreadyPlaced(_ id: String, in placements: [CompPlacement], excluding: Int? = nil) -> Bool {
        placements.enumerated().contains { index, placement in placement.id == id && index != excluding }
    }

    public enum PlacementError: Equatable, Sendable {
        /// One instance per id: this id already occupies a different slot.
        case alreadyPlaced
        /// The remaining slot units are fewer than this id's size (the clock, at size 2, is the only
        /// Phase-1 catalog entry a single free unit can refuse).
        case insufficientCapacity
        /// `id`/`arg` failed CompPlacement's own charset/length validation -- the hub must not be able to
        /// STORE an out-of-alphabet arg in the first place (design §10.7: the device-side drop is a
        /// defence, not the first line).
        case invalidArg
    }

    /// Whether `id` (with `arg`) could be placed into `placements`, replacing whatever sits at
    /// `replacing` (the id's own former slot, when this is a move/re-placement rather than a fresh add).
    /// Read-only: never mutates. `placing(...)` below calls this and only applies the result when it
    /// passes, so a caller that only wants the refusal reason (to show a message) never has to duplicate
    /// the rule.
    public static func validate(id: String, arg: String?, into placements: [CompPlacement],
                                 replacing: Int? = nil) -> PlacementError? {
        guard CompPlacement(id: id, arg: arg) != nil else { return .invalidArg }
        if isAlreadyPlaced(id, in: placements, excluding: replacing) { return .alreadyPlaced }
        var remaining = placements
        if let replacing, remaining.indices.contains(replacing) { remaining.remove(at: replacing) }
        let size = ComplicationCatalog.entry(id)?.size ?? 1
        guard unitsUsed(remaining) + size <= capacity else { return .insufficientCapacity }
        return nil
    }

    /// Place `id`/`arg` into `placements` at `index` (nil, or past the end, appends). Any PRIOR occurrence
    /// of the same id is removed first, so dropping an already-placed complication onto a new spot MOVES
    /// it rather than creating a second instance -- one-instance-per-id is enforced by construction here,
    /// not by refusing the drop. When `validate` would refuse the placement (capacity or alphabet), the
    /// list is returned UNCHANGED -- the view never has to duplicate the refusal logic to decide whether
    /// to apply the result; it can always assign this function's return value.
    public static func placing(id: String, arg: String?, into placements: [CompPlacement],
                                at index: Int? = nil) -> [CompPlacement] {
        guard let placement = CompPlacement(id: id, arg: arg) else { return placements }
        let priorIndex = placements.firstIndex(where: { $0.id == id })
        guard validate(id: id, arg: arg, into: placements, replacing: priorIndex) == nil else { return placements }
        var working = placements
        if let priorIndex { working.remove(at: priorIndex) }
        let insertAt = min(max(index ?? working.count, 0), working.count)
        working.insert(placement, at: insertAt)
        return working
    }

    /// Remove the placement at `index`. Out-of-range is a no-op (defensive; SwiftUI drop callbacks can
    /// race a state update that already changed the count).
    public static func removing(at index: Int, from placements: [CompPlacement]) -> [CompPlacement] {
        var working = placements
        guard working.indices.contains(index) else { return working }
        working.remove(at: index)
        return working
    }

    /// design §4.3 rule 5 / §10.8: an explicitly empty assignment is legal (the clock is assignable, so
    /// Home can be reduced to nothing but its eyebrow) but the editor must warn before it is sent --
    /// nothing else recovers an intentional blank Home except editing it back.
    public static func isBlank(_ placements: [CompPlacement]) -> Bool {
        placements.isEmpty
    }

    /// One row of the editor's stack: a placement paired with its catalog entry, or `nil` when the id is
    /// unknown to this build's catalog. An unknown id is PRESERVED here, not dropped -- the same treatment
    /// `PageOptions.orphan` (PageDesignerView) gives a chart instrument no longer in the ticker list. The
    /// device already drops an unknown id on its own (design §4.3 rule 1); the hub doing it too would
    /// erase state a newer firmware -- or a hub rebuilt against a stale catalog mirror (design §10.4) --
    /// might still understand, the moment the user hits Save again.
    public struct Row: Equatable, Sendable {
        public let placement: CompPlacement
        public let entry: ComplicationCatalogEntry?
        public init(placement: CompPlacement, entry: ComplicationCatalogEntry?) {
            self.placement = placement; self.entry = entry
        }
        public var isOrphan: Bool { entry == nil }
    }

    public static func rows(for placements: [CompPlacement]) -> [Row] {
        placements.map { Row(placement: $0, entry: ComplicationCatalog.entry($0.id)) }
    }
}
