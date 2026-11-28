#!/usr/bin/env python3
"""Builds the compact, sharded dictionary used by the "Ouvir" (listen) page.

Input : data/word_lookup_index.json, data/04_cards_irregular_verbs.json
Output: data/listen/<shard>.json  ->  { key: [displayWord, [[pos, definition_pt, deck, sense_id], ...]] }
        data/listen/forms.json    ->  { irregular_form: base_form }
        data/listen/phrasal.json  ->  { first_word: [[display, pattern, senses], ...] }
          pattern items: "word" | "a/b" (alternatives) | "~" (object slot) | "@" (possessive) | "#" (reflexive)

Shards are keyed by the first two letters so the phone only downloads the
few small files it actually needs (cached offline by the service worker).
"""
import json
import os
import re
import sys

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
        shards.setdefault(shard_of(k), {})[k] = [entry.get("word") or key, senses]

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
    with open(os.path.join(OUT, "phrasal.json"), "w", encoding="utf-8") as f:
        json.dump(phrasal, f, ensure_ascii=False, separators=(",", ":"))
    print(f"{sum(len(v) for v in phrasal.values())} phrasal patterns, "
          f"{os.path.getsize(os.path.join(OUT, 'phrasal.json'))/1e6:.2f} MB", file=sys.stderr)
    print(f"{len(shards)} shards, {total/1e6:.1f} MB, {len(forms)} irregular forms", file=sys.stderr)


if __name__ == "__main__":
    main()
