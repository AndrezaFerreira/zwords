#!/usr/bin/env python3
"""Builds the compact, sharded dictionary used by the "Ouvir" (listen) page.

Input : data/word_lookup_index.json, data/04_cards_irregular_verbs.json, the
        decks, plus two open sources downloaded by this script:
        - FreeDict English-Portuguese (GPL-2.0+): short translations
        - FrequencyWords pt_br_50k (MIT): used to put the most common
          translations first
Output: data/listen/<shard>.json  ->  { key: [displayWord, [[pos, definition_pt, deck, sense_id], ...],
                                              [[translation, pos], ...]  (most used first)] }
        data/listen/forms.json    ->  { irregular_form: base_form }
        data/listen/phrasal.json  ->  { first_word: [[display, pattern, senses], ...] }
          pattern items: "word" | "a/b" (alternatives) | "~" (object slot) | "@" (possessive) | "#" (reflexive)

Shards are keyed by the first two letters so the phone only downloads the
few small files it actually needs (cached offline by the service worker).
"""
import json
import math
import os
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
OUT = os.path.join(DATA, "listen")


def shard_of(key: str) -> str:
    letters = re.sub(r"[^a-z]", "", key)[:2]
    return letters if len(letters) == 2 else (letters + "_")[:2] if letters else "__"


SLOTS = {"something", "somebody", "someone", "sth", "sb", "somewhere", "doing", "do"}
POSSESSIVE = {"your", "one's", "someone's", "somebody's", "his/her"}
REFLEXIVE = {"yourself", "oneself", "myself", "himself", "herself", "themselves"}
PHRASE_POS = {"phrasal verb", "verb", "verb phrase", "idiom"}


def phrase_pattern(text: str):
    """Turns "put up with something" into ["put", "up", "with", "~"]; None if too irregular."""
    text = text.strip().lower().replace("’", "'")
    if not text or any(ch in text for ch in ",()0123456789.!?$£;:\"") or " etc" in text:
        return None
    tokens = text.split()
    if len(tokens) < 2 or len(tokens) > 6:
        return None
    pattern = []
    for token in tokens:
        if token in POSSESSIVE:
            pattern.append("@")
        elif token in REFLEXIVE:
            pattern.append("#")
        elif all(part in SLOTS for part in token.split("/")):
            pattern.append("~")
        elif re.fullmatch(r"[a-z'\-]+(/[a-z'\-]+)*", token):
            pattern.append(token)
        else:
            return None
    if pattern[0] in ("~", "@", "#") or all(p in ("~", "@", "#") for p in pattern[1:]):
        return None
    while pattern and pattern[-1] in ("~", "@", "#"):
        pattern.pop()           # trailing objects are optional for matching
    return pattern if len(pattern) >= 2 else None


# Very common phrasal verbs that the ZWords decks do not have yet. They get no
# dictionary definition; the page shows their contextual translation instead.
SUPPLEMENT = [
    "put up with", "run out of", "come up with", "get along with", "catch up with", "keep up with",
    "look down on", "look up to", "cut down on", "get away with", "go along with", "come down with",
    "get on with", "get out of", "get back to", "look forward to", "make up for", "run into",
    "end up", "find out", "figure out", "hang out", "hang on", "show up", "show off", "work out",
    "check out", "check in", "sort out", "come across", "come back", "come over", "go on", "go out",
    "go back", "go over", "go through", "grow up", "wake up", "set up", "take off", "take over",
    "take up", "turn on", "turn off", "turn up", "turn down", "fill in", "fill out", "log in", "log out",
    "sign up", "give back", "hold on", "calm down", "slow down", "cheer up", "chill out", "freak out",
    "mess up", "screw up", "drop out", "drop off", "break up", "make up", "point out", "carry on",
    "carry out", "deal with", "count on", "rely on", "depend on", "care about", "think about", "talk about",
]


def build_phrasal() -> dict:
    groups: dict[str, dict] = {}
    sources = [("05_cards_phrasal_verbs.json", None), ("03_cards_phrases.json", PHRASE_POS)]
    for filename, allowed_pos in sources:
        with open(os.path.join(DATA, filename), encoding="utf-8") as f:
            cards = json.load(f)
        deck = "phrasal_verbs" if filename.startswith("05") else "phrases"
        for card in cards:
            if allowed_pos is not None and (card.get("part_of_speech") or "") not in allowed_pos:
                continue
            display = (card.get("word") or "").strip()
            pattern = phrase_pattern(display)
            definition = (card.get("definition_pt") or "").strip()
            if not pattern or not definition:
                continue
            key = " ".join(pattern)
            group = groups.setdefault(key, {"display": display, "pattern": pattern, "senses": [], "seen": set()})
            if definition in group["seen"]:
                continue
            group["seen"].add(definition)
            group["senses"].append([card.get("part_of_speech") or "", definition, deck, card.get("sense_id") or ""])

    for phrase in SUPPLEMENT:
        pattern = phrase.split()
        groups.setdefault(" ".join(pattern), {"display": phrase, "pattern": pattern, "senses": [], "seen": set()})

    index: dict[str, list] = {}
    for group in groups.values():
        for first in group["pattern"][0].split("/"):
            index.setdefault(first, []).append([group["display"], group["pattern"], group["senses"]])
    return index


FREEDICT_URL = "https://raw.githubusercontent.com/freedict/fd-dictionaries/master/eng-por/eng-por.tei"
FREQ_URL = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/pt_br/pt_br_50k.txt"
CACHE = os.path.join(ROOT, "tools", ".cache")
FREEDICT_POS = {"s": "noun", "n": "noun", "v": "verb", "vt": "verb", "vi": "verb", "adj": "adjective",
                "a": "adjective", "adv": "adverb", "prep": "preposition", "conj": "conjunction",
                "pron": "pronoun", "interj": "interjection", "art": "article", "num": "numeral"}
