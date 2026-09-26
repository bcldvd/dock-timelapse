import AppKit
import DockAppModel
import DockCore
import SwiftUI

@main
struct DockTimelapseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(services: DockTimelapseApp.services())

    /// `--demo-data <dir>` points the app at another history; `--demo <state>` also swaps the system
    /// services for in-memory ones (recorder, Time Machine, permissions) so every screen can be shown and
    /// tested without touching the real login items or backups.
    static func services() -> AppServices {
        let args = CommandLine.arguments
        var s = args.contains("--demo") ? DemoServices.make(args) : AppServices.live()
        if let i = args.firstIndex(of: "--demo-data"), i + 1 < args.count {
            s.dataDir = URL(fileURLWithPath: args[i + 1])
        }
        if let i = args.firstIndex(of: "--output"), i + 1 < args.count {
            s.outputDir = URL(fileURLWithPath: args[i + 1])
        }
        return s
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environment(model)
        } label: {
            MenuBarIcon(rendering: model.render.isRendering, showWelcome: !model.onboarded || CommandLine.arguments.contains("--welcome"))
                .task {
                    if CommandLine.arguments.contains("--demo") {
                        model.refresh()
                        model.applyDemoState(CommandLine.arguments)
                    }
                    await keepRecordingFresh()
                }
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Dock Timelapse", id: "welcome") {
            WelcomeView()
                .environment(model)
                .modifier(RegularAppWhileOpen())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)  // opened by the menu-bar label on first launch (see MenuBarIcon)
        .restorationBehavior(.disabled)

        Window("Your Dock Timelapse", id: "player") {
            PlayerView()
                .environment(model)
                .modifier(RegularAppWhileOpen())
        }
        .defaultSize(width: 960, height: 600)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView().environment(model)
        }

        // `--menu-window`: the menu-bar panel in a normal window, for screenshots and UI review.
        Window("Menu (review)", id: "menu-review") {
            MenuPanel().environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }

    /// Record when the app opens and hourly while it runs (the background job covers the rest).
    @MainActor private func keepRecordingFresh() async {
        while !Task.isCancelled {
            model.captureNow()
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}

struct MenuBarIcon: View {
    let rendering: Bool
    let showWelcome: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "dock.rectangle")
            .symbolEffect(.pulse, isActive: rendering)
            .accessibilityLabel("Dock Timelapse")
            // The label lives from launch, unlike the menu window: the one place that can open the welcome
            // window when the app starts (defaultLaunchBehavior is ignored for menu-bar apps).
            .task {
                if showWelcome { openWindow(id: "welcome") }
                if CommandLine.arguments.contains("--menu-window") { openWindow(id: "menu-review") }
                if CommandLine.arguments.contains("--player") { openWindow(id: "player") }
            }
    }
}

/// A menu-bar app has no Dock icon; while one of its windows is open it behaves like a regular app
/// (Dock icon, ⌘-Tab), then steps back into the menu bar.
struct RegularAppWhileOpen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                AppDelegate.openWindows += 1
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            .onDisappear {
                AppDelegate.openWindows = max(0, AppDelegate.openWindows - 1)
                if AppDelegate.openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openWindows = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest-recorder"), i + 1 < args.count {
            RecorderSelfTest.run(report: URL(fileURLWithPath: args[i + 1]))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
