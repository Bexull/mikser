import Foundation

/// One way a plain spelling can be written in Kazakh, with how often the corpus saw it.
struct KazakhForm: Equatable {
    let text: String
    let count: Int
}

/// What a word typed with Russian letters may stand for.
struct KazakhEntry: Equatable {
    /// Most frequent first. May include the plain spelling itself ("туыс", "сал").
    let forms: [KazakhForm]
    /// The plain spelling is also a Russian word ("тур"): only correct it inside Kazakh text.
    var isRussianToo = false
    /// A name ("Айгерим"): Russian text keeps the Russian spelling.
    var isName = false
    /// The plain spelling is far more common in Russian ("для", "он"): a vote for Russian.
    var isMostlyRussian = false
    /// Russian has the plain spelling only as a rare word next to a common Kazakh one
    /// ("аска": асқа): correct it without waiting for Kazakh text.
    var isMostlyKazakh = false
    /// Nearly always written in capitals ("ӘКК", "АҚШ"): an abbreviation.
    var isAcronym = false
    /// The best form is a hand-picked chat word ("тұрасың"): always worth correcting to.
    var isChat = false
    /// Hand-picked, the user's own or learned word: always applies.
    var isTrusted = false

    var best: String { forms[0].text }

    func count(of text: String) -> Int {
        forms.first { $0.text == text }?.count ?? 0
    }
}

protocol KazakhLexicon {
    func entry(forPlain plain: String) -> KazakhEntry?
}

/// Everything autocorrect knows.
struct KazakhVocabulary {
    /// Plain spelling -> word: hand-picked list, the user's words, learned words.
    var words: [String: String] = [:]
    var corpus: KazakhLexicon?
    /// "prev<TAB>plain" -> form chosen after that word; "plain<TAB>next" -> form chosen before it.
    var leftContext: [String: String] = [:]
    var rightContext: [String: String] = [:]
    /// Plain "first<TAB>second" -> "first-second" or "firstsecond"; "first<TAB>secoX*" -> "-"
    /// for whole families ("бір" + "бір…" always takes a hyphen).
    var pairs: [String: String] = [:]

    /// How two typed words should be joined, if they belong together.
    func joined(_ first: String, _ second: String, firstShown: String, secondShown: String) -> String? {
        let firstPlain = KazakhWords.plain(first), secondPlain = KazakhWords.plain(second)
        if let pair = pairs[firstPlain + "\t" + secondPlain] { return pair }
        if secondPlain.count >= 4, pairs[firstPlain + "\t" + secondPlain.prefix(4) + "*"] == "-" {
            return firstShown.lowercased() + "-" + secondShown.lowercased()
        }
        return nil
    }
    /// "<b|f|-><TAB>plain ending" -> endings, most frequent first ("b" / "f": back / front stem).
    var endings: [String: [KazakhForm]] = [:]
    /// Russian words: never guessed as Kazakh.
    var russian: KazakhWordList?

    func entry(forPlain plain: String) -> KazakhEntry? {
        if let word = words[plain] {
            return KazakhEntry(forms: [KazakhForm(text: word, count: 1_000_000)], isTrusted: true)
        }
        return corpus?.entry(forPlain: plain)
    }
}

/// A memory-mapped text file of lines sorted by their first tab-separated field (UTF-8 bytes),
/// searched by binary search: large word lists for almost no memory.
final class SortedLines {
    let data: Data
    private let lineStarts: [Int]

    var count: Int { lineStarts.count }

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return nil }
        self.data = data
        var starts: [Int] = []
        starts.reserveCapacity(data.count / 20)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = 0
            for index in 0..<bytes.count where bytes[index] == 0x0A {
                if index > lineStart { starts.append(lineStart) }
                lineStart = index + 1
            }
            if lineStart < bytes.count { starts.append(lineStart) }
        }
        lineStarts = starts
    }

    /// The rest of the line after `key` and its tab, or nil if no line starts with `key`.
    func lookup(_ key: String) -> String? {
        let key = Array(key.utf8)
        return data.withUnsafeBytes { raw -> String? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var low = 0
            var high = lineStarts.count - 1
            while low <= high {
                let middle = (low + high) / 2
                let start = lineStarts[middle]
                let order = Self.compare(key, bytes, start)
                if order == 0 {
                    var from = start + key.count
                    if from < bytes.count && bytes[from] == 0x09 { from += 1 }
                    var end = from
                    while end < bytes.count && bytes[end] != 0x0A { end += 1 }
                    return String(decoding: UnsafeBufferPointer(rebasing: bytes[from..<end]), as: UTF8.self)
                }
                if order < 0 { high = middle - 1 } else { low = middle + 1 }
            }
            return nil
        }
    }

    /// Compares `key` with the first field of the line starting at `start`.
    private static func compare(_ key: [UInt8], _ bytes: UnsafeBufferPointer<UInt8>, _ start: Int) -> Int {
        var index = 0
        while true {
            let position = start + index
            let lineByte: UInt8 = position < bytes.count ? bytes[position] : 0x0A
            let lineEnded = lineByte == 0x09 || lineByte == 0x0A
            if index == key.count { return lineEnded ? 0 : -1 }
            if lineEnded { return 1 }
            if key[index] != lineByte { return key[index] < lineByte ? -1 : 1 }
            index += 1
        }
    }
}

