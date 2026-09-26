import DockCore
import DockMac
import DockRender
import Foundation
import Testing
@testable import DockAppModel

func apps(_ ids: String...) -> [DockApp] {
    ids.map { DockApp(label: $0.uppercased(), bundleID: $0, path: "/Applications/\($0).app") }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

struct FakeMac: MacSystem {
    let dock: Box<[DockApp]>
    func currentDock() throws -> [DockApp] { dock.value }
    func iconPNG(for app: DockApp) -> Data? { Data("png-\(app.label)".utf8) }
    func wallpaper() -> Wallpaper? { Wallpaper(stem: "w", suffix: ".jpg", data: Data("jpg".utf8)) }
}

final class FakeRecorder: Recorder, @unchecked Sendable {
    var state: RecorderState = .off
    var failWith: DockError?
    var stopFailWith: DockError?
    var starts = 0
    var stops = 0
    func start() throws {
        starts += 1
        if let failWith { throw failWith }
        state = .on
    }
    func stop() throws {
        stops += 1
        if let stopFailWith { throw stopFailWith }
        state = .off
    }
}

@MainActor
final class Harness {
    let dir: URL
    let dock = Box(apps("arc", "slack"))
    let recorder = FakeRecorder()
    let fda = Box(true)
    let backups = Box<Result<[Backup], DockError>>(.success([]))
    let renders = Box<[String]>([])
    let renderGate = Box<Bool>(false)  // true = renders hang until cancelled
    let renderFails = Box<Bool>(false)
    let settingsOpened = Box<[Permission]>([])
    let model: AppModel

    init() {
        dir = FileManager.default.temporaryDirectory.appending(path: "app-tests-\(UUID())")
        let (dock, fda, backups, renders, gate, fails) = (dock, fda, backups, renders, renderGate, renderFails)
        let opened = settingsOpened
        var services = AppServices(
            dataDir: dir.appending(path: "data"), outputDir: dir.appending(path: "out"),
            mac: FakeMac(dock: dock), recorder: recorder,
            listBackups: { try backups.value.get() },
            timeMachineConfigured: { true }, hasFullDiskAccess: { fda.value }, legacyRecorderInstalled: { false },
            render: { data, format, out, fps, background, progress in
                renders.value.append("\(format.name)@\(fps)/\(background.rawValue) from \(data.lastPathComponent)")
                if fails.value { throw DockError.renderFailed("disk full") }
                for k in 1...10 {
                    while gate.value { try await Task.sleep(for: .milliseconds(5)); try Task.checkCancellation() }
                    if !progress(k, 10) { throw CancellationError() }
                }
                return out
            },
            now: { LocalTime(Day(2026, 9, 26), 12) }
        )
        services.openSettings = { opened.value.append($0) }
        model = AppModel(services: services, defaults: UserDefaults(suiteName: "tests-\(UUID())")!)
    }

    func record(_ day: String, _ ids: String...) throws {
        dock.value = apps(ids)
        try Store(root: dir.appending(path: "data")).observe(apps(ids), at: LocalTime(Day(iso: day)!, 9))
    }

    func waitFor(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

func apps(_ ids: [String]) -> [DockApp] { ids.map { apps($0)[0] } }

@MainActor @Suite struct AppModelTests {
    @Test func refreshLoadsHistoryAndStats() throws {
        let h = Harness()
        try h.record("2026-01-01", "arc")
        try h.record("2026-03-01", "arc", "slack")
        h.model.refresh()
        #expect(h.model.snapshots.count == 2 && h.model.hasStory)
        let s = h.model.stats
        #expect(s.days == 269 && s.changes == 1 && s.since == Day(2026, 1, 1))
        #expect(s.lastChange == "+ SLACK" && s.lastChangeDay == Day(2026, 3, 1))
        #expect(h.model.currentDock == apps("arc", "slack"))
    }

    @Test func emptyHistoryHasNoStory() {
        let h = Harness()
        h.model.refresh()
        #expect(!h.model.hasStory && h.model.stats.days == 0 && h.model.stats.lastChange == nil)
    }

    @Test func startRecordingTurnsTheJobOnAndCapturesRightAway() {
        let h = Harness()
        h.model.startRecording()
        #expect(h.model.recorder == .on && h.recorder.starts == 1)
        #expect(h.model.snapshots.count == 1 && h.model.recorderError == nil)
        h.model.stopRecording()
        #expect(h.model.recorder == .off)
    }

    @Test func recorderFailureIsShownNotSwallowed() {
        let h = Harness()
        h.recorder.failWith = .backgroundRecording("denied")
        h.model.startRecording()
        #expect(h.model.recorderError == .backgroundRecording("denied"))
        #expect(h.model.recorderError?.recovery == .openLoginItemsSettings)
    }

    @Test func importWaitsForFullDiskAccessThenResumesByItself() async throws {
        let h = Harness()
        h.fda.value = false
        await h.model.importFromTimeMachine()
        #expect(h.model.importState == .needsFullDiskAccess)
        h.fda.value = true  // the user flips the switch in System Settings
        await h.waitFor { if case .finished = h.model.importState { true } else { false } }
        #expect(h.model.importState == .finished(ImportResult(backups: 0, read: 0, added: 0, first: nil, last: nil)))
    }

    @Test func importErrorsCarryTheirRecovery() async {
        let h = Harness()
        h.backups.value = .failure(.noTimeMachineBackups(detail: nil))
        await h.model.importFromTimeMachine()
        #expect(h.model.importState == .failed(.noTimeMachineBackups(detail: nil)))
        #expect(DockError.noTimeMachineBackups(detail: nil).recovery == .connectBackupDisk)
    }

    @Test func withoutAStoryTheVideoIsAPreview() async throws {
        let h = Harness()
        h.model.refresh()
        h.model.makeVideo()
        await h.waitFor { !h.model.render.isRendering }
        guard case .finished(let video) = h.model.render else { Issue.record("\(h.model.render)"); return }
        #expect(video.isPreview && video.files.keys.sorted() == ["landscape", "portrait"])
        #expect(video.primary.lastPathComponent == "Dock Landscape Preview.mp4")
        #expect(h.renders.value.allSatisfy { $0.contains("dock-timelapse-preview-") })
    }

    @Test func withAStoryTheVideoIsReal() async throws {
        let h = Harness()
        try h.record("2026-01-01", "arc")
        try h.record("2026-03-01", "arc", "slack")
        h.model.refresh()
        h.model.settings.portrait = false
        h.model.settings.fps = 30
        h.model.settings.background = .white
        h.model.makeVideo()
        await h.waitFor { !h.model.render.isRendering }
        guard case .finished(let video) = h.model.render else { Issue.record("\(h.model.render)"); return }
        #expect(!video.isPreview && video.primary.lastPathComponent == "Dock Landscape.mp4")
        #expect(h.renders.value == ["landscape@30/white from data"])
    }

    @Test func renderFailureIsReadable() async {
        let h = Harness()
        h.renderFails.value = true
        h.model.makeVideo()
        await h.waitFor { !h.model.render.isRendering }
        #expect(h.model.render == .failed("The video couldn't be made: disk full"))
    }

    @Test func cancelStopsTheRenderAndReturnsToIdle() async {
        let h = Harness()
        h.renderGate.value = true
        h.model.makeVideo()
        await h.waitFor { h.renders.value.count == 1 }
        #expect(h.model.render.isRendering)
        h.model.cancelRender()
        #expect(h.model.render == .idle)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.model.render == .idle)  // a late result must not resurrect the job
        #expect(h.renders.value.count == 1)
    }

    @Test func secondMakeVideoWhileRenderingIsIgnored() async {
        let h = Harness()
        h.renderGate.value = true
        h.model.makeVideo()
        h.model.makeVideo()
        await h.waitFor { h.renders.value.count == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.renders.value.count == 1)
        h.model.cancelRender()
    }

    @Test func settingsPersistAcrossLaunches() {
        let defaults = UserDefaults(suiteName: "persist-\(UUID())")!
        let h = Harness()
        let a = AppModel(services: h.model.services, defaults: defaults)
        a.settings.background = .desktop
        a.onboarded = true
        let b = AppModel(services: h.model.services, defaults: defaults)
        #expect(b.settings.background == .desktop && b.onboarded)
        #expect(VideoSettings().formats == [.landscape, .portrait])
        var none = VideoSettings()
        none.landscape = false
        none.portrait = false
        #expect(none.formats == [.landscape])  // never render nothing
    }
}

@MainActor @Suite struct RecorderHealthTests {
    func harness(log: String?) -> Harness {
        let h = Harness()
        h.recorder.state = .on
        if let log { CaptureLog.append(log, to: h.dir.appending(path: "data")) }
        return h
    }

    @Test func healthyWhenTheJobRanRecently() {
        let h = harness(log: "2026-09-26T11:00:00 unchanged")
        h.model.refresh()
        #expect(h.model.recorderHealth == .healthy)
    }

    @Test func staleWhenTheJobHasNotRunForADay() {
        let h = harness(log: "2026-09-24T11:00:00 unchanged")
        h.model.refresh()
        #expect(h.model.recorderHealth == .stale(last: LocalTime(Day(2026, 9, 24), 11)))
    }

    @Test func failingWhenTheLastCaptureErred() {
        let h = harness(log: "2026-09-26T11:00:00 error: Couldn't read the Dock's settings.")
        h.model.refresh()
        #expect(h.model.recorderHealth == .failing("Couldn't read the Dock's settings."))
    }

    @Test func pausedRecorderHasNothingToReport() {
        let h = harness(log: "2026-09-24T11:00:00 error: boom")
        h.recorder.state = .off
        h.model.refresh()
        #expect(h.model.recorderHealth == .healthy)
    }

    @Test func restartRecordingReregistersTheJob() {
        let h = harness(log: "2026-09-24T11:00:00 unchanged")
        h.model.restartRecording()
        #expect(h.recorder.stops == 1 && h.recorder.starts == 1 && h.model.recorder == .on)
    }

    @Test func stopFailureIsShownNotSwallowed() {
        let h = harness(log: nil)
        h.recorder.stopFailWith = .backgroundRecording("launchd said no")
        h.model.stopRecording()
        #expect(h.model.recorderError == .backgroundRecording("launchd said no"))
        #expect(h.model.recorder == .on)
    }
}

@MainActor @Suite struct PermissionTests {
    func row(_ h: Harness, _ p: Permission) -> PermissionRow { h.model.permissions.first { $0.permission == p }! }

    @Test func recordingIsRequiredAndAccessIsOptional() {
        let h = Harness()
        h.fda.value = false
        h.model.refresh()
        #expect(h.model.permissions.map(\.permission) == [.backgroundRecording, .fullDiskAccess])
        #expect(row(h, .backgroundRecording) == PermissionRow(permission: .backgroundRecording, status: .notYet, required: true))
        #expect(row(h, .fullDiskAccess) == PermissionRow(permission: .fullDiskAccess, status: .notYet, required: false))
        #expect(!h.model.requiredPermissionsGranted)
    }

    @Test func statusFollowsTheSystem() {
        let h = Harness()
        h.recorder.state = .needsApproval
        h.model.refresh()
        #expect(row(h, .backgroundRecording).status == .waitingForApproval)
        #expect(row(h, .fullDiskAccess).status == .granted)
        h.recorder.state = .on
        h.model.refresh()
        #expect(row(h, .backgroundRecording).status == .granted && h.model.requiredPermissionsGranted)
    }

    @Test func turningOnRecordingStartsTheJobWithoutOpeningSettings() {
        let h = Harness()
        h.model.requestPermission(.backgroundRecording)
        #expect(h.recorder.starts == 1 && h.model.recorder == .on)
        #expect(h.settingsOpened.value.isEmpty)
    }

    @Test func recordingAwaitingApprovalOpensLoginItems() {
        let h = Harness()
        h.recorder.state = .needsApproval
        h.model.refresh()
        h.model.requestPermission(.backgroundRecording)
        #expect(h.settingsOpened.value == [.backgroundRecording] && h.recorder.starts == 0)
    }

    @Test func fullDiskAccessOpensPrivacySettings() {
        let h = Harness()
        h.fda.value = false
        h.model.refresh()
        h.model.requestPermission(.fullDiskAccess)
        #expect(h.settingsOpened.value == [.fullDiskAccess])
    }

    @Test func grantedPermissionsDoNothing() {
        let h = Harness()
        h.recorder.state = .on
        h.model.refresh()
        h.model.requestPermission(.backgroundRecording)
        h.model.requestPermission(.fullDiskAccess)
        #expect(h.settingsOpened.value.isEmpty && h.recorder.starts == 0)
    }

    /// macOS sends no notification when a switch is flipped in System Settings: the model polls while a
    /// permission screen is visible and stops once everything is granted.
    @Test func watchingNoticesGrantsAndStops() async {
        let h = Harness()
        h.fda.value = false
        h.recorder.state = .needsApproval
        h.model.refresh()
        let watch = Task { await h.model.watchPermissions(every: .milliseconds(5)) }
        h.fda.value = true
        h.recorder.state = .on
        await h.waitFor { h.model.permissions.allSatisfy { $0.status == .granted } }
        #expect(h.model.permissions.allSatisfy { $0.status == .granted })
        await watch.value  // returns by itself once everything is granted
    }
}
