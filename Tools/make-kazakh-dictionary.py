#!/usr/bin/env python3
"""Builds the data for Kazakh autocorrect (Resources/kazakh/).

People type Kazakh with plain Russian letters ("сиздерди" for "сіздерді"). From a Kazakh
corpus this script learns, for every such plain spelling, which real word forms it stands
for and how often, plus the context that helps choose between them.

usage:
  make-kazakh-dictionary.py OUTDIR --words WORDS --sentences SENTENCES --russian RU [RU ...]
      [--subtitles kk_full.txt] [--informal REVIEWS.csv ...] [--chat Tools/kazakh-chat-words.txt]
      [--phrases Tools/kazakh-phrases.txt] [--joins Tools/kazakh-joins.txt] [--spoken Tools/kazakh-spoken.txt]

WORDS / SENTENCES: Leipzig Corpora files (kaz_newscrawl_2016_1M-words.txt, -sentences.txt).
REVIEWS: KazSAnDRA CSV files (informal reviews, column "text"): words the news corpus lacks.
RU: FrequencyWords ru_full.txt and Tools/russian-kazakhstan.txt ("word count" lines): plain
spellings that are Russian words are corrected only inside Kazakh phrases. Lists after the first
are Russian words of Kazakhstan ("тенге", "Актобе"): always kept in Russian text.

Output files (all UTF-8, tab-separated):
  dictionary.tsv  plain, forms ("form:count|form:count", "=" is the plain spelling), flags
                  (r = also a Russian word, R = mostly Russian, k = a rare Russian word next to a
                  common Kazakh one, n = a name, a = an abbreviation, c = chat word, s = spoken form, written the
                  standard way: "нестиміз" -> "не істейміз").
                  Sorted by plain spelling as bytes.
  context.tsv     L prev-word key form   /  R key next-word form: neighbour decides the form.
  pairs.tsv       plain first, plain second, joined: "ата ана" -> "ата-ана", "еш ким" -> "ешкім".
  russian.txt     Russian words (sorted): never guessed as Kazakh.
  endings.tsv     plain ending, forms ("ending:count|..."): to guess words the corpus lacks.
  kk.dic, kk.aff  Hunspell spelling dictionary for macOS (~/Library/Spelling).
"""

import argparse
import collections
import csv
import re

KAZAKH_ONLY = "әіңғқөүұһ"
PLAIN = str.maketrans("әіңғқөүұһ", "аингкоуух")
LETTERS = "а-яёәіңғқөүұһ"
WORD = re.compile(rf"^[{LETTERS}]{{2,}}$")
TOKEN = re.compile(r"[A-Za-zА-Яа-яЁёӘәІіҢңҒғҚқӨөҮүҰұҺһ]+")
CYRILLIC = re.compile(rf"[{LETTERS}]")
BACK, FRONT = set("аоұы"), set("әеөүіэ")


def plain(word):
    return word.translate(PLAIN)


def normalize(token):
    """Lowercase; a Latin i inside a Cyrillic word is the Kazakh і."""
    word = token.lower()
    if "i" in word and CYRILLIC.search(word):
        word = word.replace("i", "і")
    return word


def read_list(path):
    counts = collections.Counter()
    with open(path, encoding="utf-8", errors="replace") as lines:
        for line in lines:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                word, count = parts[1], parts[2]
            else:
                parts = line.split()
                if len(parts) != 2:
                    continue
                word, count = parts
            if count.isdigit():
                counts[word] += int(count)
    return counts


def read_words(path):
    """Counts per lowercase form, and how often each form was capitalized or all in capitals."""
    counts, capitalized, capitals = collections.Counter(), collections.Counter(), collections.Counter()
    hyphenated = collections.Counter()
    for raw, count in read_list(path).items():
        word = normalize(raw)
        if WORD.match(word):
            counts[word] += count
            if raw[:1].isupper() and raw[1:].islower():
                capitalized[word] += count
            elif raw.isupper():
                capitals[word] += count
        elif "-" in word:
            parts = word.split("-")
            if len(parts) == 2 and all(WORD.match(part) for part in parts):
                hyphenated[tuple(parts)] += count
    return counts, capitalized, capitals, hyphenated


def read_text_words(path):
    words = []
    if path:
        with open(path, encoding="utf-8") as lines:
            for line in lines:
                words += line.split("#", 1)[0].split()
    return [normalize(word) for word in words if WORD.match(normalize(word))]


