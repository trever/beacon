import XCTest
import SwiftUI
import AppKit
@testable import beacon_hub

// DeviceGlass.swift's device-side additions (design SS6.1/SS6.4, plan WS-7 "device-glass extraction,
// proportions, fonts"). Two jobs:
//
// 1. The four re-derived type-scale constants equal the firmware's real role sizes over the panel's own
//    466 px -- not the eyeballed multipliers this workstream replaced.
// 2. `DeviceGlassFont.resolve` genuinely takes the documented system-fallback path when the bundled face
//    is not registered, and genuinely returns the bundled face once it is -- proven by asking CoreText
//    (`NSFont(name:size:)`) directly and by inspecting which `Font` provider `resolve` actually
//    constructed, not by trusting that registration merely ran without error (plan WS-7 "Traps": "A font
//    registered but not found fails silently to a system fallback that looks almost right").

final class DeviceGlassTests: XCTestCase {

    // MARK: - Type scale (plan WS-7 step 2)

    func testTypeScaleConstantsAreExactlyTheFirmwareRoleSizesOver466() {
        // firmware/src/ui/fonts/MANIFEST.md's role table: mono 15, body 18, display 30, hero 84, all
        // measured against the panel's real 466 px width -- the same four numbers the design doc's SS6.1
        // names explicitly, so this is a literal transcription check, not a derived computation.
        XCTAssertEqual(DeviceType.mono, 15.0 / 466.0)
        XCTAssertEqual(DeviceType.body, 18.0 / 466.0)
        XCTAssertEqual(DeviceType.display, 30.0 / 466.0)
        XCTAssertEqual(DeviceType.hero, 84.0 / 466.0)
    }

    func testTypeScaleConstantsAreDistinctAndAscending() {
        // Not strictly required by the plan, but a scale that collapsed two roles to the same ratio would
        // silently defeat the point of having four constants at all.
        XCTAssertLessThan(DeviceType.mono, DeviceType.body)
        XCTAssertLessThan(DeviceType.body, DeviceType.display)
        XCTAssertLessThan(DeviceType.display, DeviceType.hero)
    }

    // MARK: - Font resolution (plan WS-7 SS6.1 "a fallback is mandatory, not optional")

    /// Recursively walks a `Font`'s opaque provider tree (via `Mirror`) for a `NamedProvider`'s registered
    /// font name -- SwiftUI gives no public API to ask "is this a custom font, and which one", but
    /// `resolve`'s whole contract is which of `.custom`/`.system` it picked. A shallow, one-level check is
    /// not enough: `resolve` chains `.weight(_:)` onto the custom case, which wraps it in a
    /// `ModifierProvider` layer, so the `NamedProvider` (and the PostScript name it carries) is nested one
    /// level deeper than `Font`'s own top-level provider.
    private func customFontName(_ font: Font) -> String? {
        func search(_ mirror: Mirror) -> String? {
            if String(describing: mirror.subjectType).contains("NamedProvider") {
                for child in mirror.children where child.label == "name" {
                    return child.value as? String
                }
            }
            for child in mirror.children {
                if let found = search(Mirror(reflecting: child.value)) { return found }
            }
            return nil
        }
        return search(Mirror(reflecting: font))
    }

    /// The full life cycle in one test (not split across methods) so it never depends on XCTest's
    /// undefined execution order: `CTFontManagerRegisterFontsForURL` is process-global and, once a face
    /// is registered, cannot be un-registered, so "not yet registered" can only be observed before this
    /// test's own registration call runs.
    func testResolveFallsBackToSystemThenReturnsTheBundledFaceOnceRegistered() {
        // Before registration: CoreText genuinely has no font under either PostScript name, so `resolve`
        // must take the documented system-fallback path -- never a `.custom` font pointed at a name
        // CoreText cannot back, which is exactly the "fails silently to a system fallback" trap the plan
        // warns about, just inverted (a `.custom` that LOOKS bundled but isn't).
        if NSFont(name: "SpaceGrotesk-Medium", size: 20) == nil {
            XCTAssertNil(NSFont(name: "JetBrainsMonoRoman-Medium", size: 20))
            XCTAssertNil(customFontName(DeviceGlassFont.resolve(.sans, size: 20)),
                         "resolve(.sans) must fall back to a system Font when the bundled face is not registered")
            XCTAssertNil(customFontName(DeviceGlassFont.resolve(.mono, size: 20)),
                         "resolve(.mono) must fall back to a system Font when the bundled face is not registered")
        }

        // Register the real bundled TTFs straight from the repo's own hub/Resources/fonts/ -- there is no
        // app bundle under `swift test` (Bundle.main is the xctest runner, not Beacon Hub.app), so
        // `DeviceGlassFont.registerBundledFonts()` itself would no-op here, which is expected and is
        // exactly why `resolve` re-checks CoreText on every call rather than caching a "did register" bit.
        DeviceGlassFont.registerFonts(in: repoFontsDirectory)

        XCTAssertNotNil(NSFont(name: "SpaceGrotesk-Medium", size: 20),
                         "Space Grotesk did not register under the PostScript name resolve() looks up")
        XCTAssertNotNil(NSFont(name: "JetBrainsMonoRoman-Medium", size: 20),
                         "JetBrains Mono did not register under the PostScript name resolve() looks up")

        XCTAssertEqual(customFontName(DeviceGlassFont.resolve(.sans, size: 20)), "SpaceGrotesk-Medium",
                       "resolve(.sans) must return the bundled face once it is registered, not the fallback")
        XCTAssertEqual(customFontName(DeviceGlassFont.resolve(.mono, size: 20)), "JetBrainsMonoRoman-Medium",
                       "resolve(.mono) must return the bundled face once it is registered, not the fallback")
    }

    /// `hub/Resources/fonts/`, located relative to this test file rather than `Bundle.main` (which has no
    /// fonts under `swift test`) -- mirrors how `Package.swift` locates its own package directory via
    /// `#filePath` for the same reason.
    private var repoFontsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DeviceGlassTests.swift -> beacon-hubTests/
            .deletingLastPathComponent()   // beacon-hubTests/ -> Tests/
            .deletingLastPathComponent()   // Tests/ -> hub/
            .appendingPathComponent("Resources/fonts", isDirectory: true)
    }
}
