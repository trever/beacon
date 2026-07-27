// The Settings window's close-confirmation policy (design SS4.3 "Approved: the close sheet", plan SS1
// WS-1 step 6). Pure and host-testable on purpose: whether closing the window needs confirmation, and
// what a chosen button does, is a fact about two booleans and a three-way choice -- it does not need an
// NSAlert, an NSWindow, or a running app to be correct, so it does not live behind one.
//
// `SettingsWindowController.windowWillClose` used to silently revert staged page and complication edits
// on every close. Now that `window.isDocumentEdited` tells the user there is unsaved work (design SS4.3),
// closing without asking is a visible data-loss path, so `windowShouldClose` presents a three-button sheet
// instead. This file is the state machine behind those three buttons; the window controller only carries
// out the effects it returns.

/// The three buttons on the close-confirmation sheet.
enum CloseIntent {
    case saveAndPush
    case discard
    case cancel
}

/// What a chosen intent actually does, in the order it must happen. `SettingsWindowController` executes
/// these one at a time; nothing here touches AppKit or `HubViewModel` directly.
enum CloseEffect: Equatable {
    case applyComps
    case applyPages
    case revertComps
    case revertPages
    case close
    case stayOpen
}

/// The pure policy. Every function takes the same two facts -- whether pages are staged-dirty, whether
/// complications are staged-dirty -- because both channels live under the one sidebar destination that can
/// go dirty today (design SS4.3).
enum SettingsClosePolicy {
    /// Whether `windowShouldClose` must stop and show the sheet rather than letting AppKit close the
    /// window immediately.
    static func needsConfirmation(pagesDirty: Bool, compsDirty: Bool) -> Bool {
        pagesDirty || compsDirty
    }

    /// `window.isDocumentEdited`'s value (design SS4.3, item 1). Kept as its own named entry point, even
    /// though it is the same disjunction as `needsConfirmation`, because the two answer different
    /// questions that only currently happen to share a formula: one drives a title-bar dot visible from
    /// every destination, the other gates whether closing needs to ask. A future channel could dirty the
    /// window without needing close confirmation (or vice versa) without this file's callers needing to
    /// know that changed.
    static func documentEdited(pagesDirty: Bool, compsDirty: Bool) -> Bool {
        pagesDirty || compsDirty
    }

    /// The ordered effects for a chosen intent.
    ///
    /// `.saveAndPush` mirrors `PageDesignerView.saveAll()` exactly: apply comps before pages (design SS7)
    /// -- the live, non-restarting push lands before the one that reboots the device -- and only for the
    /// channel that is actually dirty. This is the one place in the codebase that ordering exists twice;
    /// the test suite is what keeps the two in sync.
    ///
    /// `.discard` mirrors `PageDesignerView.revertAll()`: both channels are reverted unconditionally,
    /// comps before pages, regardless of which one is dirty -- reverting a clean channel is already a
    /// no-op there, so this matches the existing footer-bar behaviour rather than inventing a leaner one.
    ///
    /// `.cancel` never touches either channel. It leaves every staged edit exactly as it was and keeps the
    /// window open -- there is nothing for the caller to apply or revert.
    static func effects(for intent: CloseIntent, pagesDirty: Bool, compsDirty: Bool) -> [CloseEffect] {
        switch intent {
        case .cancel:
            return [.stayOpen]

        case .discard:
            return [.revertComps, .revertPages, .close]

        case .saveAndPush:
            var effects: [CloseEffect] = []
            if compsDirty { effects.append(.applyComps) }
            if pagesDirty { effects.append(.applyPages) }
            effects.append(.close)
            return effects
        }
    }
}