def harmony(word):
    for letter in reversed(word):
        if letter in BACK:
            return "b"
        if letter in FRONT:
            return "f"
    return ""


# Standard forms of the verbs people merge with "не" (what) when they speak: "не қыл" -> "нағыл".
SPOKEN_VERBS = {
    "қыл": "қыл қылам қыламын қыламыз қыласың қыласыз қыласыңдар қыласыздар қылады қылайын қылайық "
           "қылдым қылдың қылдыңыз қылды қылдық қылған қылғаным қылғаның қылып қып қылсын қылсам қылсаң "
           "қылсаңыз қылсақ қылу қылуым қылуға қылмақсың қылар",
    "істе": "істе істеймін істейміз істейсің істейсіз істейсіңдер істейсіздер істейді істейін істейік "
            "істедім істедің істедіңіз істеді істедік істеген істегенің істеп істеу істеуге істеуім "
            "істеуіміз істесем істесең істесе істесек істейтін істер істемек",
    "ет": "етемін етеміз етесің етесіз етесіңдер етеді етейін етейік еттім еттің етті еттік етіп ету "
          "етуге етсем етсең етсе етсек етер етпек",
    "бол": "болды болдың болдыңыз болған болады боласың боласыз болам боламын боламыз болса болсын "
           "болып боп бопты болыпты болмақ болмайды болар",
    "де": "деп деді дедің дедіңіз дейді дейсің дейсіз деймін дейміз дейін десе десең деген дегенің",
}
# Spoken verbs "do so / like this", too rare in the news to have their forms ("неге үйттің").
# All their common forms are added like chat words.
SPOKEN_STEMS = ("үйт", "бүйт", "сүйт", "өйт")
SPOKEN_STEM_ENDINGS = (
    "", "ші", "іңіз", "іңдер", "тім", "тің", "тіңіз", "ті", "тік", "тіңдер", "тіңіздер", "іп", "іпсің",
    "іпті", "пе", "пеші", "пеңіз", "пеңдер", "емін", "ем", "есің", "еді", "еміз", "есіз", "есіңдер",
    "ейін", "ейік", "сем", "сең", "се", "сек", "сеңіз", "кен", "кені", "кенде", "етін", "пеген", "педім",
    "педің", "педі", "пеймін", "пейсің", "пейді", "у", "уге",
)
# Present tense after "-ей-", which speech shortens to "-и-": "білмеймін" -> "білмимін".
EI_ENDING = re.compile(r"^(.+)ей(мін|міз|сің|сіз|сіңдер|сіздер|ді|тін|м)$")
AI_ENDING = re.compile(r"^(.+)ай(мын|мыз|сың|сыз|сыңдар|сыздар|ды|тын|м)$")


def spoken_variants(word):
    """The word as speech shortens it and as people type it: "-ей-" said "-и-" or typed "-еи-"."""
    variants = {word}
    if match := EI_ENDING.match(word):
        variants |= {match[1] + "и" + match[2], match[1] + "еи" + match[2]}
    if match := AI_ENDING.match(word):
        variants.add(match[1] + "аи" + match[2])
    return variants


def spoken_forms(counts, totals, best_form, russian, manual):
    """Plain spelling -> standard words, for spoken forms the corpus lacks: "не" + verb said as one
    word ("нягыл" = не қыл, "нестиміз" = не істейміз, "нетеміз" = не етеміз) and "-и-" for
    "-ей-" ("білмимін" = білмеймін). A spelling that is a real word of its own ("нақыл", "неткен",
    "жемісін") or a Russian word is left alone."""
    spoken = {}

    def add(variant, standard, count):
        key = plain(variant)
        if key in russian or key == plain(standard):
            return
        # A known spelling may only be taken over when it is this very spoken form ("неғып").
        if totals.get(key, 0) >= 3 and best_form.get(key) != variant:
            return
        if key not in spoken or spoken[key][1] < count:
            spoken[key] = (standard, count)

    for stem, forms in SPOKEN_VERBS.items():
        for form in forms.split():
            count = max(counts.get(form, 0), 10)
            # Said as one word, "неғып" asks why: "неғып олай жасадың" is "неге олай жасадың".
            standard = "неге" if form in ("қып", "қылып") else "не " + form
            for said in spoken_variants(form):
                if stem == "қыл":
                    for start in ("неғ", "нағ", "няғ", "нәғ"):
                        add(start + said[1:], standard, count)
                    add("не" + said, standard, count)
                elif stem == "істе":
                    add("не" + said, standard, count)
                    add("не" + said[1:], standard, count)
                elif stem == "ет":
                    add("н" + said, standard, count)
                    add("не" + said, standard, count)
                else:
                    add("не" + said, standard, count)
    for word, count in counts.items():
        if count >= 10 and (EI_ENDING.match(word) or AI_ENDING.match(word)):
            for said in spoken_variants(word) - {word}:
                add(said, word, count)
    for said, standard in manual:
        spoken[plain(said)] = (standard, max(counts.get(standard, 0), 50))
    return spoken


