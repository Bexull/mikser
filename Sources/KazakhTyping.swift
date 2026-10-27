import Foundation

/// Autocorrect bookkeeping, separate from the event plumbing so it can be tested on its own.
///
/// It follows what is typed since the cursor last moved, as two words: the previous finished
/// word and the one being typed. When a word ends it decides how that word should look, and
/// may also fix the previous one now that it knows what follows ("сени жаксы" → "сені жақсы",
/// "жолын болсын" → "жолың болсын", "ата ана" → "ата-ана").
struct KazakhTyping {
    enum Input {
        case text(String)   // what the key typed
        case backspace
        case reset          // arrows, clicks, shortcuts: the cursor may have moved
    }

    enum Action: Equatable {
        case pass
        /// Drop the current key, delete `delete` characters (which should read `expect`),
        /// type `insert`, then let the current key through.
        case replace(delete: Int, insert: String, expect: String)
        /// Drop the backspace, delete `delete` characters (`expect`) and type `insert`:
        /// undoes the last replacement. It takes a second ⌫: the first one only erases the key
        /// that ended the word, so a "!" can follow "Сәлеметсіз бе".
        case undo(delete: Int, insert: String, expect: String)
    }

    /// Things worth remembering about the user, picked up by the app.
    enum Event: Equatable {
        case learned(word: String)     // typed a Kazakh word we didn't know
    }

    /// Which language the current phrase is in, judged from its words so far.
    enum Language { case unknown, kazakh, russian }

    private struct Word {
        var typed: String
        var shown: String
        /// Left as typed because the phrase language wasn't known yet ("тур", names).
        var waitingForContext = false
        /// Corrected before the language was known, though it is a Russian word too ("Сени"):
        /// a Russian word next takes the correction back.
        var provisional = false
        /// The user undid our change, or it is a finished pair: leave it alone.
        var locked = false
        /// Its vote in `score`, so it can be recounted when the word changes later.
        var evidence = 0
    }

    private struct Edit {
        let previousBefore: Word?
        let separatorBefore: String
        let typed: String
        let inserted: String
        let boundary: String
        let original: String
        /// How much of `boundary` is still on screen.
        var boundaryLeft: Int
    }

    /// Votes from the phrase so far: Kazakh letters count for Kazakh, plainly Russian words
    /// for Russian. One both-language word ("он") can't flip a clearly Kazakh phrase.
    private var score = 0
    var language: Language { score > 0 ? .kazakh : score < 0 ? .russian : .unknown }
    private(set) var events: [Event] = []
    private var previous: Word?
    private var separator = ""
    private var current = ""
    private var currentLocked = false
    private var lastEdit: Edit?

