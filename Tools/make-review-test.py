#!/usr/bin/env python3
"""A test set from real informal text: KazSAnDRA reviews written with Kazakh letters, as
"typed with plain Russian letters <TAB> as written" lines, for Tools/ReviewTest.

usage: make-review-test.py KAZSANDRA_DIR OUT.tsv 05_pc_test.csv 3000
Use the test split: the dictionary builder reads the train and valid splits.
"""
import csv, random, re, sys
data, out, split = sys.argv[1], sys.argv[2], sys.argv[3]
KZ = set("әіңғқөүұһӘІҢҒҚӨҮҰҺ")
P = str.maketrans({"ә": "а", "і": "и", "ң": "н", "ғ": "г", "қ": "к", "ө": "о", "ү": "у", "ұ": "у", "һ": "х",
                   "Ә": "А", "І": "И", "Ң": "Н", "Ғ": "Г", "Қ": "К", "Ө": "О", "Ү": "У", "Ұ": "У", "Һ": "Х"})
WORD = re.compile(r"[А-Яа-яЁёӘәІіҢңҒғҚқӨөҮүҰұҺһ]+")
rows = []
with open(f"{data}/{split}", encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        text = " ".join(r["text"].split())
        words = WORD.findall(text)
        if not 3 <= len(words) <= 40 or re.search(r"[A-Za-z]", text): continue
        kz = sum(any(c in KZ for c in w) for w in words)
        if kz < max(1, len(words) // 4): continue          # clearly written with Kazakh letters
        if re.search(r"(.)\1\1", text): continue            # "ммммм", keyboard mashing
        rows.append(text)
random.seed(7)
random.shuffle(rows)
with open(out, "w", encoding="utf-8") as f:
    for text in rows[:int(sys.argv[4])]:
        f.write(text.translate(P) + "\t" + text + "\n")
print(len(rows), "usable reviews; wrote", min(len(rows), int(sys.argv[4])))
