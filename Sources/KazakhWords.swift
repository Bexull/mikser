import Foundation

/// Common Kazakh words that people type with plain Russian letters ("казак" for "қазақ").
/// Each word is found by its "Russian-letter" spelling. Words whose plain spelling is an
/// everyday Russian word are left out on purpose ("торт", "тур", "ага", "тенге", "казан"…).
enum KazakhWords {
    static let builtIn = """
    сәлем сәлеметсіз қайырлы таң түн күн қалай қалайсың қалайсыз жақсы жақсымын қош кешіріңіз кешір
    кешірім иә жоқ біз сіз сіздер менің сенің оның біздің сіздің қайда қашан қандай қанша қайсы
    қайсысы қайдан мұнда мұндай қане бүгін бүгінгі ертең ертеңгі кешегі қазір кейін бұрын уақыт сағат
    таңертең түс түнде үй үйде үйге жұмыс жұмыста оқы оқу оқушы оқытушы мұғалім сабақ қала қалада
    қазақ қазақша қазақстан ағылшын ағылшынша тіл сөйле сөйлейсіз сөйлейсің сөйлеймін түсін түсіндім
    түсінбедім түсінесің түсінік білем білмеймін білесің білесіз келдім келдің келдіңіз кеттім жүр
    жүрміз бір екі үш жеті сегіз тоғыз қырық жетпіс тоқсан жүз мың бірге үшін сияқты тағы ғана және
    бірақ сондықтан себебі бұл барлық көп үлкен кішкентай кішкене жаңа ескі жақын суық ыстық тамақ
    әже әке қыз қызым қыздар ұлым іні сіңлі қарындас құдай сүйемін қымбат қымбаттым бақыт бақытты
    денсаулық құтты құттықтаймын құттықтаймыз туған мерекеңіз болыңыз қажет мүмкін дұрыс ақша дүкен
    көше қайтып қайта сенбі жексенбі дүйсенбі сейсенбі сәрсенбі бейсенбі жұма қаңтар ақпан сәуір
    шілде қыркүйек қараша желтоқсан сізге саған маған оған бізге сіздерге оларға қалдым қалды
    айтыңыз жазыңыз оқыңыз келіңіз отырыңыз сұраймын сұрақ қызық қызықты ұнайды ұнамайды көрем
    көремін тәуелсіздік елім халық кісі әйел жігіт ғой шығар шығып кіріп беріңіз кеңес кеңсе көмек
    көмектесіңіз өте оңай қиын оқасы ештеңе
    """

    private static let plainLetters: [Character: Character] = [
        "ә": "а", "і": "и", "ң": "н", "ғ": "г", "қ": "к", "ө": "о", "ү": "у", "ұ": "у", "һ": "х",
        "i": "и",  // a Latin i typed for the Kazakh і
    ]

    /// The spelling a word gets when typed with Russian letters only.
    static func plain(_ word: String) -> String {
        String(word.lowercased().map { plainLetters[$0] ?? $0 })
    }

    static func isKazakhLetter(_ character: Character) -> Bool {
        guard let lower = character.lowercased().first, lower != "i" else { return false }
        return plainLetters[lower] != nil
    }

    static func containsKazakhLetters(_ text: String) -> Bool {
        text.contains(where: isKazakhLetter)
    }

