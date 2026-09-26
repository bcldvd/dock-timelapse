import DockAppModel
import DockCore
import DockMac
import DockRender
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Recording") {
                LabeledContent("Background recording") {
                    Toggle("", isOn: Binding(get: { model.recorder != .off },
                                             set: { $0 ? model.startRecording() : model.stopRecording() }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if model.recorder == .needsApproval {
                    LabeledContent("Needs your OK") {
                        Button("Open Login Items") { AppRecorder.openLoginItemsSettings() }
                    }
                }
                LabeledContent("History") {
                    Text(model.snapshots.isEmpty ? "None yet" : "\(model.snapshots.count) days of change since \(model.stats.since?.long ?? "")")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Record now") {
                    Button("Check the Dock") { model.captureNow() }
                }
            }
            Section("Video") {
                Toggle("Landscape (1920 × 1080)", isOn: $model.settings.landscape)
                Toggle("Portrait (1080 × 1920)", isOn: $model.settings.portrait)
                Picker("Background", selection: $model.settings.background) {
                    Text("Blurred wallpaper").tag(Background.wallpaper)
                    Text("Sharp wallpaper").tag(Background.desktop)
                    Text("White").tag(Background.white)
                }
                Picker("Smoothness", selection: $model.settings.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented)
            }
            Section("Files") {
                LabeledContent("Videos") {
                    Button("Show in Finder") { reveal(model.services.outputDir) }
                }
                LabeledContent("History data") {
                    Button("Show in Finder") { reveal(model.services.dataDir) }
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refresh() }
    }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