    mutating func takeEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    mutating func handle(_ input: Input, vocabulary: KazakhVocabulary) -> Action {
        switch input {
        case .reset:
            resetWindow()
            score = 0
            return .pass

        case .backspace:
            if var edit = lastEdit {
                guard edit.boundaryLeft == 0 else {
                    // Only the space (or comma) after the corrected word goes.
                    edit.boundaryLeft -= 1
                    lastEdit = edit
                    eraseOne()
                    return .pass
                }
                return undo(edit)
            }
            eraseOne()
            return .pass

        case .text(let text):
            lastEdit = nil
            if !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber }) {
                current += text
                return .pass
            }
            guard !current.isEmpty else {
                if text.contains(where: \.isNewline) {
                    resetWindow()
                    score = 0
                } else if previous != nil {
                    separator += text
                }
                return .pass
            }
            return finishWord(boundary: text, vocabulary: vocabulary)
        }
    }

    // MARK: - Finishing a word

    private mutating func finishWord(boundary: String, vocabulary: KazakhVocabulary) -> Action {
        let typed = current
        var word = Word(typed: typed, shown: typed, locked: currentLocked)
        var evidence = 0
        var known = false
        if currentLocked {
            evidence = KazakhWords.containsKazakhLetters(typed) ? 2 : 0
        } else {
            let decision = decide(typed, before: previous.map { lastToken(of: $0.shown) }, boundary: boundary,
                                  language: language, vocabulary: vocabulary)
            word.shown = decision.shown
            word.waitingForContext = decision.waitingForContext
            word.provisional = decision.provisional
            evidence = decision.evidence
            word.evidence = evidence
            known = decision.known
        }

        // The finished word may change how the previous one should look.
        var newPrevious = previous
        var joined: String?
        let linked = !separator.contains(where: \.isNewline) && separator.allSatisfy({ $0 == " " || $0.isPunctuation })
        if var before = previous, !before.locked, linked {
            let beforePlain = KazakhWords.plain(before.typed)
            if let form = vocabulary.rightContext[beforePlain + "\t" + word.shown.lowercased()] {
                before.shown = Self.adapt(form, to: before.typed) ?? before.typed
                before.waitingForContext = false
                before.provisional = false
            } else if before.waitingForContext, evidence > 0 {
                before.shown = decide(before.typed, before: nil, boundary: separator, language: .kazakh,
                                      vocabulary: vocabulary).shown
                before.waitingForContext = false
                score += 2 - before.evidence
                before.evidence = 2
            } else if before.provisional, evidence < 0 {
                before.shown = before.typed
                before.provisional = false
                score += -1 - before.evidence
                before.evidence = -1
            }
            if separator == " ", language != .russian, !before.shown.contains(" "), !word.shown.contains(" "),
               let pair = vocabulary.joined(before.typed, typed, firstShown: before.shown, secondShown: word.shown) {
                joined = Self.adapt(pair, to: before.typed) ?? pair
            }
            newPrevious = before
        }

        score = max(-3, min(3, score + evidence))
        if !known, !currentLocked, KazakhWords.containsKazakhLetters(typed) {
            events.append(.learned(word: typed.lowercased()))
        }

        let previousChanged = joined != nil || newPrevious?.shown != previous?.shown
        let oldSpan = previousChanged ? previous!.shown + separator + typed : typed
        let newSpan = joined ?? (previousChanged ? newPrevious!.shown + separator + word.shown : word.shown)

        let edit = Edit(previousBefore: previous, separatorBefore: separator, typed: typed, inserted: newSpan,
                        boundary: boundary, original: oldSpan, boundaryLeft: boundary.count)

        // Slide the window: the finished word becomes the previous one. A joined pair is one word now.
        if let joined, let before = previous {
            previous = Word(typed: before.typed + separator + typed, shown: joined, locked: true)
        } else if var held = newPrevious, held.provisional, !held.locked, linked, evidence == 0,
                  word.shown == typed || word.provisional, !word.waitingForContext,
                  held.typed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count < 3 {
            // A word that says nothing either way ("да", "5", another name) after a provisional
            // fix: keep them together, so a Russian word next can still take the fix back
            // ("Нурлан, Ерлан, привет").
            held.typed += separator + typed
            held.shown += separator + word.shown
            previous = held
        } else {
            previous = word
        }
        separator = boundary
        current = ""
        currentLocked = false
        if boundary.contains(where: \.isNewline) {
            resetWindow()
            score = 0
        }

        guard oldSpan != newSpan else { return .pass }
        lastEdit = edit
        return .replace(delete: oldSpan.count, insert: newSpan, expect: oldSpan)
    }

    private mutating func undo(_ edit: Edit) -> Action {
        lastEdit = nil
        // Back to what was on screen before, with the cursor at the end of the typed word.
        previous = edit.previousBefore
        if edit.original != edit.typed, var before = previous {
            before.locked = true
            previous = before
        }
        separator = edit.separatorBefore
        current = edit.typed
        currentLocked = true
        let left = String(edit.boundary.suffix(edit.boundaryLeft))
        return .undo(delete: edit.inserted.count + left.count, insert: edit.original, expect: edit.inserted + left)
    }

    /// An ordinary backspace: one character before the cursor goes.
    private mutating func eraseOne() {
        if !current.isEmpty {
            current.removeLast()
        } else if !separator.isEmpty {
            separator.removeLast()
            if separator.isEmpty, let word = previous {
                // Back inside the previous word (the last one, if several are kept together).
                let held = !word.locked && word.typed.contains(where: { !$0.isLetter && !$0.isNumber })
                current = held ? lastToken(of: word.shown) : word.shown
                currentLocked = word.locked
                previous = nil
            }
        }
    }

    private mutating func resetWindow() {
        previous = nil
        separator = ""
        current = ""
        currentLocked = false
        lastEdit = nil
    }

    private func lastToken(of text: String) -> String {
        String(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).last ?? Substring(text))
    }

    // MARK: - Deciding one word

    struct Decision {
        var shown: String
        var waitingForContext = false
        var provisional = false
        /// +2 Kazakh letters, +1 a Kazakh-only word, -1 mostly Russian, -2 a word only Russian knows.
        var evidence = 0
        var known = false
    }

    /// How `typed` should look, given the word before it and the phrase language so far.
    func decide(_ typed: String, before: String?, boundary: String, language: Language,
                vocabulary: KazakhVocabulary) -> Decision {
        guard typed.contains(where: KazakhWords.isCyrillicLetter) else { return Decision(shown: typed) }
        let plain = KazakhWords.plain(typed)
        let lower = typed.lowercased()
        let isRussian = vocabulary.russian?.contains(lower) ?? false

        // A particle typed on its own takes the form the previous word calls for ("шынымен бе").
        if let before, language != .russian, before.contains(where: KazakhWords.isCyrillicLetter),
           let particle = KazakhParticles.separate(plain: plain, after: before) {
            return Decision(shown: Self.adapt(particle, to: typed) ?? typed, evidence: 2, known: true)
        }

        if let entry = vocabulary.entry(forPlain: plain) {
            // An abbreviation ("ӘКК", "АҚШ") only when typed in capitals: in a chat "акк" is an
            // account and "сим" a SIM card.
            if entry.isAcronym, !(typed.count > 1 && typed == typed.uppercased()) {
                return Decision(shown: typed, known: true)
            }
            // Written together even in the corpus ("білесіңбе", "жоқпа"), or asked with "?" ("барма?").
            if !entry.isTrusted, language != .russian,
               let split = splitParticle(plain: plain, typed: typed, mergedCount: entry.forms[0].count,
                                         asked: boundary.contains("?"), language: language, vocabulary: vocabulary) {
                return Decision(shown: split, evidence: 2, known: true)
            }

            var form = entry.best
            var byContext = false
            if let before, let chosen = vocabulary.leftContext[before.lowercased() + "\t" + plain] {
                form = chosen
                byContext = true
            } else {
                form = Self.preferSecondPerson(entry, before: before, vocabulary: vocabulary) ?? form
                // The typed spelling is itself a common Kazakh word ("сал"): keep it.
                if !entry.isTrusted, !entry.isChat, form != lower, !KazakhWords.differsOnlyByPerson(form, lower),
                   entry.count(of: lower) >= max(1, entry.forms[0].count * 15 / 100) {
                    form = lower
                }
            }
            let ambiguousWithRussian = entry.isRussianToo || entry.isName || entry.isAcronym
            // Fixed before the language is known, and taken back if a Russian word follows
            // ("Нурлан, ты где?"): names, which say nothing about the language, and words Russian
            // has only as rare ones ("аска"). A name Russian also has as a word ("Канат", "Мука")
            // only with a capital and if the Kazakh name is common.
            let tentative = language == .unknown && !entry.isTrusted && !byContext && (entry.isMostlyKazakh || entry.isAcronym
                || entry.isName && (!entry.isRussianToo || typed.first?.isUppercase == true && entry.forms[0].count >= 50))
            let waits = ambiguousWithRussian && !entry.isTrusted && !byContext && language != .kazakh && !tentative
            let shown = waits ? typed : (Self.adapt(form, to: typed) ?? typed)
            let provisional = shown != typed && (isRussian || tentative) && language == .unknown && !byContext
                && !entry.isTrusted
            let evidence: Int
            if provisional || tentative {
                evidence = 0    // a guess about the language can't count as a vote for it ("Сени как дела")
            } else if KazakhWords.containsKazakhLetters(shown) {
                evidence = 2
            } else if entry.isMostlyRussian {
                evidence = -1
            } else {
                evidence = ambiguousWithRussian || isRussian ? 0 : 1
            }
            return Decision(shown: shown, waitingForContext: waits && form != lower, provisional: provisional,
                            evidence: evidence, known: true)
        }

        // Not a word the corpus knows. Russian words are left alone.
        if isRussian {
            return Decision(shown: typed, evidence: -2, known: true)
        }
        if let split = splitParticle(plain: plain, typed: typed, mergedCount: 0, asked: boundary.contains("?"),
                                     language: language, vocabulary: vocabulary) {
            return Decision(shown: split, evidence: 2, known: true)
        }
        let capitalized = typed.first?.isUppercase == true
        if let guess = compose(plain: plain, capitalized: capitalized, language: language, vocabulary: vocabulary),
           guess.text != lower {
            // A name with a Kazakh ending ("Узынагашка"), but the phrase may still turn out
            // Russian ("Нурланов сказал").
            let provisional = guess.fromName && language == .unknown
            return Decision(shown: Self.adapt(guess.text, to: typed) ?? typed, provisional: provisional,
                            evidence: provisional ? 0 : 2, known: true)
        }
        // Written small ("узынагашка"), a name waits for the phrase to show it is Kazakh.
        if language == .unknown, !capitalized,
           let guess = compose(plain: plain, capitalized: false, language: .kazakh, vocabulary: vocabulary),
           guess.fromName, guess.text != lower {
            return Decision(shown: typed, waitingForContext: true, known: true)
        }
        return Decision(shown: typed, evidence: KazakhWords.containsKazakhLetters(typed) ? 2 : -1)
    }

    /// A stem good enough to build on: a Kazakh word, not a Russian look-alike. A name only with
    /// a Kazakh case ending ("Ұзынағаш" + "қа"), and written small only inside a Kazakh phrase.
    private func usableStem(_ entry: KazakhEntry, ending: String, capitalized: Bool, language: Language) -> Bool {
        if entry.isName, !capitalized && language != .kazakh || !KazakhWords.nameEndings.contains(ending) {
            return false
        }
        return !entry.isRussianToo || language == .kazakh || KazakhWords.containsKazakhLetters(entry.best)
    }

    /// "айтасынба" → "айтасың ба", "биргана" → "бір ғана": a particle written together with its word.
    /// `mergedCount` > 0 when the merged spelling itself is in the corpus: then the stem must be
    /// far more common, or the word must end with a question mark.
    private func splitParticle(plain: String, typed: String, mergedCount: Int, asked: Bool, language: Language,
                               vocabulary: KazakhVocabulary) -> String? {
        for particle in KazakhParticles.attachable {
            guard plain.hasSuffix(particle.plain), plain.count - particle.plain.count >= 3 else { continue }
            let stemPlain = String(plain.dropLast(particle.plain.count))
            let stemTyped = String(typed.dropLast(particle.plain.count))
            let capitalized = typed.first?.isUppercase == true
            let stem: String
            if let entry = vocabulary.entry(forPlain: stemPlain), !entry.isName || capitalized || language == .kazakh {
                // A merged spelling the corpus knows well is a word of its own ("барма": don't go).
                if mergedCount > 0 && !(asked && particle.isQuestion)
                    && (mergedCount >= 20 || entry.forms[0].count < mergedCount * 5) { continue }
                stem = Self.preferSecondPerson(entry, before: nil, vocabulary: vocabulary) ?? entry.best
            } else if mergedCount == 0, let guess = compose(plain: stemPlain, capitalized: capitalized,
                                                            language: language, vocabulary: vocabulary) {
                stem = guess.text
            } else {
                continue
            }
            guard particle.fits(stem) || (asked && particle.isQuestion && mergedCount == 0) else { continue }
            let shownStem = Self.adapt(stem, to: stemTyped) ?? stemTyped
            return shownStem + " " + particle.form(stem)
        }
        return nil
    }

    struct Guess {
        let text: String
        /// Built on a name ("Ұзынағаш" + "қа").
        let fromName: Bool
    }

    /// A word the corpus lacks: a known stem plus a common ending ("көрсет" + "ші").
    func compose(plain: String, capitalized: Bool, language: Language, vocabulary: KazakhVocabulary) -> Guess? {
        guard plain.count >= 5, language != .russian else { return nil }
        for cut in stride(from: plain.count - 1, through: 3, by: -1) {
            let stemPlain = String(plain.prefix(cut))
            let endingPlain = String(plain.dropFirst(cut))
            guard let entry = vocabulary.entry(forPlain: stemPlain),
                  usableStem(entry, ending: endingPlain, capitalized: capitalized, language: language) else { continue }
            let stem = entry.best
            guard let endings = vocabulary.endings[KazakhWords.harmony(of: stem) + "\t" + endingPlain],
                  var ending = endings.first?.text else { continue }
            if let second = endings.dropFirst().first(where: {
                KazakhWords.differsOnlyByPerson(ending, $0.text) && KazakhWords.isSecondPersonEnding(stem + $0.text)
                    && $0.count * 20 >= endings[0].count
            }) {
                ending = second.text
            }
            guard KazakhWords.fitsHarmony(stem: stem, ending: ending) else { continue }
            return Guess(text: stem + ending, fromName: entry.isName)
        }
        return nil
    }

    /// Chat is mostly "you": between "-ың/-ің" (your) and "-ын/-ін" (his) take "-ың" unless
    /// the previous word points at a third person ("оның").
    static func preferSecondPerson(_ entry: KazakhEntry, before: String?, vocabulary: KazakhVocabulary) -> String? {
        let best = entry.forms[0]
        guard entry.forms.count > 1, best.text.count >= 4 else { return nil }
        if let before, KazakhWords.thirdPersonCues.contains(before.lowercased()) { return nil }
        for form in entry.forms.dropFirst() where form.count >= max(5, best.count / 100) {
            if KazakhWords.differsOnlyByPerson(best.text, form.text), KazakhWords.isSecondPersonEnding(form.text),
               form.text.filter({ $0 == "ң" }).count > best.text.filter({ $0 == "ң" }).count,
               !isWordOfItsOwn(best.text, other: form.text, vocabulary: vocabulary) {
                return form.text
            }
        }
        return nil
    }

    /// "Ойын" is a game, not "ой" + "-ын" (his thought): the corpus has its plural "ойындар",
    /// and a possessive ending never takes one.
    private static func isWordOfItsOwn(_ word: String, other: String, vocabulary: KazakhVocabulary) -> Bool {
        guard let index = zip(word.indices, zip(word, other)).first(where: { $0.1.0 != $0.1.1 })?.0 else { return false }
        let stem = String(word[...index])
        return ["дар", "дер", "тар", "тер", "лар", "лер"].contains { plural in
            vocabulary.entry(forPlain: KazakhWords.plain(stem + plural))?.forms.contains { $0.text == stem + plural } ?? false
        }
    }

    /// `form` with the typed word's capitalization, or nil if the typed word is already right.
    static func adapt(_ form: String, to typed: String) -> String? {
        let adapted: String
        let letters = typed.filter(\.isLetter)
        if letters.count > 1, letters == letters.uppercased(), letters != letters.lowercased() {
            adapted = form.uppercased()
        } else if let first = typed.first, first.isUppercase {
            adapted = form.prefix(1).uppercased() + form.dropFirst()
        } else {
            adapted = form
        }
        return adapted == typed ? nil : adapted
    }
}

