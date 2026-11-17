import Foundation
import Network

/// A loopback-only HTTP endpoint that lets Claude (through the foley-mcp bridge) drive the open session.
/// Every request must carry the token written to ~/Library/Application Support/mitroley/control.json,
/// which keeps web pages and other users on the machine out.
@MainActor
final class ControlServer {
    private var listener: NWListener?
    private unowned let store: Store
    private let token: String
    private(set) var port: UInt16 = 0

    static var infoURL: URL { AppPaths.support.appendingPathComponent("control.json") }

    init(store: Store) {
        self.store = store
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        start(on: 47810)
    }

    /// Tries a port; if it is taken (another copy of the app), moves to the next one.
    private func start(on candidate: UInt16) {
        guard candidate <= 47815 else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: candidate)!)
        guard let l = try? NWListener(using: params) else { start(on: candidate + 1); return }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            Task { @MainActor in self?.receive(conn, buffer: Data()) }
        }
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = candidate
                    self.publish()
                case .failed:
                    l.cancel()
                    if self.port == 0 { self.start(on: candidate + 1) }
                default: break
                }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    private func publish() {
        let info: [String: Any] = ["port": Int(port), "token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        guard let data = try? JSONSerialization.data(withJSONObject: info) else { return }
        let url = Self.infoURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buf[..<range.lowerBound], as: UTF8.self)
                    let lines = head.components(separatedBy: "\r\n")
                    var headers: [String: String] = [:]
                    for l in lines.dropFirst() {
                        if let c = l.firstIndex(of: ":") {
                            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    let length = Int(headers["content-length"] ?? "0") ?? 0
                    let body = buf[range.upperBound...]
                    if body.count >= length {
                        let parts = (lines.first ?? "").split(separator: " ")
                        let method = parts.count > 0 ? String(parts[0]) : ""
                        let path = parts.count > 1 ? String(parts[1]) : ""
                        let (status, payload) = await self.handle(method: method, path: path, headers: headers, body: Data(body.prefix(length)))
                        self.respond(conn, status: status, json: payload)
                        return
                    }
                }
                if done || error != nil || buf.count > (8 << 20) { conn.cancel(); return }
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Error"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(method: String, path: String, headers: [String: String], body: Data) async -> (Int, [String: Any]) {
        if method == "GET", path == "/health" { return (200, ["app": "Foley"]) }
        guard headers["x-foley-token"] == token else { return (401, ["ok": false, "error": "Missing or wrong token."]) }
        switch (method, path) {
        case ("GET", "/tools"):
            return (200, ["tools": Commands.tools])
        case ("POST", "/call"):
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let name = obj["name"] as? String else {
                return (400, ["ok": false, "error": "Expected {name, arguments}."])
            }
            do {
                let result = try await store.commands.call(name, (obj["arguments"] as? [String: Any]) ?? [:])
                return (200, ["ok": true, "result": result.json, "images": result.images.map { ["label": $0.label, "path": $0.path] }])
            } catch {
                return (200, ["ok": false, "error": error.localizedDescription])
            }
        default:
            return (404, ["ok": false, "error": "Unknown route."])
        }
    }
}
