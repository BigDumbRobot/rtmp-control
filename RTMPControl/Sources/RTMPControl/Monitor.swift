import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Preferences

@MainActor
final class AppPreferences: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var stackPath: String { didSet { defaults.set(stackPath, forKey: "stackPath") } }
    @Published var startServerOnLaunch: Bool { didSet { defaults.set(startServerOnLaunch, forKey: "startServerOnLaunch") } }
    @Published var notifyPerformers: Bool { didSet { defaults.set(notifyPerformers, forKey: "notifyPerformers"); if notifyPerformers { Notifier.requestPermission() } } }
    @Published var notifyProblems: Bool { didSet { defaults.set(notifyProblems, forKey: "notifyProblems"); if notifyProblems { Notifier.requestPermission() } } }
    @Published var showTextInMenuBar: Bool { didSet { defaults.set(showTextInMenuBar, forKey: "showTextInMenuBar") } }
    @Published private(set) var loginItemError: String?

    init() {
        stackPath = defaults.string(forKey: "stackPath")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("rtmp-server").path
        startServerOnLaunch = defaults.object(forKey: "startServerOnLaunch") as? Bool ?? true
        notifyPerformers = defaults.object(forKey: "notifyPerformers") as? Bool ?? true
        notifyProblems = defaults.object(forKey: "notifyProblems") as? Bool ?? true
        showTextInMenuBar = defaults.object(forKey: "showTextInMenuBar") as? Bool ?? true
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = "Couldn't change login item: \(error.localizedDescription)"
            }
        }
    }
}

enum Notifier {
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Phase

enum ServerPhase: Equatable {
    case checking
    case noDocker
    case dockerOff
    case stopped
    case starting(String)
    case stopping
    /// Server up, nobody streaming.
    case ready
    /// Server up, at least one performer live.
    case live
    case unresponsive
    case failed(String)

