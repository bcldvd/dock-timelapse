import Foundation

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0), with no dependencies.
/// It speaks the parts of MCP a tools-only server needs: initialize, ping, tools/list, tools/call.
public final class MCPServer: @unchecked Sendable {
    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    let tools: DockTools
    let name: String
    let version: String

    public init(tools: DockTools, name: String = "dock-timelapse", version: String = "0.3.0") {
        self.tools = tools
        self.name = name
        self.version = version
    }

    /// Serve until stdin closes.
    public func run() async {
        while let line = readLine(strippingNewline: true) {
            guard let reply = await handle(line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    /// One message in, at most one message out (notifications get no reply).
    public func handle(_ line: String) async -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            return id == nil ? nil : error(id!, -32600, "Invalid request")
        }
        if id == nil { return nil }  // notifications (initialized, cancelled, …)
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? Self.protocolVersions[0]
            return result(id!, [
                "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": name, "title": "Dock Timelapse", "version": version],
                "instructions": DockTools.instructions,
            ])
        case "ping":
            return result(id!, [:])
        case "tools/list":
            return result(id!, ["tools": DockTools.definitions])
        case "tools/call":
            guard let tool = params["name"] as? String else { return error(id!, -32602, "Missing tool name") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard DockTools.definitions.contains(where: { $0["name"] as? String == tool }) else {
                return error(id!, -32602, "Unknown tool: \(tool)")
            }
            return result(id!, await tools.call(tool, args))
        default:
            return error(id!, -32601, "Method not found: \(method)")
        }
    }

    func result(_ id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func error(_ id: Any, _ code: Int, _ message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])
        else { return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"# }
        return String(decoding: data, as: UTF8.self)
    }
}