    static func isCyrillicLetter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) } && character.isLetter
    }

    /// "b" if the word's last vowel is back (а о ұ ы), "f" if front (ә е ө ү і), "-" if unknown.
    static func harmony(of word: String) -> String {
        for letter in word.lowercased().reversed() {
            if "аоұыя".contains(letter) { return "b" }
            if "әеөүіэ".contains(letter) { return "f" }
        }
        return "-"
    }

    /// Kazakh writes ғ and қ with back vowels, г and к with front ones; an ending must agree
    /// with its stem.
    static func fitsHarmony(stem: String, ending: String) -> Bool {
        let stemHarmony = harmony(of: stem)
        guard stemHarmony != "-" else { return true }
        for letter in ending {
            if "аоұы".contains(letter) || "ғқ".contains(letter) { return stemHarmony == "b" }
            if "әеөүі".contains(letter) || "гк".contains(letter) { return stemHarmony == "f" }
        }
        return true
    }

    /// Same word but "your" (ң) instead of "his" (н) near the end: "күнің" / "күнін".
    static func differsOnlyByPerson(_ first: String, _ second: String) -> Bool {
        let a = Array(first), b = Array(second)
        guard a.count == b.count, a != b else { return false }
        for index in a.indices where a[index] != b[index] {
            let pair = Set([a[index], b[index]])
            guard pair == ["н", "ң"], index >= a.count - 4 else { return false }
        }
        return true
    }

    /// A real "your"/"you" ending: -сың, -ың, -ыңыз, -ыңды, -ың + case... but not "-мың" (1st person).
    static func isSecondPersonEnding(_ word: String) -> Bool {
        let lower = word.lowercased()
        let cases = ["", "ыз", "із", "ды", "ді", "ты", "ті", "а", "е", "нан", "нен", "мен", "да", "де", "та", "те",
                     "ға", "ге", "қа", "ке", "дар", "дер"]
        for suffix in cases {
            guard lower.hasSuffix("ң" + suffix) else { continue }
            let stem = Array(lower.dropLast(suffix.count + 1))
            guard let vowel = stem.last else { return false }
            if "ыі".contains(vowel) {
                return stem.count < 2 || stem[stem.count - 2] != "м"
            }
            return "аеоөұүә".contains(vowel)
        }
        return false
    }

    /// Words after which "-ын/-ін" (his, hers) is meant rather than "-ың/-ің" (your).
    static let thirdPersonCues: Set<String> = ["оның", "олардың", "өзінің", "соның", "мұның", "бұның", "кімнің"]

    /// Endings a name or place takes in Kazakh ("Ұзынағашқа", "Қарлығашпен"), plain spelling.
    /// Russian case endings ("Нурлана", "Нурланом") are not here.
    static let nameEndings: Set<String> = [
        "га", "ге", "ка", "ке", "на", "не",                 // to
        "ны", "ни", "ды", "ди", "ты", "ти",                 // object
        "нын", "нин", "дын", "дин", "тын", "тин",           // of
        "да", "де", "та", "те", "дагы", "деги", "тагы", "теги",
        "дан", "ден", "тан", "тен", "нан", "нен",           // from
        "мен", "бен", "пен", "сыз", "сиз",                  // with, without
        "дай", "дей", "тай", "тей", "дики", "тики", "ники",
        "лар", "лер", "дар", "дер", "тар", "тер",
    ]

    /// The autocorrect data built from a Kazakh text corpus, shipped in the app.
    static func loadVocabulary() -> KazakhVocabulary {
        guard let folder = Bundle.main.url(forResource: "kazakh", withExtension: nil) else { return KazakhVocabulary() }
        return KazakhVocabulary.load(from: folder)
    }

    /// Plain spelling -> correct word. The user's list (one word per line, # for comments)
    /// comes last, so it can add words and override built-in ones.
    static func dictionary(userList: String = "", includeBuiltIn: Bool = true) -> [String: String] {
        var result: [String: String] = [:]
        for word in builtIn.split(whereSeparator: \.isWhitespace) where includeBuiltIn {
            let correct = String(word)
            let key = plain(correct)
            if key != correct, result[key] == nil { result[key] = correct }
        }
        for line in userList.split(whereSeparator: \.isNewline) {
            let text = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            for word in text.split(whereSeparator: \.isWhitespace) {
                let correct = String(word).lowercased()
                let key = plain(correct)
                if key != correct { result[key] = correct }
            }
        }
        return result
    }

    static var userListURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mixer/kazakh-words.txt")
    }

    static let userListTemplate = """
    # Свои казахские слова для автозамены — по одному или несколько в строке, в правильном написании.
    # Микшер сам поймёт, как их набирают русскими буквами: «рақмет» сработает на «ракмет».
    # Изменения подхватываются сразу после сохранения.

    """
}
