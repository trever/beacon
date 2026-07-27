import SwiftUI
import AppKit
import BeaconHubKit

// The device's page set, laid out as ONE elastic composition column beside a bounded inspector (design
// 2026-07-27-hub-visual-system SS5.1, plan WS-2): what is ON the Beacon (draggable, reorderable) stacked
// directly above the full AVAILABLE catalog, an `HSplitView` away from the selected page's own options --
// and, when Home is selected, the six-slot complication editor.
//
// The carousel and the catalog used to be three horizontal zones (a full-bleed band above a fixed-width
// grid beside an inspector) separated only because the interaction was dragging BETWEEN them. Stacked in
// one column they are two vertical zones, and the drag becomes a short vertical gesture inside a single
// column instead of a diagonal haul from a left-hand grid up into a band spanning the whole window.
//
// Editing STAGES for pages (applying restarts the Beacon, ~5 s) and for complications (applying is live,
// no restart) independently, but one "Save & push" button commits both: complications first, pages
// second (design SS7's push order -- so if the page push restarts the device, the complication blob is
// already persisted and the device boots correct). The footer shows a line per dirty channel so neither
// verb is silently folded into the other (design SS3.11).
struct PageDesignerView: View {
    @ObservedObject var model: HubViewModel
    @State private var selection: String?
    @State private var targetedCardIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The enabled strip's card width; the device-glass preview inside it is `cardW - 30` so a 3 pt bezel
    /// on each side still clears the card's own edge with a little breathing room either side.
    private let cardW: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                composition
                inspector
            }
            footer
        }
        .onAppear {
            if selection == nil {
                selection = model.pageRows.first(where: \.enabled)?.id ?? model.pageRows.first?.id
            }
        }
    }

    // --- composition: the enabled strip and the AVAILABLE catalog, one elastic column (design SS5.1) ---

    private var composition: some View {
        VStack(alignment: .leading, spacing: 0) {
            compositionHeader
            enabledCarousel
            disclaimerLine
            Divider()
            availableSection
        }
        // Width only: `HSplitView` (an NSSplitView bridge) already stretches each pane to the full split
        // height on its own, and design SS5.3 reserves an infinite-height frame for the ONE pane that
        // should absorb slack by growing its content -- the composition column absorbs slack by giving
        // its catalog grid more COLUMNS, not by stretching a fixed-height view taller.
        .frame(minWidth: 380, maxWidth: .infinity)
    }

    private var compositionHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("On the Beacon").font(HubType.pane).foregroundStyle(HubColor.inkPrimary)
            Spacer()
            enabledCountBadge
        }
        .padding(.horizontal, HubSpace.l).padding(.top, HubSpace.m).padding(.bottom, HubSpace.s)
    }

    private var enabledCountBadge: some View {
        Text("\(model.enabledPageIDs.count) of \(model.pageRows.count) enabled")
            .font(HubType.caption).monospacedDigit()
            .foregroundStyle(HubColor.inkSecondary)
            .padding(.horizontal, HubSpace.s).padding(.vertical, HubSpace.hair)
            .background(HubColor.fillControl, in: HubShape.pill)
    }

    // design SS6.3's honesty-string rule: this is the HUB talking about the device, so it lives in hub ink
    // below the strip, once -- never inside a device-glass panel (contract C3).
    private var disclaimerLine: some View {
        Text("Previews are approximations \u{2014} the Beacon renders these itself.")
            .font(HubType.caption).foregroundStyle(HubColor.inkSecondary)
            .padding(.horizontal, HubSpace.l).padding(.bottom, HubSpace.s)
    }

    // --- the enabled strip: device order, draggable, reorderable (design SS3.5: no full-bleed fill) ---

    private var enabledRows: [PageRow] { model.pageRows.filter(\.enabled) }

    private var enabledCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HubSpace.l) {
                    ForEach(Array(enabledRows.enumerated()), id: \.element.id) { pair in
                        carouselCard(index: pair.offset, row: pair.element)
                    }
                    appendDropZone
                }
                .padding(.horizontal, HubSpace.l).padding(.vertical, HubSpace.m)
            }
            // Single-parameter onChange: the package deploys to macOS 13 (design SS9.1), where the
            // two-parameter overload does not exist.
            .onChange(of: enabledRows.map(\.id)) { _ in
                if let sel = selection {
                    withAnimation(HubMotion.animation(HubMotion.normal, reduceMotion: reduceMotion)) {
                        proxy.scrollTo(sel, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 200)
        // design SS3.5: the strip takes NO fill -- it sits on the window background, bounded by hairlines
        // (the Divider below the header, and `disclaimerLine`'s own Divider that follows) top and bottom,
        // exactly like a toolbar-adjacent band. The device-glass cards carry the visual weight instead.
    }

    private func carouselCard(index: Int, row: PageRow) -> some View {
        CarouselCard(model: model, row: row, index: index, width: cardW, isSelected: selection == row.id,
                     isTargeted: targetedCardIndex == index,
                     onSelect: { selection = row.id },
                     onMove: { delta in moveEnabled(id: row.id, delta: delta) },
                     onDisable: { disablePage(row.id) })
            .id(row.id)
            .draggable(row.id)
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first else { return false }
                placeOnCarousel(id: id, atEnabledIndex: index)
                return true
            } isTargeted: { targeted in
                targetedCardIndex = targeted ? index : (targetedCardIndex == index ? nil : targetedCardIndex)
            }
    }

    private var appendDropZone: some View {
        HubShape.card
            .strokeBorder(HubColor.lineHairline, style: StrokeStyle(lineWidth: HubStroke.hairline, dash: [5, 4]))
            .frame(width: 60, height: 150)
            .overlay(Image(systemName: "plus").foregroundStyle(HubColor.inkSecondary))
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first else { return false }
                placeOnCarousel(id: id, atEnabledIndex: nil)
                return true
            }
    }

    // --- the AVAILABLE catalog: the full page set, greyed where already enabled (design SS3.7) ---

    private var availableSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubSpace.m) {
                Text("AVAILABLE").hubEyebrow().foregroundStyle(HubColor.inkSecondary)
                // Trap (plan WS-2 #1): `.adaptive(minimum: 110)` gives exactly three columns at 380 pt --
                // 110*3 + 10*2 + HubSpace.l*2 = 382. The 10 pt gutter below is that exact contract; it is
                // not `HubSpace.s`/`HubSpace.m` and must not be "simplified" onto the ladder.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(model.pageRows) { row in
                        availableTile(row)
                    }
                }
            }
            .padding(HubSpace.l)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
            disablePage(id)
            return true
        }
    }

    private func availableTile(_ row: PageRow) -> some View {
        CatalogTile(title: row.title, detail: row.detail, isEnabled: row.enabled,
                    isSelected: selection == row.id) {
            selection = row.id
            if !row.enabled { placeOnCarousel(id: row.id, atEnabledIndex: nil) }
        }
        .draggable(row.id)
    }

    // --- inspector: bounded, top-aligned, never stretched (design SS5.2) ---

    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let id = selection, let row = model.pageRows.first(where: { $0.id == id }) {
                inspectorHeader(row)
                    .padding(.horizontal, HubSpace.l).padding(.top, HubSpace.m).padding(.bottom, HubSpace.s)
                Divider()
                if row.id == CompLimits.homeFace {
                    ComplicationEditorView(model: model)
                } else {
                    PageOptions(model: model, row: row)
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                EmptyState(systemImage: "list.bullet.rectangle", title: "Select a page",
                           message: "Choose a page to edit its options.")
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 260, idealWidth: 280, maxWidth: 320, alignment: .topLeading)
    }

    private func inspectorHeader(_ row: PageRow) -> some View {
        VStack(alignment: .leading, spacing: HubSpace.xs) {
            HStack(spacing: HubSpace.s) {
                Text(row.title).font(HubType.pane).foregroundStyle(HubColor.inkPrimary)
                if row.pinned { HubBadge("always on") }
                if !row.enabled { HubBadge("hidden") }
            }
            Text(row.detail).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
        }
    }

    // --- footer: two independent staging channels, one commit button (design SS3.11) ---

    private var footer: some View {
        FooterBar(channels: footerChannels) {
            AnyView(footerButtons)
        }
    }

    @ViewBuilder private var footerButtons: some View {
        HStack(spacing: HubSpace.s) {
            if model.pagesDirty || model.compsDirty {
                HubButton(title: "Revert", kind: .secondary) { revertAll() }
            }
            HubButton(title: "Save & push", kind: .primary, prominent: true,
                      isEnabled: model.pagesDirty || model.compsDirty) { saveAll() }
        }
    }

    private var footerChannels: [FooterBar<AnyView>.Channel] {
        var channels: [FooterBar<AnyView>.Channel] = []
        if pagesLine == nil && compsLine == nil {
            channels.append(.init("status", text: "The Beacon is running this configuration.", isDirty: false))
        }
        if let pagesLine {
            channels.append(.init("pages", text: pagesLine, isDirty: model.pagesDirty && model.pageSync == nil))
        }
        if let compsLine {
            channels.append(.init("comps", text: compsLine, isDirty: model.compsDirty && model.compSync == nil))
        }
        return channels
    }

    // A live sync message (post-action confirmation, e.g. "Sent…"/"Saved…") always wins over the dirty
    // preview text for its own channel -- mirrors the single-channel footer this replaces.
    private var pagesLine: String? {
        if let s = model.pageSync { return s }
        if model.pagesDirty { return "Pages changed \u{00B7} the Beacon restarts (~5 s)." }
        return nil
    }
    private var compsLine: String? {
        if let s = model.compSync { return s }
        if model.compsDirty { return "Complications updated \u{00B7} applies immediately." }
        return nil
    }

    // Comps first, pages second (design SS7 / plan item 13): the cheap non-restarting push lands before
    // the one that restarts the device, so if the page push reboots it, the complication blob is already
    // persisted and the device boots showing the right assignment.
    private func saveAll() {
        if model.compsDirty { model.onApplyComps(model.compSlots) }
        if model.pagesDirty { model.onApplyPages(model.enabledPageIDs, model.enabledPageOpts) }
    }

    private func revertAll() {
        model.onRevertComps()
        model.onRevertPages()
    }

    // --- page mutations (mirrors the array-level move(_:) the old carousel used; not pure-kit material --
    // BeaconHubKit.ComplicationEditor owns the RULES that actually need host-testing, per the brief) ---
    //
    // This block is UNCHANGED layout logic (plan WS-2 "what already exists," do not rewrite): only the
    // surrounding view tree moved.

    /// Enable `id` (if it wasn't already) and move it to `targetIndex` among the ENABLED subset (nil =
    /// append at the end). `targetIndex` is a position in the enabled list AS CURRENTLY DISPLAYED -- i.e.
    /// it may still include the dragged row itself, when this is a reorder rather than a fresh enable.
    /// Resolving it to a stable id BEFORE removing anything avoids an off-by-one: removing the dragged
    /// row first would shift every subsequent index down by one, corrupting a numeric target index.
    /// Disabled rows elsewhere in `model.pageRows` keep their relative position -- they don't appear in
    /// the enabled-filtered carousel, so where they sit in the backing array doesn't matter beyond
    /// preserving `enabledPageIDs`'s order for the rows that DO show.
    private func placeOnCarousel(id: String, atEnabledIndex targetIndex: Int?) {
        guard let sourceIndex = model.pageRows.firstIndex(where: { $0.id == id }) else { return }
        let enabledBefore = model.pageRows.filter(\.enabled)
        let targetID: String? = targetIndex.flatMap { enabledBefore.indices.contains($0) ? enabledBefore[$0].id : nil }

        var row = model.pageRows[sourceIndex]
        row.enabled = true
        model.pageRows.remove(at: sourceIndex)

        let insertion: Int
        if let targetID, targetID == id {
            insertion = min(sourceIndex, model.pageRows.count)   // dropped on itself: restore its own spot
        } else if let targetID, let idx = model.pageRows.firstIndex(where: { $0.id == targetID }) {
            insertion = idx
        } else {
            insertion = model.pageRows.count
        }
        model.pageRows.insert(row, at: insertion)
        model.pageSync = nil
        selection = id
    }

    private func disablePage(_ id: String) {
        guard let i = model.pageRows.firstIndex(where: { $0.id == id }), !model.pageRows[i].pinned else { return }
        model.pageRows[i].enabled = false
        model.pageSync = nil
    }

    /// The chevron buttons' path: swap `id` with its enabled-subset neighbour. Kept as the keyboard/
    /// accessibility equivalent to dragging (design SS3.3) -- drag-and-drop with no non-pointer equivalent
    /// is a regression.
    private func moveEnabled(id: String, delta: Int) {
        let ids = enabledRows.map(\.id)
        guard let idx = ids.firstIndex(of: id) else { return }
        let target = idx + delta
        guard ids.indices.contains(target) else { return }
        guard let a = model.pageRows.firstIndex(where: { $0.id == id }),
              let b = model.pageRows.firstIndex(where: { $0.id == ids[target] }) else { return }
        withAnimation(HubMotion.animation(HubMotion.normal, reduceMotion: reduceMotion)) {
            model.pageRows.swapAt(a, b)
        }
        model.pageSync = nil
    }
}

