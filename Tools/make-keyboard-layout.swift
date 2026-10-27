// Builds the "Русская + Қазақша" keyboard layout bundle.
//
// It clones the system "Russian – PC" layout key by key (read from macOS itself, so every
// symbol stays where it was) and puts the nine Kazakh letters on the Option layer of the
// Russian letter they replace in everyday writing: а→ә, и→і, н→ң, г→ғ, к→қ, о→ө, у→ү, х→һ,
// and ұ next to у, on ц. The Mixer app adds the same letters on the right ⌘.
//
// usage: make-keyboard-layout <output .bundle path>

import AppKit
import Carbon

let layoutName = "RussianKazakh"
let displayName = "Русская + Қазақша"
let bundleID = "com.bexul.keyboardlayout.russiankazakh"
/// macOS names bundled layouts "<bundle id>.keylayout.<layout name>".
let inputSourceID = "\(bundleID).keylayout.\(layoutName)"
/// Cyrillic layouts (group 7) must use an id from 19456 to 19967.
let layoutNumber = 19621
let sourceLayoutID = "com.apple.keylayout.RussianWin"

/// Russian letter -> Kazakh letter on the Option layer.
let kazakhLetters: [(russian: Character, kazakh: Character)] = [
    ("а", "ә"), ("и", "і"), ("н", "ң"), ("г", "ғ"), ("к", "қ"),
    ("о", "ө"), ("у", "ү"), ("ц", "ұ"), ("х", "һ"),
]

// UCKeyTranslate modifier bits ((EventModifiers >> 8) & 0xFF).
let commandBit: UInt32 = 0x01, shiftBit: UInt32 = 0x02, capsBit: UInt32 = 0x04, optionBit: UInt32 = 0x08, controlBit: UInt32 = 0x10

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: make-keyboard-layout <output .bundle>") }
let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1])

// MARK: - Read the source layout

guard let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: sourceLayoutID] as CFDictionary, true)?
        .takeRetainedValue() as? [TISInputSource],
      let source = sources.first,
      let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
    fail("cannot read \(sourceLayoutID)")
}
let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
let keyboardType = UInt32(LMGetKbdType())

struct Output: Equatable {
    var text: String
    var isDeadKey: Bool
}

/// What a key types with the given modifiers. A dead key is followed by a space,
/// which gives the accent on its own.
func translate(_ keyCode: UInt16, _ modifiers: UInt32) -> Output {
    layoutData.withUnsafeBytes { raw -> Output in
        let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                                    0, &deadKeyState, characters.count, &length, &characters)
        guard status == noErr else { return Output(text: "", isDeadKey: false) }
        guard deadKeyState != 0 else {
            return Output(text: String(utf16CodeUnits: characters, count: length), isDeadKey: false)
        }
        UCKeyTranslate(layout, 49, UInt16(kUCKeyActionDown), 0, keyboardType,
                       0, &deadKeyState, characters.count, &length, &characters)
        return Output(text: String(utf16CodeUnits: characters, count: length), isDeadKey: true)
    }
}

let keyCodes = Array(UInt16(0)...UInt16(127))
let combos = Array(UInt32(0)..<32)

var tables: [UInt32: [UInt16: String]] = [:]
var deadKeys: [String] = []
for combo in combos {
    var table: [UInt16: String] = [:]
    for code in keyCodes {
        let output = translate(code, combo)
        if output.isDeadKey { deadKeys.append("key \(code) combo \(combo)") }
        if !output.text.isEmpty { table[code] = output.text }
    }
    tables[combo] = table
}
if !deadKeys.isEmpty {
    print("note: \(deadKeys.count) dead keys flattened: \(deadKeys.prefix(6).joined(separator: ", "))")
}

// MARK: - Add the Kazakh letters

let baseTable = tables[0]!
for (russian, kazakh) in kazakhLetters {
    guard let code = baseTable.first(where: { $0.value == String(russian) })?.key else {
        fail("no key types \(russian) in \(sourceLayoutID)")
    }
    for combo in combos where combo & optionBit != 0 && combo & (commandBit | controlBit) == 0 {
        // Same case rules as the Russian letter without Option (Shift, Caps Lock, both).
        let plain = tables[combo & ~optionBit]![code] ?? String(russian)
        let upper = plain != plain.lowercased()
        tables[combo]![code] = upper ? String(kazakh).uppercased() : String(kazakh)
    }
    print("⌥\(russian) → \(kazakh)   (key \(code))")
}

