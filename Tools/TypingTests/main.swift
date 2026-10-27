// Tests for the autocorrect logic. Build and run:
//   swiftc -o build/test-typing Tools/TypingTests/main.swift Sources/KazakhTyping.swift \
//     Sources/KazakhWords.swift Sources/KazakhLexicon.swift
//   build/test-typing [Resources/kazakh Tools/TypingTests/chat-phrases.tsv Tools/TypingTests/russian-phrases.tsv]

import Foundation

var failures = 0

/// A tiny stand-in for the corpus.
struct FakeCorpus: KazakhLexicon {
    let entries: [String: KazakhEntry]
    func entry(forPlain plain: String) -> KazakhEntry? { entries[plain] }
}

func entry(_ forms: [(String, Int)], russian: Bool = false, name: Bool = false, mostlyKazakh: Bool = false) -> KazakhEntry {
    KazakhEntry(forms: forms.map { KazakhForm(text: $0.0, count: $0.1) }, isRussianToo: russian, isName: name,
                isMostlyKazakh: mostlyKazakh)
}

var fake = KazakhVocabulary(words: KazakhWords.dictionary(userList: "рақмет\n# comment\nсәлем # inline"))
fake.corpus = FakeCorpus(entries: [
    "агайын": entry([("ағайын", 500)]), "туыс": entry([("туыс", 900)]),
    "сиздерди": entry([("сіздерді", 300)]), "шакырамыз": entry([("шақырамыз", 200)]),
    "жакка": entry([("жаққа", 700)]), "баргым": entry([("барғым", 90)]), "келип": entry([("келіп", 9000)]),
    "тур": entry([("тұр", 11000), ("тур", 140), ("түр", 85)], russian: true),
    "мен": entry([("мен", 90000)], russian: true), "бир": entry([("бір", 50000)]),
    "он": entry([("он", 5000), ("оң", 2300)], russian: true), "сени": entry([("сені", 730)], russian: true),
    "жаксы": entry([("жақсы", 8000)]), "коремин": entry([("көремін", 400)]),
    "айгерим": entry([("әйгерім", 159), ("айгерім", 26)], name: true), "кайда": entry([("қайда", 3000)]),
    "сал": entry([("сәл", 1200), ("сал", 234)], russian: true),
    "озин": entry([("өзін", 4400), ("өзің", 590)]), "кунин": entry([("күнін", 790), ("күнің", 50)], russian: true),
    "туган": entry([("туған", 6000)]), "жолын": entry([("жолын", 1400), ("жолың", 50)]),
    "болсын": entry([("болсын", 3000)]), "айтасын": entry([("айтасың", 120), ("айтасын", 40)]),
    "ата": entry([("ата", 4000)]), "ана": entry([("ана", 3000)], russian: true),
    "шынымен": entry([("шынымен", 400)]), "ба": entry([("ба", 900)], russian: true),
    "корсет": entry([("көрсет", 300)], russian: true), "бар": entry([("бар", 20000)], russian: true),
    "барма": entry([("барма", 30)]), "кешке": entry([("кешке", 500)]),
    "нурлан": entry([("нұрлан", 1610)], name: true), "ерлан": entry([("ерлан", 1164)], name: true),
    "узынагаш": entry([("ұзынағаш", 45)], name: true),
    "аска": entry([("асқа", 205)], russian: true, mostlyKazakh: true), "жатам": entry([("жатам", 10)]),
    "ойын": entry([("ойын", 9000), ("ойың", 120)]), "ойындар": entry([("ойындар", 900)]),
    "салеметсиз": entry([("сәлеметсіз", 300)]),
])
fake.leftContext = ["туған\tкунин": "күнің"]
fake.rightContext = ["жолын\tболсын": "жолың"]
fake.pairs = ["ата\tана": "ата-ана"]
fake.endings = ["f\tши": [KazakhForm(text: "ші", count: 215)],
                "b\tка": [KazakhForm(text: "қа", count: 720), KazakhForm(text: "ка", count: 79)]]

/// Types `keys` ("⌫" backspace, "⟲" reset) into a pretend text field and returns its text.
/// Every edit must find on screen exactly the text it expects to delete.
func type(_ keys: [String], _ vocabulary: KazakhVocabulary) -> String {
    var typing = KazakhTyping()
    var text = ""
    for key in keys {
        let input: KazakhTyping.Input = key == "⌫" ? .backspace : key == "⟲" ? .reset : .text(key)
        switch typing.handle(input, vocabulary: vocabulary) {
        case .pass:
            if key == "⌫" { if !text.isEmpty { text.removeLast() } } else if key != "⟲" { text += key }
        case .replace(let delete, let insert, let expect):
            if !text.hasSuffix(expect) || expect.count != delete { failures += 1; print("FAIL  edit expected «\(expect)» but screen ends «\(text.suffix(delete))»") }
            text.removeLast(min(delete, text.count))
            text += insert + key
        case .undo(let delete, let insert, let expect):
            if !text.hasSuffix(expect) || expect.count != delete { failures += 1; print("FAIL  undo expected «\(expect)» but screen ends «\(text.suffix(delete))»") }
            text.removeLast(min(delete, text.count))
            text += insert
        }
    }
    return text
}

func check(_ name: String, _ keys: String, _ expected: String, _ vocabulary: KazakhVocabulary = fake) {
    let result = type(keys.map(String.init), vocabulary)
    if result == expected {
        print("ok    \(name): «\(result)»")
    } else {
        failures += 1
        print("FAIL  \(name): got «\(result)», expected «\(expected)»")
    }
}

