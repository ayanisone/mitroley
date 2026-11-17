import Foundation

// foley-mcp: a Model Context Protocol server (stdio) that forwards tool calls to the running Foley app.
// It holds no logic of its own; the app defines the tools. Register it with a client, for example:
//   claude mcp add mitroley -- /Applications/mitroley.app/Contents/MacOS/foley-mcp

let infoURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("mitroley/control.json")

struct BridgeError: Error { var message: String }

func control() -> (port: Int, token: String)? {
    guard let data = try? Data(contentsOf: infoURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = obj["port"] as? Int, let token = obj["token"] as? String else { return nil }
    return (port, token)
}

func http(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 900) throws -> [String: Any] {
    guard let c = control() else { throw BridgeError(message: "mitroley has not been opened on this Mac yet.") }
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(c.port)\(path)")!)
    req.httpMethod = method
    req.timeoutInterval = timeout
    req.setValue(c.token, forHTTPHeaderField: "X-Foley-Token")
    if let body {
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let sem = DispatchSemaphore(value: 0)
    var result: Result<[String: Any], Error> = .failure(BridgeError(message: "No response."))
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    URLSession(configuration: config).dataTask(with: req) { data, _, error in
        if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result = .success(obj)
        } else {
            result = .failure(BridgeError(message: error?.localizedDescription ?? "mitroley returned something unreadable."))
        }
        sem.signal()
    }.resume()
    sem.wait()
    return try result.get()
}

/// Makes sure the app is up, launching it if needed.
func ensureApp() throws {
    if (try? http("GET", "/health", timeout: 2)) != nil { return }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    open.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", "studio.foley.app"]
    try? open.run()
    open.waitUntilExit()
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.5)
        if (try? http("GET", "/health", timeout: 2)) != nil { return }
    }
    throw BridgeError(message: "mitroley is not running and could not be started. Open the mitroley app, then try again.")
}

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, _ code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }
func toolError(_ id: Any, _ message: String) {
    reply(id, ["content": [["type": "text", "text": message]], "isError": true])
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8), !data.isEmpty,
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = msg["method"] as? String else { continue }
    guard let id = msg["id"] else { continue }   // notifications need no reply
    let params = (msg["params"] as? [String: Any]) ?? [:]
    switch method {
    case "initialize":
        reply(id, [
            "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "mitroley", "version": "0.1.0"],
            "instructions": "mitroley is a Mac app for fitting sound effects and ambience to a video. These tools edit the session that is open in the app. Start with get_project, then analyze_video to see the picture. Scenes map time ranges to acoustic spaces; tracks that follow the scene take on that space automatically.",
        ])
    case "ping":
        reply(id, [:])
    case "tools/list":
        do {
            try ensureApp()
            let tools = (try http("GET", "/tools")["tools"] as? [[String: Any]]) ?? []
            reply(id, ["tools": tools.map { t -> [String: Any] in
                ["name": t["name"] ?? "", "description": t["description"] ?? "", "inputSchema": t["input_schema"] ?? [:]]
            }])
        } catch let e as BridgeError { fail(id, -32000, e.message) } catch { fail(id, -32000, error.localizedDescription) }
    case "tools/call":
        do {
            try ensureApp()
            let out = try http("POST", "/call", body: ["name": params["name"] ?? "", "arguments": params["arguments"] ?? [:]])
            guard out["ok"] as? Bool == true else {
                toolError(id, (out["error"] as? String) ?? "mitroley could not do that.")
                break
            }
            var text = "{}"
            if let r = out["result"], let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
                text = String(decoding: d, as: UTF8.self)
            }
            var content: [[String: Any]] = [["type": "text", "text": text]]
            for img in (out["images"] as? [[String: Any]]) ?? [] {
                guard let path = img["path"] as? String, let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
                content.append(["type": "text", "text": (img["label"] as? String) ?? path])
                content.append(["type": "image", "data": bytes.base64EncodedString(), "mimeType": "image/jpeg"])
            }
            reply(id, ["content": content])
        } catch let e as BridgeError { toolError(id, e.message) } catch { toolError(id, error.localizedDescription) }
    default:
        fail(id, -32601, "Method not found: \(method)")
    }
}