// MARK: - Write the .keylayout

var uniqueTables: [[UInt16: String]] = []
var combosByTable: [[UInt32]] = []
for combo in combos {
    let table = tables[combo]!
    if let index = uniqueTables.firstIndex(of: table) {
        combosByTable[index].append(combo)
    } else {
        uniqueTables.append(table)
        combosByTable.append([combo])
    }
}

func modifierKeys(_ combo: UInt32) -> String {
    var keys: [String] = []
    if combo & shiftBit != 0 { keys.append("anyShift") }
    if combo & capsBit != 0 { keys.append("caps") }
    if combo & optionBit != 0 { keys.append("anyOption") }
    if combo & commandBit != 0 { keys.append("command") }
    if combo & controlBit != 0 { keys.append("anyControl") }
    return keys.joined(separator: " ")
}

func escape(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        case "'": result += "&apos;"
        default:
            if scalar.value < 0x20 || scalar.value == 0x7F {
                result += String(format: "&#x%04X;", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    return result
}

let maxOutput = uniqueTables.flatMap(\.values).map(\.utf16.count).max() ?? 1
var xml = """
<?xml version="1.1" encoding="UTF-8"?>
<!DOCTYPE keyboard SYSTEM "file://localhost/System/Library/DTDs/KeyboardLayout.dtd">
<!-- \(displayName): Russian – PC with Kazakh letters on Option. Generated by make-keyboard-layout. -->
<keyboard group="7" id="\(layoutNumber)" name="\(layoutName)" maxout="\(maxOutput)">
    <layouts>
        <layout first="0" last="255" mapSet="map" modifiers="modifiers"/>
    </layouts>
    <modifierMap id="modifiers" defaultIndex="\(combosByTable.firstIndex { $0.contains(0) }!)">

"""
for (index, tableCombos) in combosByTable.enumerated() {
    xml += "        <keyMapSelect mapIndex=\"\(index)\">\n"
    for combo in tableCombos {
        xml += "            <modifier keys=\"\(modifierKeys(combo))\"/>\n"
    }
    xml += "        </keyMapSelect>\n"
}
xml += "    </modifierMap>\n    <keyMapSet id=\"map\">\n"
for (index, table) in uniqueTables.enumerated() {
    xml += "        <keyMap index=\"\(index)\">\n"
    for code in keyCodes {
        if let text = table[code] {
            xml += "            <key code=\"\(code)\" output=\"\(escape(text))\"/>\n"
        }
    }
    xml += "        </keyMap>\n"
}
xml += "    </keyMapSet>\n</keyboard>\n"

// MARK: - Icon (template glyph for the menu bar input menu)

func iconImage(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let side = CGFloat(pixels)
    let frame = NSRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88)
    let box = NSBezierPath(roundedRect: frame, xRadius: side * 0.2, yRadius: side * 0.2)
    NSColor.black.setFill()
    box.fill()
    let font = NSFont.systemFont(ofSize: side * 0.62, weight: .bold)
    let glyph = NSAttributedString(string: "Қ", attributes: [.font: font, .foregroundColor: NSColor.black])
    let size = glyph.size()
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    glyph.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2 - side * 0.02))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Assemble the bundle

let fileManager = FileManager.default
let resources = bundleURL.appendingPathComponent("Contents/Resources")
try? fileManager.removeItem(at: bundleURL)
try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
try xml.write(to: resources.appendingPathComponent("\(layoutName).keylayout"), atomically: true, encoding: .utf8)

let iconset = fileManager.temporaryDirectory.appendingPathComponent("\(layoutName)-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64)] {
    try iconImage(pixels: pixels).representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("\(name).png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("\(layoutName).icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? fileManager.removeItem(at: iconset)

let info: [String: Any] = [
    "CFBundleIdentifier": bundleID,
    "CFBundleName": layoutName,
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "KLInfo_\(layoutName)": [
        "TISInputSourceID": inputSourceID,
        "TISIntendedLanguage": "kk",
        "TISIconIsTemplate": true,
    ],
]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))

for language in ["ru", "en", "kk"] {
    let folder = resources.appendingPathComponent("\(language).lproj")
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try "\"\(layoutName)\" = \"\(displayName)\";\n".write(to: folder.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)
}

print("keyboard type \(keyboardType), \(uniqueTables.count) key maps, wrote \(bundleURL.path)")
