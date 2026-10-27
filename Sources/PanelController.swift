import AppKit
import SwiftUI

/// Glass panel that drops down from the menu bar without stealing focus
/// from the app the user is working in.
final class GlassPanel: NSPanel {
    static let cornerRadius: CGFloat = 24

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PanelController.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The window server can't see the glass's rounded shape and would draw a rectangular
    /// shadow and rim. AppKit asks windows for this mask to shape both.
    @objc func _cornerMask() -> NSImage? { Self.cornerMask }

    private static let cornerMask: NSImage = {
        let side = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }()
}

/// Lets the first click on a slider work even though the panel is not key yet.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController {
    static let width: CGFloat = 320

    private let panel = GlassPanel()
    private let model: MixerModel
    private weak var statusItem: NSStatusItem?
    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?
    private var contentHeight: CGFloat = 200
    private(set) var isOpen = false

    init(model: MixerModel, keyboard: KazakhKeyboard? = nil, statusItem: NSStatusItem) {
        self.model = model
        self.statusItem = statusItem

        let hosting = FirstClickHostingView(rootView: MixerView(model: model, keyboard: keyboard) { [weak self] height in
            self?.contentHeightChanged(height)
        })
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let glass = NSGlassEffectView()
        glass.cornerRadius = GlassPanel.cornerRadius
        glass.contentView = hosting
        // Keep the SwiftUI content exactly as large as the glass when the panel resizes.
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        panel.contentView = glass
    }

    /// Frames of the panel's view stack (diagnostics only).
    func layoutDescription() -> String {
        var lines = ["panel \(panel.frame) contentHeight=\(contentHeight)"]
        var view: NSView? = panel.contentView
        var depth = 0
        while let current = view, depth < 3 {
            lines.append(String(repeating: "  ", count: depth) + "\(type(of: current)) frame=\(current.frame)")
            view = current.subviews.first
            depth += 1
        }
        return lines.joined(separator: "\n")
    }

    /// Photographs the panel window, shadow included (diagnostics only).
    func captureWindow(to url: URL) -> Bool {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return false }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageDefault (keeps the shadow)
        guard let image = create(.null, 1 << 3, UInt32(panel.windowNumber), 0)?.takeRetainedValue() else { return false }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        model.panelWillOpen()

        applyFrame()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        installMonitors()
        keepStatusItemHighlighted()
        // Shape the shadow once the glass has actually drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
    }

    /// The status button drops its highlight when the click that opened the panel ends;
    /// put it back so the icon stays lit while the panel is open, like a native menu.
    private func keepStatusItemHighlighted() {
        statusItem?.button?.highlight(true)
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let self, self.isOpen { self.statusItem?.button?.highlight(true) }
                }
            }
            if let monitor { NSEvent.removeMonitor(monitor) }
            return event
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        statusItem?.button?.highlight(false)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func contentHeightChanged(_ height: CGFloat) {
        let rounded = ceil(height)
        guard abs(rounded - contentHeight) > 0.5 else { return }
        contentHeight = rounded
        // Resizing the window from inside SwiftUI's layout pass resizes the glass twice;
        // do it right after the pass instead.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.applyFrame()
            }
        }
    }

    private func applyFrame() {
        panel.setFrame(frame(forHeight: contentHeight), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: panel.frame.size)
        panel.invalidateShadow()
    }

    /// Hangs the panel just under the menu bar icon, kept on screen.
    private func frame(forHeight height: CGFloat) -> NSRect {
        let width = Self.width
        guard let button = statusItem?.button, let window = button.window else {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSRect(x: visible.maxX - width - 8, y: visible.maxY - height - 6, width: width, height: height)
        }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.minX, visible.minX + 8), visible.maxX - width - 8)
        let top = anchor.minY - 6
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Esc
            MainActor.assumeIsolated { self?.close() }
            return nil
        }) {
            monitors.append(local)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
    }
}