/// Russian words, one per line (Tools/make-kazakh-dictionary.py writes russian.txt).
final class KazakhWordList {
    private let lines: SortedLines

    init?(url: URL) {
        guard let lines = SortedLines(url: url) else { return nil }
        self.lines = lines
    }

    func contains(_ word: String) -> Bool { lines.lookup(word) != nil }
}

/// The word-form list built by Tools/make-kazakh-dictionary.py: one line per plain spelling,
/// "plain<TAB>form:count|form:count<TAB>flags", sorted by plain spelling (UTF-8 bytes).
/// "=" is the plain spelling itself; flags: "r" also a Russian word, "n" a name.
final class KazakhCorpus: KazakhLexicon {
    private let lines: SortedLines

    var count: Int { lines.count }

    init?(url: URL) {
        guard let lines = SortedLines(url: url) else { return nil }
        self.lines = lines
    }

    func entry(forPlain plain: String) -> KazakhEntry? {
        guard let rest = lines.lookup(plain) else { return nil }
        let fields = rest.split(separator: "\t", omittingEmptySubsequences: false)
        guard let formsField = fields.first else { return nil }
        let forms = Self.parseForms(String(formsField), plain: plain)
        guard !forms.isEmpty else { return nil }
        let flags = fields.count > 1 ? fields[1] : ""
        return KazakhEntry(forms: forms, isRussianToo: flags.contains("r"), isName: flags.contains("n"),
                           isMostlyRussian: flags.contains("R"), isMostlyKazakh: flags.contains("k"),
                           isAcronym: flags.contains("a"), isChat: flags.contains("c"))
    }

    /// "form:count|=:count" -> forms; "=" is the plain spelling.
    static func parseForms(_ field: String, plain: String) -> [KazakhForm] {
        field.split(separator: "|").compactMap { item in
            guard let colon = item.lastIndex(of: ":"), let count = Int(item[item.index(after: colon)...]) else { return nil }
            let text = String(item[..<colon])
            return KazakhForm(text: text == "=" ? plain : text, count: count)
        }
    }
}

extension KazakhVocabulary {
    /// Loads everything from a folder of files built by Tools/make-kazakh-dictionary.py.
    static func load(from folder: URL) -> KazakhVocabulary {
        var vocabulary = KazakhVocabulary()
        vocabulary.corpus = KazakhCorpus(url: folder.appendingPathComponent("dictionary.tsv"))
        vocabulary.russian = KazakhWordList(url: folder.appendingPathComponent("russian.txt"))
        forEachLine(folder.appendingPathComponent("context.tsv")) { fields in
            guard fields.count == 4 else { return }
            if fields[0] == "L" { vocabulary.leftContext[fields[1] + "\t" + fields[2]] = fields[3] }
            if fields[0] == "R" { vocabulary.rightContext[fields[1] + "\t" + fields[2]] = fields[3] }
        }
        forEachLine(folder.appendingPathComponent("pairs.tsv")) { fields in
            guard fields.count == 3 else { return }
            vocabulary.pairs[fields[0] + "\t" + fields[1]] = fields[2]
        }
        forEachLine(folder.appendingPathComponent("endings.tsv")) { fields in
            guard fields.count == 3 else { return }
            vocabulary.endings[fields[0] + "\t" + fields[1]] = KazakhCorpus.parseForms(fields[2], plain: fields[1])
        }
        return vocabulary
    }

    private static func forEachLine(_ url: URL, _ body: ([String]) -> Void) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            body(line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init))
        }
    }
}
