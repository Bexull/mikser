import AppKit
import ApplicationServices
import Carbon
import Observation

/// Settings and state for the Kazakh keyboard helpers, used by the panel. Main thread only.
@Observable
final class KazakhKeyboard {
    private(set) var layoutInstalled = false
    private(set) var hasAccess = false
    /// The app the user is typing in (the panel never takes focus from it).
    private(set) var frontmostApp: (id: String, name: String)?

    var rightCommand: Bool {
        didSet {
            defaults.set(rightCommand, forKey: "kazakh.rightCommand")
            applySettings()
        }
    }

    var autocorrect: Bool {
        didSet {
            defaults.set(autocorrect, forKey: "kazakh.autocorrect")
            applySettings()
        }
    }

    /// The helpers need a keyboard event tap, which needs the Accessibility permission.
    var needsAccess: Bool { layoutInstalled && (rightCommand || autocorrect) && !hasAccess }

    var isFrontmostExcluded: Bool { frontmostApp.map { isExcluded($0.id) } ?? false }

    /// Apps where autocorrect would get in the way: terminals, code editors, password managers.
    static let builtInExclusions: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.cmuxterm.app", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "com.google.antigravity", "com.apple.dt.Xcode",
        "com.google.android.studio", "org.jkiss.dbeaver.core.product", "com.apple.Passwords",
        "com.apple.keychainaccess", "com.1password.1password", "org.blenderfoundation.blender",
    ]

    @ObservationIgnored private let engine = KazakhKeyboardEngine()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wordsModified: Date?
    @ObservationIgnored private var userList = ""
    @ObservationIgnored private var corpusWords = 0

    init() {
        rightCommand = UserDefaults.standard.object(forKey: "kazakh.rightCommand") as? Bool ?? true
        autocorrect = UserDefaults.standard.object(forKey: "kazakh.autocorrect") as? Bool ?? true
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        for case let name? in [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged] {
            center.addObserver(forName: Notification.Name(name as String), object: nil, queue: .main) { [weak self] _ in
                self?.refreshLayout()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshFrontmostApp()
        }
        engine.onEvents = { [weak self] events in
            DispatchQueue.main.async { self?.remember(events) }
        }

        refreshLayout()
        refreshFrontmostApp()
        reloadWordsIfChanged()
        applySettings()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if KazakhLayout.isInstalled { KazakhLayout.clearStaleLayoutCaches() }
            let vocabulary = KazakhWords.loadVocabulary()
            DispatchQueue.main.async {
                guard let self else { return }
                self.corpusWords = (vocabulary.corpus as? KazakhCorpus)?.count ?? 0
                self.engine.setBase(vocabulary)
                self.pushWords()
            }
        }
        if needsAccess && !defaults.bool(forKey: "kazakh.accessPrompted") {
            requestAccess()
        }

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func installLayout() {
        do {
            try KazakhLayout.install()
        } catch {
            NSSound.beep()
        }
        refreshLayout()
        requestAccess()
    }

    /// First time: the system dialog that adds the app to Privacy & Security → Accessibility.
    /// After that the dialog no longer appears, so open that settings page directly.
    func requestAccess() {
        guard !AXIsProcessTrusted() else {
            applySettings()
            return
        }
        if defaults.bool(forKey: "kazakh.accessPrompted"),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else {
            defaults.set(true, forKey: "kazakh.accessPrompted")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    func openUserWords() {
        let url = KazakhWords.userListURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? KazakhWords.userListTemplate.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    /// Turns autocorrect off (or back on) in the app the user is typing in.
    func toggleFrontmostExclusion() {
        guard let app = frontmostApp else { return }
        var excluded = Set(defaults.stringArray(forKey: "kazakh.excludedApps") ?? [])
        var included = Set(defaults.stringArray(forKey: "kazakh.includedApps") ?? [])
        if isExcluded(app.id) {
            excluded.remove(app.id)
            if Self.builtInExclusions.contains(app.id) { included.insert(app.id) }
        } else {
            included.remove(app.id)
            excluded.insert(app.id)
        }
        defaults.set(Array(excluded), forKey: "kazakh.excludedApps")
        defaults.set(Array(included), forKey: "kazakh.includedApps")
        refreshFrontmostApp(force: true)
    }

    /// Forgets the words learned from typing and the corrections the user turned down.
    func forgetLearned() {
        for key in ["kazakh.learned", "kazakh.seen"] {
            defaults.removeObject(forKey: key)
        }
        pushWords()
    }

    var learnedCount: Int { defaults.dictionary(forKey: "kazakh.learned")?.count ?? 0 }

    func diagnostics() -> String {
        "keyboard: layout installed=\(layoutInstalled) active=\(KazakhLayout.isCurrent) access=\(hasAccess) "
            + "tap=\(engine.isRunning) rightCommand=\(rightCommand) autocorrect=\(autocorrect) "
            + "app=\(frontmostApp?.id ?? "-") excluded=\(isFrontmostExcluded) corpus=\(corpusWords) "
            + "keys=\(engine.keysSeen) letters=\(engine.lettersTyped) replaced=\(engine.wordsReplaced) "
            + "skipped=\(engine.editsSkipped) learned=\(learnedCount) lastCommand=[\(engine.lastCommandKey)]"
    }

    // MARK: - State

    private func isExcluded(_ id: String) -> Bool {
        if Set(defaults.stringArray(forKey: "kazakh.includedApps") ?? []).contains(id) { return false }
        return Self.builtInExclusions.contains(id) || id.hasPrefix("com.jetbrains.")
            || Set(defaults.stringArray(forKey: "kazakh.excludedApps") ?? []).contains(id)
    }

    private func refreshFrontmostApp(force: Bool = false) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let id = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
        if force || frontmostApp?.id != id {
            frontmostApp = (id, app.localizedName ?? id)
        }
        let suspended = isExcluded(id)
        engine.update { $0.autocorrectSuspended = suspended }
    }

    private func refreshLayout() {
        let installed = KazakhLayout.isInstalled
        if installed != layoutInstalled { layoutInstalled = installed }
        let active = KazakhLayout.isCurrent
        engine.update { $0.layoutActive = active }
        applySettings()
    }

    private func applySettings() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccess { hasAccess = trusted }
        engine.update {
            $0.rightCommand = rightCommand
            $0.autocorrect = autocorrect
        }
        if layoutInstalled && (rightCommand || autocorrect) && trusted && !engine.isRunning {
            if !engine.start() {
                // Some systems also want Input Monitoring for keyboard taps.
                CGRequestListenEventAccess()
            }
        }
    }

    private func tick() {
        if !hasAccess || !engine.isRunning { applySettings() }
        reloadWordsIfChanged()
    }

    private func reloadWordsIfChanged() {
        let url = KazakhWords.userListURL
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != wordsModified || wordsModified == nil else { return }
        wordsModified = modified ?? .distantPast
        userList = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        pushWords()
    }

    // MARK: - Learning

    /// Hand-picked words, then learned ones, then the user's list (which wins).
    private func pushWords() {
        var words = KazakhWords.dictionary()
        for case let (plain, word as String) in defaults.dictionary(forKey: "kazakh.learned") ?? [:] {
            words[plain] = word
        }
        words.merge(KazakhWords.dictionary(userList: userList, includeBuiltIn: false)) { $1 }
        engine.setWords(words)
    }

    /// Typing the same unknown Kazakh word twice teaches it.
    private func remember(_ events: [KazakhTyping.Event]) {
        var seen = defaults.dictionary(forKey: "kazakh.seen") as? [String: Int] ?? [:]
        var learned = defaults.dictionary(forKey: "kazakh.learned") as? [String: String] ?? [:]
        for case .learned(let word) in events {
            seen[word, default: 0] += 1
            if seen[word]! >= 2 {
                learned[KazakhWords.plain(word)] = word
                seen[word] = nil
            }
        }
        defaults.set(seen, forKey: "kazakh.seen")
        defaults.set(learned, forKey: "kazakh.learned")
        pushWords()
    }
}

/// Keyboard event tap: right ⌘ + key types a Kazakh letter, and Kazakh typed with Russian
/// letters gets its proper spelling. Active only while "Русская + Қазақша" is selected.
/// Runs on its own thread so typing never waits for the UI.
final class KazakhKeyboardEngine {
    struct Config {
        var rightCommand = true
        var autocorrect = true
        var layoutActive = false
        /// The app being typed in is on the "don't correct" list.
        var autocorrectSuspended = false
    }

    /// Key code -> Kazakh letter for right ⌘, the same keys as ⌥ in the layout.
    private static let letters: [Int64: (lower: String, upper: String)] = [
        3: ("ә", "Ә"), 11: ("і", "І"), 16: ("ң", "Ң"), 32: ("ғ", "Ғ"), 15: ("қ", "Қ"),
        38: ("ө", "Ө"), 14: ("ү", "Ү"), 13: ("ұ", "Ұ"), 33: ("һ", "Һ"),
    ]
    /// Keys that move the cursor: whatever word was being typed is no longer under it.
    private static let navigationKeys: Set<Int64> = [123, 124, 125, 126, 115, 119, 116, 121, 117, 53]
    private static let deleteKey: Int64 = 51
    private static let syntheticMarker: Int64 = 0x4B5A_4B42
    // Device-dependent modifier bits (NX_DEVICELCMDKEYMASK / NX_DEVICERCMDKEYMASK).
    private static let leftCommandBit: UInt64 = 0x08
    private static let rightCommandBit: UInt64 = 0x10

    /// Learned words and turned-down corrections, sent to the main thread.
    var onEvents: (([KazakhTyping.Event]) -> Void)?

    private let lock = NSLock()
    private var config = Config()
    private var base = KazakhVocabulary()
    private var vocabulary = KazakhVocabulary()

    /// Counters for the state dump (written on the tap thread, read for diagnostics only).
    private(set) var keysSeen = 0
    private(set) var lettersTyped = 0
    private(set) var wordsReplaced = 0
    private(set) var editsSkipped = 0
    /// The last ⌘ + key pressed in the Kazakh layout: key code and raw modifier flags.
    private(set) var lastCommandKey = "-"

    // Touched only on the tap thread.
    private var typing = KazakhTyping()
    private var convertedKeys: Set<Int64> = []
    private var rightCommandDown = false
    private var leftCommandDown = false
    private let source = CGEventSource(stateID: .privateState)
    private let systemWide = AXUIElementCreateSystemWide()

    private var tap: CFMachPort?

    var isRunning: Bool { tap != nil }

    func update(_ change: (inout Config) -> Void) {
        lock.lock()
        change(&config)
        lock.unlock()
    }

    /// The corpus data, loaded once.
    func setBase(_ vocabulary: KazakhVocabulary) {
        lock.lock()
        let words = self.vocabulary.words
        base = vocabulary
        self.vocabulary = vocabulary
        self.vocabulary.words = words
        lock.unlock()
    }

    func setWords(_ words: [String: String]) {
        lock.lock()
        vocabulary.words = words
        lock.unlock()
    }

    private func snapshot() -> (Config, KazakhVocabulary) {
        lock.lock()
        defer { lock.unlock() }
        return (config, vocabulary)
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        var mask: CGEventMask = 0
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown] {
            mask |= CGEventMask(1) << type.rawValue
        }
        let callback: CGEventTapCallBack = { proxy, type, event, context in
            let engine = Unmanaged<KazakhKeyboardEngine>.fromOpaque(context!).takeUnretainedValue()
            return engine.handle(proxy: proxy, type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let thread = Thread {
            let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Kazakh keyboard"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    // MARK: - Tap callback

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .leftMouseDown, .rightMouseDown:
            _ = typing.handle(.reset, vocabulary: KazakhVocabulary())
            return pass

        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let command = event.flags.contains(.maskCommand)
            if code == 54 { rightCommandDown = command }
            if code == 55 { leftCommandDown = command }
            if !command {
                rightCommandDown = false
                leftCommandDown = false
            }
            return pass

        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else { return pass }
            return handleKey(proxy: proxy, isDown: type == .keyDown, event: event)

        default:
            return pass
        }
    }

    private func handleKey(proxy: CGEventTapProxy, isDown: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let (config, words) = snapshot()
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if isDown { keysSeen += 1 }

        guard config.layoutActive else {
            if isDown { _ = typing.handle(.reset, vocabulary: words) }
            return pass
        }

        // The release of a key we turned into a letter shouldn't carry ⌘ either.
        if !isDown {
            if convertedKeys.remove(code) != nil { event.flags = Self.withoutCommand(event.flags) }
            return pass
        }

        let flags = event.flags
        if flags.contains(.maskCommand) {
            lastCommandKey = "key \(code) flags 0x\(String(flags.rawValue, radix: 16)) right=\(rightCommandDown) left=\(leftCommandDown)"
        }
        var typedLetter: String?
        if config.rightCommand, isRightCommandOnly(flags),
           !flags.contains(.maskControl), !flags.contains(.maskAlternate),
           let letter = Self.letters[code] {
            let upper = flags.contains(.maskShift) || flags.contains(.maskAlphaShift)
            let text = upper ? letter.upper : letter.lower
            event.flags = Self.withoutCommand(flags)
            Self.setText(text, on: event)
            convertedKeys.insert(code)
            typedLetter = text
            lettersTyped += 1
        }

        guard config.autocorrect, !config.autocorrectSuspended else {
            _ = typing.handle(.reset, vocabulary: words)
            return pass
        }

        let input: KazakhTyping.Input
        if let typedLetter {
            input = .text(typedLetter)
        } else if flags.contains(.maskCommand) || flags.contains(.maskControl) || Self.navigationKeys.contains(code) {
            input = .reset
        } else if code == Self.deleteKey {
            input = .backspace
        } else {
            let text = Self.text(of: event)
            let isControl = text.unicodeScalars.contains { $0.value < 0x20 && !"\r\n\t".unicodeScalars.contains($0) }
            input = text.isEmpty || isControl ? .reset : .text(text)
        }

        let action = typing.handle(input, vocabulary: words)
        let events = typing.takeEvents()
        if !events.isEmpty { onEvents?(events) }

        switch action {
        case .pass:
            return pass
        case .replace(let delete, let insert, let expect):
            guard screenShows(expect) else { return skipEdit(pass) }
            wordsReplaced += 1
            post(backspaces: delete, then: insert, proxy: proxy)
            if let boundary = event.copy() {
                boundary.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                boundary.tapPostEvent(proxy)
            }
            return nil
        case .undo(let delete, let insert, let expect):
            guard screenShows(expect) else { return skipEdit(pass) }
            post(backspaces: delete, then: insert, proxy: proxy)
            return nil
        }
    }

    /// The text field doesn't look the way we think (autocomplete, another autocorrect):
    /// leave it alone and start over.
    private func skipEdit(_ pass: Unmanaged<CGEvent>) -> Unmanaged<CGEvent> {
        editsSkipped += 1
        _ = typing.handle(.reset, vocabulary: KazakhVocabulary())
        return pass
    }

    /// Asks the focused text field (Accessibility API) whether `text` sits right before the
    /// cursor with nothing selected. Apps that can't answer are trusted.
    private func screenShows(_ text: String) -> Bool {
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return true }
        let element = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)

        var rangeValue: CFTypeRef?
        var selection = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection) else { return true }
        if selection.length > 0 { return false }

        let length = text.utf16.count
        guard selection.location >= length else { return false }
        var before = CFRange(location: selection.location - length, length: length)
        guard let beforeValue = AXValueCreate(.cfRange, &before) else { return true }
        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         beforeValue, &stringValue) == .success,
              let shown = stringValue as? String else { return true }
        return shown.precomposedStringWithCanonicalMapping == text.precomposedStringWithCanonicalMapping
    }

    private func isRightCommandOnly(_ flags: CGEventFlags) -> Bool {
        guard flags.contains(.maskCommand) else { return false }
        let raw = flags.rawValue
        if raw & (Self.leftCommandBit | Self.rightCommandBit) != 0 {
            return raw & Self.rightCommandBit != 0 && raw & Self.leftCommandBit == 0
        }
        return rightCommandDown && !leftCommandDown
    }

    private static func withoutCommand(_ flags: CGEventFlags) -> CGEventFlags {
        CGEventFlags(rawValue: flags.rawValue & ~(CGEventFlags.maskCommand.rawValue | leftCommandBit | rightCommandBit))
    }

    private static func text(of event: CGEvent) -> String {
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        return String(utf16CodeUnits: characters, count: length)
    }

    private static func setText(_ text: String, on event: CGEvent) {
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    }

    /// Deletes `count` characters and types `text`, right where the user is typing.
    private func post(backspaces count: Int, then text: String, proxy: CGEventTapProxy) {
        func send(_ key: CGKeyCode, text: [UniChar]? = nil) {
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown) else { continue }
                event.flags = []
                if let text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
                event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
                event.tapPostEvent(proxy)
            }
        }
        for _ in 0..<count { send(CGKeyCode(Self.deleteKey)) }
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            send(0, text: Array(units[start..<min(start + 16, units.count)]))
        }
    }
}
