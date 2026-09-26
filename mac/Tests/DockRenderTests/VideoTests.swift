import AVFoundation
import DockCore
import Foundation
import Testing
@testable import DockRender

func outDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "video-tests-\(UUID())")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test(arguments: VideoFormat.all)
func rendersAPlayableMP4AndLeavesNothingElse(_ format: VideoFormat) async throws {
    let dir = outDir()
    let out = dir.appending(path: "dock.mp4")
    try await renderVideo(dataRoot: renderData, format: format, to: out, fps: 10)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["dock.mp4"])
    let asset = AVURLAsset(url: out)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(Int(size.width) == format.width && Int(size.height) == format.height)
    let expected = try loadTimeline(renderData).duration
    #expect(abs(try await asset.load(.duration).seconds - expected) < 0.2)
    #expect(abs(try await track.load(.nominalFrameRate) - 10) < 0.5)
}

@Test func cancellingLeavesNoFileBehind() async throws {
    let dir = outDir()
    await #expect(throws: CancellationError.self) {
        try await renderVideo(dataRoot: renderData, format: .landscape, to: dir.appending(path: "dock.mp4"), fps: 10) { done, _ in
            done < 5
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func existingVideoIsReplacedOnlyWhenTheNewOneIsDone() async throws {
    let dir = outDir()
    let out = dir.appending(path: "dock.mp4")
    try Data("old".utf8).write(to: out)
    _ = try? await renderVideo(dataRoot: renderData, format: .landscape, to: out, fps: 10) { done, _ in done < 3 }
    #expect(try Data(contentsOf: out) == Data("old".utf8))  // a cancelled render keeps the previous video
}

@Test func stillReplacesTheOldPNGAndLeavesNoTemporaryBehind() throws {
    let dir = outDir()
    let out = dir.appending(path: "still.png")
    try Data("old".utf8).write(to: out)
    try renderStill(dataRoot: renderData, format: .landscape, at: 1, to: out)
    #expect(try Data(contentsOf: out).starts(with: [0x89, 0x50, 0x4E, 0x47]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["still.png"])
}

@Test func failedStillLeavesNoTemporaryBehind() throws {
    let dir = outDir()
    let out = dir.appending(path: "still.png")
    try FileManager.default.createDirectory(at: out.appending(path: "in-the-way"), withIntermediateDirectories: true)
    #expect(throws: DockError.storageUnavailable(out.path)) {
        try renderStill(dataRoot: renderData, format: .landscape, at: 1, to: out)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["still.png"])
}

@Test func renderingWithoutHistoryExplains() async {
    await #expect(throws: DockError.noHistory) {
        try await renderVideo(dataRoot: outDir(), format: .landscape, to: outDir().appending(path: "x.mp4"))
    }
}

/// Guards against per-frame work that doesn't scale (the uncached 260 px shadow once made portrait 20×
/// slower). Generous bound: ~1 ms/frame here, 50 ms is a regression on any Apple silicon Mac.
@Test(arguments: VideoFormat.all)
func framesDrawFast(_ format: VideoFormat) throws {
    let timeline = try loadTimeline(renderData)
    let renderer = Renderer(dataRoot: renderData, format: format, timeline: timeline)
    let ctx = bitmapContext(format.width, format.height)
    renderer.draw(timeline.at(0), into: ctx)  // warm caches
    let frames = 60
    let start = Date()
    for k in 0..<frames { renderer.draw(timeline.at(timeline.duration * Double(k) / Double(frames)), into: ctx) }
    let perFrame = Date().timeIntervalSince(start) / Double(frames)
    #expect(perFrame < 0.05, "\(format.name): \(Int(perFrame * 1000)) ms per frame")
}