MERGED_PARTICLES = ("ма", "ме", "ба", "бе", "па", "пе", "ғой", "қой", "ғо", "қо", "ше", "ғана", "қана")


def read_informal(paths, known):
    """Words from informal reviews that the news corpus (`known`) lacks: chat and app words.
    Only reviews written with Kazakh letters count, and words the news has keep their news
    counts, since reviews are full of typos ("Кәспи", "брақ"). Particles written together with
    their word ("жоқпа") are not words of their own."""
    counts = collections.Counter()
    for path in paths or []:
        with open(path, encoding="utf-8", newline="") as rows:
            for row in csv.DictReader(rows):
                words = [word for word in map(normalize, TOKEN.findall(row["text"])) if WORD.match(word)]
                with_letters = sum(any(letter in KAZAKH_ONLY for letter in word) for word in words)
                if with_letters >= 2 and with_letters * 5 >= len(words):
                    counts.update(words)
    known_keys = collections.Counter()
    for word, count in known.items():
        known_keys[plain(word)] += count

    def merged(word):
        key = plain(word)
        return any(key.endswith(plain(particle)) and len(key) - len(particle) >= 3
                   and known_keys[key[:-len(particle)]] >= 3 for particle in MERGED_PARTICLES)

    return {word: count for word, count in counts.items() if known_keys[plain(word)] < 3 and not merged(word)}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("outdir")
    parser.add_argument("--words", required=True)
    parser.add_argument("--sentences", required=True)
    parser.add_argument("--russian", nargs="+", required=True)
    parser.add_argument("--subtitles")
    parser.add_argument("--informal", nargs="*")
    parser.add_argument("--spoken")
    parser.add_argument("--chat")
    parser.add_argument("--phrases")
    parser.add_argument("--joins")
    parser.add_argument("--min-count", type=int, default=3)
    parser.add_argument("--min-russian", type=int, default=50, help="Russian words this common protect their spelling")
    args = parser.parse_args()
    out = args.outdir.rstrip("/") + "/"

    counts, capitalized, capitals, hyphenated = read_words(args.words)
    if args.subtitles:
        for raw, count in read_list(args.subtitles).items():
            word = normalize(raw)
            if WORD.match(word):
                counts[word] += count * 3  # conversational, but a small sample
    chat = read_text_words(args.chat) + [stem + ending for stem in SPOKEN_STEMS for ending in SPOKEN_STEM_ENDINGS]
    for word in chat:
        counts[word] = max(counts[word], 50, counts[plain(word)] + 1 if plain(word) != word else 0)
    phrases = []
    if args.phrases:
        with open(args.phrases, encoding="utf-8") as lines:
            phrases = [[normalize(w) for w in line.split("#", 1)[0].split()] for line in lines]
        phrases = [phrase for phrase in phrases if len(phrase) > 1]
        for phrase in phrases:
            for word in phrase:
                counts[word] = max(counts[word], 50)
    informal = read_informal(args.informal, counts)
    counts.update(informal)

    russian_counts = collections.Counter()
    local_russian = set()
    for index, path in enumerate(args.russian):
        for word, count in read_list(path).items():
            russian_counts[word.lower()] += count
            if index > 0:
                local_russian.add(word.lower())
    russian = {word for word, count in russian_counts.items() if count >= args.min_russian}
    # Every Russian word seen at least 3 times: the app never guesses Kazakh forms for them.
    known_russian = sorted({w for w, c in russian_counts.items() if c >= 3 and re.match(rf"^[{LETTERS}]+$", w)},
                           key=lambda w: w.encode())
    with open(out + "russian.txt", "w", encoding="utf-8") as file:
        file.writelines(word + "\n" for word in known_russian)
    print(f"russian: {len(known_russian)} words, {len(russian)} common enough to protect Kazakh look-alikes")

    # dictionary.tsv
    groups = collections.defaultdict(dict)
    for word, count in counts.items():
        if count >= args.min_count:
            groups[plain(word)][word] = count
    chat_set = set(chat)
    kazakh_total = sum(counts.values())
    russian_total = sum(russian_counts.values())
    lines, names, flagged = [], 0, 0
    best_form = {key: max(forms, key=forms.get) for key, forms in groups.items()}
    totals = {key: sum(forms.values()) for key, forms in groups.items()}
    manual = []
    if args.spoken:
        with open(args.spoken, encoding="utf-8") as rows:
            for row in rows:
                parts = row.split("#", 1)[0].split(None, 1)
                if len(parts) == 2:
                    manual.append((normalize(parts[0]), " ".join(normalize(w) for w in parts[1].split())))
    spoken = spoken_forms(counts, totals, best_form, russian, manual)
    for key, (standard, count) in spoken.items():
        lines.append((key.encode(), f"{key}\t{standard}:{count}\ts\n"))
    for key, forms in groups.items():
        if key in spoken:
            continue
        ranked = sorted(forms.items(), key=lambda item: -item[1])[:3]
        best = ranked[0][0]
        flags = ""
        total = sum(forms.values())
        if key in russian:
            flags += "r"
            kazakh_rate = counts.get(key, 0) / kazakh_total
            if russian_counts[key] / russian_total > 2 * kazakh_rate:
                flags += "R"
            # Russian has it, but rarely next to a common Kazakh word ("аска": асқа, a cartoon name in
            # Russian subtitles): the app fixes it at once and takes it back if Russian follows.
            if best != key and key not in local_russian \
                    and russian_counts[key] / russian_total < 0.02 * total / kazakh_total:
                flags += "k"
        # Short and nearly always in capitals: an abbreviation ("ӘКК", "АҚШ"), which the app fixes
        # only when typed in capitals ("акк" in a chat is an account).
        if len(key) <= 5 and sum(capitals[f] for f in forms) >= 0.85 * total:
            flags += "a"
        if best in chat_set:
            flags += "c"
        # Rare words too: a word seen a few times and always with a capital is a name or a place
        # ("Әбдешев", "Ұзынағашта"), which a Russian phrase keeps in Russian spelling.
        if best not in chat_set and sum(capitalized[f] for f in forms) >= 0.85 * total:
            flags += "n"
            names += 1
        flagged += bool(flags) and best != key
        encoded = "|".join(f"{'=' if form == key else form}:{count}" for form, count in ranked)
        lines.append((key.encode(), f"{key}\t{encoded}\t{flags}\n"))
    lines.sort()
    with open(out + "dictionary.tsv", "w", encoding="utf-8") as file:
        file.writelines(line for _, line in lines)
    print(f"dictionary: {len(lines)} spellings, {names} names, {flagged} corrected only inside Kazakh phrases, "
          f"{len(spoken)} spoken forms")

    # context.tsv: which neighbour makes a less common form win
    ambiguous = {key for key, forms in groups.items()
                 if len(forms) > 1 and sorted(forms.values())[-2] >= max(10, 0.02 * max(forms.values()))}
    left = collections.defaultdict(collections.Counter)
    right = collections.defaultdict(collections.Counter)
    with open(args.sentences, encoding="utf-8", errors="replace") as sentences:
        for line in sentences:
            tokens = [normalize(t) for t in TOKEN.findall(line.split("\t", 1)[-1])]
            for first, second in zip(tokens, tokens[1:]):
                if not (WORD.match(first) and WORD.match(second)):
                    continue
                if plain(second) in ambiguous:
                    left[(first, plain(second))][second] += 1
                if plain(first) in ambiguous:
                    right[(plain(first), second)][first] += 1
    rules = {}
    for (side, table) in (("L", left), ("R", right)):
        for (a, b), forms in table.items():
            total = sum(forms.values())
            form, count = forms.most_common(1)[0]
            key = b if side == "L" else a
            if total >= 5 and count >= 0.6 * total and form != best_form.get(key):
                rules[(side, a, b)] = form
    for phrase in phrases:
        for first, second in zip(phrase, phrase[1:]):
            rules[("L", first, plain(second))] = second
            rules[("R", plain(first), second)] = first
    with open(out + "context.tsv", "w", encoding="utf-8") as file:
        for (side, a, b), form in sorted(rules.items()):
            file.write(f"{side}\t{a}\t{b}\t{form}\n")
    print(f"context: {len(rules)} rules from {len(ambiguous)} ambiguous spellings")

    # pairs.tsv: hyphenated pairs that are written that way most of the time, and joins
    separate = collections.Counter()
    with open(args.sentences, encoding="utf-8", errors="replace") as sentences:
        wanted = {pair for pair, count in hyphenated.items() if count >= 5}
        for line in sentences:
            tokens = [normalize(t) for t in re.findall(r"[^\s.,!?;:()«»\"“”]+", line.split("\t", 1)[-1])]
            for pair in zip(tokens, tokens[1:]):
                if pair in wanted:
                    separate[pair] += 1
    suffixes = {"да", "де", "та", "те", "ға", "ге", "қа", "ке", "ны", "ні", "ды", "ді", "ты", "ті", "ның", "нің",
                "дың", "дің", "тың", "тің", "ша", "ше", "лар", "лер", "дан", "ден", "тан", "тен", "нан", "нен",
                "ғы", "гі", "қы", "кі", "сы", "сі", "ы", "і", "на", "не", "ма", "ме", "ба", "бе", "па", "пе"}
    pairs = {}
    for (first, second), count in hyphenated.items():
        if (count >= 5 and count >= 2 * separate[(first, second)] and second not in suffixes
                and counts[first] >= 20 and counts[second] >= 20):
            pairs[(first, second)] = f"{first}-{second}"
    if args.joins:
        with open(args.joins, encoding="utf-8") as lines:
            for line in lines:
                line = line.split("#", 1)[0].strip()
                if "\t" in line:
                    apart, joined = line.split("\t")
                    first, second = apart.split()
                    pairs[(first, second)] = joined
    # Families: "бір-біріне", "бір-бірімен", "бір-бірін"... -> any "бір" + "бір…" takes a hyphen.
    families = collections.Counter()
    for (first, second) in pairs:
        if "-" in pairs[(first, second)] and len(second) >= 4:
            families[(plain(first), plain(second)[:4])] += 1
    with open(out + "pairs.tsv", "w", encoding="utf-8") as file:
        for (first, second), joined in sorted(pairs.items()):
            file.write(f"{plain(first)}\t{plain(second)}\t{joined}\n")
        for (first, prefix), variants in sorted(families.items()):
            if variants >= 3:
                file.write(f"{first}\t{prefix}*\t-\n")
    print(f"pairs: {len(pairs)}")

    # endings.tsv: endings of frequent words, to guess words the corpus lacks
    endings = collections.defaultdict(collections.Counter)
    for key, forms in groups.items():
        form = best_form[key]
        if sum(forms.values()) < 6 or len(key) < 4:
            continue
        for length in range(1, min(7, len(key) - 1)):
            endings[(harmony(form[:-length]), key[-length:])][form[-length:]] += 1
    with open(out + "endings.tsv", "w", encoding="utf-8") as file:
        kept = 0
        for (vowels, ending), forms in sorted(endings.items()):
            total = sum(forms.values())
            if total < 20:
                continue
            ranked = forms.most_common(3)
            # н/ң differ by person (his/your): judge confidence without that difference
            merged = collections.Counter()
            for form, count in forms.items():
                merged[form.replace("ң", "н")] += count
            if merged.most_common(1)[0][1] < 0.9 * total:
                continue
            kept += 1
            encoded = "|".join(f"{form}:{count}" for form, count in ranked)
            file.write(f"{vowels or '-'}\t{ending}\t{encoded}\n")
    print(f"endings: {kept}")

    # kk.dic / kk.aff for the macOS spelling checker
    spelling = sorted({word for word, count in counts.items() if count >= args.min_count and word not in informal}
                      | {word.capitalize() for word, count in capitalized.items() if count >= 10})
    with open(out + "kk.dic", "w", encoding="utf-8") as file:
        file.write(f"{len(spelling)}\n")
        file.writelines(word + "\n" for word in spelling)
    with open(out + "kk.aff", "w", encoding="utf-8") as file:
        file.write("SET UTF-8\nTRY аеыіоұүөәиқғңһнтлрскдмбжзшпугйхвфцчщэюяёъь\nWORDCHARS -\n")
    print(f"spelling: {len(spelling)} words")


if __name__ == "__main__":
    main()
