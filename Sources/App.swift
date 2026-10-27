import AppKit

@main
enum MixerApp {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel()
    private let keyboard = KazakhKeyboard()
    private var statusItem: NSStatusItem?
    private var panel: PanelController?
    private var selfTest: SelfTest?
    private var dumpSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            PanelSnapshot.run(directory: arguments[index + 1])
            return
        }
        if let index = arguments.firstIndex(of: "--capture"), index + 1 < arguments.count {
            PanelCapture.run(directory: arguments[index + 1])
            return
        }
        if arguments.contains("--install-keyboard-layout") || arguments.contains("--check-keyboard-layout") {
            if arguments.contains("--install-keyboard-layout") {
                do {
                    try KazakhLayout.install().forEach { print($0) }
                } catch {
                    print("install failed: \(error)")
                }
            }
            KazakhLayout.check().forEach { print($0) }
            print("current input source: \(KazakhLayout.currentInputSourceID ?? "-")")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Микшер")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.toolTip = "Микшер"
        }
        statusItem = item
        panel = PanelController(model: model, keyboard: keyboard, statusItem: item)
        model.start()
        keyboard.start()

        signal(SIGUSR1, SIG_IGN)
        let dump = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        dump.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.writeStateDump(extra: self.keyboard.diagnostics())
            }
        }
        dump.resume()
        dumpSignal = dump

        if let index = arguments.firstIndex(of: "--selftest") {
            let test = SelfTest(model: model, arguments: Array(arguments[(index + 1)...]))
            selfTest = test
            test.run()
        }
        if arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.panel?.open() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel?.toggle()
        }
    }

    private func showMenu() {
        panel?.close()
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()
        let login = NSMenuItem(title: "Открывать при входе в систему", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = model.launchAtLogin ? .on : .off
        menu.addItem(login)
        if model.hasAdjustments {
            let reset = NSMenuItem(title: "Вернуть всем 100%", action: #selector(resetAll), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }
        menu.addItem(.separator())
        menu.addItem(keyboardMenuItem())
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    private func keyboardMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        func add(_ title: String, _ action: Selector, on: Bool? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if let on { item.state = on ? .on : .off }
            submenu.addItem(item)
        }
        add(keyboard.layoutInstalled ? "Переустановить раскладку" : "Установить раскладку «Русская + Қазақша»", #selector(installLayout))
        add("Казахские буквы на правом ⌘", #selector(toggleRightCommand), on: keyboard.rightCommand)
        add("Автозамена казахских слов", #selector(toggleAutocorrect), on: keyboard.autocorrect)
        add("Мои слова для автозамены…", #selector(openUserWords))
        if let frontmost = keyboard.frontmostApp {
            add("Не исправлять в «\(frontmost.name)»", #selector(toggleExclusion), on: keyboard.isFrontmostExcluded)
        }
        if keyboard.learnedCount > 0 {
            add("Забыть выученное (\(keyboard.learnedCount))", #selector(forgetLearned))
        }
        if keyboard.needsAccess {
            submenu.addItem(.separator())
            add("Дать доступ к клавиатуре…", #selector(requestKeyboardAccess))
        }
        let item = NSMenuItem(title: "Казахская клавиатура", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func installLayout() { keyboard.installLayout() }
    @objc private func toggleRightCommand() { keyboard.rightCommand.toggle() }
    @objc private func toggleAutocorrect() { keyboard.autocorrect.toggle() }
    @objc private func openUserWords() { keyboard.openUserWords() }
    @objc private func requestKeyboardAccess() { keyboard.requestAccess() }
    @objc private func toggleExclusion() { keyboard.toggleFrontmostExclusion() }
    @objc private func forgetLearned() { keyboard.forgetLearned() }

    @objc private func toggleLaunchAtLogin() {
        model.setLaunchAtLogin(!model.launchAtLogin)
    }

    @objc private func resetAll() {
        model.resetAll()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
