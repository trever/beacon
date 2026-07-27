import SwiftUI
import BeaconHubKit

// Home's six-slot complication editor -- the Pages tab's inspector when "Home" is selected (design §4,
// §5; plan §6). Every RULE (6-unit capacity with the clock counting as 2, one-instance-per-id, arg
// validation, the blank-Home warning) lives in BeaconHubKit.ComplicationEditor; this view only renders
// what that pure layer decides and turns gestures into calls into it -- it never re-derives a rule.
//
// The assignment is modeled as an ORDERED LIST of placements, matching the device's own resolver (design
// §4.1: "size and per-instance state are different mechanisms"). There is no notion of six fixed "well"
// indices with their own state -- the clock is one list entry charged 2 slot units, never two entries.
// Drops therefore target INSERTION POINTS around the stack (the same "insert-at-index" primitive the
// Pages carousel above uses for reordering pages), not a positional 1-6 grid.
//
// WS-3 (2026-07-27-hub-visual-system-plan.md SS"WS-3", design SS2/SS3/SS5): this view is laid out for the
// Pages inspector's 260 pt column (228 pt of content after the inspector's own SS5.1 padding), and every
// literal font size / colour / radius here has been replaced by HubStyle/HubRows/HubSurfaces tokens and
// components. The model above is untouched -- only pixels moved.
//
// Defect 1 fix: PageDesignerView's `inspector` container pads only the header it renders directly
// (`inspectorHeader`) -- it never wraps the embedded content view in horizontal padding, exactly like
// PageOptions (PageDesignerInspector.swift), which pads its own body rather than relying on its container
// to. This view used to apply NO horizontal padding of its own, so "Complications"/the badge/the stack all
// sat flush against the column's left edge while the header above them (padded by the container) did not
// -- two visibly different left edges. The `#Preview`s below happened to hide this: they wrapped the view
// in their own `.padding(HubSpace.l)`, which simulated the correct inset without the production code
// actually having it.
//
// One owner, chosen: EACH embedded inspector section pads itself at `HubSpace.l` horizontal / `HubSpace.m`
// vertical -- the same call PageOptions already makes -- rather than PageDesignerView.inspector wrapping
// whatever it embeds. That keeps the Divider directly under the header full-bleed (matching the
// composition column's own Divider-is-full-bleed convention) while every block of *content* shares the
// header's HubSpace.l left edge.
struct ComplicationEditorView: View {
    @ObservedObject var model: HubViewModel

    /// Index of the stack row whose arg-picker popover is open, if any.
    @State private var argPickerFor: Int?
    /// Transient refusal message shown under the stack (capacity / duplicate / invalid arg).
    @State private var dropMessage: String?

    private var wire: [String] { model.compSlots[CompLimits.homeFace] ?? [] }
    private var placements: [CompPlacement] { wire.compactMap(CompPlacement.init) }
    private var rows: [ComplicationEditor.Row] { ComplicationEditor.rows(for: placements) }

