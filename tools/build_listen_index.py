#!/usr/bin/env python3
"""Builds the compact, sharded dictionary used by the "Ouvir" (listen) page.

Input : data/word_lookup_index.json, data/04_cards_irregular_verbs.json
Output: data/listen/<shard>.json  ->  { key: [displayWord, [[pos, definition_pt, deck, sense_id], ...]] }
        data/listen/forms.json    ->  { irregular_form: base_form }

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
    print(f"{len(shards)} shards, {total/1e6:.1f} MB, {len(forms)} irregular forms", file=sys.stderr)


if __name__ == "__main__":
    main()
