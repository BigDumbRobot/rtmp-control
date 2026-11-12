import AppKit
import SwiftUI

/// Large status light shown at the top of the panel.
struct StatusLight: View {
    let phase: ServerPhase

    var body: some View {
        ZStack {
            Circle().fill(phase.color.opacity(0.14))
            if phase == .live {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    Circle()
                        .stroke(phase.color.opacity(0.6 * (1 - t)), lineWidth: 2)
                        .scaleEffect(0.45 + 0.55 * t)
                }
            }
            Circle()
                .fill(phase.color.gradient)
                .frame(width: 24, height: 24)
                .shadow(color: phase.color.opacity(phase == .live ? 0.7 : 0), radius: 6)
            if phase.isBusy {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
        .accessibilityLabel(phase.title)
    }
}

/// A titled, rounded group of rows.
struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var copyable = false
    var mono = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .font(mono ? .callout.monospaced() : .callout)
            if copyable { CopyButton(text: value) }
        }
        .font(.callout)
    }
}

struct CopyButton: View {
    let text: String
    var help = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            copyToClipboard(text)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .frame(width: 14)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct Banner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            if pulsing {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    Circle().fill(color).frame(width: 7, height: 7).opacity(0.35 + 0.65 * abs(cos(t * .pi)))
                }
                .frame(width: 7, height: 7)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Bitrate graph for the last few minutes.
struct Sparkline: View {
    let values: [Double]
    let capacity: Int
    var color: Color = .green

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(values.max() ?? 0, 0.5) * 1.15
            let step = w / CGFloat(max(capacity - 1, 1))
            let offset = CGFloat(capacity - values.count) * step
            let points = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step, y: h - CGFloat(v / maxV) * h)
            }
            if points.count >= 2 {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: h))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: h))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.14))
                    Path { p in
                        p.move(to: points[0])
                        points.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
            }
        }
        .accessibilityLabel("Bitrate over the last 3 minutes")
    }
}

enum Format {
    static func duration(seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s % 60)s" }
        return "\(s)s"
    }

    static func mbps(_ bitsPerSecond: Double) -> String {
        String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
    }

    static func ago(_ t: Double?) -> String {
        guard let t else { return "Never used" }
        let s = Date().timeIntervalSince1970 - t
        if s < 60 { return "Used just now" }
        if s < 3600 { return "Used \(Int(s / 60))m ago" }
        if s < 86_400 { return "Used \(Int(s / 3600))h ago" }
        return "Used " + Date(timeIntervalSince1970: t).formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Asks the user to pick a folder. Returns nil if cancelled.
@MainActor
func chooseFolder(title: String, startingAt path: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: path)
    return panel.runModal() == .OK ? panel.url?.path : nil
}