check("hand-picked word", "казак ", "қазақ ")
check("capitalized", "Казак, ", "Қазақ, ")
check("all caps", "КАЗАКСТАН!", "ҚАЗАҚСТАН!")
check("already right", "қазақ ", "қазақ ")
check("Russian untouched", "привет как дела ", "привет как дела ")
check("backspace takes back the space only", "казак ⌫", "қазақ")
check("then punctuation", "казак ⌫!", "қазақ!")
check("second backspace undoes", "казак ⌫⌫", "казак")
check("undo then keep", "казак ⌫⌫ ", "казак ")
check("split particle, then !", "салеметсизбе ⌫!", "сәлеметсіз бе!")
check("reset mid-word", "каз⟲ак ", "казак ")
check("user word", "ракмет ", "рақмет ")
check("inflected words", "агайын туыс, сиздерди шакырамыз ", "ағайын туыс, сіздерді шақырамыз ")
check("Kazakh phrase fixes тур", "мен бир жакка баргым келип тур ", "мен бір жаққа барғым келіп тұр ")
check("Russian phrase keeps тур", "поедем в тур ", "поедем в тур ")
check("тур alone stays", "тур ", "тур ")
check("first word fixed by the next", "сени жаксы коремин ", "сені жақсы көремін ")
check("name in Russian", "Привет, Айгерим ", "Привет, Айгерим ")
check("name in Kazakh", "Айгерим кайда ", "Әйгерім қайда ")
check("name alone", "Айгерим ", "Әйгерім ")
check("name taken back by Russian", "Айгерим, привет ", "Айгерим, привет ")
check("names held for a take-back", "Нурлан, Ерлан, привет ", "Нурлан, Ерлан, привет ")
check("back into held names", "Нурлан, Ерлан ⌫⌫⌫ан ", "Нұрлан, Ерлан ")
check("name + case ending", "Узынагашка ", "Ұзынағашқа ")
check("no Russian case ending", "Нурлана ", "Нурлана ")
check("small name waits for Kazakh", "узынагашка жаксы ", "ұзынағашқа жақсы ")
check("small name alone stays", "узынагашка ", "узынагашка ")
check("rare Russian look-alike alone", "аска ", "асқа ")
check("rare look-alike taken back", "аска, привет ", "аска, привет ")
check("common Russian look-alike waits", "тур ", "тур ")
check("spoken ғой, merged", "жатамго ", "жатам ғой ")
check("spoken ғой, separate", "жатам го ", "жатам ғой ")
check("slang го untouched", "го ", "го ")
check("common word kept", "мен сал ", "мен сал ")
check("your, not his", "озин ", "өзің ")
check("a word of its own, not his", "ойын ", "ойын ")
check("his after оның", "оның озин ", "оның өзін ")
check("left context", "туган кунин ", "туған күнің ")
check("right context", "жолын болсын ", "жолың болсын ")
check("merged question", "айтасынба ", "айтасың ба ")
check("question mark splits", "барма?", "бар ма?")
check("no split without ?", "барма ", "барма ")
check("particle form", "шынымен ба ", "шынымен бе ")
check("hyphen pair", "ата ана ", "ата-ана ")
check("stem + ending", "корсетши ", "көрсетші ")
check("undo a two-word fix", "сени жаксы ⌫⌫", "сени жаксы")
check("return resets", "мен\rтур ", "мен\rтур ")

func loadPhrases(_ path: String) -> [(typed: String, expected: String, tag: String)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).compactMap { line in
        guard !line.hasPrefix("#") else { return nil }
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let tag = columns.count > 2 ? columns[2].replacingOccurrences(of: "# ", with: "") : "word forms"
        return (columns[0], columns.count > 1 ? columns[1] : columns[0], tag)
    }
}

/// `strict`: every miss is a failure (Russian text must never change).
func score(_ title: String, _ phrases: [(typed: String, expected: String, tag: String)], _ vocabulary: KazakhVocabulary,
           strict: Bool = false) {
    var right = 0
    var misses: [String: [String]] = [:]
    for phrase in phrases {
        let got = type((phrase.typed + " ").map(String.init), vocabulary).trimmingCharacters(in: .whitespaces)
        if got == phrase.expected { right += 1 } else { misses[phrase.tag, default: []].append("«\(phrase.typed)» → «\(got)» (надо «\(phrase.expected)»)") }
    }
    print("\n\(title): \(right) of \(phrases.count) right")
    if strict { failures += phrases.count - right }
    for (tag, lines) in misses.sorted(by: { $0.key < $1.key }) {
        print("  [\(tag)] \(lines.count) wrong")
        lines.forEach { print("    " + $0) }
    }
}

if CommandLine.arguments.count > 1 {
    var real = KazakhVocabulary.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
    real.words = KazakhWords.dictionary()
    print("\nreal data: \((real.corpus as? KazakhCorpus)?.count ?? 0) spellings, \(real.leftContext.count + real.rightContext.count) context rules, \(real.pairs.count) pairs, \(real.endings.count) endings")
    if CommandLine.arguments.count > 2 { score("Kazakh phrases", loadPhrases(CommandLine.arguments[2]), real) }
    if CommandLine.arguments.count > 3 { score("Russian phrases (must not change)", loadPhrases(CommandLine.arguments[3]), real, strict: true) }
}

print("\n\(failures) failures")
exit(failures == 0 ? 0 : 1)
