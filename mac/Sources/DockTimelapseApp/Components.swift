import AppKit
import DockMac
import DockAppModel
import DockCore
import SwiftUI

/// App icons: the live icon from the app on disk, or the one saved with the history if the app is gone.
@MainActor
enum IconStore {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for app: DockApp, saved: URL?) -> NSImage {
        let key = "\(app.key)|\(saved?.path ?? "")" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: NSImage
        if !app.path.isEmpty, FileManager.default.fileExists(atPath: app.path) {
            image = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path)
        } else if let saved, let img = NSImage(contentsOf: saved) {
            image = img
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct AppIconView: View {
    let app: DockApp
    let saved: URL?
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: IconStore.image(for: app, saved: saved))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel(app.label)
    }
}

/// The user's Dock, drawn as a small glass Dock.
struct DockStrip: View {
    @Environment(AppModel.self) private var model
    let apps: [DockApp]
    var width: CGFloat = 328
    var maxIcon: CGFloat = 30
    /// When set, icons spring in one by one (the welcome screen), like the video's intro.
    var animateIn = false
    @State private var appeared = false

    var body: some View {
        // Icons and gaps shrink together so any Dock fits (gap = 18% of an icon, like the real Dock).
        let count = CGFloat(max(1, apps.count))
        let icon = min(maxIcon, (width - 24) / (count + 0.18 * (count - 1)))
        let spacing = icon * 0.18
        HStack(spacing: spacing) {
            ForEach(Array(apps.enumerated()), id: \.element.key) { k, app in
                AppIconView(app: app, saved: model.iconURL(for: app), size: icon)
                    .scaleEffect(!animateIn || appeared ? 1 : 0.2)
                    .opacity(!animateIn || appeared ? 1 : 0)
                    .animation(.spring(response: 0.45, dampingFraction: 0.62).delay(0.3 + Double(k) * 0.06), value: appeared)
                    .help(app.label)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .onAppear { appeared = true }
    }
}

/// A rounded glass surface for grouped content in the menu.
struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: 16))
    }
}

struct RecordingBadge: View {
    let state: RecorderState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: state == .on ? 3 : 0)
                .symbolEffect(.pulse, isActive: state == .on)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    var color: Color {
        switch state {
        case .on: .green
        case .needsApproval: .orange
        case .off: .secondary
        }
    }

    var text: String {
        switch state {
        case .on: "Recording"
        case .needsApproval: "Waiting for your OK"
        case .off: "Paused"
        }
    }
}

extension DockError.Recovery {
    var title: String {
        switch self {
        case .openFullDiskAccessSettings: "Open Privacy Settings"
        case .connectBackupDisk: "Try Again"
        case .startRecording: "Start Recording"
        case .openLoginItemsSettings: "Open Login Items"
        }
    }
}

/// Human dates: "today", "yesterday", "3 days ago", else "2 Nov 2025".
func friendly(_ day: Day, today: Day) -> String {
    switch today.days(since: day) {
    case 0: "today"
    case 1: "yesterday"
    case 2..<7: "\(today.days(since: day)) days ago"
    default: day.short
    }
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
