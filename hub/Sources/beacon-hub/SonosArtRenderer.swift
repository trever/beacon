import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

// Fetches Sonos/CDN album art and rasterises it to the frozen device tile format
// (docs/specs/2026-07-27-sonos-album-art-design.md §1, §3.1, §6): 200x200, big-endian RGB565, row-major,
// header-less, 80,000 bytes. Kept as its own type, deliberately separate from `LanAssetServer` (not built
// in this phase -- Phase B) and from SonosProvider's poll pipeline, so the LAN server that will eventually
// serve this tile never contains rasterising logic (design §1.5: "the server must never learn what a
// pixel is").
//
// Phase A scope (design §9): prove the pipeline end-to-end on the hub only -- no device, no BLE, no LAN
// server. `render(imageData:)`/`render(cgImage:)` are the pure, host-tested half (decode -> aspect-fit
// letterbox -> big-endian RGB565 -> SHA-256); `fetchAndRender(url:)` is thin network glue over it and is
// deliberately NOT fixture-tested with a live network call, matching this codebase's existing convention
// (SonosOAuth, SonosProvider.api) of unit-testing the pure logic and leaving URLSession plumbing itself to
// integration/manual verification.
enum SonosArtRenderer {

    // --- the frozen tile format (design §3.1, §1) ---

    struct Tile: Equatable {
        static let width = 200
        static let height = 200
        static let byteCount = width * height * 2   // 80,000 -- big-endian RGB565, row-major, header-less

        let pixels: Data       // exactly `byteCount` bytes
        let sha256Hex: String  // hex digest of `pixels` -- feeds the design's URL-then-tile-digest cache (§5)
    }

    enum FetchError: Error, Equatable {
        case invalidScheme
        case tooLarge(Int)
        case httpStatus(Int)
        case network(String)
        case decodeFailed
    }

    // --- network: fetch the art (design §6.2 -- this must NEVER carry the Sonos OAuth credential) ---

    static let maxDownloadBytes = 4 * 1024 * 1024   // design §6.3
    static let fetchTimeout: TimeInterval = 5        // design §6.3

    // Only http/https may be fetched -- reject file:, data:, everything else before any network attempt
    // (design §6.3: "Scheme must be http or https. Reject file:, data:, everything else.").
    static func isFetchable(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }

