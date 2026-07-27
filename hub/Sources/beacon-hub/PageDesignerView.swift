import SwiftUI
import BeaconHubKit

// The device's page set, laid out the way the device lays it out: a horizontal run of panels you scroll
// through, each one enable/disable-able and reorderable in place. Replaces the checkbox list that lived
// in Settings.
//
// Editing STAGES. Applying restarts the Beacon (~5 s), so "Save & push" is one deliberate action rather
// than a push per checkbox; the button is live only when the list actually differs from what the device
// is running.
struct PageDesignerView: View {
    @ObservedObject var model: HubViewModel
    @State private var selection: String?

    private let cardW: CGFloat = 250

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            carousel
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { if selection == nil { selection = model.pageRows.first?.id } }
    }

    // --- header ---

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Device pages").font(.system(size: 15, weight: .semibold))
                Text("Scroll the pages as they appear on the Beacon. Toggle what shows, drag the arrows to reorder.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.enabledPageIDs.count) of \(model.pageRows.count)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // --- carousel ---

    private var carousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                cards
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
            }
            // Single-parameter onChange: the package deploys to macOS 13, where the two-parameter
            // overload does not exist. Keeps the moved card in view when reordering pushes it past the fold.
            .onChange(of: model.pageRows.map(\.id)) { _ in
                if let sel = selection { withAnimation { proxy.scrollTo(sel, anchor: .center) } }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var cards: some View {
        HStack(spacing: 18) {
            ForEach(Array(model.pageRows.enumerated()), id: \.element.id) { pair in
                card(index: pair.offset, row: pair.element)
            }
        }
    }

    private func card(index: Int, row: PageRow) -> some View {
        PageCard(model: model, row: row, index: index, width: cardW, isSelected: selection == row.id)
            .id(row.id)
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection = row.id } }
    }

    // --- footer ---

    private var footer: some View {
        HStack(spacing: 10) {
            statusIcon
            Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.pagesDirty {
                DeckButton(title: "Revert") { model.onRevertPages() }
            }
            DeckButton(title: "Save & push") { model.onApplyPages(model.enabledPageIDs, model.enabledPageOpts) }
                .disabled(!model.pagesDirty)
                .opacity(model.pagesDirty ? 1 : 0.4)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var statusIcon: some View {
        if model.pageSync != nil {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if model.pagesDirty {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
        } else {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
        }
    }

    private var statusText: String {
        if let s = model.pageSync { return s }
        if model.pagesDirty { return "Unsaved changes. The Beacon restarts when you push (about 5 seconds)." }
        return "The Beacon is running this page set."
    }
}

// One page: its panel preview, name, enable switch and reorder arrows.
private struct PageCard: View {
    @ObservedObject var model: HubViewModel
    let row: PageRow
    let index: Int
    let width: CGFloat
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                DevicePreview(pageID: row.id, model: model, size: width - 30)
                    .saturation(row.enabled ? 1 : 0)
                    .opacity(row.enabled ? 1 : 0.32)
                if !row.enabled {
                    Text("hidden").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(8)
                }
            }
            .padding(.top, 4)

            HStack(spacing: 6) {
                Text(row.title).font(.system(size: 13, weight: .semibold))
                if row.pinned {
                    Text("always on").font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
            }
            Text(row.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(2)
                .frame(height: 26, alignment: .top)

            PageOptions(model: model, row: row)
                .padding(.horizontal, 10)

            HStack(spacing: 8) {
                arrow("chevron.left", enabled: index > 0) { move(-1) }
                Toggle("", isOn: Binding(
                    get: { row.enabled },
                    set: { on in
                        guard let i = model.pageRows.firstIndex(where: { $0.id == row.id }) else { return }
                        model.pageRows[i].enabled = on
                        model.pageSync = nil
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(row.pinned)
                    .help(row.pinned ? "The Beacon always keeps Settings reachable" : "")
                arrow("chevron.right", enabled: index < model.pageRows.count - 1) { move(1) }
            }
            .padding(.bottom, 4)
        }
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.18),
                              lineWidth: isSelected ? 2 : 1)
        )
    }

    private func arrow(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless).disabled(!enabled).opacity(enabled ? 0.75 : 0.2)
    }

    private func move(_ delta: Int) {
        let to = index + delta
        guard model.pageRows.indices.contains(index), model.pageRows.indices.contains(to) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { model.pageRows.swapAt(index, to) }
        model.pageSync = nil
    }
}

// Per-page settings. Only the chart has any today; the rest say so plainly rather than showing an empty
// well that reads like something failed to load.
private struct PageOptions: View {
    @ObservedObject var model: HubViewModel
    let row: PageRow

    var body: some View {
        Group {
            if row.id == "chart" { chartPicker } else { none }
        }
        .frame(height: 24)
    }

    private var none: some View {
        Text("No options").font(.system(size: 10)).foregroundStyle(.secondary.opacity(0.6))
    }

    // The chart follows a TICKER ID from the configured list, not a typed symbol: the device resolves
    // the Yahoo symbol and display name from that row, so there is nothing free-form to mistype.
    // Binance rows are excluded -- the chart fetch speaks the Yahoo API only.
    private var eligible: [TickerRow] { model.tickerRows.filter { $0.src == .yahoo } }

    /// The stored instrument, when it is no longer in the ticker list. Offered as its own (marked) entry
    /// so it round-trips: silently resolving it to a DIFFERENT instrument would make the picker read as
    /// though the user had chosen that one, and one Save & push later it would be true.
    private var orphan: String? {
        guard let sym = row.opts["sym"], !sym.isEmpty,
              !eligible.contains(where: { $0.id == sym }) else { return nil }
        return sym
    }

    @ViewBuilder private var chartPicker: some View {
        if eligible.isEmpty {
            Text("No Yahoo tickers configured").font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
            Picker("", selection: Binding(
                get: { row.opts["sym"] ?? defaultSym },
                set: { newValue in
                    guard let i = model.pageRows.firstIndex(where: { $0.id == row.id }) else { return }
                    model.pageRows[i].opts["sym"] = newValue
                    model.pageSync = nil
                })) {
                    if let orphan {
                        Text("\(orphan) (not in ticker list)").tag(orphan)
                    }
                    ForEach(eligible, id: \.id) { t in
                        Text(t.name.isEmpty ? t.sym : t.name).tag(t.id)
                    }
                }
                .labelsHidden().controlSize(.small).disabled(!row.enabled)
        }
    }

    /// Matches CHART_TICKER_ID in the firmware: what the device falls back to when no option is set.
    private var defaultSym: String {
        eligible.contains { $0.id == "sp500" } ? "sp500" : (eligible.first?.id ?? "")
    }
}
