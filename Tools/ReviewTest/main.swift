// Word-level check of autocorrect on real text: each line is "typed <TAB> as written"
// (Tools/make-review-test.py). Build and run:
//   swiftc -O -o build/review-test Tools/ReviewTest/main.swift Sources/KazakhTyping.swift \
//     Sources/KazakhWords.swift Sources/KazakhLexicon.swift
//   build/review-test Resources/kazakh review-test.tsv [number of misses to list]

import Foundation

let vocabularyPath = CommandLine.arguments[1], setPath = CommandLine.arguments[2]
let showErrors = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 0 : 0
var vocabulary = KazakhVocabulary.load(from: URL(fileURLWithPath: vocabularyPath))
vocabulary.words = KazakhWords.dictionary()

func type(_ text: String) -> String {
    var typing = KazakhTyping()
    var screen = ""
    for key in (text + " ").map(String.init) {
        switch typing.handle(.text(key), vocabulary: vocabulary) {
        case .pass: screen += key
        case .replace(let delete, let insert, _):
            screen.removeLast(min(delete, screen.count)); screen += insert + key
        case .undo(let delete, let insert, _):
            screen.removeLast(min(delete, screen.count)); screen += insert
        }
    }
    return screen.trimmingCharacters(in: .whitespaces)
}
func words(_ text: String) -> [String] {
    text.split(whereSeparator: { !$0.isLetter }).map(String.init)
}
let kazakh = Set("әіңғқөүұһӘІҢҒҚӨҮҰҺ")
var needed = 0, restored = 0, plainKept = 0, plainChanged = 0, other = 0, exact = 0, total = 0, mismatched = 0
var errors: [String: Int] = [:]
let lines = try! String(contentsOfFile: setPath, encoding: .utf8).split(separator: "\n")
for line in lines {
    let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else { continue }
    total += 1
    let got = type(parts[0])
    if got == parts[1] { exact += 1 }
    let typedWords = words(parts[0]), gotWords = words(got), expectedWords = words(parts[1])
    guard gotWords.count == expectedWords.count else {
        mismatched += 1
        errors["[split/join] " + parts[0].prefix(60) + " → " + got.prefix(60), default: 0] += 1
        continue
    }
    for ((typed, got), expected) in zip(zip(typedWords, gotWords), expectedWords) {
        if expected.contains(where: kazakh.contains) {
            needed += 1
            if got == expected { restored += 1 } else { errors["\(typed) → \(got) (надо \(expected))", default: 0] += 1 }
        } else if typed == expected {
            if got == expected { plainKept += 1 } else {
                plainChanged += 1
                errors["!! \(typed) → \(got) (было верно)", default: 0] += 1
            }
        } else { other += 1 }
    }
}
func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.1f%%", 100.0 * Double(a) / Double(b)) }
print("reviews: \(total), exactly right: \(exact) (\(pct(exact, total))), word count changed: \(mismatched)")
print("words with Kazakh letters restored: \(restored) of \(needed) (\(pct(restored, needed)))")
print("words without Kazakh letters spoiled: \(plainChanged) of \(plainKept + plainChanged) (\(pct(plainChanged, plainKept + plainChanged)))")
if showErrors > 0 {
    print("\nmost common misses:")
    for (text, count) in errors.sorted(by: { $0.value > $1.value || $0.value == $1.value && $0.key < $1.key }).prefix(showErrors) {
        print("  \(count)× \(text)")
    }
}
