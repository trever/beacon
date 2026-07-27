import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import beacon_hub

// Host-tested, offline, no network (same convention as SonosAPITests/SonosOAuthTests): the pure
// decode -> letterbox -> big-endian-RGB565 -> hash pipeline in SonosArtRenderer, plus the request-building
// half of the security rules in design 2026-07-27-sonos-album-art-design §6.2/§6.3 (no OAuth header, no
// non-http(s) scheme). fetchAndRender's URLSession glue itself is not exercised here, matching how
// SonosOAuth's exchange()/refresh() POSTs are left to integration -- only parseTokenResponse is tested.
final class SonosArtRendererTests: XCTestCase {

    // --- request building: the security rules, asserted, not just argued (design §6.2/§6.3) ---

    func testBuildRequestRejectsNonHTTPSchemes() {
        XCTAssertNil(SonosArtRenderer.buildRequest(for: URL(string: "file:///etc/passwd")!))
        XCTAssertNil(SonosArtRenderer.buildRequest(for: URL(string: "data:image/png;base64,AAAA")!))
        XCTAssertNil(SonosArtRenderer.buildRequest(for: URL(string: "ftp://example.com/a.jpg")!))
    }

    func testBuildRequestAcceptsHTTPAndHTTPS() {
        XCTAssertNotNil(SonosArtRenderer.buildRequest(for: URL(string: "https://cdn.example.com/a.jpg")!))
        XCTAssertNotNil(SonosArtRenderer.buildRequest(for: URL(string: "http://192.168.1.50:1400/getaa")!))
    }

    // The load-bearing security assertion: this request must never carry the Sonos bearer token. Unlike
    // SonosProvider.api(path:completion:), which unconditionally attaches "Authorization: Bearer ...",
    // this path must not -- a third-party CDN host named by untrusted JSON must never see the credential.
    func testBuildRequestCarriesNoAuthorizationHeader() {
        let req = SonosArtRenderer.buildRequest(for: URL(string: "https://cdn.example.com/a.jpg")!)
        XCTAssertNil(req?.value(forHTTPHeaderField: "Authorization"))
    }

    func testBuildRequestUsesTheFiveSecondTimeout() {
        let req = SonosArtRenderer.buildRequest(for: URL(string: "https://cdn.example.com/a.jpg")!)
        XCTAssertEqual(req?.timeoutInterval, 5)
    }

    // --- render(): shape/size invariants ---

    func testRenderReturnsNilForGarbageBytes() {
        XCTAssertNil(SonosArtRenderer.render(imageData: Data("not an image".utf8)))
        XCTAssertNil(SonosArtRenderer.render(imageData: Data()))
    }

    func testRenderProducesExactlyEightyThousandBytes() {
        let image = solidColorImage(width: 64, height: 64, r: 100, g: 150, b: 200)
        let tile = SonosArtRenderer.render(cgImage: image)
        XCTAssertEqual(tile?.pixels.count, 80_000)
        XCTAssertEqual(tile?.pixels.count, SonosArtRenderer.Tile.byteCount)
    }

    // --- the byte-order trap (design §1.4, §10 risk 3): byte-exact over known pixels ---
    //
    // A source image exactly 200x200 makes the aspect-fit a no-op (scale 1.0, zero letterbox), so source
    // pixel (x, 0) maps 1:1 onto tile row 0 at that x -- isolating the RGB565 conversion + byte-order logic
    // from the separately-tested letterbox/scale behavior below.
    func testRenderBigEndianRGB565FourKnownPixelsPlusOneMixed() {
        let pixels: [(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8)] = [
            (0, 0, 255, 0, 0),      // pure red
            (1, 0, 0, 255, 0),      // pure green
            (2, 0, 0, 0, 255),      // pure blue
            (3, 0, 255, 128, 64),   // mixed
            (4, 0, 0, 0, 0),        // black -- also §1.4's frozen 4th sample, and the letterbox colour
        ]
        let image = testImage(width: 200, height: 200, pixels: pixels, background: (0, 0, 0))
        guard let tile = SonosArtRenderer.render(cgImage: image) else { return XCTFail("render returned nil") }

        func bytes(atPixel x: Int) -> [UInt8] {
            let off = x * 2   // row 0, so byte offset == x * bytesPerPixel
            return [tile.pixels[off], tile.pixels[off + 1]]
        }
        XCTAssertEqual(bytes(atPixel: 0), [0xF8, 0x00], "pure red")
        XCTAssertEqual(bytes(atPixel: 1), [0x07, 0xE0], "pure green")
        XCTAssertEqual(bytes(atPixel: 2), [0x00, 0x1F], "pure blue")
        XCTAssertEqual(bytes(atPixel: 3), [0xFC, 0x08], "mixed (255,128,64)")
        XCTAssertEqual(bytes(atPixel: 4), [0x00, 0x00], "black")
    }