/// Kazakh particles and the form each takes after a given word.
enum KazakhParticles {
    struct Particle {
        let plain: String
        let isQuestion: Bool
        let form: (String) -> String
        /// Whether the word before it can take this particle at all.
        let fits: (String) -> Bool
    }

    /// Particles people write together with the previous word.
    static let attachable: [Particle] = {
        var list = ["ма", "ме", "ба", "бе", "па", "пе"].map {
            Particle(plain: $0, isQuestion: true, form: question, fits: isPredicate)
        }
        list += [
            Particle(plain: "ше", isQuestion: false, form: { _ in "ше" }, fits: { pronouns.contains($0.lowercased()) }),
            Particle(plain: "гой", isQuestion: false, form: emphatic, fits: isPredicate),
            Particle(plain: "кой", isQuestion: false, form: emphatic, fits: isPredicate),
            // Spoken "ғой": "келе жатамго" is "келе жатам ғой".
            Particle(plain: "го", isQuestion: false, form: emphatic, fits: isPredicate),
            Particle(plain: "ко", isQuestion: false, form: emphatic, fits: isPredicate),
            Particle(plain: "гана", isQuestion: false, form: only, fits: { limited.contains($0.lowercased()) }),
            Particle(plain: "кана", isQuestion: false, form: only, fits: { limited.contains($0.lowercased()) }),
        ]
        return list
    }()

