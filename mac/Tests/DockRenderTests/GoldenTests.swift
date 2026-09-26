import CoreGraphics
import DockCore
import Foundation
import ImageIO
import Testing
@testable import DockRender

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures")
let renderData = fixtures.appending(path: "render-data")

struct GoldenFrame: Decodable, CustomTestStringConvertible, Sendable {
    let format: String, background: String, name: String, t: Double, path: String
    var testDescription: String { "\(format)-\(background)-\(name)" }
}

let goldens: [GoldenFrame] = {
    struct File: Decodable { let frames: [GoldenFrame] }
    let data = try! Data(contentsOf: fixtures.appending(path: "golden.json"))
    return try! JSONDecoder().decode(File.self, from: data).frames
}()

/// RGBA8 pixels of an image scaled to w×h.
func pixels(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return buf
}

struct Difference {
    let mean: Double  // mean absolute RGB difference, 0–255
    let worstBlock: Double  // the worst 16×16 block's mean difference
}

func compare(_ a: [UInt8], _ b: [UInt8], _ w: Int, _ h: Int, block: Int = 16) -> Difference {
    var total = 0.0, worst = 0.0
    for by in stride(from: 0, to: h, by: block) {
        for bx in stride(from: 0, to: w, by: block) {
            var sum = 0.0, n = 0
            for y in by..<min(h, by + block) {
                for x in bx..<min(w, bx + block) {
                    let i = (y * w + x) * 4
                    for c in 0..<3 { sum += abs(Double(a[i + c]) - Double(b[i + c])) }
                    n += 3
                }
            }
            total += sum
            worst = max(worst, sum / Double(n))
        }
    }
    return Difference(mean: total / Double(w * h * 3), worstBlock: worst)
}

/// Python and Swift draw the same frames. Fonts rasterize differently (FreeType vs Core Text) and blurs
/// differ slightly, so frames are compared at quarter size with tolerances that still catch a misplaced
/// Dock, a missing label, a wrong color or a broken background.
@Test(arguments: goldens)
func matchesPythonGoldenFrame(_ g: GoldenFrame) throws {
    let fmt = VideoFormat.named(g.format)!
    let timeline = try loadTimeline(renderData)
    let swift = Renderer(dataRoot: renderData, format: fmt, timeline: timeline, background: Background(rawValue: g.background)!)
        .image(at: g.t)
    let gold = try #require(CGImageSourceCreateWithURL(fixtures.appending(path: g.path) as CFURL, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    let (w, h) = (gold.width, gold.height)
    if let dump = ProcessInfo.processInfo.environment["DOCK_GOLDEN_DUMP"] {
        try writePNG(swift, to: URL(fileURLWithPath: dump).appending(path: "\(g.testDescription).png"))
    }
    let d = compare(pixels(swift, w, h), pixels(gold, w, h), w, h)
    // Measured: means 0.7–1.8, worst blocks ≤ 43. The worst blocks are the "↕" of moved-app labels,
    // which Python's font lacks (it draws a box) and Core Text draws properly. A missing pill, icon or a
    // shifted Dock pushes a block far beyond 48.
    #expect(d.mean < 2.5, "mean \(d.mean)")
    #expect(d.worstBlock < 48, "worst block \(d.worstBlock)")
}