// One enabled page: its device-glass preview, name, and reorder/remove controls (design SS6.2). Title,
// reorder chevrons and remove button sit BELOW the glass on the window background -- the old remove `x`
// was a white-on-black circle drawn ON TOP of the panel, hub chrome painted onto device content, which is
// exactly the lie SS6 exists to prevent. `settings` is pinned (no remove affordance, no drag-out) --
// `PageLimits.alwaysID` already encodes this and the device force-appends it regardless, so showing it as
// removable would be a lie.
private struct CarouselCard: View {
    @ObservedObject var model: HubViewModel
    let row: PageRow
    let index: Int
    let width: CGFloat
    let isSelected: Bool
    let isTargeted: Bool
    let onSelect: () -> Void
    let onMove: (Int) -> Void
    let onDisable: () -> Void

    private var previewSize: CGFloat { width - 30 }

    var body: some View {
        VStack(spacing: HubSpace.s) {
            DeviceGlassPanel(size: previewSize, isSelected: isSelected || isTargeted) {
                DevicePreview(pageID: row.id, model: model, size: previewSize)
            }

            HStack(spacing: HubSpace.xs) {
                Text(row.title).font(HubType.bodyEmph).foregroundStyle(HubColor.inkPrimary).lineLimit(1)
                if row.pinned { HubBadge("always on") }
                Spacer(minLength: HubSpace.xs)
                if !row.pinned {
                    IconButton(systemImage: "xmark.circle.fill", label: "Remove \(row.title) from the Beacon",
                               action: onDisable)
                }
            }

            HStack(spacing: HubSpace.xs) {
                IconButton(systemImage: "chevron.left", label: "Move \(row.title) earlier",
                           isEnabled: index > 0) { onMove(-1) }
                IconButton(systemImage: "chevron.right", label: "Move \(row.title) later") { onMove(1) }
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