    private static let pronouns: Set<String> = ["мен", "сен", "ол", "біз", "сіз", "сендер", "сіздер", "олар"]
    private static let limited: Set<String> = ["бір", "аз", "сен", "мен", "сіз", "біз", "ол", "осы", "сол", "тек", "сәл"]
    private static let predicateWords: Set<String> = [
        "жақсы", "дұрыс", "рас", "бар", "жоқ", "мүмкін", "керек", "дайын", "аман", "сау", "шын", "шынымен",
        "солай", "осылай", "бос", "ыстық", "суық", "қымбат", "арзан", "мұнда", "сонда", "осында", "бүгін",
        "ертең", "қазір", "сен", "сіз", "сендер", "сіздер", "ол", "олар", "мен", "біз", "сенікі", "менікі",
        "жатыр", "отыр", "тұр", "жүр",
    ]
    private static let predicateEndings = [
        "сың", "сің", "сыз", "сіз", "мын", "мін", "бын", "бін", "пын", "пін", "мыз", "міз", "быз", "біз",
        "пыз", "піз", "дар", "дер", "тар", "тер", "дың", "дің", "тың", "тің", "ңыз", "ңіз", "ды", "ді",
        "ты", "ті", "ған", "ген", "қан", "кен", "атын", "етін", "йтын", "йтін", "ады", "еді", "йды", "йді",
    ]
    /// "I did", "we did" ("айттым", "келдік"), and spoken "I do" ("жатам", "келем", "ойлайм"
    /// for "жатырмын", "келемін", "ойлаймын"). Only after a few letters: "тік" alone is a verb.
    private static let shortEndings = [
        "дым", "дім", "тым", "тім", "дық", "дік", "тық", "тік", "ам", "ем", "йм",
    ]

