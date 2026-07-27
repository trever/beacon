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
        VStack(alignment: .leading, spacing: 10) {
            header
            stack
            warnings
            Divider()
            palette
        }
    }

    // --- header ---

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Complications").font(.system(size: 13, weight: .semibold))
                Text("Drag a tile onto the stack to place it; drag within the stack to reorder.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(ComplicationEditor.unitsUsed(placements)) of \(ComplicationEditor.capacity) slots")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    // --- the stack (design order == device order) ---

    private var stack: some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.element.placement.id) { index, row in
                stackRow(index: index, row: row)
            }
            appendDropZone
        }
    }

    private func stackRow(index: Int, row: ComplicationEditor.Row) -> some View {
        ComplicationStackRow(row: row, onRemove: { removeRow(at: index) },
                              onPickArg: { argPickerFor = index })
            .draggable(row.placement.id)
            .dropDestination(for: String.self) { items, _ in handleDrop(items, at: index) }
            .popover(isPresented: Binding(get: { argPickerFor == index },
                                          set: { if !$0 { argPickerFor = nil } })) {
                argPicker(for: row, index: index)
            }
    }

    private var appendDropZone: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(height: 26)
            .overlay(Text(rows.isEmpty ? "Drop here" : "").font(.system(size: 10)).foregroundStyle(.secondary))
            .dropDestination(for: String.self) { items, _ in handleDrop(items, at: nil) }
    }

    @ViewBuilder private var warnings: some View {
        if let dropMessage {
            Text(dropMessage).font(.system(size: 10)).foregroundStyle(.orange)
        }
        if ComplicationEditor.isBlank(placements) {
            Text("Home will be blank \u{2014} only the eyebrow and status chip will show.")
                .font(.system(size: 10)).foregroundStyle(.orange)
        }
    }

    // --- palette ---

    private var palette: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AVAILABLE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(ComplicationCatalog.all, id: \.id) { entry in
                    paletteTile(entry)
                }
            }
        }
    }

    private func paletteTile(_ entry: ComplicationCatalogEntry) -> some View {
        let placed = ComplicationEditor.isAlreadyPlaced(entry.id, in: placements)
        return VStack(spacing: 3) {
            Text(entry.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(entry.size == 2 ? "2 slots" : "1 slot").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.18)))
        .opacity(placed ? 0.35 : 1)
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

// One row in the stack: the placement's label, a 2-slot badge for the clock, an "unknown" mark for an
// orphaned id (design §10.4 -- preserved, not dropped, the same treatment PageOptions.orphan gives a
// missing chart instrument), a tappable arg summary for fin/usage, and a remove button (the
// non-drag-and-drop path -- mirrors the Pages carousel keeping chevron buttons alongside dragging).
private struct ComplicationStackRow: View {
    let row: ComplicationEditor.Row
    let onRemove: () -> Void
    let onPickArg: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                titleLine
                detailLine
            }
            Spacer(minLength: 6)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from Home")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.18)))
    }

    private var title: String { row.entry?.label ?? row.placement.id }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let entry = row.entry, entry.size == 2 {
                badge("2 slots", color: .secondary)
            }
            if row.isOrphan {
                badge("unknown", color: .orange)
            }
        }
    }

    @ViewBuilder private var detailLine: some View {
        if let entry = row.entry, entry.takesArg {
            Button(action: onPickArg) {
                Text(row.placement.arg.map { "Arg: \($0)" } ?? "Choose \u{2026}")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } else if row.isOrphan {
            Text("Not in this build's catalog \u{2014} kept as-is.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}

private struct ArgOption: Identifiable {
    let id: String
    let label: String
}

/// Shared popover body for the fin/usage arg pickers -- a plain tappable list, mirroring
/// SonosRoomPopover/ChartInstrumentPopover's "no matches" honesty rather than an empty-looking sheet.
private struct ArgPickerList: View {
    let title: String
    let options: [ArgOption]
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11, weight: .semibold)).padding(8)
            Divider()
            if options.isEmpty {
                Text("Nothing to choose from yet.").font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(options) { option in
                            Button { select(option.id) } label: {
                                Text(option.label).font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
