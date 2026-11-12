import AppKit
import SwiftUI

enum PanelTab: Hashable {
    case live, keys, activity, settings
}

/// The panel that drops down from the menu bar icon.
struct PanelView: View {
    @EnvironmentObject private var monitor: ServerMonitor
    @State private var tab: PanelTab = .live

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                StatusLight(phase: monitor.phase)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.phase.title)
                        .font(.title2.weight(.semibold))
                    Text(monitor.statusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)

            Picker("", selection: $tab) {
                Text(monitor.liveCount > 0 ? "Live (\(monitor.liveCount))" : "Live").tag(PanelTab.live)
                Text("Keys").tag(PanelTab.keys)
                Text("Activity").tag(PanelTab.activity)
                Text("Settings").tag(PanelTab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch tab {
                case .live: LiveTab()
                case .keys: KeysTab()
                case .activity: ActivityTab()
                case .settings: SettingsTab()
                }
            }
            .frame(height: 520)

            Divider()
            FooterBar()
        }
        .frame(width: 390)
        .onAppear { Task { await monitor.refresh(); await monitor.refreshData() } }
    }
}

struct FooterBar: View {
    @EnvironmentObject private var monitor: ServerMonitor
    @EnvironmentObject private var prefs: AppPreferences

    var body: some View {
        HStack(spacing: 14) {
            Button {
                NSWorkspace.shared.open(API.dashboardURL)
            } label: { Label("Dashboard", systemImage: "rectangle.3.group") }
                .disabled(!monitor.phase.isUp)
                .help("Open the full-size dashboard in your browser")

            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: prefs.stackPath)
            } label: { Label("Folder", systemImage: "folder") }
                .help("Show the server folder in Finder")

            Spacer()

            Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }
                .help("Quit RTMP Control (the server keeps running)")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Live

struct LiveTab: View {
    @EnvironmentObject private var monitor: ServerMonitor
    @State private var confirming: Pending?
    @State private var confirmKick: String?

    enum Pending { case stop, restart, kickAll }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                if let pending = confirming { confirmation(for: pending) }
                problemBanners

                if monitor.phase.isUp {
                    if monitor.streams.isEmpty {
                        Card(title: "Live now") {
                            Text("Nobody is streaming right now. Performers connect with the server address and their own key from the Keys tab.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        ForEach(monitor.streams) { stream in
                            StreamCard(stream: stream, confirmKick: $confirmKick)
                        }
                    }
                    serverCard
                }
            }
            .padding(16)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if monitor.phase.isUp || monitor.phase == .stopping {
                Button { request(.stop) } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)