    var body: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            header
            stack
            warnings
            Divider()
            palette
        }
        // Matches PageOptions's own self-padding exactly (PageDesignerInspector.swift) -- see the doc
        // comment above `struct ComplicationEditorView` for why this view, not its container, owns the
        // inset.
        .padding(.horizontal, HubSpace.l).padding(.vertical, HubSpace.m)
    }

    // --- header ---

    // At 228 pt of content width the title/subtitle and the "n of N slots" capsule cannot share a row
    // (plan WS-3 item 1: the header "puts a two-line title beside a capsule chip on one row"). Stacking
    // the badge under the header is the deterministic choice the plan asks for, rather than a
    // GeometryReader race that measures available width at render time.
    private var header: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            SectionHeader(title: "Complications",
                          subtitle: "Drag a tile onto the stack to place it; drag within the stack to reorder.")
            HubBadge("\(ComplicationEditor.unitsUsed(placements)) of \(ComplicationEditor.capacity) slots")
        }
    }

    // --- the stack (design order == device order) ---

    private var stack: some View {
        VStack(alignment: .leading, spacing: HubSpace.s) {
            if !rows.isEmpty {
                Card(padding: .rows) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.placement.id) { index, row in
                            if index > 0 {
                                RowSeparator(hasLeadingIcon: false)
                            }
                            stackRow(index: index, row: row)
                        }
                    }
                }
            }
            appendDropZone
        }
    }

    // `SettingsRow`'s two text slots (title/subtitle) carry the placement's label and its arg/orphan
    // detail; the "2 slots" and "unknown" marks are informational, not controls, so they ride alongside
    // the row's one real trailing control (remove) rather than counting against design SS3.2's "exactly
    // one control" rule. Tapping the row (outside the remove button) opens the arg picker for fin/usage --
    // the same action the old detail-line button performed -- since `SettingsRow`'s subtitle is plain text
    // and cannot carry its own tap target.
    private func stackRow(index: Int, row: ComplicationEditor.Row) -> some View {
        let title = row.entry?.label ?? row.placement.id
        return SettingsRow(title: title, subtitle: stackRowSubtitle(row)) {
            HStack(spacing: HubSpace.s) {
                if let entry = row.entry, entry.size == 2 {
                    HubBadge("2 slots")
                }
                if row.isOrphan {
                    HubBadge("unknown", tint: HubColor.stateWarn)
                }
                IconButton(systemImage: "xmark.circle.fill", label: "Remove \(title)") {
                    removeRow(at: index)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let entry = row.entry, entry.takesArg else { return }
            argPickerFor = index
        }
        .draggable(row.placement.id)
        .dropDestination(for: String.self) { items, _ in handleDrop(items, at: index) }
        .popover(isPresented: Binding(get: { argPickerFor == index },
                                      set: { if !$0 { argPickerFor = nil } })) {
            argPicker(for: row, index: index)
        }
    }

    private func stackRowSubtitle(_ row: ComplicationEditor.Row) -> String? {
        if let entry = row.entry, entry.takesArg {
            return row.placement.arg.map { "Arg: \($0)" } ?? "Choose \u{2026}"
        }
        if row.isOrphan {
            return "Not in this build's catalog \u{2014} kept as-is."
        }
        return nil
    }

    // Defect 2 fix: `HubShape.control` is a `RoundedRectangle` -- like any bare `Shape`, its ideal height is
    // effectively infinite, so a `minHeight`-only frame leaves it free to accept whatever height its
    // container offers rather than hugging its own content. Here that container is
    // `PageDesignerView.inspector`'s outer VStack, which ends in a trailing `Spacer(minLength: 0)`: with
    // nothing else claiming the pane's extra vertical space, this shape happily grabbed all of it, pushing
    // `warnings`/the Divider/`palette` (the AVAILABLE grid) down and off-screen. Pinning BOTH ends of the
    // frame makes the zone exactly 26 pt regardless of how much height its ancestors offer.
    private var appendDropZone: some View {
        HubShape.control
            .strokeBorder(HubColor.lineHairline, style: StrokeStyle(lineWidth: HubStroke.hairline, dash: [4, 3]))
            .frame(height: 26)
            .overlay {
                if rows.isEmpty {
                    Text("Drop here").font(HubType.caption).foregroundStyle(HubColor.inkSecondary)
                }
            }
            .dropDestination(for: String.self) { items, _ in handleDrop(items, at: nil) }
    }

    @ViewBuilder private var warnings: some View {
        // Transient refusal (capacity / duplicate / invalid arg): it clears on the next successful drop,
        // so it stays an inline `type.secondary` line rather than the standing `StatusRow` treatment
        // (plan WS-3 item 5's explicitly-allowed "may stay inline" option).
        if let dropMessage {
            Text(dropMessage).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
        }
        // The blank-Home warning is a genuine standing state until the user places something, so it takes
        // the full `StatusRow` `warn` treatment -- the glyph carries the colour, the word stays
        // `ink.primary` (design SS2.3).
        if ComplicationEditor.isBlank(placements) {
            StatusRow(state: .warn,
                      title: "Home will be blank \u{2014} only the eyebrow and status chip will show.") {
                EmptyView()
            }
        }
    }

    // --- palette ---

    private var palette: some View {
        VStack(alignment: .leading, spacing: HubSpace.s) {
            Text("AVAILABLE").hubEyebrow().foregroundStyle(HubColor.inkSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: HubSpace.s)], spacing: HubSpace.s) {
                ForEach(ComplicationCatalog.all, id: \.id) { entry in
                    paletteTile(entry)
                }
            }
        }
    }

    // `CatalogTile` requires a real action (it is the same tile the Pages AVAILABLE grid uses to toggle a
    // provider on tap); wiring it to append this id mirrors that contract and gives keyboard/VoiceOver
    // users a way to place a complication that pure drag-and-drop does not. It calls the identical
    // `handleDrop` path a drop onto the append zone already used -- dragging an already-placed palette
    // tile onto the append zone was already legal before this change (the old `paletteTile` never
    // disabled `.draggable` when `placed` was true), so tapping a placed tile moving it to the end of the
    // stack is exposing an existing capability through a second input method, not new behaviour.
    private func paletteTile(_ entry: ComplicationCatalogEntry) -> some View {
        let placed = ComplicationEditor.isAlreadyPlaced(entry.id, in: placements)
        return CatalogTile(title: entry.label,
                            detail: entry.size == 2 ? "2 slots" : "1 slot",
                            isEnabled: placed,
                            isSelected: false) {
            _ = handleDrop([entry.id], at: nil)
        }
        .help(placed ? "\(entry.label) is already on Home. One instance of each complication at a time." : entry.detail)
        .draggable(entry.id)
    }

    // --- drop handling: everything here is deciding WHERE, the RULES live in ComplicationEditor ---

    private func handleDrop(_ items: [String], at index: Int?) -> Bool {
        guard let id = items.first, let entry = ComplicationCatalog.entry(id) else { return false }
        let priorIndex = placements.firstIndex(where: { $0.id == id })
        let existingArg = priorIndex.map { placements[$0].arg } ?? nil
        if let error = ComplicationEditor.validate(id: id, arg: existingArg, into: placements, replacing: priorIndex) {
            dropMessage = message(for: error, entry: entry)
            return false
        }
        let next = ComplicationEditor.placing(id: id, arg: existingArg, into: placements, at: index)
        update(next)
        dropMessage = nil
        // A fresh placement of an arg-taking complication is dropped bare -- prompt for the arg right
        // away rather than leaving it silently unconfigured.
        if entry.takesArg && existingArg == nil && priorIndex == nil {
            argPickerFor = next.firstIndex(where: { $0.id == id })
        }
        return true
    }

    private func removeRow(at index: Int) {
        update(ComplicationEditor.removing(at: index, from: placements))
        if argPickerFor == index { argPickerFor = nil }
    }

    private func message(for error: ComplicationEditor.PlacementError, entry: ComplicationCatalogEntry) -> String {
        switch error {
        case .alreadyPlaced:
            return "\(entry.label) is already on Home."
        case .insufficientCapacity:
            return "Not enough room for \(entry.label) (needs \(entry.size == 2 ? "2 slots" : "1 slot"))."
        case .invalidArg:
            return "\(entry.label) has an invalid argument."
        }
    }

    private func update(_ next: [CompPlacement]) {
        model.compSlots[CompLimits.homeFace] = next.map(\.wire)
    }

    // --- arg picker: fin takes a ticker id, usage takes a provider id (design §4.5) ---

    @ViewBuilder private func argPicker(for row: ComplicationEditor.Row, index: Int) -> some View {
        switch row.placement.id {
        case "fin":
            ArgPickerList(title: "Choose a ticker",
                          options: model.tickerRows.map { ArgOption(id: $0.id, label: $0.name.isEmpty ? $0.sym : $0.name) },
                          select: { setArg($0, at: index) })
        case "usage":
            ArgPickerList(title: "Choose a provider",
                          options: model.providers.map { ArgOption(id: $0.id, label: $0.label) },
                          select: { setArg($0, at: index) })
        default:
            EmptyView()
        }
    }

    private func setArg(_ arg: String, at index: Int) {
        guard placements.indices.contains(index) else { return }
        let id = placements[index].id
        guard ComplicationEditor.validate(id: id, arg: arg, into: placements, replacing: index) == nil else { return }
        update(ComplicationEditor.placing(id: id, arg: arg, into: placements, at: index))
        argPickerFor = nil
    }
}

