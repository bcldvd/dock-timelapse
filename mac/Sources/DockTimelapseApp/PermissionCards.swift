import DockAppModel
import SwiftUI

/// Everything Dock Timelapse asks macOS for, one card each, each with one button that turns into "Done"
/// by itself once macOS says yes.
struct PermissionCards: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                ForEach(model.permissions, id: \.permission) { PermissionCard(row: $0) }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: model.permissions)
        .task { await model.watchPermissions() }
    }
}

struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let row: PermissionRow

    var body: some View {
        HStack(spacing: 16) {
            PermissionIcon(permission: row.permission, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.permission.title).font(.title3.weight(.semibold))
                    if !row.required {
                        Text("Optional")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(row.permission.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var trailing: some View {
        switch row.status {
        case .granted:
            Label("Done", systemImage: "checkmark")
                .font(.body.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .notYet:
            Button(row.permission.action) { PermissionGuide.request(row.permission, model: model) }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        case .waitingForApproval:
            Button("Allow in Settings") { PermissionGuide.request(row.permission, model: model) }
                .buttonStyle(.glassProminent)
                .tint(.orange)
                .controlSize(.large)
        }
    }
}

struct PermissionIcon: View {
    let permission: Permission
    let size: Double

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: permission.colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: permission.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .accessibilityHidden(true)
    }
}

extension Permission {
    var title: String {
        switch self {
        case .backgroundRecording: "Background recording"
        case .fullDiskAccess: "Time Machine access"
        }
    }

    var reason: String {
        switch self {
        case .backgroundRecording: "Checks your Dock once an hour, even when this app is closed."
        case .fullDiskAccess: "Reads your backups to bring back past Docks."
        }
    }

    var action: String {
        switch self {
        case .backgroundRecording: "Turn On"
        case .fullDiskAccess: "Allow"
        }
    }

    var symbol: String {
        switch self {
        case .backgroundRecording: "record.circle"
        case .fullDiskAccess: "clock.arrow.circlepath"
        }
    }

    var colors: [Color] {
        switch self {
        case .backgroundRecording: [Color(red: 1, green: 0.38, blue: 0.35), Color(red: 0.86, green: 0.15, blue: 0.2)]
        case .fullDiskAccess: [Color(red: 0.35, green: 0.78, blue: 0.62), Color(red: 0.1, green: 0.55, blue: 0.5)]
        }
    }
}