                Button { request(.restart) } label: {
                    Label("Fresh Restart", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .help("Restarts the server and drops every connection, including stuck ones")

                if monitor.liveCount >= 2 {
                    Button { confirming = .kickAll } label: {
                        Label("Kick All", systemImage: "person.2.slash").frame(maxWidth: .infinity)
                    }
                }
            } else {
                Button {
                    Task { await monitor.start() }
                } label: {
                    Label(monitor.phase.isBusy ? "Starting…" : "Start Server", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(monitor.phase == .noDocker)
            }
        }
        .controlSize(.large)
        .disabled(monitor.phase.isBusy)
    }

    @ViewBuilder
    private var problemBanners: some View {
        switch monitor.phase {
        case .noDocker:
            VStack(alignment: .leading, spacing: 8) {
                Banner(text: "The server runs in Docker Desktop, which isn't installed on this Mac.", tint: .red)
                Button("Download Docker Desktop") {
                    NSWorkspace.shared.open(URL(string: "https://www.docker.com/products/docker-desktop/")!)
                }
            }
        case .failed(let message):
            Banner(text: message, tint: .red)
        case .unresponsive:
            Banner(text: "The server is running but not answering. Press Fresh Restart.", tint: .red)
        case .dockerOff:
            Banner(text: "Docker Desktop isn't running. Start opens it for you; it can take a minute.",
                   systemImage: "info.circle.fill", tint: .blue)
        default:
            EmptyView()
        }
        if monitor.phase.isUp, monitor.serverURLIsPlaceholder {
            Banner(text: "Set the server address performers use in Settings, so the setup messages you send them are correct.",
                   systemImage: "info.circle.fill", tint: .blue)
        }
        if let error = monitor.lastError {
            Banner(text: error, tint: .red)
        }
    }

    private func request(_ action: Pending) {
        if monitor.liveCount > 0 { confirming = action } else { perform(action) }
    }

    private func perform(_ action: Pending) {
        confirming = nil
        Task {
            switch action {
            case .stop: await monitor.stop()
            case .restart: await monitor.restart()
            case .kickAll: await monitor.kickAll()
            }
        }
    }

    private func confirmation(for action: Pending) -> some View {
        let n = monitor.liveCount
        let who = "\(n) performer\(n == 1 ? " is" : "s are") live."
        let text: String
        let button: String
        switch action {
        case .stop:
            text = "\(who) Stopping the server disconnects them, and they can't reconnect until you start it again."
            button = "Stop Anyway"
        case .restart:
            text = "\(who) A fresh restart disconnects them for a few seconds. Most encoders reconnect by themselves."
            button = "Restart Anyway"
        case .kickAll:
            text = "Disconnect all \(n) live performers? Their encoders may reconnect automatically."
            button = "Kick All"
        }
        return VStack(alignment: .leading, spacing: 10) {
            Banner(text: text)
            HStack {
                Spacer()
                Button("Cancel") { confirming = nil }
                    .keyboardShortcut(.cancelAction)
                Button(button) { perform(action) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
    }

    private var serverCard: some View {
        Card(title: "Server") {
            if let s = monitor.status {
                InfoRow(label: "Running for", value: Format.duration(seconds: s.uptime ?? 0))
                InfoRow(label: "Total in / out", value: "\(Format.mbps(s.bwIn ?? 0))  /  \(Format.mbps(s.bwOut ?? 0))")
            }
            InfoRow(label: "Performers connect to",
                    value: monitor.serverURLIsPlaceholder ? "Not set (see Settings)" : monitor.serverURL,
                    copyable: !monitor.serverURLIsPlaceholder, mono: !monitor.serverURLIsPlaceholder)
            InfoRow(label: "OBS pulls from", value: "rtmp://localhost:1935/live/<key>", mono: true)
        }
    }
}

struct StreamCard: View {
    @EnvironmentObject private var monitor: ServerMonitor
    let stream: StreamInfo
    @Binding var confirmKick: String?

    var body: some View {
        let health = monitor.health(of: stream)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stream.displayName).font(.headline)
                    Text(stream.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Pill(text: health.title, color: health.color, pulsing: health == .good)
            }

            if stream.live {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.2f", stream.mbps))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("Mbps in").font(.callout).foregroundStyle(.secondary)
                }
                Sparkline(values: monitor.history[stream.name] ?? [], capacity: ServerMonitor.historyLength,
                          color: health.color)
                    .frame(height: 38)
                if health == .unstable || health == .noData {
                    Text("Bitrate is dropping. The performer's upload connection may be struggling. Ask them to lower their bitrate or use a wired connection.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 4) {
                    InfoRow(label: "Live for", value: Format.duration(seconds: stream.timeMs / 1000))
                    if let v = stream.videoText { InfoRow(label: "Video", value: v) }
                    if let a = stream.audioText { InfoRow(label: "Audio", value: a) }
                    if let e = stream.encoder { InfoRow(label: "Encoder", value: e) }
                    InfoRow(label: "Viewers", value: stream.viewers == 0 ? "None (OBS isn't pulling it)" : "\(stream.viewers)")
                }
                if !stream.known {
                    Text("This key isn't in your list. It may have been deleted while live.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if confirmKick == stream.name {
                    HStack {
                        Text("Disconnect \(stream.displayName)?").font(.callout)
                        Spacer()
                        Button("Cancel") { confirmKick = nil }
                        Button("Kick") {
                            confirmKick = nil
                            Task { await monitor.kick(stream.name) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    .controlSize(.small)
                } else {
                    HStack {
                        Spacer()
                        Button(role: .destructive) { confirmKick = stream.name } label: {
                            Label("Kick", systemImage: "xmark.circle")
                        }
                        .controlSize(.small)
                        .help("Disconnect this performer. Their encoder may reconnect by itself.")
                    }
                }
            } else {
                Text("OBS is connected and waiting for this performer to start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(stream.live ? health.color.opacity(0.45) : .clear, lineWidth: 1))
    }
}

// MARK: - Keys

struct KeysTab: View {
    @EnvironmentObject private var monitor: ServerMonitor
    @State private var name = ""
    @State private var custom = ""
    @State private var showCustom = false
    @State private var justAdded: StreamKey?
    @State private var pendingDelete: StreamKey?
    @State private var renaming: String?
    @State private var newLabel = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !monitor.phase.isUp {
                    Banner(text: "Start the server to add or change keys.", systemImage: "info.circle.fill", tint: .blue)
                }
                addCard
                if let added = justAdded { addedCard(added) }
                if let k = pendingDelete { deleteConfirmation(k) }
                if let error = monitor.lastError { Banner(text: error, tint: .red) }

                Card(title: "Stream keys (\(monitor.keys.count))") {
                    if monitor.keys.isEmpty {
                        Text("No keys yet. Add a performer above.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(monitor.keys.reversed().enumerated()), id: \.element.id) { i, k in
                            if i > 0 { Divider() }
                            row(k)
                        }
                    }
                }
            }
            .padding(16)
            .disabled(!monitor.phase.isUp)
        }
    }

    private var addCard: some View {
        Card(title: "Add a performer") {
            HStack {
                TextField("Performer name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add Key", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            DisclosureGroup("Use a specific key", isExpanded: $showCustom) {
                TextField("e.g. maria-k7f2xq9p", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .padding(.top, 4)
            }
            .font(.callout)
            Text("A hard-to-guess key is created automatically. Each performer gets their own key, so nobody blocks anyone else.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        let label = name.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        Task {
            if let k = await monitor.addKey(label: label, custom: showCustom ? custom.trimmingCharacters(in: .whitespaces) : "") {
                justAdded = k
                name = ""
                custom = ""
                showCustom = false
            }
        }
    }

    private func addedCard(_ k: StreamKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Banner(text: "Key created for \(k.label): \(k.key)", systemImage: "checkmark.circle.fill", tint: .green)
            HStack {
                Button("Copy Setup Message") {
                    copyToClipboard(monitor.setupMessage(for: k))
                    justAdded = nil
                }
                .buttonStyle(.borderedProminent)
                Button("Copy Key") { copyToClipboard(k.key) }
                Spacer()
                Button("Done") { justAdded = nil }
            }
            .controlSize(.small)
        }
    }

    private func deleteConfirmation(_ k: StreamKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Banner(text: monitor.isLive(k.key)
                   ? "\(k.label) is live. Deleting their key disconnects them and they can't reconnect."
                   : "Delete \(k.label)'s key? They won't be able to stream with it any more.")
            HStack {
                Spacer()
                Button("Cancel") { pendingDelete = nil }
                Button("Delete Key") {
                    pendingDelete = nil
                    Task { await monitor.delete(k.key) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func row(_ k: StreamKey) -> some View {
        let live = monitor.isLive(k.key)
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(!k.enabled ? Color.gray.opacity(0.4) : live ? .green : .gray)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                if renaming == k.key {
                    TextField("Name", text: $newLabel)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let label = newLabel
                            renaming = nil
                            Task { await monitor.rename(k.key, label) }
                        }
                        .onExitCommand { renaming = nil }
                } else {
                    HStack(spacing: 6) {
                        Text(k.label).font(.callout.weight(.semibold))
                        if live { Pill(text: "Live", color: .green) }
                        if !k.enabled { Pill(text: "Disabled", color: .gray) }
                    }
                }
                HStack(spacing: 4) {
                    Text(k.key).font(.caption.monospaced()).textSelection(.enabled)
                    CopyButton(text: k.key, help: "Copy key").controlSize(.small)
                }
                .foregroundStyle(.secondary)
                Text(Format.ago(k.lastUsed)).font(.caption2).foregroundStyle(.tertiary)
            }
            .opacity(k.enabled ? 1 : 0.6)
            Spacer()
            Menu {
                Button("Copy Setup Message") { copyToClipboard(monitor.setupMessage(for: k)) }
                Button("Copy Key") { copyToClipboard(k.key) }
                Button("Rename…") { newLabel = k.label; renaming = k.key }
                Divider()
                if live {
                    Button("Kick") { Task { await monitor.kick(k.key) } }
                }
                Button(k.enabled ? "Disable" : "Enable") {
                    Task { await monitor.setEnabled(k.key, !k.enabled) }
                }
                Button("Delete…", role: .destructive) { pendingDelete = k }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

// MARK: - Activity

struct ActivityTab: View {
    @EnvironmentObject private var monitor: ServerMonitor

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if monitor.events.isEmpty {
                    Text(monitor.phase.isUp ? "No activity yet." : "Start the server to see activity.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                }
                ForEach(monitor.events.prefix(200)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(color(e)).frame(width: 8, height: 8)
                        (Text(text(e)) + Text((e.count ?? 1) > 1 ? "  ×\(e.count!)" : "").foregroundColor(.secondary))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Text(e.date.formatted(Calendar.current.isDateInToday(e.date)
                                              ? .dateTime.hour().minute().second()
                                              : .dateTime.month(.abbreviated).day().hour().minute()))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 7)
                    Divider()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func color(_ e: ServerEvent) -> Color {
        switch e.kind {
        case "live": return .green
        case "rejected": return .red
        case "disabled", "kicked": return .orange
        case "added", "removed", "changed": return .blue
        default: return .gray
        }
    }

    private func text(_ e: ServerEvent) -> String {
        let name = monitor.label(for: e.key)
        switch e.kind {
        case "live": return "\(name) started streaming"
        case "ended": return "\(name) stopped streaming"
        case "rejected": return "Rejected unknown key “\(e.key)”"
        case "disabled": return "Blocked disabled key: \(name)"
        case "kicked": return "Kicked \(name)"
        case "added": return "Added key for \(e.detail ?? name)"
        case "removed": return "Deleted key for \(e.detail ?? name)"
        case "changed": return "\(e.detail == "enabled" ? "Enabled" : "Disabled") \(name)"
        default: return "\(e.kind) \(e.key)"
        }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @EnvironmentObject private var monitor: ServerMonitor
    @EnvironmentObject private var prefs: AppPreferences
    @State private var url = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $url, prompt: Text("rtmp://your.address:1935/live"))
                    .font(.callout.monospaced())
                    .onSubmit(save)
                HStack {
                    if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(.green).font(.callout) }
                    Spacer()
                    Button("Save", action: save)
                        .disabled(!monitor.phase.isUp || url == monitor.serverURL || url.isEmpty)
                }
            } header: {
                Text("Address performers stream to")
            } footer: {
                Text("Your public IP or host name, e.g. rtmp://stream.example.com:1935/live. Your router must forward TCP port 1935 to this Mac. This goes into the setup messages you copy for performers.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Start server when this app opens", isOn: $prefs.startServerOnLaunch)
                Toggle("Open RTMP Control at login", isOn: Binding(get: { prefs.launchAtLogin },
                                                                    set: { prefs.launchAtLogin = $0 }))
                if let e = prefs.loginItemError { Text(e).font(.caption).foregroundStyle(.red) }
                LabeledContent("Server folder") {
                    HStack(spacing: 6) {
                        Text(prefs.stackPath)
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Change…") {
                            if let p = chooseFolder(title: "Choose the RTMP server folder", startingAt: prefs.stackPath) {
                                prefs.stackPath = p
                            }
                        }
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("The server runs in Docker Desktop. For a machine that should always be ready, also turn on “Start Docker Desktop when you sign in” in Docker's settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("When performers go live or stop", isOn: $prefs.notifyPerformers)
                Toggle("Problems (unstable stream, rejected key, server down)", isOn: $prefs.notifyProblems)
            }

            Section("Menu bar") {
                Toggle("Show status text next to the icon", isOn: $prefs.showTextInMenuBar)
            }
        }
        .formStyle(.grouped)
        .onAppear { url = monitor.serverURLIsPlaceholder ? "" : monitor.serverURL }
    }

    private func save() {
        let value = url.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        Task {
            if await monitor.saveServerURL(value) {
                saved = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                saved = false
            }
        }
    }
}