private struct ArgOption: Identifiable {
    let id: String
    let label: String
}

/// Shared popover body for the fin/usage arg pickers -- a plain tappable list, mirroring
/// SonosRoomPopover/ChartInstrumentPopover's "no matches" honesty rather than an empty-looking sheet.
/// Each option is a `ListRow` (design SS3.4) rather than a hand-rolled button.
private struct ArgPickerList: View {
    let title: String
    let options: [ArgOption]
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(HubType.secondary).fontWeight(.semibold).foregroundStyle(HubColor.inkPrimary)
                .padding(HubSpace.s)
            Divider()
            if options.isEmpty {
                Text("Nothing to choose from yet.").font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                    .padding(HubSpace.s)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(options) { option in
                            ListRow(primary: option.label) { select(option.id) }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 220)
    }
}

// 260 pt: the real inspector column width this view is embedded at (PageDesignerView.inspector's
// `minWidth`). The view pads itself down to 228 pt of content -- previewing at 260 with no extra preview-
// level padding is what actually matches production now; the old 228 pt + `.padding(HubSpace.l)` preview
// was simulating the inset from OUTSIDE, which is exactly what let Defect 1 hide from anyone eyeballing
// just this preview.
#Preview("260 pt column (228 pt content) -- light") {
    ComplicationEditorView(model: HubViewModel())
        .frame(width: 260)
        .preferredColorScheme(.light)
}

#Preview("260 pt column (228 pt content) -- dark") {
    ComplicationEditorView(model: HubViewModel())
        .frame(width: 260)
        .preferredColorScheme(.dark)
}
