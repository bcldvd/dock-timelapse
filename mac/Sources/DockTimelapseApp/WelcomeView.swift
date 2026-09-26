import DockAppModel
import DockCore
import DockMac
import SwiftUI

/// First launch: what this is, start recording, bring back the past, make the first video.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = Step.initial
    @State private var wallpaper: NSImage?

    enum Step: Int, CaseIterable {
        case hello, record, past, ready

        /// `--welcome-step N` opens a given step (screenshots, UI review).
        static var initial: Step {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--welcome-step"), i + 1 < args.count, let n = Int(args[i + 1]) else { return .hello }
            return Step(rawValue: n) ?? .hello
        }
    }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case .hello: hello
                    case .record: record
                    case .past: past
                    case .ready: ready
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                dots.padding(.bottom, 22)
            }
            .padding(.horizontal, 56)
            .padding(.top, 40)
        }
        .frame(width: 720, height: 540)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .task {
            model.refresh()
            wallpaper = model.services.mac.wallpaper().flatMap { NSImage(data: $0.data) }
        }
    }

    private func go(_ next: Step) {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = next }
    }

    // MARK: pieces

    private var background: some View {
        ZStack {
            if let wallpaper {
                Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill).blur(radius: 30, opaque: true)
            } else {
                LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.24), Color(red: 0.2, green: 0.1, blue: 0.3)],
                               startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(.white.opacity(s == step ? 0.95 : 0.35))
                    .frame(width: s == step ? 18 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: step)
        .accessibilityHidden(true)
    }

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.system(size: 40, weight: .bold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
        }
    }

    private func primary(_ label: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage { Label(label, systemImage: systemImage) } else { Text(label) }
            }
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .font(.callout)
    }

    // MARK: steps

    private var hello: some View {
        VStack(spacing: 34) {
            Spacer(minLength: 0)
            DockStrip(apps: model.currentDock, width: 560, maxIcon: 46, animateIn: true)
            title("Your Dock tells a story.",
                  "Dock Timelapse quietly remembers the apps you keep in your Dock, and turns their story into a beautiful video.")
            primary("Get Started") { go(.record) }
            Spacer(minLength: 0)
        }
    }

    private var record: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 0)
            Image(systemName: "record.circle")
                .font(.system(size: 64, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
            title("Start recording",
                  "Once an hour, Dock Timelapse checks which apps are in your Dock and keeps a note on the days something changes. Everything stays on this Mac.")
            if model.legacyRecorderFound, let since = model.stats.since {
                Label("Your recording since \(since.long) carries over.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
            }
            switch model.recorder {
            case .on:
                Label("Recording", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                    .task {
                        try? await Task.sleep(for: .milliseconds(700))
                        go(.past)
                    }
            case .needsApproval:
                VStack(spacing: 12) {
                    Text("One more click: allow Dock Timelapse in Login Items.")
                        .font(.callout)
                    primary("Open Login Items", systemImage: "gearshape") { AppRecorder.openLoginItemsSettings() }
                }
                .task {  // macOS doesn't tell us; check until the switch is on
                    while !Task.isCancelled && model.recorder != .on {
                        try? await Task.sleep(for: .seconds(1))
                        model.refresh()
                    }
                }
            case .off:
                VStack(spacing: 12) {
                    primary("Start Recording", systemImage: "record.circle") { model.startRecording() }
                    if let error = model.recorderError {
                        Text(error.errorDescription ?? "").font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var past: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 0)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
            if model.timeMachineConfigured {
                title("Bring back your past",
                      "Your Time Machine backups hold earlier versions of your Dock. Import them and your first video covers months, not days.")
                importControls
            } else {
                title("No Time Machine? No problem.",
                      "Your story builds up from today. Meanwhile, a preview shows what your video will look like, with an invented past.")
                primary("Continue") { go(.ready) }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var importControls: some View {
        switch model.importState {
        case .idle:
            VStack(spacing: 14) {
                primary("Import from Time Machine", systemImage: "clock.arrow.circlepath") {
                    Task { await model.importFromTimeMachine() }
                }
                secondary("Skip for now") { go(.ready) }
            }
        case .needsFullDiskAccess:
            VStack(spacing: 14) {
                Text("Dock Timelapse needs Full Disk Access to read your backups.\nTurn it on in System Settings; the import continues automatically.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 14) {
                    primary("Open Privacy Settings", systemImage: "lock.shield") { Permissions.openFullDiskAccessSettings() }
                    ProgressView().controlSize(.small).tint(.white)
                }
                secondary("Skip for now") { model.dismissImport(); go(.ready) }
            }
        case .running(let fraction):
            VStack(spacing: 10) {
                ProgressView(value: fraction).frame(width: 320).tint(.white)
                Text("Reading your backups…").font(.callout).foregroundStyle(.white.opacity(0.8))
            }
        case .finished(let r):
            VStack(spacing: 14) {
                Label(r.added == 0 ? "Your backups had nothing new." : "Found \(r.added) days of history, back to \(r.first.flatMap(Day.init(iso:))?.long ?? "?").",
                      systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.green)
                primary("Continue") { go(.ready) }
            }
        case .failed(let error):
            VStack(spacing: 14) {
                Text(error.errorDescription ?? "The import didn't work.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 520)
                HStack(spacing: 16) {
                    if let recovery = error.recovery, recovery == .openFullDiskAccessSettings {
                        primary(recovery.title) { Permissions.openFullDiskAccessSettings() }
                    } else {
                        primary("Try Again") { Task { await model.importFromTimeMachine() } }
                    }
                }
                secondary("Skip for now") { model.dismissImport(); go(.ready) }
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 0)
            DockStrip(apps: model.currentDock, width: 560, maxIcon: 46)
            title("You're all set.", readySubtitle)
            VStack(spacing: 14) {
                primary(model.hasStory ? "Make My First Video" : "Watch a Preview", systemImage: "play.fill") {
                    model.onboarded = true
                    model.makeVideo()
                    openWindow(id: "player")
                    dismissWindow(id: "welcome")
                }
                secondary("Close") {
                    model.onboarded = true
                    dismissWindow(id: "welcome")
                }
            }
            Text("Dock Timelapse lives in your menu bar.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
        }
    }

    private var readySubtitle: String {
        let s = model.stats
        if model.hasStory, let since = s.since {
            return "Your history goes back to \(since.long): \(s.changes) changes over \(s.days) days."
        }
        return "Recording has started. Come back in a few weeks for the real story, or watch a preview now."
    }
}
