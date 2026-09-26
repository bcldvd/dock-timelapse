import AVKit
import DockAppModel
import DockCore
import DockRender
import SwiftUI

/// Watch the video, switch format, share it, or remake it with another look.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @State private var format = "landscape"
    @State private var player = AVPlayer()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.render {
            case .finished(let video):
                PlayerSurface(player: player)
                    .aspectRatio(format == "portrait" ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
                    .onAppear { load(video) }
                    .onChange(of: video) { _, v in load(v) }
                    .onChange(of: format) { _, _ in load(video) }
                    .overlay(alignment: .topLeading) {
                        if video.isPreview {
                            Label("Preview · invented past", systemImage: "sparkles")
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .glassEffect(.regular, in: .capsule)
                                .padding(14)
                        }
                    }
            case .rendering(let fraction, let step):
                VStack(spacing: 16) {
                    ProgressView(value: fraction).frame(width: 320).tint(.white)
                    Text(step).foregroundStyle(.white.opacity(0.85))
                    Button("Cancel") { model.cancelRender() }.buttonStyle(.glass)
                }
            case .failed(let message):
                VStack(spacing: 14) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Try Again") { model.makeVideo() }.buttonStyle(.glassProminent)
                }
                .padding()
            case .idle:
                VStack(spacing: 14) {
                    Text("No video yet").foregroundStyle(.white.opacity(0.8))
                    Button("Make My Video") { model.makeVideo() }.buttonStyle(.glassProminent)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .toolbar { toolbar }
        .navigationTitle(title)
        .onDisappear { player.pause() }
    }

    private var title: String {
        guard let first = model.snapshots.first?.day, let last = model.snapshots.last?.day, model.hasStory else {
            return "Your Dock"
        }
        return "My Dock, \(first.monthYear) – \(last.monthYear)"
    }

    private var video: Video? {
        if case .finished(let v) = model.render { return v }
        return nil
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let video {
            if video.files.count > 1 {
                ToolbarItem(placement: .principal) {
                    Picker("Format", selection: $format) {
                        Label("Landscape", systemImage: "rectangle").tag("landscape")
                        Label("Portrait", systemImage: "rectangle.portrait").tag("portrait")
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .help("Landscape for screens, portrait for stories")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(Background.allCases, id: \.self) { bg in
                        Button {
                            model.settings.background = bg
                            model.makeVideo(preview: video.isPreview)
                        } label: {
                            if bg == video.background { Label(name(bg), systemImage: "checkmark") } else { Text(name(bg)) }
                        }
                    }
                } label: {
                    Label("Look", systemImage: "paintpalette")
                }
                .help("Remake the video with another background")
                Button("Show in Finder", systemImage: "folder") { revealInFinder(url(video)) }
                ShareLink(item: url(video))
            }
        }
    }

    private func name(_ b: Background) -> String {
        switch b {
        case .wallpaper: "Blurred Wallpaper"
        case .desktop: "Sharp Wallpaper"
        case .white: "White"
        }
    }

    private func url(_ video: Video) -> URL { video.files[format] ?? video.primary }

    private func load(_ video: Video) {
        if video.files[format] == nil { format = video.files.keys.contains("landscape") ? "landscape" : video.files.keys.first! }
        player.replaceCurrentItem(with: AVPlayerItem(url: url(video)))
        player.play()
    }
}

/// AppKit's player (native controls, full screen, share). SwiftUI's `VideoPlayer` aborts on launch in this
/// OS version (a metadata failure inside `_AVKit_SwiftUI`), so the mature AppKit view is used instead.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.showsSharingServiceButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
