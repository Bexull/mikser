import Carbon
import Foundation

/// The "Русская + Қазақша" keyboard layout that ships inside the app
/// (built by Tools/make-keyboard-layout.swift).
enum KazakhLayout {
    /// macOS names bundled layouts "<bundle id>.keylayout.<layout name>".
    static let inputSourceID = "com.bexul.keyboardlayout.russiankazakh.keylayout.RussianKazakh"
    /// The layout it replaces, so there are still only two languages to switch between.
    static let replacedInputSourceID = "com.apple.keylayout.RussianWin"
    private static let bundleName = "RussianKazakh.bundle"

    private static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keyboard Layouts")
            .appendingPathComponent(bundleName)
    }

    static func inputSource(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return list?.first
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let value = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }

    static var isInstalled: Bool {
        guard let source = inputSource(inputSourceID) else { return false }
        return boolProperty(source, kTISPropertyInputSourceIsEnabled)
    }

    static var currentInputSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    static var isCurrent: Bool { currentInputSourceID == inputSourceID }

    /// Copies the layout to ~/Library/Keyboard Layouts, turns it on in place of "Russian – PC"
    /// and switches to it if Russian was the active layout. Returns what was done.
    @discardableResult
    static func install() throws -> [String] {
        guard let bundled = Bundle.main.url(forResource: "RussianKazakh", withExtension: "bundle") else {
            throw CoreAudioError(status: -1, operation: "layout missing from app bundle")
        }
        var report: [String] = []
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copied aside and moved in at once: an app that reads the folder halfway through the
        // copy keeps a layout list without it (see clearStaleLayoutCaches).
        let staged = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                         appropriateFor: installedURL, create: true).appendingPathComponent(bundleName)
        try fileManager.copyItem(at: bundled, to: staged)
        if fileManager.fileExists(atPath: installedURL.path) {
            _ = try fileManager.replaceItemAt(installedURL, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: installedURL)
        }
        report.append("copied to \(installedURL.path)")

        let registered = TISRegisterInputSource(installedURL as CFURL)
        report.append("registered: \(registered)")
        report += installSpelling()
        report += clearStaleLayoutCaches().map { "layout cache cleared: \($0)" }

        guard let source = inputSource(inputSourceID) else {
            report.append("not visible yet: log out and back in, then run the install again")
            return report
        }
        report.append("enabled: \(TISEnableInputSource(source))")

        let wasRussian = currentInputSourceID == replacedInputSourceID
        if wasRussian {
            report.append("selected: \(TISSelectInputSource(source))")
        }
        if let russian = inputSource(replacedInputSourceID), boolProperty(russian, kTISPropertyInputSourceIsEnabled) {
            report.append("Russian – PC disabled: \(TISDisableInputSource(russian))")
        }
        return report
    }

    /// Apps from the App Store (Teams, Telegram) keep their own copy of the keyboard layout list
    /// in the user cache folder (<app id>/com.apple.IntlDataCache.le*). A copy made around the
    /// time the layout was installed can lack it for good: in that app the layout can't be
    /// selected and only ABC types. Deleting such copies makes the apps rebuild them the next
    /// time they start. Returns the apps whose copy was deleted.
    @discardableResult
    static func clearStaleLayoutCaches() -> [String] {
        let fileManager = FileManager.default
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let installed = (try? fileManager.attributesOfItem(atPath: installedURL.path))?[.modificationDate] as? Date,
              confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return [] }
        let root = URL(fileURLWithPath: String(cString: buffer))
        let names = ["com.apple.IntlDataCache.le", "com.apple.IntlDataCache.le.kbdx"]
        var cleared: [String] = []
        for app in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
            let files = names.map { root.appendingPathComponent(app).appendingPathComponent($0) }
            let stale = files.contains { file in
                guard let written = (try? fileManager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
                else { return false }
                return written < installed.addingTimeInterval(60)
            }
            guard stale else { continue }
            files.forEach { try? fileManager.removeItem(at: $0) }
            cleared.append(app)
        }
        return cleared
    }

    /// A Kazakh spelling dictionary for macOS (Hunspell, ~/Library/Spelling), so the system's own
    /// spell checker stops underlining and "fixing" Kazakh words.
    static func installSpelling() -> [String] {
        guard let folder = Bundle.main.url(forResource: "kazakh", withExtension: nil) else { return ["no spelling data"] }
        let spelling = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Spelling")
        try? FileManager.default.createDirectory(at: spelling, withIntermediateDirectories: true)
        var report: [String] = []
        for name in ["kk.dic", "kk.aff"] {
            let target = spelling.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: target)
                report.append("spelling: \(name)")
            } catch {
                report.append("spelling \(name) failed: \(error.localizedDescription)")
            }
        }
        return report
    }

    /// Tests the installed layout itself: what a few keys type.
    static func check() -> [String] {
        guard let source = inputSource(inputSourceID),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return ["layout not available"]
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        func type(_ code: UInt16, _ modifiers: UInt32) -> String {
            data.withUnsafeBytes { raw in
                var state: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                UCKeyTranslate(raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), code,
                               UInt16(kUCKeyActionDown), modifiers, keyboardType, 0, &state, 4, &length, &characters)
                return String(utf16CodeUnits: characters, count: length)
            }
        }
        let plain = [3, 11, 16, 32, 15, 38, 14, 13, 33].map { type(UInt16($0), 0) }.joined()
        let option = [3, 11, 16, 32, 15, 38, 14, 13, 33].map { type(UInt16($0), 0x08) }.joined()
        let digits = (18...29).map { type(UInt16($0), 0) }.joined()
        return ["plain: \(plain)", "option: \(option)", "number row: \(digits)", "⌘ layer: \(type(13, 0x01))\(type(3, 0x01))"]
    }
}
