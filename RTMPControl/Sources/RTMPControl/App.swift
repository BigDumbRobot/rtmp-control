import AppKit
import SwiftUI
import UserNotifications

@main
struct RTMPControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model.prefs)
                .environmentObject(model.monitor)
        } label: {
            MenuBarLabel(monitor: model.monitor, prefs: model.prefs)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let prefs: AppPreferences
    let monitor: ServerMonitor

    init() {
        prefs = AppPreferences()
        monitor = ServerMonitor(prefs: prefs)
        monitor.begin()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Menu bar icon: colour shows the state at a glance.
struct MenuBarLabel: View {
    @ObservedObject var monitor: ServerMonitor
    @ObservedObject var prefs: AppPreferences

    var body: some View {
        let image = Self.icon(for: monitor.phase)
        if prefs.showTextInMenuBar, let text = monitor.menuBarText {
            HStack(spacing: 4) {
                Image(nsImage: image)
                Text(text)
            }
        } else {
            Image(nsImage: image)
        }
    }

    static func icon(for phase: ServerPhase) -> NSImage {
        let up = phase.isUp || phase.isBusy
        let name = up ? "video.fill" : "video.slash.fill"
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let plain = phase == .stopped || phase == .dockerOff
        if !plain {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: [phase.nsColor]))
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: phase.title)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = plain
        return image
    }
}