    // Builds the outbound request. Deliberately carries NO Authorization header, and this is deliberately
    // never built from SonosProvider.api() (which unconditionally attaches the Sonos bearer token --
    // SonosProvider.swift's `api(path:completion:)`) -- design §6.2: the hub must not send its Sonos
    // credential to a third-party CDN host named by an untrusted JSON field. Returns nil for a non-http(s)
    // scheme so a caller cannot accidentally dispatch one.
    static func buildRequest(for url: URL) -> URLRequest? {
        guard isFetchable(url) else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: fetchTimeout)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        return req
    }

    // Fetches + rasterises in one call. `configuration` defaults to `.ephemeral` (no cookies, no shared
    // cache -- this is a one-shot, unauthenticated GET at a CDN, not a session). Enforces the download cap
    // and the http(s)-only redirect rule via `BoundedDownloadDelegate` below, on the wire, not after the
    // fact.
    static func fetchAndRender(url: URL, configuration: URLSessionConfiguration = .ephemeral,
                               completion: @escaping (Result<Tile, FetchError>) -> Void) {
        guard let request = buildRequest(for: url) else {
            completion(.failure(.invalidScheme))
            return
        }
        let delegate = BoundedDownloadDelegate(maxBytes: maxDownloadBytes) { result in
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let data):
                guard let tile = render(imageData: data) else {
                    completion(.failure(.decodeFailed))
                    return
                }
                completion(.success(tile))
            }
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.session = session   // deliberate retain cycle: keeps both alive until finish() breaks it
        session.dataTask(with: request).resume()
    }

    // --- pure: decode + letterbox + convert (host-tested, no network) ---

    // Decodes arbitrary image bytes via ImageIO -- JPEG/PNG/WebP/HEIC, whatever decoders are installed,
    // deliberately never a hand-rolled parser (design §6.3) -- aspect-fits into 200x200 letterboxed on
    // pure black (design §3.1: never crop), and converts to big-endian RGB565, row-major (design §1.4).
    // Returns nil for anything that is not a decodable image.
    static func render(imageData: Data) -> Tile? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return render(cgImage: cgImage)
    }

    // Not private: SonosArtRendererTests exercises this directly against synthetic CGImages built with
    // exact known pixels, the same way SonosAPITests exercises SonosAPI's parsers directly against
    // synthetic JSON, so the byte-exact assertions are not entangled with a JPEG/PNG codec round-trip.
    static func render(cgImage: CGImage) -> Tile? {
        let w = Tile.width, h = Tile.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // RGBX, 8 bits/component, big-endian 32-bit words -- a fixed, host-independent byte layout
        // (R,G,B,pad per pixel) regardless of the arm64 host's native (little) endianness.
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: colorSpace, bitmapInfo: bitmapInfo)
        else { return nil }
        ctx.interpolationQuality = .high

        // Pure black background -- the letterbox bars (design §3.1: "pads with pure black"; this is also
        // the panel's AMOLED off-pixel and §1.4's frozen black sample, 0x00 0x00).
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Aspect-fit, centred -- never crop (design's settled decision, §11 Q5). Upscaling a small source
        // is allowed and expected (design §3.1: "a slightly soft tile is a better outcome than a protocol
        // with variable dimensions").
        let sw = CGFloat(cgImage.width), sh = CGFloat(cgImage.height)
        guard sw > 0, sh > 0 else { return nil }
        let scale = min(CGFloat(w) / sw, CGFloat(h) / sh)
        let drawW = sw * scale, drawH = sh * scale
        let drawX = (CGFloat(w) - drawW) / 2, drawY = (CGFloat(h) - drawH) / 2
        ctx.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

        guard let raw = ctx.data else { return nil }
        let srcBuf = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // Big-endian RGB565, row-major, top row first. Verified empirically (testRenderTopRowIsVisualTopNotBottom):
        // although CG's DRAWING coordinate space is bottom-up (y=0 at the bottom, matching PDF/PostScript
        // convention -- which is why the background fill and the aspect-fit rect above use that space),
        // the bitmap context's underlying MEMORY BUFFER is already top-down row-major -- buffer row 0 is
        // the visual top of what was drawn. No row reversal is needed or wanted here; an earlier version
        // of this code added one "for symmetry" and it was backwards, silently producing a
        // vertically-flipped tile that still looked like a plausible fully-rendered image at a glance --
        // exactly the class of bug design §1.4 warns endianness mistakes produce, just on the other axis.
        var pixels = Data(count: Tile.byteCount)
        pixels.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            let outPtr = out.bindMemory(to: UInt8.self)
            for outRow in 0..<h {
                let srcRowStart = outRow * w * 4
                let outRowStart = outRow * w * 2
                for x in 0..<w {
                    let sOff = srcRowStart + x * 4
                    let r = srcBuf[sOff], g = srcBuf[sOff + 1], b = srcBuf[sOff + 2]
                    let r5 = UInt16(r >> 3), g6 = UInt16(g >> 2), b5 = UInt16(b >> 3)
                    let value = (r5 << 11) | (g6 << 5) | b5
                    let oOff = outRowStart + x * 2
                    outPtr[oOff] = UInt8(value >> 8)          // high byte first -- big-endian (LV_COLOR_16_SWAP)
                    outPtr[oOff + 1] = UInt8(value & 0xFF)
                }
            }
        }

        let digest = SHA256.hash(data: pixels)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Tile(pixels: pixels, sha256Hex: hex)
    }
}

// Minimal bounded-download URLSessionDataDelegate: aborts once the response exceeds `maxBytes` as bytes
// arrive (design §6.3's 4MB cap, enforced on the wire rather than after the whole body has landed) and
// refuses to follow a redirect to a non-http(s) scheme (§6.3). Exactly-once completion, guarded by a lock
// since URLSession delegate callbacks can race a cancel against a completion.
private final class BoundedDownloadDelegate: NSObject, URLSessionDataDelegate {
    private let maxBytes: Int
    private var buffer = Data()
    private var status = -1
    private let completion: (Result<Data, SonosArtRenderer.FetchError>) -> Void
    private let lock = NSLock()
    private var finished = false
    var session: URLSession?   // see fetchAndRender: deliberate retain cycle, broken here on completion

    init(maxBytes: Int, completion: @escaping (Result<Data, SonosArtRenderer.FetchError>) -> Void) {
        self.maxBytes = maxBytes
        self.completion = completion
    }

    private func finish(_ result: Result<Data, SonosArtRenderer.FetchError>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        completion(result)
        session?.finishTasksAndInvalidate()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? -1
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        if buffer.count > maxBytes {
            dataTask.cancel()
            finish(.failure(.tooLarge(buffer.count)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(.network(error.localizedDescription)))   // no-op if already finished (e.g. tooLarge's cancel)
            return
        }
        guard (200..<300).contains(status) else {
            finish(.failure(.httpStatus(status)))
            return
        }
        finish(.success(buffer))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let scheme = request.url?.scheme, scheme == "http" || scheme == "https" else {
            completionHandler(nil)
            finish(.failure(.invalidScheme))
            return
        }
        completionHandler(request)
    }
}