    // Vertical-orientation sanity: a wrong row order would look "plausible but scrambled" exactly like a
    // wrong byte order would (design §1.4's stated failure mode), so it gets the same explicit pixel-level
    // proof rather than an assumption. Top half red, bottom half blue, exact 200x200 (no scaling).
    func testRenderTopRowIsVisualTopNotBottom() {
        var pixels: [(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8)] = []
        for x in 0..<200 {
            pixels.append((x, 0, 255, 0, 0))      // visual top row: red
            pixels.append((x, 199, 0, 0, 255))    // visual bottom row: blue
        }
        let image = testImage(width: 200, height: 200, pixels: pixels, background: (0, 0, 0))
        guard let tile = SonosArtRenderer.render(cgImage: image) else { return XCTFail("render returned nil") }

        let topRowOffset = 0
        let bottomRowOffset = 199 * 200 * 2
        XCTAssertEqual([tile.pixels[topRowOffset], tile.pixels[topRowOffset + 1]], [0xF8, 0x00],
                       "tile row 0 must be the visual top (red), not the bottom")
        XCTAssertEqual([tile.pixels[bottomRowOffset], tile.pixels[bottomRowOffset + 1]], [0x00, 0x1F],
                       "tile row 199 must be the visual bottom (blue)")
    }

    // --- letterbox / aspect-fit (design §3.1, §11 Q5: letterbox, never crop) ---

    func testRenderLetterboxesWideSourceWithBlackBarsTopAndBottom() {
        // 400x200 (2:1): scale = min(200/400, 200/200) = 0.5 -> drawn 200x100, centred -> a 50px black
        // bar above and below.
        let image = solidColorImage(width: 400, height: 200, r: 255, g: 255, b: 255)
        guard let tile = SonosArtRenderer.render(cgImage: image) else { return XCTFail("render returned nil") }

        func pixel(x: Int, y: Int) -> [UInt8] {
            let off = (y * 200 + x) * 2
            return [tile.pixels[off], tile.pixels[off + 1]]
        }
        XCTAssertEqual(pixel(x: 100, y: 0), [0x00, 0x00], "top letterbox bar must be pure black")
        XCTAssertEqual(pixel(x: 100, y: 199), [0x00, 0x00], "bottom letterbox bar must be pure black")
        XCTAssertEqual(pixel(x: 100, y: 100), [0xFF, 0xFF], "centre must be the source's white, RGB565 0xFFFF")
    }

    func testRenderNeverCropsAndAlwaysProduces200x200RegardlessOfSourceAspect() {
        for (w, h) in [(50, 50), (400, 200), (200, 400), (37, 501), (1000, 1)] {
            let image = solidColorImage(width: w, height: h, r: 10, g: 20, b: 30)
            let tile = SonosArtRenderer.render(cgImage: image)
            XCTAssertEqual(tile?.pixels.count, 80_000, "source \(w)x\(h) must still produce a full 200x200 tile")
        }
    }

