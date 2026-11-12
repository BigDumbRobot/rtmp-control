import AppKit
import Foundation

// MARK: - Shell

enum Shell {
    struct Output {
        let status: Int32
        let text: String
        var lastLine: String {
            text.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: -1, text: error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus,
                                                      text: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

// MARK: - Docker

/// Runs the server's containers with Docker Desktop's command-line tool.
enum Docker {
    static let candidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]
    static var path: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }
    static var desktopInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Docker.app") }

    /// Apps opened from Finder get a minimal PATH; docker needs its credential helpers on it.
    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    static func run(_ args: [String]) async -> Shell.Output {
        guard let path else { return Shell.Output(status: -1, text: "Docker isn't installed.") }
        return await Shell.run(path, args, environment: environment)
    }

    static func daemonRunning() async -> Bool {
        await run(["info", "--format", "{{.ServerVersion}}"]).status == 0
    }

    static func compose(_ folder: String, _ args: [String]) async -> Shell.Output {
        await run(["compose", "--project-directory", folder, "-f", folder + "/compose.yaml"] + args)
    }

    /// true = running, false = exists but stopped, nil = no such container.
    static func containerRunning(_ name: String) async -> Bool? {
        let out = await run(["inspect", "-f", "{{.State.Running}}", name])
        guard out.status == 0 else { return nil }
        return out.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    static func launchDesktop() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Server folder

enum Stack {
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("stack") }

    static func isInstalled(at folder: String) -> Bool {
        FileManager.default.fileExists(atPath: folder + "/compose.yaml")
    }

    /// Creates the server folder from the copy inside the app, if it doesn't exist yet.
    static func installIfNeeded(at folder: String) throws {
        guard !isInstalled(at: folder) else { return }
        guard let bundled, FileManager.default.fileExists(atPath: bundled.path) else {
            throw NSError(domain: "RTMPControl", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No server files found at \(folder)."])
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: bundled.path) {
            let dest = folder + "/" + item
            if !fm.fileExists(atPath: dest) {
                try fm.copyItem(atPath: bundled.appendingPathComponent(item).path, toPath: dest)
            }
        }
        try fm.createDirectory(atPath: folder + "/data", withIntermediateDirectories: true)
    }
}

// MARK: - Admin API (the rtmp-admin container)

struct ServerStatus: Decodable {
    let online: Bool
    let uptime: Double?
    let bwIn: Double?
    let bwOut: Double?
    let streams: [StreamInfo]?
}

struct StreamInfo: Decodable, Identifiable, Equatable {
    let name: String
    let label: String?
    let known: Bool
    let live: Bool
    let bwIn: Double
    let timeMs: Double
    let width: String?
    let height: String?
    let fps: String?
    let vcodec: String?
    let acodec: String?
    let sampleRate: String?
    let channels: String?
    let encoder: String?
    let viewers: Int

    var id: String { name }
    var displayName: String { label ?? (known ? name : "Unknown key") }
    var mbps: Double { bwIn / 1_000_000 }

    var videoText: String? {
        guard let width, let height else { return nil }
        var s = "\(width)×\(height)"
        if let fps, let f = Double(fps), f > 0 { s += " @ \(Int(f.rounded()))" }
        if let vcodec { s += " · \(vcodec)" }
        return s
    }

    var audioText: String? {
        guard let acodec else { return nil }
        var s = acodec
        if let sampleRate, let r = Double(sampleRate), r > 0 { s += " · \(r.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(r / 1000)) : String(format: "%.1f", r / 1000)) kHz" }
        switch channels {
        case "1": s += " · mono"
        case "2": s += " · stereo"
        case let c?: s += " · \(c) ch"
        default: break
        }
        return s
    }
}

struct StreamKey: Decodable, Identifiable, Equatable {
    let key: String
    let label: String
    let enabled: Bool
    let created: Double?
    let lastUsed: Double?
    var id: String { key }
}

struct ServerEvent: Decodable, Identifiable, Equatable {
    let t: Double
    let kind: String
    let key: String
    let detail: String?
    let count: Int?
    var id: String { "\(kind)|\(key)|\(t)" }
    var date: Date { Date(timeIntervalSince1970: t) }
}

struct AdminSettings: Decodable {
    let serverUrl: String?
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum API {
    static let base = URL(string: "http://127.0.0.1:8090")!
    static let dashboardURL = URL(string: "http://localhost:8090")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "No response") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(message: msg ?? "The server answered with error \(http.statusCode).")
        }
    }

    static func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(from: base.appendingPathComponent(path))
        try check(data, response)
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    static func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Admin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try check(data, response)
        return data
    }

    static func status() async throws -> ServerStatus { try await get("api/status") }
    static func keys() async throws -> [StreamKey] { try await get("api/keys") }
    static func events() async throws -> [ServerEvent] { try await get("api/events") }
    static func settings() async throws -> AdminSettings { try await get("api/settings") }

    static func addKey(label: String, custom: String) async throws -> StreamKey {
        let data = try await post("api/keys", ["label": label, "key": custom])
        return try decoder.decode(StreamKey.self, from: data)
    }
    static func setEnabled(_ key: String, _ enabled: Bool) async throws { try await post("api/keys/update", ["key": key, "enabled": enabled]) }
    static func rename(_ key: String, _ label: String) async throws { try await post("api/keys/update", ["key": key, "label": label]) }
    static func delete(_ key: String) async throws { try await post("api/keys/delete", ["key": key]) }
    static func kick(_ key: String) async throws { try await post("api/kick", ["key": key]) }
    static func kickAll() async throws { try await post("api/kick-all", [:]) }
    static func saveServerURL(_ url: String) async throws { try await post("api/settings", ["server_url": url]) }
}