    /// A finished statement that a question particle can follow ("айтасың", "болды", "жақсы"),
    /// as opposed to a bare verb stem ("кешік" + "пе" is "don't be late").
    static func isPredicate(_ word: String) -> Bool {
        let lower = word.lowercased()
        return predicateWords.contains(lower) || predicateEndings.contains { lower.hasSuffix($0) }
            || shortEndings.contains { lower.count >= $0.count + 2 && lower.hasSuffix($0) }
    }

    /// The particle a separate word should be ("ба" after "шынымен" is "бе"), or nil.
    static func separate(plain: String, after word: String) -> String? {
        switch plain {
        case "ма", "ме", "ба", "бе", "па", "пе": return question(after: word)
        case "гой": return emphatic(after: word)
        case "го", "ко":
            // Spoken "ғой" after a statement ("жатам го"), not slang "го" (let's go) or Russian "ко".
            return isPredicate(word) ? emphatic(after: word) : nil
        case "гана": return only(after: word)
        default: return nil
        }
    }

    /// ма/ме after vowels and л, р, у, й; ба/бе after м, н, ң, з, ж; па/пе after the rest.
    /// The vowel follows the word's last vowel.
    static func question(after word: String) -> String {
        let lower = word.lowercased()
        guard let last = lower.last else { return "ма" }
        let consonant: String
        if "аәеоөұүыіиэюяуйлр".contains(last) {
            consonant = "м"
        } else if "мнңзж".contains(last) {
            consonant = "б"
        } else {
            consonant = "п"
        }
        return consonant + (KazakhWords.harmony(of: lower) == "f" ? "е" : "а")
    }

    /// ғой after voiced sounds, қой after voiceless ones.
    static func emphatic(after word: String) -> String {
        isVoiceless(word) ? "қой" : "ғой"
    }

    static func only(after word: String) -> String {
        isVoiceless(word) ? "қана" : "ғана"
    }

    private static func isVoiceless(_ word: String) -> Bool {
        guard let last = word.lowercased().last else { return false }
        return "кқпстфхцчшщ".contains(last)
    }
}
