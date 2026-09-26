import DockAppModel
import DockCore
import DockMac
import SwiftUI

/// The menu-bar window: your Dock, its story in numbers, and one obvious thing to do.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Namespace private var glass

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.currentDock.isEmpty {
                DockStrip(apps: model.currentDock)
                    .frame(maxWidth: .infinity)
            }
            story
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    videoArea
                    importArea
                    if let error = model.recorderError ?? model.historyError { errorCard(error) }
                }
            }
            .animation(.smooth(duration: 0.35), value: model.render)
            .animation(.smooth(duration: 0.35), value: model.importState)
            Divider().padding(.horizontal, -4)
            footer
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { model.refresh() }
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dock Timelapse").font(.headline)
                RecordingBadge(state: model.recorder, health: model.recorderHealth)
            }
            Spacer()
            if model.recorder == .needsApproval {
                Button("Allow…") { PermissionGuide.request(.backgroundRecording, model: model) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } else if model.recorder == .on && model.recorderHealth != .healthy {
                Button("Restart Recording") { model.restartRecording() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var story: some View {
        let stats = model.stats
        if model.snapshots.isEmpty {
            Text("Your Dock's story starts today. Import your past from Time Machine to see months of history right away.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    number(stats.days, stats.days == 1 ? "day" : "days")
                    number(stats.changes, stats.changes == 1 ? "change" : "changes")
                    number(model.currentDock.count, "apps")
                }
                Group {
                    if let last = stats.lastChange, let day = stats.lastChangeDay {
                        Text("Latest: \(last), \(friendly(day, today: model.services.now().day))")
                    } else if let since = stats.since {
                        Text("Recording since \(since.long). No changes yet.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
    }

    private func number(_ n: Int, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(n)")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .contentTransition(.numericText(value: Double(n)))
            Text(unit).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var videoArea: some View {
        switch model.render {
        case .idle:
            VStack(spacing: 8) {
                Button { model.makeVideo() } label: {
                    Label(model.hasStory ? "Make My Video" : "Make a Preview Video", systemImage: "play.rectangle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .glassEffectID("video", in: glass)
                if !model.hasStory {
                    Text("You don't have much history yet, so the preview invents a past that ends with today's Dock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .rendering(let fraction, let step):
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(step).font(.callout.weight(.medium))
                        Spacer()
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: fraction))
                        Button { model.cancelRender() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Cancel")
                    }
                    ProgressView(value: fraction).progressViewStyle(.linear)
                }
            }
            .glassEffectID("video", in: glass)
        case .finished(let video):
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your video is ready").font(.callout.weight(.semibold))
                        Text(video.isPreview ? "Preview · invented past" : "\(video.files.count == 2 ? "Landscape and portrait" : "Landscape"), in Movies")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Play") { openWindow(id: "player") }
                        .buttonStyle(.glassProminent)
                }
            }
            .glassEffectID("video", in: glass)
            .contextMenu {
                Button("Show in Finder") { revealInFinder(video.primary) }
                Button("Make Another") { model.dismissVideo() }
            }
        case .failed(let message):
            Card(tint: .red.opacity(0.25)) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { model.makeVideo() }.buttonStyle(.glass)
                }
            }
            .glassEffectID("video", in: glass)
        }
    }

    @ViewBuilder private var importArea: some View {
        switch model.importState {
        case .idle:
            HStack(spacing: 10) {
                Button { Task { await model.importFromTimeMachine() } } label: {
                    Label("Import Past", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
                }
                .help(model.timeMachineConfigured ? "Read your past Docks from Time Machine backups"
                                                  : "Time Machine isn't set up on this Mac")
                .disabled(!model.timeMachineConfigured)
                Button { model.makeVideo(preview: true) } label: {
                    Label("Preview", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .help("A video with an invented past that ends with today's Dock")
                .disabled(model.render.isRendering)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        case .needsFullDiskAccess:
            Card(tint: .orange.opacity(0.2)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow access to your backups").font(.callout.weight(.semibold))
                    Text("Dock Timelapse needs Full Disk Access to read your backups. The import continues by itself once it's on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Allow Access") { PermissionGuide.request(.fullDiskAccess, model: model) }
                            .buttonStyle(.glassProminent)
                        Spacer()
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.dismissImport() }.buttonStyle(.borderless)
                    }
                }
            }
        case .running(let fraction):
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reading your Time Machine backups…").font(.callout.weight(.medium))
                    ProgressView(value: fraction)
                }
            }
        case .finished(let r):
            Card(tint: .green.opacity(0.15)) {
                HStack {
                    Image(systemName: "clock.badge.checkmark.fill").foregroundStyle(.green).font(.title3)
                    Text(r.added == 0 ? "Nothing new in your backups." : "Added \(r.added) days of history, back to \(r.first.flatMap(Day.init(iso:))?.long ?? "?").")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.dismissImport() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            }
        case .failed(let error):
            errorCard(error, dismiss: { model.dismissImport() }) {
                if error.recovery == .connectBackupDisk { Task { await model.importFromTimeMachine() } }
                else if error.recovery == .openFullDiskAccessSettings { PermissionGuide.request(.fullDiskAccess, model: model) }
            }
        }
    }

    private func errorCard(_ error: DockError, dismiss: (() -> Void)? = nil, action: (() -> Void)? = nil) -> some View {
        Card(tint: .orange.opacity(0.2)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error.errorDescription ?? "Something went wrong.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let dismiss {
                        Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
                if let recovery = error.recovery {
                    Button(recovery.title) {
                        if let action { action(); return }
                        switch recovery {
                        case .openFullDiskAccessSettings: PermissionGuide.request(.fullDiskAccess, model: model)
                        case .openLoginItemsSettings: PermissionGuide.request(.backgroundRecording, model: model)
                        case .startRecording: model.startRecording()
                        case .connectBackupDisk: break
                        }
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if model.recorder == .off {
                Button("Resume Recording", systemImage: "record.circle") { model.startRecording() }
            } else {
                Button("Pause Recording", systemImage: "pause.circle") { model.stopRecording() }
            }
            Spacer()
            Button("Settings…", systemImage: "gearshape") {
                openSettings()
                NSApp.activate()
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut(",")
            Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                .labelStyle(.iconOnly)
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .font(.callout)
    }
}
