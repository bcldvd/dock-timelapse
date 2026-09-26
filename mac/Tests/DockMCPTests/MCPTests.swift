import DockCore
import DockMac
import Foundation
import Testing
@testable import DockMCP

struct FakeMac: MacSystem {
    func currentDock() throws -> [DockApp] {
        [DockApp(label: "Arc", bundleID: "company.thebrowser.Browser", path: "/Applications/Arc.app"),
         DockApp(label: "Slack", bundleID: "com.tinyspeck.slackmacgap", path: "/Applications/Slack.app")]
    }
    func iconPNG(for app: DockApp) -> Data? { nil }
    func wallpaper() -> Wallpaper? { nil }
}

final class FakeRecorder: Recorder, @unchecked Sendable {
    var state: RecorderState = .off
    func start() throws { state = .on }
    func stop() throws { state = .off }
}

func server(_ data: URL, rendered: @escaping @Sendable (String) -> Void = { _ in }) -> MCPServer {
    let recorder = FakeRecorder()
    return MCPServer(tools: DockTools(data: data, out: data.appending(path: "out"), mac: FakeMac(), recorder: { recorder },
                                      listBackups: { throw DockError.noTimeMachineBackups(detail: nil) },
                                      render: { _, f, out, fps, bg in rendered("\(f.name)@\(fps)/\(bg.rawValue)"); return out }))
}

func tmp() -> URL {
    let u = FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID())")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func ask(_ s: MCPServer, _ method: String, _ params: [String: Any] = [:], id: Int = 1) async throws -> [String: Any] {
    let line = String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]), as: UTF8.self)
    let reply = try #require(await s.handle(line))
    return try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
}

func call(_ s: MCPServer, _ tool: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
    try await ask(s, "tools/call", ["name": tool, "arguments": args])["result"] as! [String: Any]
}

func text(_ r: [String: Any]) -> String { ((r["content"] as! [[String: Any]])[0]["text"] as? String) ?? "" }

@Test func initializeNegotiatesTheProtocol() async throws {
    let r = try await ask(server(tmp()), "initialize", ["protocolVersion": "2025-03-26", "capabilities": [:],
                                                         "clientInfo": ["name": "test", "version": "1"]])
    let result = r["result"] as! [String: Any]
    #expect(result["protocolVersion"] as? String == "2025-03-26")
    #expect((result["serverInfo"] as! [String: Any])["name"] as? String == "dock-timelapse")
    #expect((result["capabilities"] as! [String: Any])["tools"] != nil)
    let unknown = try await ask(server(tmp()), "initialize", ["protocolVersion": "1999-01-01"])
    #expect((unknown["result"] as! [String: Any])["protocolVersion"] as? String == MCPServer.protocolVersions[0])
}

@Test func listsTheSameToolsAsThePythonServer() async throws {
    let tools = (try await ask(server(tmp()), "tools/list")["result"] as! [String: Any])["tools"] as! [[String: Any]]
    #expect(Set(tools.map { $0["name"] as! String }) == ["dock_status", "current_dock", "dock_history", "install_recording",
        "uninstall_recording", "capture_now", "import_time_machine", "render_timelapse", "render_preview", "render_frame"])
    for t in tools { #expect((t["inputSchema"] as! [String: Any])["type"] as? String == "object") }
}

@Test func notificationsGetNoReplyAndGarbageIsAParseError() async throws {
    let s = server(tmp())
    #expect(await s.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    #expect(await s.handle("") == nil)
    let bad = try #require(await s.handle("{nope"))
    #expect(bad.contains("-32700"))
    let unknown = try await ask(s, "resources/list")
    #expect((unknown["error"] as! [String: Any])["code"] as? Int == -32601)
}

@Test func recordingHistoryAndStatus() async throws {
    let data = tmp()
    let s = server(data)
    #expect(try await call(s, "dock_status")["structuredContent"].flatMap { ($0 as! [String: Any])["recording"] as? Bool } == false)
    let installed = try await call(s, "install_recording")["structuredContent"] as! [String: Any]
    #expect(installed["installed"] as? Bool == true)
    let history = (try await call(s, "dock_history")["structuredContent"] as! [String: Any])["result"] as! [[String: Any]]
    #expect(history.count == 1 && history[0]["changes"] as? [String] == ["(first snapshot)"] && history[0]["source"] as? String == "recorded")
    let dock = (try await call(s, "current_dock")["structuredContent"] as! [String: Any])["result"] as! [[String: Any]]
    #expect(dock[0]["name"] as? String == "Arc" && dock[0]["position"] as? Int == 1)
    #expect(text(try await call(s, "capture_now")).contains("unchanged"))
}

@Test func errorsComeBackAsToolErrorsWithAWayForward() async throws {
    let s = server(tmp())
    let render = try await call(s, "render_timelapse")
    #expect(render["isError"] as? Bool == true && text(render).contains("render_preview"))
    let tm = try await call(s, "import_time_machine")
    #expect(tm["isError"] as? Bool == true && text(tm).contains("backup disk"))
    let bad = try await call(s, "render_preview", ["format": "square"])
    #expect(bad["isError"] as? Bool == true && text(bad).contains("format"))
    let unknown = try await ask(s, "tools/call", ["name": "rm_rf"])
    #expect((unknown["error"] as! [String: Any])["code"] as? Int == -32602)
}

@Test func renderUsesTheRequestedOptions() async throws {
    let data = tmp()
    let log = Log()
    let s = server(data) { log.add($0) }
    _ = try await call(s, "install_recording")
    let r = try await call(s, "render_timelapse", ["format": "portrait", "fps": 24, "background": "white"])
    #expect(r["isError"] == nil)
    #expect(log.items == ["portrait@24/white"])
    let paths = (r["structuredContent"] as! [String: Any])["result"] as! [String]
    #expect(paths == [data.appending(path: "out/dock-portrait-white.mp4").path])
}

final class Log: @unchecked Sendable {
    private(set) var items: [String] = []
    func add(_ s: String) { items.append(s) }
}
