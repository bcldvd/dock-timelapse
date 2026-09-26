@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import DockCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

public func loadTimeline(_ dataRoot: URL, timing: Timing = Timing()) throws -> Timeline {
    let snaps = try Store(root: dataRoot).snapshots()
    return try Timeline(buildScenes(snaps), timing: timing)
}

/// Render the history in `dataRoot` to an H.264 MP4 (hardware encoder, plays everywhere incl. iPhone).
/// `progress` gets (frames done, total) and may return false to cancel.
@discardableResult
public func renderVideo(dataRoot: URL, format: VideoFormat, to out: URL, fps: Int = 60,
                        background: Background = .wallpaper, timing: Timing = Timing(),
                        progress: (@Sendable (Int, Int) -> Bool)? = nil) async throws -> URL {
    guard fps > 0 else { throw DockError.renderFailed("fps must be a positive number") }
    let timeline = try loadTimeline(dataRoot, timing: timing)
    let renderer = Renderer(dataRoot: dataRoot, format: format, timeline: timeline, background: background)
    let total = Int((timeline.duration * Double(fps)).rounded()) + 1
    let fm = FileManager.default
    try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Write next to the destination, then move into place: a cancelled or failed render never leaves a
    // broken file where the user expects a video.
    let partial = out.deletingLastPathComponent().appending(path: ".\(out.lastPathComponent).partial.mp4")
    try? fm.removeItem(at: partial)

    let writer: AVAssetWriter
    do { writer = try AVAssetWriter(outputURL: partial, fileType: .mp4) } catch {
        throw DockError.renderFailed(error.localizedDescription)
    }
    writer.shouldOptimizeForNetworkUse = true
    let pixels = format.width * format.height
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: format.width,
        AVVideoHeightKey: format.height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: pixels * fps / 6,  // ~20 Mbit/s at 1080p60: crisp icons and type
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoAllowFrameReorderingKey: true,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: format.width,
        kCVPixelBufferHeightKey as String: format.height,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ])
    guard writer.canAdd(input) else { throw DockError.renderFailed("the video encoder isn't available") }
    writer.add(input)
    guard writer.startWriting() else {
        throw DockError.renderFailed(writer.error?.localizedDescription ?? "couldn't start writing")
    }
    writer.startSession(atSourceTime: .zero)

    var cancelled = false
    do {
        for k in 0..<total {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard writer.status == .writing, let pool = adaptor.pixelBufferPool else {
                throw DockError.renderFailed(writer.error?.localizedDescription ?? "the encoder stopped")
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw DockError.renderFailed("out of memory") }
            try autoreleasepool {
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: format.width,
                                          height: format.height, bitsPerComponent: 8,
                                          bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else {
                    throw DockError.renderFailed("couldn't draw a frame")
                }
                renderer.draw(timeline.at(Double(k) / Double(fps)), into: ctx)
            }
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps))) {
                throw DockError.renderFailed(writer.error?.localizedDescription ?? "a frame couldn't be encoded")
            }
            if let progress, !progress(k + 1, total) { cancelled = true; break }
        }
    } catch {
        writer.cancelWriting()
        try? fm.removeItem(at: partial)
        if error is CancellationError { throw error }
        throw error
    }
    if cancelled {
        writer.cancelWriting()
        try? fm.removeItem(at: partial)
        throw CancellationError()
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        try? fm.removeItem(at: partial)
        throw DockError.renderFailed(writer.error?.localizedDescription ?? "the video couldn't be finished")
    }
    try? fm.removeItem(at: out)
    try fm.moveItem(at: partial, to: out)
    return out
}

/// One frame as a PNG.
@discardableResult
public func renderStill(dataRoot: URL, format: VideoFormat, at t: Double, to out: URL,
                        background: Background = .wallpaper, timing: Timing = Timing()) throws -> URL {
    let timeline = try loadTimeline(dataRoot, timing: timing)
    let image = Renderer(dataRoot: dataRoot, format: format, timeline: timeline, background: background)
        .image(at: max(0, t))
    try writePNG(image, to: out)
    return out
}

public func writePNG(_ image: CGImage, to out: URL) throws {
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw DockError.storageUnavailable(out.path)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw DockError.storageUnavailable(out.path) }
}