PT_FUNCTION = {"de", "a", "o", "as", "os", "do", "da", "dos", "das", "com", "se", "em", "para", "um", "uma",
               "no", "na", "por", "ao", "à", "e", "ou", "que", "algo", "alguém"}
PARTICLES = {"up", "down", "out", "off", "in", "on", "back", "away", "over", "around", "round", "about",
             "through", "along", "together", "apart", "aside", "forward", "across", "by", "for", "with",
             "into", "onto", "after", "at", "to", "from", "of", "upon", "behind", "ahead"}


def download(url: str, name: str) -> str:
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        with urllib.request.urlopen(url, timeout=120) as response, open(path, "wb") as out:
            out.write(response.read())
    return path


def load_frequency() -> dict:
    ranks = {}
    with open(download(FREQ_URL, "pt_br_50k.txt"), encoding="utf-8") as f:
        for rank, line in enumerate(f, 1):
            word = line.split(" ")[0].strip().lower()
            if word and word not in ranks:
                ranks[word] = rank
    return ranks


def translation_score(text: str, ranks: dict) -> float:
    words = [w for w in re.split(r"[\s\-]+", text.lower()) if w]
    content = [w for w in words if w not in PT_FUNCTION] or words
    rarest = max(ranks.get(w, 80000) for w in content)
    return math.log(rarest) + 1.5 * (len(content) - 1)


def load_freedict(ranks: dict) -> dict:
    """{ key: (orth, [[translation, pos], ...]) } with the most used translations first."""
    ns = {"tei": "http://www.tei-c.org/ns/1.0"}
    root = ET.parse(download(FREEDICT_URL, "eng-por.tei")).getroot()
    out: dict[str, tuple] = {}
    for entry in root.iter("{http://www.tei-c.org/ns/1.0}entry"):
        orth = entry.find("tei:form/tei:orth", ns)
        if orth is None or not (orth.text or "").strip():
            continue
        word = orth.text.strip()
        pos = ""
        items = []
        for child in entry:
            tag = child.tag.split("}")[1]
            if tag == "gramGrp":
                code = (child.findtext("tei:pos", default="", namespaces=ns) or "").strip().lower()
                pos = FREEDICT_POS.get(code, "")
            elif tag == "sense":
                for quote in child.iter("{http://www.tei-c.org/ns/1.0}quote"):
                    text = (quote.text or "").strip()
                    if text:
                        items.append((text, pos))
        key = word.lower()
        previous = out.get(key, (word, []))[1]
        seen = {t for t, _ in previous}
        merged = previous + [[t, p] for t, p in items if t not in seen and not seen.add(t)]
        out[key] = (word, merged)
    for key, (word, items) in out.items():
        order = {t: i for i, (t, _) in enumerate(items)}
        items.sort(key=lambda item: (translation_score(item[0], ranks), order[item[0]]))
    return out


def main() -> None:
    with open(os.path.join(DATA, "word_lookup_index.json"), encoding="utf-8") as f:
        index = json.load(f)

    shards: dict[str, dict] = {}
    for key, entry in index.items():
        senses = []
        for s in entry.get("senses", []):
            definition = (s.get("definition_pt") or "").strip()
            if not definition:
                continue
            senses.append([s.get("part_of_speech") or "", definition, s.get("deck") or "", s.get("sense_id") or ""])
        if not senses:
            continue
        k = key.lower()
        shards.setdefault(shard_of(k), {})[k] = [entry.get("word") or key, senses, []]

    ranks = load_frequency()
    freedict = load_freedict(ranks)
    for key, (word, items) in freedict.items():
        if not items:
            continue
        shard = shards.setdefault(shard_of(key), {})
        if key in shard:
            shard[key][2] = items
        else:
            shard[key] = [word, [], items]

    forms = {}
    with open(os.path.join(DATA, "04_cards_irregular_verbs.json"), encoding="utf-8") as f:
        for card in json.load(f):
            base = (card.get("base_form") or card.get("word") or "").lower()
            for field in ("past_simple", "past_participle"):
                for form in card.get(field) or []:
                    form = form.lower().strip()
                    if form and form != base and form not in forms:
                        forms[form] = base

    os.makedirs(OUT, exist_ok=True)
    for old in os.listdir(OUT):
        os.remove(os.path.join(OUT, old))
    total = 0
    for name, content in shards.items():
        path = os.path.join(OUT, f"{name}.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(content, f, ensure_ascii=False, separators=(",", ":"))
        total += os.path.getsize(path)
    with open(os.path.join(OUT, "forms.json"), "w", encoding="utf-8") as f:
        json.dump(forms, f, ensure_ascii=False, separators=(",", ":"))
    phrasal = build_phrasal()
    # FreeDict's own multi-word verbs ("look for") become recognizable expressions too.
    known = {" ".join(item[1]) for group in phrasal.values() for item in group}
    for key, (word, items) in freedict.items():
        parts = key.split()
        if 2 <= len(parts) <= 4 and items and all(p in PARTICLES for p in parts[1:]) \
                and re.fullmatch(r"[a-z]+", parts[0]) and key not in known:
            phrasal.setdefault(parts[0], []).append([word, parts, []])
    with open(os.path.join(OUT, "phrasal.json"), "w", encoding="utf-8") as f:
        json.dump(phrasal, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{sum(len(v) for v in phrasal.values())} phrasal patterns, "
          f"{os.path.getsize(os.path.join(OUT, 'phrasal.json'))/1e6:.2f} MB", file=sys.stderr)
    print(f"{len(shards)} shards, {total/1e6:.1f} MB, {len(forms)} irregular forms", file=sys.stderr)


if __name__ == "__main__":
    main()
