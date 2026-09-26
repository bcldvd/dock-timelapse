import CoreGraphics
import DockCore
import Foundation
import Testing
@testable import DockRender

/// Renders run side by side (both video formats, the app and the MCP server), so a frame must not depend on
/// what else is being drawn at the same time.
@Test func framesDontDependOnConcurrentRenders() async throws {
    let timeline = try loadTimeline(renderData)
    let jobs = goldens.map { (VideoFormat.named($0.format)!, Background(rawValue: $0.background)!, $0.t) }
    func draw(_ j: (VideoFormat, Background, Double)) -> [UInt8] {
        let img = Renderer(dataRoot: renderData, format: j.0, timeline: try! loadTimeline(renderData), background: j.1).image(at: j.2)
        return pixels(img, img.width / 4, img.height / 4)
    }
    let alone = jobs.map(draw)
    for _ in 0..<3 {
        let together = await withTaskGroup(of: (Int, [UInt8]).self) { group in
            for (i, j) in jobs.enumerated() { group.addTask { (i, draw(j)) } }
            var out = [[UInt8]](repeating: [], count: jobs.count)
            for await (i, b) in group { out[i] = b }
            return out
        }
        for i in jobs.indices { #expect(together[i] == alone[i], "\(jobs[i].0.name) \(jobs[i].1) t=\(jobs[i].2)") }
    }
}