    func testRenderUpscalesSmallSquareSourceToFillWithNoLetterbox() {
        let image = solidColorImage(width: 20, height: 20, r: 255, g: 0, b: 255)
        guard let tile = SonosArtRenderer.render(cgImage: image) else { return XCTFail("render returned nil") }
        // A square source into a square target has zero letterbox -- every corner should be the source
        // colour, not black.
        func pixel(x: Int, y: Int) -> [UInt8] {
            let off = (y * 200 + x) * 2
            return [tile.pixels[off], tile.pixels[off + 1]]
        }
        let expected: [UInt8] = [0xF8, 0x1F]   // (255,0,255) -> r5=31,g6=0,b5=31 -> 0xF81F
        XCTAssertEqual(pixel(x: 0, y: 0), expected)
        XCTAssertEqual(pixel(x: 199, y: 199), expected)
    }

    // --- hashing (feeds the design §5 URL-then-tile-digest cache; not wired into SonosProvider in Phase A) ---

    func testRenderHashIsDeterministic() {
        let image = solidColorImage(width: 64, height: 64, r: 9, g: 9, b: 9)
        let a = SonosArtRenderer.render(cgImage: image)
        let b = SonosArtRenderer.render(cgImage: image)
        XCTAssertEqual(a?.sha256Hex, b?.sha256Hex)
        XCTAssertEqual(a?.sha256Hex.count, 64, "sha256 hex digest is 64 chars")
    }

    func testRenderHashDiscriminatesDifferentPixels() {
        // RGB565 keeps only 5/6/5 bits per channel, so two 8-bit colours must differ by enough to land in
        // different buckets (a blue channel of 1 vs 2 would both floor to RGB565 level 0 and produce an
        // identical tile+hash by design, not by bug) -- these differ by 64 in blue, well past one bucket
        // (8 levels of 8-bit blue per RGB565 level).
        let a = SonosArtRenderer.render(cgImage: solidColorImage(width: 64, height: 64, r: 1, g: 2, b: 3))
        let b = SonosArtRenderer.render(cgImage: solidColorImage(width: 64, height: 64, r: 1, g: 2, b: 67))
        XCTAssertNotEqual(a?.sha256Hex, b?.sha256Hex)
    }

    // --- end-to-end through a real PNG codec round-trip (decode is ImageIO's, not hand-rolled -- §6.3) ---

    func testRenderImageDataDecodesARealPNGRoundTrip() throws {
        let image = solidColorImage(width: 80, height: 80, r: 20, g: 200, b: 40)
        let pngData = try encodePNG(image)
        guard let tile = SonosArtRenderer.render(imageData: pngData) else { return XCTFail("render(imageData:) returned nil") }
        XCTAssertEqual(tile.pixels.count, 80_000)
        // Square source at any size letterboxes to zero bars -- corner must be the source colour, RGB565
        // (20,200,40) -> r5=2,g6=50,b5=5 -> value = (2<<11)|(50<<5)|5 = 4096+1600+5 = 5701 = 0x1645.
        XCTAssertEqual([tile.pixels[0], tile.pixels[1]], [0x16, 0x45])
    }

    // --- "make it visible" (task step 4): render a demo tile and write BOTH the raw BE-RGB565 bytes and
    // a re-decoded PNG preview to a known, inspectable path. Fully offline/deterministic (a generated
    // pattern, not network) so it runs safely as part of the ordinary `swift test` suite. See this repo's
    // agent report for the exact path and a second, real-photograph demo produced out-of-band. ---