    var isUp: Bool { self == .ready || self == .live || self == .unresponsive }
    var isBusy: Bool {
        switch self {
        case .starting, .stopping, .checking: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .checking: return "Checking…"
        case .noDocker: return "Docker Needed"
        case .dockerOff: return "Server Off"
        case .stopped: return "Server Stopped"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .ready: return "Server Ready"
        case .live: return "Live"
        case .unresponsive: return "Not Responding"
        case .failed: return "Couldn't Start"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .live: return .systemGreen
        case .ready: return .systemOrange
        case .unresponsive, .failed, .noDocker: return .systemRed
        case .starting, .stopping, .checking: return .systemBlue
        case .stopped, .dockerOff: return .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

enum StreamHealth {
    case good, unstable, noData, waiting

    var title: String {
        switch self {
        case .good: return "Live"
        case .unstable: return "Unstable"
        case .noData: return "No data"
        case .waiting: return "Waiting"
        }
    }

    var color: Color {
        switch self {
        case .good: return .green
        case .unstable: return .orange
        case .noData: return .red
        case .waiting: return .gray
        }
    }
}

// MARK: - Monitor

/// Watches the RTMP server, starts/stops it through Docker, and manages stream keys.
@MainActor
final class ServerMonitor: ObservableObject {
    @Published private(set) var phase: ServerPhase = .checking
    @Published private(set) var status: ServerStatus?
    @Published private(set) var keys: [StreamKey] = []
    @Published private(set) var events: [ServerEvent] = []
    @Published private(set) var serverURL: String = ""
    /// Recent incoming bitrate per stream, in Mbps (one sample per refresh, 3 minutes).
    @Published private(set) var history: [String: [Double]] = [:]
    @Published var lastError: String?

    static let historyLength = 90
    let prefs: AppPreferences

    private var timer: Timer?
    private var refreshing = false
    private var operationInProgress = false
    private var tick = 0
    private var apiFailures = 0
    private var knownLive: Set<String>?
    private var unstableSince: [String: Date] = [:]
    private var notifiedUnstable: Set<String> = []
    private var notifiedRejected: [String: Date] = [:]
    private var lastEventTime: Double?

    init(prefs: AppPreferences) {
        self.prefs = prefs
    }

    var streams: [StreamInfo] {
        (status?.streams ?? []).sorted { a, b in a.live != b.live ? a.live : a.displayName < b.displayName }
    }
    var liveStreams: [StreamInfo] { streams.filter(\.live) }
    var liveCount: Int { liveStreams.count }

    var statusDetail: String {
        switch phase {
        case .checking: return "Looking for the RTMP server"
        case .noDocker: return "Install Docker Desktop to run the server"
        case .dockerOff: return "Docker isn't running · press Start"
        case .stopped: return "Press Start to put the server online"
        case .starting(let step): return step
        case .stopping: return "Shutting down"
        case .ready: return "Waiting for performers · \(keys.filter(\.enabled).count) active key\(keys.filter(\.enabled).count == 1 ? "" : "s")"
        case .live:
            let names = liveStreams.map(\.displayName)
            return names.count <= 2 ? names.joined(separator: " & ") + " streaming" : "\(names.count) performers streaming"
        case .unresponsive: return "The server is running but not answering"
        case .failed(let message): return message
        }
    }

    var menuBarText: String? {
        switch phase {
        case .live: return "LIVE \(liveCount)"
        case .ready: return "READY"
        case .unresponsive, .failed, .noDocker: return "ERROR"
        case .stopped, .dockerOff: return "OFF"
        case .starting, .stopping, .checking: return "…"
        }
    }

    func health(of stream: StreamInfo) -> StreamHealth {
        guard stream.live else { return .waiting }
        let recent = Array((history[stream.name] ?? []).suffix(10))
        guard recent.count >= 4 else { return .good }
        let avg = recent.reduce(0, +) / Double(recent.count)
        if avg < 0.05 { return .noData }
        if (recent.min() ?? 0) < avg * 0.4 { return .unstable }
        return .good
    }

    func label(for key: String) -> String {
        keys.first { $0.key == key }?.label ?? key
    }

    func isLive(_ key: String) -> Bool { liveStreams.contains { $0.name == key } }

    // MARK: Loop

    func begin() {
        Notifier.requestPermission()
        Task {
            await refresh()
            if prefs.startServerOnLaunch, phase == .stopped || phase == .dockerOff { await start() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !refreshing, !operationInProgress else { return }
        refreshing = true
        defer { refreshing = false }
        tick += 1

        if let s = try? await API.status() {
            guard !operationInProgress else { return }
            apiFailures = 0
            if s.online {
                status = s
                recordHistory(s)
                transition(to: (s.streams ?? []).contains(where: \.live) ? .live : .ready)
                checkStreamChanges()
            } else {
                status = nil
                transition(to: .unresponsive)
            }
            // Keys/events/settings change less often.
            if tick % 2 == 0 || keys.isEmpty { await refreshData() }
            return
        }

        // Admin API not answering: find out why.
        apiFailures += 1
        let next: ServerPhase
        if Docker.path == nil {
            next = .noDocker
        } else if !(await Docker.daemonRunning()) {
            next = .dockerOff
        } else {
            let rtmp = await Docker.containerRunning("rtmp")
            let admin = await Docker.containerRunning("rtmp-admin")
            if rtmp == true || admin == true {
                // Allow a couple of misses (e.g. the admin service restarting itself).
                next = apiFailures >= 3 ? .unresponsive : (phase.isUp ? phase : .checking)
            } else {
                next = .stopped
            }
        }
        guard !operationInProgress else { return }
        if !next.isUp { status = nil; history = [:] }
        if case .failed = phase, next == .stopped || next == .dockerOff { return }
        transition(to: next)
    }

    func refreshData() async {
        async let k = try? API.keys()
        async let e = try? API.events()
        async let s = try? API.settings()
        let (keys, events, settings) = await (k, e, s)
        if let keys { self.keys = keys }
        if let events {
            notifyNewEvents(events)
            self.events = events
        }
        if let url = settings?.serverUrl { serverURL = url }
    }

    private func recordHistory(_ s: ServerStatus) {
        var next: [String: [Double]] = [:]
        for stream in s.streams ?? [] where stream.live {
            var h = history[stream.name] ?? []
            h.append(stream.mbps)
            if h.count > Self.historyLength { h.removeFirst(h.count - Self.historyLength) }
            next[stream.name] = h
        }
        history = next
    }

    private func transition(to next: ServerPhase) {
        let old = phase
        guard old != next else { return }
        phase = next
        guard prefs.notifyProblems, old != .checking, !old.isBusy else { return }
        switch (old, next) {
        case (let previous, .stopped) where previous.isUp, (let previous, .dockerOff) where previous.isUp:
            Notifier.post("RTMP Server Stopped", "The server stopped unexpectedly. Performers can't connect.")
        case (_, .unresponsive):
            Notifier.post("RTMP Server Not Responding", "The server is running but not answering. Try Restart.")
        default:
            break
        }
    }

    private func checkStreamChanges() {
        let live = Set(liveStreams.map(\.name))
        defer { knownLive = live }
        // Unstable streams (notify once per episode, after it's lasted ~10 s).
        for stream in liveStreams {
            if health(of: stream) == .unstable || health(of: stream) == .noData {
                let since = unstableSince[stream.name] ?? Date()
                unstableSince[stream.name] = since
                if Date().timeIntervalSince(since) > 10, !notifiedUnstable.contains(stream.name) {
                    notifiedUnstable.insert(stream.name)
                    if prefs.notifyProblems {
                        Notifier.post("\(stream.displayName)'s stream is unstable",
                                      "Their bitrate is dropping. Their upload connection may be struggling.")
                    }
                }
            } else {
                unstableSince[stream.name] = nil
                notifiedUnstable.remove(stream.name)
            }
        }
        guard let before = knownLive, prefs.notifyPerformers else { return }
        for name in live.subtracting(before) {
            Notifier.post("\(label(for: name)) is live", "Streaming on key \(name).")
        }
        for name in before.subtracting(live) {
            Notifier.post("\(label(for: name)) stopped streaming", "The stream on key \(name) ended.")
            unstableSince[name] = nil
            notifiedUnstable.remove(name)
        }
    }

    private func notifyNewEvents(_ list: [ServerEvent]) {
        defer { lastEventTime = list.map(\.t).max() ?? lastEventTime }
        guard let since = lastEventTime, prefs.notifyProblems else { return }
        for event in list where event.t > since && event.kind == "rejected" {
            // At most once per key every 10 minutes (encoders retry constantly).
            if let last = notifiedRejected[event.key], Date().timeIntervalSince(last) < 600 { continue }
            notifiedRejected[event.key] = Date()
            Notifier.post("Unknown stream key rejected",
                          "Someone tried to stream with “\(event.key)”. If it's a performer, add the key in RTMP Control.")
        }
    }

    // MARK: Start / stop

    func start() async {
        guard !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        lastError = nil
        phase = .starting("Preparing")

        guard Docker.path != nil else { phase = .noDocker; return }
        do {
            try Stack.installIfNeeded(at: prefs.stackPath)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        if !(await Docker.daemonRunning()) {
            phase = .starting("Opening Docker Desktop")
            Docker.launchDesktop()
            var up = false
            for _ in 0..<90 {   // up to ~3 minutes on a cold start
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if await Docker.daemonRunning() { up = true; break }
            }
            guard up else {
                phase = .failed("Docker Desktop didn't start. Open it once by hand, accept any prompts, then press Start again.")
                return
            }
        }

        phase = .starting("Starting the server")
        let out = await Docker.compose(prefs.stackPath, ["up", "-d"])
        guard out.status == 0 else {
            phase = .failed(Self.explain(out))
            return
        }
        await waitForAPI()
    }

    func stop() async {
        guard !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        phase = .stopping
        let out = await Docker.compose(prefs.stackPath, ["stop"])
        status = nil
        history = [:]
        knownLive = nil
        phase = out.status == 0 ? .stopped : .failed(Self.explain(out))
    }

    /// Fresh start: recreates both containers, which drops every connection (including ghost sessions).
    func restart() async {
        guard !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        lastError = nil
        phase = .starting("Restarting the server")
        status = nil
        history = [:]
        knownLive = nil
        guard await Docker.daemonRunning() else {
            operationInProgress = false
            await start()
            return
        }
        let out = await Docker.compose(prefs.stackPath, ["up", "-d", "--force-recreate"])
        guard out.status == 0 else {
            phase = .failed(Self.explain(out))
            return
        }
        await waitForAPI()
    }

    private func waitForAPI() async {
        phase = .starting("Waiting for the server")
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let s = try? await API.status(), s.online {
                status = s
                phase = (s.streams ?? []).contains(where: \.live) ? .live : .ready
                operationInProgress = false
                await refreshData()
                return
            }
        }
        phase = .failed("The server started but isn't answering. Try Restart.")
    }

    private static func explain(_ out: Shell.Output) -> String {
        let lower = out.text.lowercased()
        if lower.contains("port is already allocated") || lower.contains("address already in use") {
            return "Port 1935 or 8090 is already in use by another program or container."
        }
        if lower.contains("pull access denied") || lower.contains("dial tcp") || lower.contains("timeout") {
            return "Couldn't download the server software. Check the internet connection."
        }
        if lower.contains("no such file") || lower.contains("no configuration file") {
            return "Server files are missing. Check the server folder in Settings."
        }
        return out.lastLine.isEmpty ? "Docker reported an error." : out.lastLine
    }

    // MARK: Actions

    private func act(_ work: () async throws -> Void) async {
        do {
            try await work()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshData()
        if let s = try? await API.status(), s.online { status = s }
    }

    func kick(_ key: String) async { await act { try await API.kick(key) } }
    func kickAll() async { await act { try await API.kickAll() } }
    func setEnabled(_ key: String, _ enabled: Bool) async { await act { try await API.setEnabled(key, enabled) } }
    func rename(_ key: String, _ label: String) async { await act { try await API.rename(key, label) } }
    func delete(_ key: String) async { await act { try await API.delete(key) } }

    func addKey(label: String, custom: String) async -> StreamKey? {
        do {
            let k = try await API.addKey(label: label, custom: custom)
            lastError = nil
            await refreshData()
            return k
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func saveServerURL(_ url: String) async -> Bool {
        do {
            try await API.saveServerURL(url)
            serverURL = url
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setupMessage(for key: StreamKey) -> String {
        """
        Hi \(key.label), here are your streaming settings:

        Server: \(serverURL)
        Stream key: \(key.key)

        Recommended: 1080p30 at 4–6 Mbps CBR (or 720p30 at 2.5–4 Mbps), keyframe interval 2 s, \
        AAC audio 48 kHz 160 kbps. Please use a wired connection if you can.
        """
    }

    var serverURLIsPlaceholder: Bool { serverURL.isEmpty || serverURL.contains("YOUR-PUBLIC-ADDRESS") }
}
