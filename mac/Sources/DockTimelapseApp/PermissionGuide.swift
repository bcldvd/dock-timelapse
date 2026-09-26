import AppKit
import DockAppModel
import SwiftUI

/// Opens System Settings where a permission is granted and floats a small guide beside its window: what to
/// switch on and, for Full Disk Access, the app icon to drag into the list (the step people get stuck on).
/// The guide closes itself once macOS reports the permission, and brings Dock Timelapse back to the front.
@MainActor enum PermissionGuide {
    private static var panel: NSPanel?
    private static var follow: Task<Void, Never>?

    static func request(_ permission: Permission, model: AppModel) {
        let before = model.status(of: permission)
        model.requestPermission(permission)
        // Turning recording on can come back as "needs approval": then it's off to Login Items as well.
        if permission == .backgroundRecording && before == .notYet && model.status(of: permission) == .waitingForApproval {
            model.requestPermission(permission)
        }
        if model.status(of: permission) != .granted { show(permission, model: model) }
    }

    static func show(_ permission: Permission, model: AppModel) {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let host = NSHostingView(rootView: GuideView(permission: permission, close: { close() }).environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        self.panel = panel
        place(panel)
        panel.orderFrontRegardless()

        follow = Task { @MainActor in
            var elapsed = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                elapsed += 0.5
                model.refresh()
                if model.status(of: permission) == .granted {
                    try? await Task.sleep(for: .milliseconds(900))  // let the "Done" check land
                    close()
                    comeBack()
                    return
                }
                if elapsed < 8 { place(panel) }  // System Settings takes a moment to open and settle
            }
        }
    }

    /// Back to our window (welcome, menu). macOS may not let us take focus from System Settings, so the
    /// window is also brought above it.
    private static func comeBack() {
        guard AppDelegate.openWindows > 0 else { return }
        for window in NSApp.windows where window.isVisible && window.canBecomeMain { window.orderFrontRegardless() }
        NSApp.activate()
    }

    static func close() {
        follow?.cancel()
        follow = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Beside System Settings' window if there's room, otherwise inside its lower-right corner, otherwise at
    /// the bottom right of the screen.
    private static func place(_ panel: NSPanel) {
        let size = panel.frame.size
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
        if let settings = settingsWindowFrame() {
            let gap = 16.0
            let midY = settings.midY - size.height / 2
            if settings.maxX + gap + size.width <= visible.maxX {
                origin = NSPoint(x: settings.maxX + gap, y: midY)
            } else if settings.minX - gap - size.width >= visible.minX {
                origin = NSPoint(x: settings.minX - gap - size.width, y: midY)
            } else {
                origin = NSPoint(x: settings.maxX - size.width - 24, y: settings.minY + 24)
            }
        }
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    /// System Settings' main window in AppKit screen coordinates. Window bounds are readable without screen
    /// recording permission (titles aren't, so the owner is matched by process).
    private static func settingsWindowFrame() -> NSRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .first?.processIdentifier,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        let frames = list.compactMap { w -> CGRect? in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.width > 300, rect.height > 200 else { return nil }
            return rect
        }
        guard let top = frames.max(by: { $0.width * $0.height < $1.width * $1.height }),
              let primary = NSScreen.screens.first else { return nil }
        // Quartz: origin top-left of the primary display, y down. AppKit: bottom-left, y up.
        return NSRect(x: top.minX, y: primary.frame.maxY - top.maxY, width: top.width, height: top.height)
    }
}

extension AppModel {
    func status(of permission: Permission) -> PermissionStatus? {
        permissions.first { $0.permission == permission }?.status
    }
}

/// The floating card beside System Settings.
private struct GuideView: View {
    @Environment(AppModel.self) private var model
    let permission: Permission
    let close: () -> Void

    private var granted: Bool { model.status(of: permission) == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(granted ? "All set" : heading).font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close")
            }
            if granted {
                Label("Dock Timelapse can \(permission == .fullDiskAccess ? "read your backups" : "record in the background").",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else {
                switch permission {
                case .fullDiskAccess: dragSteps
                case .backgroundRecording: switchSteps
                }
            }
        }
        .padding(18)
        .frame(width: 320)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: granted)
    }

    private var heading: String {
        switch permission {
        case .fullDiskAccess: "Allow Full Disk Access"
        case .backgroundRecording: "Allow background recording"
        }
    }

    private var dragSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                DraggableAppIcon()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag Dock Timelapse into the list")
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Label("then turn its switch on", systemImage: "arrow.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Or click + under the list and choose Dock Timelapse in Applications.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var switchSteps: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
            Text("Under “Allow in the Background”, turn on the switch next to Dock Timelapse.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app's icon, draggable as the app itself: dropping it into a System Settings privacy list adds it.
private struct DraggableAppIcon: View {
    @State private var hint = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 56, height: 56)
            .offset(x: hint ? -5 : 0)
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .help("Drag into the list in System Settings")
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(0.4)) { hint = true }
            }
            .accessibilityLabel("Dock Timelapse app icon, drag into the list")
    }
}