    func testWritesVisiblePreviewOfARenderedTile() throws {
        // A synthetic "cover" -- a few solid blocks plus a circle -- distinct enough from a blank swatch
        // to make the letterbox/aspect-fit/colour pipeline visually checkable at a glance, run through the
        // exact same non-square-source path testRenderLetterboxesWideSourceWithBlackBars exercises.
        let source = demoCoverImage(width: 500, height: 260)
        guard let tile = SonosArtRenderer.render(cgImage: source) else { return XCTFail("render returned nil") }
        XCTAssertEqual(tile.pixels.count, 80_000)

        let outDir = previewDirectory()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        try tile.pixels.write(to: outDir.appendingPathComponent("tile.rgb565be"))

        let decoded = decodeBigEndianRGB565(tile.pixels, width: 200, height: 200)
        let pngURL = outDir.appendingPathComponent("tile-preview.png")
        try encodePNG(decoded, to: pngURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: pngURL.path))
    }

    // MARK: - test image builders (construct INPUT images independently of the renderer under test)

    private func previewDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/beacon-hubTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // hub
            .appendingPathComponent("sonos-art-preview", isDirectory: true)
    }

    private func makeContext(width: Int, height: Int) -> CGContext {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: colorSpace, bitmapInfo: bitmapInfo)!
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none
        return ctx
    }

    private func solidColorImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        ctx.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    // `pixels` are specified in VISUAL coordinates (y=0 is the top, matching how a human describes an
    // image) and flipped into CGContext's bottom-up space here -- independent of, and not reused from,
    // SonosArtRenderer's own flip logic, so this is a genuine cross-check rather than a tautology.
    private func testImage(width: Int, height: Int, pixels: [(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8)],
                           background: (UInt8, UInt8, UInt8)) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        ctx.setFillColor(red: CGFloat(background.0) / 255, green: CGFloat(background.1) / 255,
                         blue: CGFloat(background.2) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for p in pixels {
            ctx.setFillColor(red: CGFloat(p.r) / 255, green: CGFloat(p.g) / 255, blue: CGFloat(p.b) / 255, alpha: 1)
            let cgY = height - 1 - p.y
            ctx.fill(CGRect(x: p.x, y: cgY, width: 1, height: 1))
        }
        return ctx.makeImage()!
    }

    private func demoCoverImage(width: Int, height: Int) -> CGImage {
        let ctx = makeContext(width: width, height: height)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        // Deep-blue background, an orange disc, and a cream stripe -- a plausible-looking "cover".
        ctx.setFillColor(red: 0.08, green: 0.10, blue: 0.30, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1)
        let r = CGFloat(min(width, height)) * 0.32
        ctx.fillEllipse(in: CGRect(x: CGFloat(width) / 2 - r, y: CGFloat(height) / 2 - r, width: r * 2, height: r * 2))
        ctx.setFillColor(red: 0.96, green: 0.94, blue: 0.86, alpha: 1)
        ctx.fill(CGRect(x: 0, y: CGFloat(height) * 0.86, width: CGFloat(width), height: CGFloat(height) * 0.06))
        return ctx.makeImage()!
    }

    // MARK: - PNG encode/decode helpers (verification only, not the code under test)

    @discardableResult
    private func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw XCTSkip("CGImageDestination unavailable")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("PNG finalize failed") }
        return data as Data
    }

    private func encodePNG(_ image: CGImage, to url: URL) throws {
        let data = try encodePNG(image)
        try data.write(to: url)
    }

    // Reverses SonosArtRenderer's own conversion (big-endian RGB565 -> 8-bit RGB) purely for producing a
    // human-viewable preview PNG -- deliberately re-derived here rather than calling anything in
    // SonosArtRenderer, so a bug in the renderer's conversion isn't masked by decoding with the same code.
    private func decodeBigEndianRGB565(_ pixels: Data, width: Int, height: Int) -> CGImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            for i in 0..<(width * height) {
                let hi = UInt16(p[i * 2]), lo = UInt16(p[i * 2 + 1])
                let value = (hi << 8) | lo
                let r5 = (value >> 11) & 0x1F
                let g6 = (value >> 5) & 0x3F
                let b5 = value & 0x1F
                rgba[i * 4 + 0] = UInt8((r5 * 255) / 31)
                rgba[i * 4 + 1] = UInt8((g6 * 255) / 63)
                rgba[i * 4 + 2] = UInt8((b5 * 255) / 31)
                rgba[i * 4 + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: colorSpace, bitmapInfo: bitmapInfo)!
        return ctx.makeImage()!
    }
}
