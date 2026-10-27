import AppKit
import SwiftUI

/// Diagnostic run used while developing: `Mixer --selftest <app-id> <volume> <seconds>`.
/// Prints the engine state every second, sets the app's volume after two seconds,
/// restores it at the end and quits.
@MainActor
final class SelfTest {
    private let model: MixerModel
    private let target: String?
    private let volume: Double
    private let duration: TimeInterval
    private let startedAt = Date()
    private var applied = false
    private var timer: Timer?

    init(model: MixerModel, arguments: [String]) {
        self.model = model
        target = arguments.first.flatMap { $0 == "-" ? nil : $0 }
        volume = arguments.count > 1 ? Double(arguments[1]) ?? 0.25 : 0.25
        duration = arguments.count > 2 ? Double(arguments[2]) ?? 12 : 12
    }

    func run() {
        model.log = { Self.emit("log: " + $0) }
        Self.emit("selftest target=\(target ?? "-") volume=\(volume) duration=\(duration)")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(startedAt)
        if let target, !applied, elapsed > 2, model.apps.contains(where: { $0.id == target }) {
            model.setVolume(volume, for: target)
            applied = true
            Self.emit("applied volume \(volume) to \(target)")
        }
        Self.emit(String(format: "t=%.0f ", elapsed) + model.diagnostics())

        if elapsed > duration {
            timer?.invalidate()
            if let target { model.reset(target) }
            Self.emit("selftest done")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.terminate(nil)
            }
        }
    }

    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

/// `Mixer --snapshot <dir>` renders the panel with sample rows to PNGs (light and dark) and quits.
@MainActor
enum PanelSnapshot {
    static func run(directory: String) {
        let model = previewModel()

        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let backdrop = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
            let view = NSHostingView(rootView: MixerView(model: model) { _ in }
                .background(Color(nsColor: backdrop)))
            view.appearance = appearance
            let size = view.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let path = (directory as NSString).appendingPathComponent(dark ? "panel-dark.png" : "panel-light.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) \(size)")
        }
        fflush(stdout)
        NSApp.terminate(nil)
    }

    static func previewModel() -> MixerModel {
        let model = MixerModel()
        let names = ["com.google.Chrome", "com.spotify.client", "ru.keepcoder.Telegram", "com.hnc.Discord", "com.apple.Safari"]
        var items: [AppItem] = []
        let volumes: [(Double, Bool, Bool)] = [(0.62, false, true), (1, false, true), (0.35, true, false), (0.8, false, false), (0.15, false, false)]
        for (index, id) in names.enumerated() {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let (volume, muted, playing) = volumes[index]
            items.append(AppItem(id: id, name: name, icon: NSWorkspace.shared.icon(forFile: url.path), processObjects: [],
                                 isPlaying: playing, volume: volume, isMuted: muted))
        }
        model.loadPreview(items, master: 0.44, output: OutputInfo(name: "Динамики MacBook Pro", symbol: "laptopcomputer", hasVolume: true, canMute: true))
        return model
    }
}

/// `Mixer --capture <dir> [light|dark]` opens the real panel with sample rows, photographs its
/// window (shadow and rim included) and quits. Used to check the panel's outline.
@MainActor
enum PanelCapture {
    private static var keepAlive: [AnyObject] = []

    static func run(directory: String) {
        let arguments = ProcessInfo.processInfo.arguments
        let appearance = arguments.contains("light") ? "light" : arguments.contains("dark") ? "dark" : "system"
        if appearance != "system" {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }

        let model = PanelSnapshot.previewModel()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: nil)
        let controller = PanelController(model: model, statusItem: item)
        keepAlive = [item, controller]
        controller.open()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                print(controller.layoutDescription())
                let path = (directory as NSString).appendingPathComponent("capture-\(appearance).png")
                if controller.captureWindow(to: URL(fileURLWithPath: path)) {
                    print("wrote \(path)")
                } else {
                    print("capture failed")
                }
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }
}
