// ============================================================
// ZWORDS OUVIR -- live English captions from the microphone,
// one-tap vocabulary with real context, pt-BR translation.
//
// Plain script, no build step (same as the rest of ZWords).
//   * Speech:     Web Speech API (Safari on iPhone, Chrome on Android)
//   * Translation: Chrome's on-device Translator when available,
//                 otherwise free public endpoints (no key, no cost)
//   * Meaning:    ZWords' own Portuguese dictionary (data/listen/*),
//                 matched against the sentence translation to pick the
//                 sense that fits the context
//   * Storage:    IndexedDB on the device (no account, no server)
// ============================================================

(() => {

    "use strict";

    const $ = id => document.getElementById(id);

    const els = {
        app: $("listenApp"),
        captions: $("captions"),
        lines: $("lines"),
        empty: $("emptyState"),
        mic: $("micButton"),
        micLabel: $("micLabel"),
        notice: $("notice"),
        jumpLive: $("jumpLive"),
        libraryCount: $("libraryCount"),
        library: $("library"),
        librarySearch: $("librarySearch"),
        wordList: $("wordList"),
        libraryEmpty: $("libraryEmpty"),
        detail: $("detail"),
        detailBody: $("detailBody"),
        review: $("review"),
        reviewBody: $("reviewBody"),
        reviewTitle: $("reviewTitle")
    };


    // ============================================================
    // TEXT HELPERS
    // ============================================================

    const WORD_RE = /\p{L}+(?:['’\-]\p{L}+)*/u;

    function escapeHtml(value) {
        return String(value ?? "")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;");
    }

    function normalizeWord(word) {
        return word.replace(/[’‘]/g, "'").toLowerCase();
    }

    function fold(text) {
        return String(text || "")
            .normalize("NFD")
            .replace(/[̀-ͯ]/g, "")
            .toLowerCase();
    }

    function foldedWords(text, minLength = 3) {
        return fold(text).split(/[^a-z0-9]+/).filter(w => w.length >= minLength);
    }

    const PT_STOPWORDS = new Set((
        "que uma uns umas dos das nos nas para com por pelo pela mais como seu sua seus suas ele ela eles elas "
        + "nao sim algo alguem alguma algum coisa coisas geralmente especialmente outro outra muito pouco ser "
        + "esta este isso isto aquele aquela onde quando quem qual voce eles tem ter foi sao era sobre entre "
        + "ate sem mas pois tambem ainda forma modo pessoa pessoas usado usada fazer feito"
    ).split(" "));

    function contentWords(text) {
        return foldedWords(text, 3).filter(w => !PT_STOPWORDS.has(w));
    }

    const PT_SUFFIXES = /(ando|endo|indo|ados|adas|idos|idas|ado|ada|ido|ida|ava|ia|ou|ei|ar|er|ir|os|as|es|o|a|e|s)$/;

    /** Rough Portuguese stem so "achar" matches "acho", "casas" matches "casa". */
    function stem(word) {
        if (word.length < 4) return word;
        const cut = word.replace(PT_SUFFIXES, "");
        return cut.length >= 3 ? cut : word;
    }

    /** Splits recognized text into sentences without losing any word. */
    function splitSentences(text) {
        const out = [];
        let start = 0;
        for (let i = 0; i < text.length; i++) {
            const ch = text[i];
            if ((ch === "." || ch === "!" || ch === "?") && text[i + 1] === " " && /[A-Z"“]/.test(text[i + 2] || "")) {
                out.push(text.slice(start, i + 1).trim());
                start = i + 2;
            }
        }
        const rest = text.slice(start).trim();
        if (rest) out.push(rest);
        return out.filter(Boolean);
    }

    const BREAK_BEFORE = new Set(["and", "but", "so", "because", "then", "or", "when", "while", "which", "if", "until", "although"]);

    /**
     * Breaks a long run-on transcript (Safari often returns whole paragraphs
     * without punctuation) into subtitle-sized pieces, at natural joints.
     */
    // Never cut right after these ("…about it I | figure…") nor right before a
    // particle ("dug | around"): both pieces would lose their meaning.
    const NO_BREAK_AFTER = new Set(("i you we they he she it the a an to of my your his her our their its this that "
        + "these those can could will would should must may might don't didn't doesn't can't won't wouldn't "
        + "i'm you're we're they're he's she's it's i've i'd i'll is are was were be been not very really just "
        + "kind sort about with for at in on from by into like").split(" "));
    const NO_BREAK_BEFORE = new Set("up down out off around away back over about along in on at to of with for".split(" "));
    const bare = word => word.toLowerCase().replace(/[^a-z']/g, "");

    function isJoint(words, j) {
        return BREAK_BEFORE.has(bare(words[j])) || /[,;:.!?]["”')]?$/.test(words[j - 1]);
    }

    function canBreak(words, j) {
        return !NO_BREAK_AFTER.has(bare(words[j - 1])) && !NO_BREAK_BEFORE.has(bare(words[j]));
    }

    function chunkSentence(text) {
        const words = text.split(/\s+/).filter(Boolean);
        if (words.length <= 24) return [text];
        const out = [];
        let start = 0;
        while (words.length - start > 24) {
            let cut = -1;
            for (let j = start + 20; j >= start + 10 && cut < 0; j--) if (isJoint(words, j) && canBreak(words, j)) cut = j;
            for (let j = start + 20; j >= start + 10 && cut < 0; j--) if (canBreak(words, j)) cut = j;
            if (cut < 0) cut = start + 20;
            out.push(words.slice(start, cut).join(" "));
            start = cut;
        }
        out.push(words.slice(start).join(" "));
        return out;
    }

    /** The subtitle-sized piece of `sentence` that holds word number `index`. */
    function focusSentence(sentence, index) {
        const pieces = chunkSentence(sentence);
        if (pieces.length === 1) return { sentence, index };
        let offset = 0;
        for (const piece of pieces) {
            const count = piece.split(/\s+/).filter(Boolean).length;
            if (index < offset + count) return { sentence: piece, index: index - offset };
            offset += count;
        }
        return { sentence, index };
    }

    /** Whitespace chunks; `w` is the tappable word inside the chunk. */
    function tokenize(text) {
        return text.split(/\s+/).filter(Boolean).map(chunk => {
            const match = chunk.match(WORD_RE);
            return { t: chunk, w: match ? normalizeWord(match[0]) : null };
        });
    }

    function highlightForm(sentence, form) {
        const safe = escapeHtml(sentence);
        const pattern = form
            .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
            .replace(/'/g, "['’]");
        try {
            return safe.replace(new RegExp(`(^|[^\\p{L}])(${pattern})(?![\\p{L}])`, "iu"), "$1<mark>$2</mark>");
        } catch (error) {
            return safe;
        }
    }

    function sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    async function fetchWithTimeout(url, ms = 7000) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), ms);
        try {
            return await fetch(url, { signal: controller.signal });
        } finally {
            clearTimeout(timer);
        }
    }


    // ============================================================
    // STORAGE (IndexedDB, falls back to memory)
    // ============================================================

    const Store = (() => {
        const DB_NAME = "zwords_listen_db";
        const STORE = "vocab";
        let dbPromise = null;
        const memory = new Map();

        function open() {
            if (dbPromise) return dbPromise;
            dbPromise = new Promise(resolve => {
                try {
                    const request = indexedDB.open(DB_NAME, 1);
                    request.onupgradeneeded = () => {
                        request.result.createObjectStore(STORE, { keyPath: "key" });
                    };
                    request.onsuccess = () => resolve(request.result);
                    request.onerror = () => resolve(null);
                } catch (error) {
                    resolve(null);
                }
            });
            return dbPromise;
        }

        async function run(mode, fn) {
            const db = await open();
            if (!db) return fn(null);
            return new Promise((resolve, reject) => {
                const tx = db.transaction(STORE, mode);
                const result = fn(tx.objectStore(STORE));
                tx.oncomplete = () => resolve(result && "result" in result ? result.result : undefined);
                tx.onerror = () => reject(tx.error);
            });
        }

        return {
            all: () => run("readonly", s => s ? s.getAll() : { result: [...memory.values()] }).then(r => r || []),
            get: key => run("readonly", s => s ? s.get(key) : { result: memory.get(key) }),
            put: record => run("readwrite", s => s ? s.put(record) : memory.set(record.key, record)),
            del: key => run("readwrite", s => s ? s.delete(key) : memory.delete(key))
        };
    })();


    // ============================================================
    // DICTIONARY (ZWords pt-BR senses, sharded by 2 letters)
    // ============================================================

    const Dict = (() => {
        const shards = new Map();
        let formsPromise = null;

        function shardName(key) {
            const letters = key.replace(/[^a-z]/g, "").slice(0, 2);
            if (letters.length === 2) return letters;
            if (letters.length === 1) return letters + "_";
            return "__";
        }

        function loadJson(url) {
            return fetchWithTimeout(url, 10000)
                .then(r => (r.ok ? r.json() : {}))
                .catch(() => null);
        }

        function shard(key) {
            const name = shardName(key);
            if (!shards.has(name)) {
                const promise = loadJson(`data/listen/${name}.json`).then(data => {
                    if (data === null) shards.delete(name);   // offline: retry later
                    return data || {};
                });
                shards.set(name, promise);
            }
            return shards.get(name);
        }

        function forms() {
            if (!formsPromise) {
                formsPromise = loadJson("data/listen/forms.json").then(data => {
                    if (data === null) formsPromise = null;
                    return data || {};
                });
            }
            return formsPromise;
        }

        async function entry(key) {
            const data = await shard(key);
            return data[key] || null;
        }

        function candidates(w) {
            const list = [w];
            const add = c => { if (c && c.length > 1 && !list.includes(c)) list.push(c); };
            const doubled = s => (s.length > 2 && s[s.length - 1] === s[s.length - 2] ? s.slice(0, -1) : null);
            if (w.endsWith("'s")) add(w.slice(0, -2));
            if (w.endsWith("s'")) add(w.slice(0, -1));
            if (w.endsWith("ies")) add(w.slice(0, -3) + "y");
            if (w.endsWith("es")) add(w.slice(0, -2));
            if (w.endsWith("s") && !w.endsWith("ss")) add(w.slice(0, -1));
            if (w.endsWith("ied")) add(w.slice(0, -3) + "y");
            if (w.endsWith("ed")) {
                const base = w.slice(0, -2);
                add(base); add(base + "e"); add(doubled(base)); add(w.slice(0, -1));
            }
            if (w.endsWith("ing")) {
                const base = w.slice(0, -3);
                add(base); add(base + "e"); add(doubled(base));
                if (base.endsWith("y")) add(base.slice(0, -1) + "ie");
            }
            if (w.endsWith("ier")) add(w.slice(0, -3) + "y");
            if (w.endsWith("iest")) add(w.slice(0, -4) + "y");
            if (w.endsWith("er")) { add(w.slice(0, -2)); add(w.slice(0, -1)); add(doubled(w.slice(0, -2))); }
            if (w.endsWith("est")) { add(w.slice(0, -3)); add(w.slice(0, -2)); add(doubled(w.slice(0, -3))); }
            return list;
        }

        /** Dictionary form of a word ("ran" → "run", "studies" → "study"). */
        async function lemma(form) {
            const w = normalizeWord(form);
            if (w.includes("'") && !w.endsWith("'s")) {
                return { key: w, entry: await entry(w) };   // contractions stay as they are
            }
            const irregular = (await forms())[w];
            const list = candidates(w);
            if (irregular) list.splice(1, 0, irregular);
            // First choice: a form with ZWords senses (the real dictionary form);
            // translation-only entries like "thriving" must not split "thrive".
            let fallback = null;
            for (const candidate of list) {
                const found = await entry(candidate);
                if (!found || !(candidate === w || candidate === irregular || candidate.length >= 3)) continue;
                if (found[1].length) return { key: candidate, entry: found };
                fallback = fallback || { key: candidate, entry: found };
            }
            return fallback || { key: w, entry: null };
        }

        return { lemma, entry };
    })();


    // ============================================================
    // PHRASAL VERBS & EXPRESSIONS (ZWords decks, data/listen/phrasal.json)
    // ============================================================

    const Phrasal = (() => {
        let promise = null;
        const POSSESSIVES = new Set(["my", "your", "his", "her", "its", "our", "their", "one's"]);
        const REFLEXIVES = new Set(["myself", "yourself", "himself", "herself", "itself", "ourselves", "yourselves", "themselves", "oneself"]);
        // Only adverb particles let an object sit before them ("turn it off", "pick the kids up").
        const SEPARABLE = new Set(["up", "down", "out", "off", "in", "on", "back", "away", "over", "around", "round",
            "about", "through", "along", "together", "apart", "aside", "forward", "across", "by", "behind", "ahead"]);

        function load() {
            if (!promise) {
                promise = fetchWithTimeout("data/listen/phrasal.json", 15000)
                    .then(r => (r.ok ? r.json() : {}))
                    .catch(() => { promise = null; return {}; });
            }
            return promise;
        }

        const matches = (item, word) => item.split("/").includes(word);

        function breaksBefore(tokens, position) {
            return position > 0 && /[.,!?;:—]["”')]?$/.test(tokens[position - 1].t);
        }

        function matchAt(tokens, start, pattern) {
            const positions = [start];
            let from = start + 1;
            let gap = 0;
            let minGap = 0;
            for (let k = 1; k < pattern.length; k++) {
                const item = pattern[k];
                if (item === "~") {
                    gap = 4;
                    minGap = 1;
                    continue;
                }
                if (k === 1 && gap === 0 && SEPARABLE.has(item.split("/")[0])) gap = 2;
                let found = -1;
                for (let p = from; p < tokens.length && p <= from + gap; p++) {
                    if (breaksBefore(tokens, p) || !tokens[p].w) break;
                    const w = tokens[p].w;
                    const ok = item === "@" ? POSSESSIVES.has(w)
                        : item === "#" ? REFLEXIVES.has(w)
                        : matches(item, w);
                    if (ok && p - from >= minGap) {
                        found = p;
                        break;
                    }
                    // "dig around in…": a particle is not an object, so it cannot be skipped.
                    if (SEPARABLE.has(w)) break;
                }
                if (found < 0) return null;
                positions.push(found);
                from = found + 1;
                gap = 0;
                minGap = 0;
            }
            return positions;
        }

        // Particles that almost always make a phrasal verb right after a verb
        // ("dug around", "freaked out"). Prepositions like in/on/at/to are left
        // out on purpose: "sat on the chair" is not a phrasal verb.
        const LOOSE_PARTICLES = new Set(["up", "down", "out", "off", "around", "round", "about", "away",
            "back", "over", "along", "aside", "apart", "together", "forward", "ahead"]);

        const DETERMINERS = new Set(["the", "a", "an", "this", "that", "these", "those", "my", "your", "his",
            "her", "its", "our", "their", "some", "any", "every", "each", "no"]);

        /** Verb + particle not in the dictionary yet ("dig around"). */
        async function looseMatch(tokens, index) {
            const tapped = tokens[index].w;
            let verbAt = -1;
            if (LOOSE_PARTICLES.has(tapped) && index > 0 && !breaksBefore(tokens, index)) verbAt = index - 1;
            else if (tokens[index + 1]?.w && LOOSE_PARTICLES.has(tokens[index + 1].w) && !breaksBefore(tokens, index + 1)) verbAt = index;
            if (verbAt < 0 || !tokens[verbAt].w) return null;
            const word = tokens[verbAt].w;
            if (DETERMINERS.has(tokens[verbAt - 1]?.w)) return null;      // "the house around…" is a noun
            const { key: verb, entry } = await Dict.lemma(word);
            if (!entry) return null;
            const senses = entry[1].map(([pos]) => String(pos).toLowerCase());
            const inflected = verb !== word;                                  // "dug", "freaked", "walking"
            if (!(senses[0] === "verb" || (inflected && senses.includes("verb")))) return null;
            const particle = tokens[verbAt + 1].w;
            return { score: 0, display: `${verb} ${particle}`, pattern: [verb, particle], senses: [], positions: [verbAt, verbAt + 1] };
        }

        /** The longest known expression that includes the tapped word, or null. */
        async function find(tokens, index) {
            if (!tokens[index]?.w) return null;
            const table = await load();
            let best = null;
            for (let start = Math.max(0, index - 7); start <= index; start++) {
                const word = tokens[start].w;
                if (!word) continue;
                const { key: lemma } = await Dict.lemma(word);
                const firsts = new Set([word, lemma]);
                const candidates = [];
                firsts.forEach(first => (table[first] || []).forEach(c => candidates.push(c)));
                for (const [display, pattern, senses] of candidates) {
                    const positions = matchAt(tokens, start, pattern);
                    if (!positions || !positions.includes(index)) continue;
                    const literals = pattern.filter(item => !"~@#".includes(item)).length;
                    const score = literals * 10 - (positions[positions.length - 1] - positions[0]);
                    if (!best || score > best.score) best = { score, display, pattern, senses, positions };
                }
            }
            if (!best) best = await looseMatch(tokens, index);
            if (!best) return null;
            const first = best.positions[0];
            const last = best.positions[best.positions.length - 1];
            return {
                isPhrase: true,
                key: best.display.toLowerCase(),
                headword: best.display,
                form: tokens.slice(first, last + 1).map(t => t.w || t.t).join(" "),
                lookup: best.pattern.filter(item => !"~@#".includes(item)).map(item => item.split("/")[0]).join(" "),
                senses: best.senses,
                positions: best.positions
            };
        }

        return { find, load };
    })();


    // ============================================================
    // MORE SENSES (Wiktionary, free and open: CC BY-SA)
    // ============================================================

    const Wiki = (() => {
        const SKIP_LABEL = /\b(obsolete|archaic|dated|historical|nonstandard|rare|uncommon)\b/i;
        const FORM_OF = /^(plural of|(simple )?past (tense|participle) of|present participle of|third-person singular|alternative (form|spelling|letter-case form) of|obsolete (form|spelling) of|inflection of|comparative (form )?of|superlative (form )?of|misspelling of|eye dialect|abbreviation of|initialism of|clipping of)/i;
        const MAX_PER_POS = 6;
        const MAX_TOTAL = 14;

        function text(html) {
            const body = new DOMParser().parseFromString(String(html || ""), "text/html").body;
            return (body.textContent || "").replace(/\s+/g, " ").trim();
        }

        async function fetchEntry(title) {
            const url = "https://en.wiktionary.org/api/rest_v1/page/definition/" + encodeURIComponent(title.replace(/ /g, "_"));
            const response = await fetchWithTimeout(url, 10000);
            if (response.status === 404) return [];
            if (!response.ok) throw new Error("wiktionary " + response.status);
            const data = await response.json();
            return data.en || [];
        }

        /** English senses: [[pos, definition]], [] if none, null if offline. */
        async function senses(term) {
            const titles = [term];
            if (term === term.toLowerCase()) titles.push(term[0].toUpperCase() + term.slice(1));
            let groups = [];
            try {
                for (const title of titles) {
                    groups = await fetchEntry(title);
                    if (groups.length) break;
                }
            } catch (error) {
                return null;
            }
            const out = [];
            for (const group of groups) {
                const pos = String(group.partOfSpeech || "").toLowerCase();
                let count = 0;
                for (const item of group.definitions || []) {
                    const definition = text(item.definition);
                    const label = (definition.match(/^\(([^)]*)\)/) || [])[1] || "";
                    if (!definition || definition.length < 4 || SKIP_LABEL.test(label) || FORM_OF.test(definition)) continue;
                    out.push([pos, definition]);
                    if (++count >= MAX_PER_POS || out.length >= MAX_TOTAL) break;
                }
                if (out.length >= MAX_TOTAL) break;
            }
            return out;
        }

        return { senses };
    })();

    /** Extra senses that are not already said by ZWords' own dictionary. */
    function newSenses(base, extras) {
        const kept = [];
        const signature = definition => new Set(contentWords(definition).map(stem));
        const known = base.map(([, definition]) => signature(definition));
        for (const extra of extras) {
            const mine = signature(extra[1]);
            if (!mine.size) continue;
            const duplicate = known.some(other => {
                if (!other.size) return false;
                let shared = 0;
                mine.forEach(s => { if (other.has(s)) shared++; });
                return shared / Math.min(mine.size, other.size) >= 0.6;
            });
            if (!duplicate) {
                kept.push(extra);
                known.push(mine);
            }
        }
        return kept;
    }


    // ============================================================
    // TRANSLATION (free; on-device when the browser offers it)
    // ============================================================

    const Translate = (() => {
        const CACHE_KEY = "zwl_translation_cache_v2";
        const cache = new Map();
        let onDevice = null;
        let googleBlockedUntil = 0;
        let memoryBlockedUntil = Number(localStorage.getItem("zwl_mymemory_blocked") || 0);
        let active = 0;
        const waiting = [];

        try {
            const saved = JSON.parse(localStorage.getItem(CACHE_KEY) || "[]");
            saved.forEach(([k, v]) => cache.set(k, v));
        } catch (error) { /* ignore */ }

        let persistTimer = null;
        function persist() {
            clearTimeout(persistTimer);
            persistTimer = setTimeout(() => {
                try {
                    const entries = [...cache.entries()].slice(-1500);
                    localStorage.setItem(CACHE_KEY, JSON.stringify(entries));
                } catch (error) { /* quota: ignore */ }
            }, 1500);
        }

        const same = (a, b) => String(a || "").trim().toLowerCase().replace(/[.!?]+$/, "")
            === String(b || "").trim().toLowerCase().replace(/[.!?]+$/, "");

        function remember(key, value) {
            cache.delete(key);
            cache.set(key, value);
            persist();
        }

        async function limited(task) {
            if (active >= 2) await new Promise(resolve => waiting.push(resolve));
            active++;
            try {
                return await task();
            } finally {
                active--;
                const next = waiting.shift();
                if (next) next();
            }
        }

        /** Call during a user gesture (download may need one). */
        async function prepareOnDevice() {
            if (onDevice || !("Translator" in self)) return;
            try {
                const options = { sourceLanguage: "en", targetLanguage: "pt" };
                const availability = await self.Translator.availability(options);
                if (availability === "unavailable") return;
                onDevice = await self.Translator.create(options);
            } catch (error) {
                onDevice = null;
            }
        }

        async function google(text, withDictionary) {
            if (Date.now() < googleBlockedUntil) throw new Error("google paused");
            const url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=pt&dt=t"
                + (withDictionary ? "&dt=bd" : "")
                + "&q=" + encodeURIComponent(text);
            let response;
            try {
                response = await fetchWithTimeout(url);
            } catch (error) {
                googleBlockedUntil = Date.now() + 60 * 1000;        // no connection: pause a minute
                throw error;
            }
            if (!response.ok) {
                if (response.status === 429 || response.status >= 500) googleBlockedUntil = Date.now() + 5 * 60 * 1000;
                throw new Error(`google ${response.status}`);
            }
            const data = await response.json();
            const translation = (data[0] || []).map(part => part[0] || "").join("").trim();
            const dictionary = Array.isArray(data[1])
                ? data[1].map(group => ({ pos: group[0], terms: group[1] || [] }))
                : [];
            if (!translation) throw new Error("empty");
            return { translation, dictionary };
        }

        async function myMemory(text) {
            if (Date.now() < memoryBlockedUntil) throw new Error("mymemory paused");
            const url = "https://api.mymemory.translated.net/get?langpair=en|pt-BR&q=" + encodeURIComponent(text.slice(0, 480));
            const response = await fetchWithTimeout(url);
            const data = await response.json();
            const result = data?.responseData?.translatedText;
            if (data?.quotaFinished || /MYMEMORY WARNING|USED ALL AVAILABLE FREE/i.test(result || "") || data?.responseStatus === 429) {
                // Daily free quota used up: leave it alone for a few hours.
                memoryBlockedUntil = Date.now() + 6 * 60 * 60 * 1000;
                try { localStorage.setItem("zwl_mymemory_blocked", String(memoryBlockedUntil)); } catch (e) { /* ignore */ }
                throw new Error("mymemory quota");
            }
            if (data?.responseStatus !== 200 || !result) throw new Error("mymemory");
            return result.trim();
        }

        async function sentence(text) {
            const key = text.trim();
            if (!key) return null;
            if (cache.has("s:" + key)) return cache.get("s:" + key);
            return limited(async () => {
                if (cache.has("s:" + key)) return cache.get("s:" + key);
                let result = null;
                if (onDevice) {
                    try { result = await onDevice.translate(key); } catch (error) { result = null; }
                }
                if (!result) {
                    try { result = (await google(key, false)).translation; } catch (error) { result = null; }
                }
                if (!result) {
                    try { result = await myMemory(key); } catch (error) { result = null; }
                }
                if (result && same(result, key)) result = null;       // left in English: not a translation
                if (result) remember("s:" + key, result);
                return result;
            });
        }

        /** Translation of a single word plus its dictionary alternatives. */
        async function word(text) {
            const key = "w:" + text;
            if (cache.has(key)) return cache.get(key);
            return limited(async () => {
                let result = null;
                try {
                    result = await google(text, true);
                } catch (error) {
                    let translation = null;
                    if (onDevice) {
                        try { translation = await onDevice.translate(text); } catch (e) { translation = null; }
                    }
                    if (!translation) {
                        try { translation = await myMemory(text); } catch (e) { translation = null; }
                    }
                    if (translation && !same(translation, text)) result = { translation, dictionary: [] };
                }
                if (result && same(result.translation, text) && !result.dictionary.length) result = null;
                if (result) remember(key, result);
                return result;
            });
        }

        function cached(text) {
            return cache.get("s:" + text.trim()) || null;
        }

        /** Sentence translation keeping [markers] around the tapped expression. */
        async function marked(text) {
            const key = "m:" + text;
            if (cache.has(key)) return cache.get(key);
            return limited(async () => {
                let result = null;
                try {
                    result = (await google(text, false)).translation;
                } catch (error) {
                    try { result = await myMemory(text); } catch (e) { result = null; }
                }
                if (result) remember(key, result);
                return result;
            });
        }

        /** Translates several short texts with one request when possible. */
        async function lines(texts) {
            if (!texts.length) return [];
            const joined = texts.join("\n");
            const key = "l:" + joined;
            if (cache.has(key)) return cache.get(key);
            let result = null;
            try {
                const translated = await limited(() => google(joined, false));
                const parts = translated.translation.split("\n").map(part => part.trim());
                if (parts.length === texts.length) result = parts;
            } catch (error) {
                result = null;
            }
            if (!result) return null;                 // try again later, when Google answers
            remember(key, result);
            return result;
        }

        /** Background work only runs when Google answers; the backup is kept for taps. */
        const googleAvailable = () => Date.now() >= googleBlockedUntil;

        return { prepareOnDevice, sentence, word, cached, marked, lines, googleAvailable };
    })();


    // ============================================================
    // MEANING IN CONTEXT
    // ============================================================

    const POS_PT = {
        noun: "substantivo", verb: "verbo", adjective: "adjetivo", adverb: "advérbio",
        pronoun: "pronome", preposition: "preposição", conjunction: "conjunção",
        interjection: "interjeição", determiner: "determinante", article: "artigo",
        "phrasal verb": "phrasal verb", abbreviation: "abreviação", exclamation: "exclamação"
    };

    function posLabel(pos) {
        return POS_PT[String(pos || "").toLowerCase()] || pos || "";
    }

    const SUBJECTS = new Set(["i", "you", "we", "they", "he", "she", "it", "who", "people"]);
    const VERB_BEFORE = new Set(["to", "can", "could", "will", "would", "should", "must", "might", "may", "shall",
        "do", "does", "did", "don't", "doesn't", "didn't", "can't", "couldn't", "won't", "wouldn't", "shouldn't",
        "i'll", "you'll", "we'll", "they'll", "he'll", "she'll", "i'd", "you'd", "we'd", "they'd", "let's", "just", "never", "always"]);
    const NOUN_BEFORE = new Set(["the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her",
        "its", "our", "their", "some", "any", "every", "each", "no", "of"]);

    /** Context around the tapped word: likely part of speech and the subject before a verb. */
    function contextHint(tokens, index) {
        const previous = tokens[index - 1]?.w || "";
        if (SUBJECTS.has(previous)) return { pos: "verb", lead: tokens[index - 1].w };
        if (VERB_BEFORE.has(previous)) return { pos: "verb", lead: "" };
        if (NOUN_BEFORE.has(previous)) return { pos: "noun", lead: "" };
        return { pos: "", lead: "" };
    }

    function hintFields(tokens, index) {
        const hint = contextHint(tokens, index);
        return { posHint: hint.pos, lead: hint.lead };
    }

    /** "We sat on the [bank] of the river": brackets around the expression. */
    function markSentence(tokens, first, last) {
        return tokens.map((token, i) => {
            let text = token.t;
            if (i === first || i === last) {
                const match = text.match(WORD_RE);
                if (match) {
                    const before = text.slice(0, match.index);
                    const word = match[0];
                    const after = text.slice(match.index + word.length);
                    text = before + (i === first ? "[" : "") + word + (i === last ? "]" : "") + after;
                }
            }
            return text;
        }).join(" ");
    }

    /** What Google put inside the brackets: the expression's translation in this sentence. */
    function extractMarked(translation) {
        const found = String(translation || "").match(/\[([^\[\]]{1,80})\]/);
        if (!found) return "";
        const text = found[1].replace(/^[\s"“”'.,;:!?¿¡-]+|[\s"“”'.,;:!?¿¡-]+$/g, "");
        return text && text.split(/\s+/).length <= 8 ? text : "";
    }

    /** Rejects a "translation" that is just the English words left untouched. */
    function usefulMarked(text, englishTokens) {
        if (!text) return "";
        const english = new Set(englishTokens.map(t => t.w).filter(Boolean));
        const words = foldedWords(text, 1);
        return words.length && words.every(w => english.has(w)) ? "" : text;
    }

    /** What a tap means: a phrasal verb/expression around the word, or the word itself. */
    async function resolveTarget(tokens, index) {
        const phrase = await Phrasal.find(tokens, index).catch(() => null);
        if (phrase) {
            const own = await Dict.entry(phrase.key).catch(() => null);
            return { ...phrase, tokens, translations: own?.[2] || [] };
        }
        const form = tokens[index].w;
        const { key, entry } = await Dict.lemma(form);
        const hint = contextHint(tokens, index);
        // "thriving": its own translations ("próspero") first, then those of "thrive".
        const formEntry = form !== key ? await Dict.entry(form).catch(() => null) : null;
        const seen = new Set();
        const translations = [...(formEntry?.[2] || []), ...(entry?.[2] || [])]
            .filter(([text]) => !seen.has(text) && seen.add(text));
        return {
            isPhrase: false,
            posHint: hint.pos,
            lead: hint.lead,
            key,
            headword: entry ? entry[0] : key,
            form,
            lookup: key,
            senses: entry ? entry[1] : [],
            translations,
            positions: [index],
            tokens
        };
    }

    /**
     * The fixed dictionary's translations, most used first; the one that
     * appears in the sentence translation (if known) goes first, then those
     * of the likely part of speech.
     */
    function pickTranslations(target, sentenceTranslation) {
        const list = target.translations || [];
        const translated = fold(sentenceTranslation);
        const hinted = target.posHint || "";
        const fits = ([text]) => {
            const words = foldedWords(text, 3);
            return Boolean(translated) && words.length > 0 && words.every(w => translated.includes(stem(w)));
        };
        const contextual = list.find(fits) || null;
        const rest = list.filter(item => item !== contextual);
        const ordered = [
            ...(contextual ? [contextual] : []),
            ...(hinted ? rest.filter(([, pos]) => pos === hinted) : []),
            ...(hinted ? rest.filter(([, pos]) => pos !== hinted) : rest)
        ];
        return {
            contextual: contextual ? contextual[0] : "",
            top: ordered.slice(0, 3).map(([text]) => text),
            pos: contextual ? contextual[1] : hinted
        };
    }

    /**
     * Meaning of the tap in this sentence. The fixed dictionary always
     * answers (offline); with `network`, one extra request translates the
     * sentence with the expression in [brackets] for the exact contextual
     * word ("Ela [desistiu] de fumar").
     */
    async function explainTarget(target, sentenceTranslation, { network = true } = {}) {
        let contextual = "";
        if (network && target.tokens && target.positions?.length) {
            const first = target.positions[0];
            const last = target.positions[target.positions.length - 1];
            const markedTranslation = await Translate.marked(markSentence(target.tokens, first, last)).catch(() => null);
            contextual = usefulMarked(extractMarked(markedTranslation), target.tokens.slice(first, last + 1));
        }
        const english = new Set([
            ...String(target.form || "").split(" "), ...String(target.lookup || "").split(" "), target.key
        ].filter(Boolean).map(w => fold(w)));
        const untranslated = text => {
            const words = foldedWords(text, 1);
            return !words.length || words.every(w => english.has(w));
        };

        const pick = pickTranslations(target, sentenceTranslation);
        let gloss = contextual || pick.contextual || pick.top[0] || "";
        if (untranslated(gloss)) gloss = "";
        gloss = gloss.toLowerCase();

        const sense = chooseSense(target.senses || [], gloss, sentenceTranslation, pick.pos || target.posHint);
        return {
            gloss,
            pos: sense ? sense[0] : (pick.pos || target.posHint || ""),
            definition: sense ? sense[1] : "",
            senseId: sense ? sense[3] : "",
            viaNetwork: Boolean(contextual)
        };
    }

    /**
     * The sense whose definition shares words with the sentence translation
     * or the contextual gloss. Part of speech only breaks ties: it is never
     * enough on its own to show a definition.
     */
    function chooseSense(senses, gloss, sentenceTranslation, wantedPos) {
        if (!senses.length) return null;
        const translatedStems = new Set(contentWords(sentenceTranslation).map(stem));
        const glossStems = foldedWords(gloss, 3).map(stem);
        const wanted = String(wantedPos || "").toLowerCase();
        let sense = null;
        let best = -1;
        let bestEvidence = 0;
        senses.forEach(candidate => {
            const [pos, definition] = candidate;
            const defStems = contentWords(definition).map(stem);
            let evidence = 0;
            defStems.forEach(s => { if (translatedStems.has(s)) evidence += 1; });
            glossStems.forEach(s => { if (defStems.some(d => d.startsWith(s) || s.startsWith(d))) evidence += 3; });
            let score = evidence;
            if (wanted && pos && wanted === String(pos).toLowerCase()) score += 2;
            if (score > best) { best = score; bestEvidence = evidence; sense = candidate; }
        });
        if (bestEvidence <= 0 && senses.length > 1) return null;
        return sense;
    }

    /** Single-word meaning (used for retries of older entries). */
    async function explain(form, sentence, sentenceTranslation) {
        const { key, entry } = await Dict.lemma(form);
        const tokens = tokenize(sentence);
        const index = tokens.findIndex(t => t.w === normalizeWord(form));
        const hint = index >= 0 ? contextHint(tokens, index) : { pos: "", lead: "" };
        const meaning = await explainTarget({
            key, form: normalizeWord(form), lookup: key, senses: entry ? entry[1] : [],
            translations: entry?.[2] || [], posHint: hint.pos, lead: hint.lead
        }, sentenceTranslation, { network: false });
        return { key, headword: entry ? entry[0] : key, ...meaning };
    }


    // ============================================================
    // VOCABULARY
    // ============================================================

    const savedForms = new Set();
    let saveChain = Promise.resolve();

    async function loadSavedForms() {
        const all = await Store.all();
        savedForms.clear();
        all.forEach(record => {
            savedForms.add(record.key);
            record.contexts.forEach(c => savedForms.add(normalizeWord(c.form)));
        });
        updateLibraryBadge(all.length);
    }

    function updateLibraryBadge(count) {
        els.libraryCount.hidden = count === 0;
        els.libraryCount.textContent = count > 99 ? "99+" : String(count);
    }

    function markSaved(form) {
        savedForms.add(form);
        const selector = `.w[data-w="${CSS.escape(form)}"]`;
        els.lines.querySelectorAll(selector).forEach(el => el.classList.add("saved"));
    }

    function refreshOpenViews(key) {
        if (!els.detail.hidden && els.detail.dataset.key === key) openDetail(key);
        if (!els.library.hidden) renderLibrary();
    }

    // Bump whenever the way meanings/phrasal verbs are chosen improves: every
    // word already in the library is then re-checked automatically, so nobody
    // keeps studying a meaning the old logic got wrong.
    const MEANING_VERSION = 6;   // (unchanged: gloss-less contexts are retried anyway)

    function newRecord(target, now) {
        return {
            key: target.key,
            headword: target.headword,
            createdAt: now,
            updatedAt: now,
            box: 0,
            due: Date.now(),
            contexts: [],
            ...(target.isPhrase ? { phrase: true, lookup: target.lookup, senses: target.senses } : {})
        };
    }

    /** One tap: saves immediately (no confirmation), meaning arrives after. */
    function saveTarget(target, sentence, translationPromise, meaningPromise) {
        saveChain = saveChain.then(async () => {
            const now = new Date().toISOString();
            const record = (await Store.get(target.key)) || newRecord(target, now);
            record.updatedAt = now;
            if (!record.contexts.some(c => c.sentence === sentence)) {
                record.contexts.push({
                    form: target.form,
                    sentence,
                    translation: "",
                    gloss: "",
                    definition: "",
                    pos: "",
                    tap: target.tap,
                    ...(target.full ? { full: target.full, fullTap: target.fullTap } : {}),
                    at: now
                });
            }
            await Store.put(record);
            savedForms.add(target.key);
            updateLibraryBadge((await Store.all()).length);
        }).catch(error => console.error("save failed", error));

        Promise.all([translationPromise, meaningPromise.catch(() => null)])
            .then(([translation, meaning]) => {
                saveChain = saveChain.then(async () => {
                    const record = await Store.get(target.key);
                    const context = record?.contexts.find(c => c.sentence === sentence);
                    if (!context) return;
                    if (!context.translation && translation) context.translation = translation;
                    if (!context.gloss && !context.definition && meaning && (meaning.gloss || meaning.definition)) {
                        Object.assign(context, {
                            gloss: meaning.gloss,
                            definition: meaning.definition,
                            pos: meaning.pos,
                            senseId: meaning.senseId,
                            net: Boolean(meaning.viaNetwork),
                            mv: meaning.gloss ? MEANING_VERSION : 0
                        });
                    }
                    await Store.put(record);
                    refreshOpenViews(target.key);
                }).catch(error => console.error("save failed", error));
                return saveChain;
            })
            .finally(() => enrich(target.key).then(refreshOutdated));
    }

    const enriching = new Set();

    async function enrich(key) {
        if (enriching.has(key)) return;
        enriching.add(key);
        try {
            const record = await Store.get(key);
            if (!record) return;
            let changed = false;
            for (const context of record.contexts) {
                if (!context.translation) {
                    const translation = await Translate.sentence(context.sentence);
                    if (translation) { context.translation = translation; changed = true; }
                }
                // Meanings are (re)computed by refreshContext, which knows the
                // exact words around the tap (see refreshOutdated).
            }
            if (changed) {
                const latest = await Store.get(key);
                if (latest) {
                    // Keep contexts added meanwhile; overwrite only enriched fields.
                    latest.contexts = latest.contexts.map(c => record.contexts.find(r => r.sentence === c.sentence) || c);
                    latest.headword = record.headword;
                    await Store.put(latest);
                }
                refreshOpenViews(key);
            }
        } catch (error) {
            console.error("enrich failed", error);
        } finally {
            enriching.delete(key);
        }
    }

    const EXTRA_VERSION = 1;
    const extrasInFlight = new Set();

    /** Completes a saved word with every sense Wiktionary has (translated). */
    async function ensureExtras(key) {
        if (extrasInFlight.has(key)) return false;
        extrasInFlight.add(key);
        try {
            const record = await Store.get(key);
            if (!record || record.extra?.v === EXTRA_VERSION) return false;
            const term = record.phrase ? (record.lookup || record.key) : record.key;
            const english = await Wiki.senses(term);
            if (english === null) return false;                       // offline: later
            let extras = [];
            if (english.length) {
                const translated = await Translate.lines(english.map(([, definition]) => definition));
                if (!translated) return false;                         // offline: later
                const base = record.phrase ? (record.senses || []) : ((await Dict.entry(record.key))?.[1] || []);
                extras = newSenses(base, english.map(([pos], i) => [pos, translated[i], "wiktionary", ""]));
            }
            const latest = await Store.get(key);
            if (!latest) return false;
            latest.extra = { v: EXTRA_VERSION, senses: extras };
            // Contexts that had no definition may now find one that fits.
            if (extras.length) {
                const base = latest.phrase ? (latest.senses || []) : ((await Dict.entry(latest.key))?.[1] || []);
                latest.contexts.forEach(context => {
                    if (context.definition) return;
                    const sense = chooseSense([...base, ...extras], context.gloss, context.translation, context.pos);
                    if (sense) {
                        context.definition = sense[1];
                        context.pos = context.pos || sense[0];
                    }
                });
            }
            await Store.put(latest);
            refreshOpenViews(key);
            return true;
        } catch (error) {
            console.error("extra senses failed", error);
            return false;
        } finally {
            extrasInFlight.delete(key);
        }
    }

    async function ensureAllExtras() {
        if (!navigator.onLine) return;
        const all = await Store.all();
        for (const record of all) {
            if (record.extra?.v === EXTRA_VERSION) continue;
            if (!Translate.googleAvailable()) return;          // retried later (scheduleRetry)
            await ensureExtras(record.key);
            await sleep(1500);
        }
    }

    let refreshing = false;

    /** Re-checks words saved with an older meaning logic (see MEANING_VERSION). */
    async function refreshOutdated() {
        if (refreshing || !navigator.onLine) return;
        refreshing = true;
        let changed = false;
        try {
            const all = await Store.all();
            for (const record of all) {
                for (const context of record.contexts) {
                    const network = Translate.googleAvailable();
                    const outdated = (context.mv || 1) < MEANING_VERSION || !context.gloss;
                    const improvable = context.net === false && network && (context.tries || 0) < 2;
                    if (!outdated && !improvable) continue;
                    if (!network && context.gloss) continue;          // keep it; improve when Google answers
                    if (network) await sleep(700);
                    const done = saveChain.then(() => refreshContext(record.key, context.sentence, network));
                    saveChain = done.catch(() => {});
                    if (await done.catch(() => false)) changed = true;
                }
            }
        } finally {
            refreshing = false;
        }
        if (changed) {
            await loadSavedForms();
            if (!els.library.hidden) renderLibrary();
            if (!els.detail.hidden) openDetail(els.detail.dataset.key);
        }
        scheduleRetry();
    }

    let retryTimer = null;

    async function pendingCount() {
        const all = await Store.all();
        return all.reduce((sum, r) => sum + r.contexts.filter(c => !c.gloss).length, 0);
    }

    /** While anything is still waiting for a translation, try again every 3 minutes. */
    async function scheduleRetry() {
        clearTimeout(retryTimer);
        const pending = await pendingCount();
        updatePendingNote(pending);
        if (pending) retryTimer = setTimeout(() => refreshOutdated(), 3 * 60 * 1000);
    }

    function updatePendingNote(pending) {
        const note = document.getElementById("pendingNote");
        if (!note) return;
        note.hidden = !pending;
        note.textContent = pending
            ? `${pending} tradução(ões) aguardando o tradutor. O site tenta de novo sozinho a cada poucos minutos.`
            : "";
    }

    async function refreshContext(key, sentence, network = true) {
        const record = await Store.get(key);
        const context = record?.contexts.find(c => c.sentence === sentence);
        if (!context) return false;
        const original = context.full || sentence;
        const fullTokens = tokenize(original);
        const first = normalizeWord(String(context.form).split(" ")[0]);
        const savedTap = context.full ? context.fullTap : context.tap;
        const fullIndex = Number.isInteger(savedTap) && fullTokens[savedTap]?.w
            ? savedTap
            : fullTokens.findIndex(t => t.w === first);
        if (fullIndex < 0) {
            context.mv = MEANING_VERSION;           // cannot locate the word: keep as is
            await Store.put(record);
            return false;
        }
        // Long run-on transcripts are reduced to the piece around the word.
        const focus = focusSentence(original, fullIndex);
        const shortened = focus.sentence !== sentence;
        const index = focus.index;
        const tokens = tokenize(focus.sentence);
        const target = await resolveTarget(tokens, index);
        if (!target.isPhrase && focus.sentence !== original) Object.assign(target, hintFields(fullTokens, fullIndex));
        const translation = shortened
            ? (network ? await Translate.sentence(focus.sentence) : "")
            : (context.translation || (network ? await Translate.sentence(sentence) : ""));
        if (shortened && !translation) return false;                 // offline: try again later
        const meaning = await explainTarget(target, translation, { network });
        if (!meaning.gloss) {
            // Translator unavailable: try again later, but stop showing a wrong
            // "meaning" that is only the English word itself.
            const english = new Set([...String(context.form).split(" "), record.key].map(w => fold(w)));
            const words = foldedWords(context.gloss, 1);
            if (words.length && words.every(w => english.has(w))) {
                context.gloss = "";
                await Store.put(record);
                return true;
            }
            return false;
        }

        const updated = {
            ...context,
            sentence: focus.sentence,
            form: target.form,
            translation: translation || context.translation || "",
            gloss: meaning.gloss,
            definition: meaning.definition,
            pos: meaning.pos,
            senseId: meaning.senseId,
            tap: index,
            net: Boolean(meaning.viaNetwork),
            tries: (context.tries || 0) + (network ? 1 : 0),
            ...(focus.sentence !== original ? { full: original, fullTap: fullIndex } : {}),
            mv: MEANING_VERSION
        };

        if (target.key === record.key) {
            const duplicate = shortened && record.contexts.some(c => c.sentence === focus.sentence);
            record.contexts = duplicate
                ? record.contexts.filter(c => c.sentence !== sentence)
                : record.contexts.map(c => (c.sentence === sentence ? updated : c));
            if (target.isPhrase) Object.assign(record, { phrase: true, lookup: target.lookup, senses: target.senses });
            await Store.put(record);
            return true;
        }

        // It belongs to another entry now (e.g. "dug" → "dig around"): move it.
        record.contexts = record.contexts.filter(c => c.sentence !== sentence);
        if (record.contexts.length) await Store.put(record);
        else await Store.del(record.key);
        const destination = (await Store.get(target.key)) || newRecord(target, context.at || new Date().toISOString());
        if (!destination.contexts.some(c => c.sentence === focus.sentence)) destination.contexts.push(updated);
        await Store.put(destination);
        return true;
    }

    async function enrichPending() {
        const all = await Store.all();
        for (const record of all) {
            if (record.contexts.some(c => !c.translation)) {
                await enrich(record.key);
            }
        }
    }


    // ============================================================
    // CAPTIONS
    // ============================================================

    const MAX_LINES = 300;
    let mode = localStorage.getItem("zwl_mode") || "both";
    let lineSeq = 0;
    const lines = [];                 // { id, text, translation, el }
    const interim = { text: "", translation: "", el: null, timer: null, requested: "" };
    let followLive = true;

    function lineElement(text, extraClass = "") {
        const el = document.createElement("div");
        el.className = "line " + extraClass;
        const en = document.createElement("p");
        en.className = "en";
        fillWords(en, text);
        const pt = document.createElement("p");
        pt.className = "pt pending";
        el.append(en, pt);
        return el;
    }

    function fillWords(container, text) {
        const fragment = document.createDocumentFragment();
        tokenize(text).forEach((token, index) => {
            if (index > 0) fragment.append(" ");
            if (token.w) {
                const span = document.createElement("span");
                span.className = "w" + (savedForms.has(token.w) ? " saved" : "");
                span.dataset.w = token.w;
                span.dataset.i = String(index);
                span.textContent = token.t;
                fragment.append(span);
            } else {
                fragment.append(token.t);
            }
        });
        container.replaceChildren(fragment);
    }

    function setPt(el, text, translation) {
        const pt = el.querySelector(".pt");
        if (translation) {
            pt.textContent = translation;
            pt.classList.remove("pending");
        } else {
            pt.textContent = mode === "pt" ? text : "…";
            pt.classList.add("pending");
        }
    }

    function ensureInterimElement() {
        if (!interim.el) {
            interim.el = lineElement("", "interim");
            interim.el.hidden = true;
            els.lines.append(interim.el);
        }
        return interim.el;
    }

    function addFinal(text) {
        const clean = text.replace(/\s+/g, " ").trim();
        if (!clean) return;
        els.empty.hidden = true;
        splitSentences(clean).flatMap(chunkSentence).forEach(sentence => {
            const line = { id: ++lineSeq, text: sentence, translation: Translate.cached(sentence), el: null };
            line.el = lineElement(sentence);
            line.el.dataset.id = line.id;
            setPt(line.el, line.text, line.translation);
            els.lines.insertBefore(line.el, ensureInterimElement());
            lines.push(line);
            if (!line.translation && mode !== "en") translateLine(line);
        });
        while (lines.length > MAX_LINES) {
            const old = lines.shift();
            old.el.remove();
        }
        markCurrent();
        scrollToLive();
    }

    async function translateLine(line) {
        const translation = await Translate.sentence(line.text);
        if (!translation) return;
        line.translation = translation;
        if (line.el.isConnected) setPt(line.el, line.text, translation);
    }

    function setInterim(text) {
        const el = ensureInterimElement();
        const clean = text.replace(/\s+/g, " ").trim();
        if (clean === interim.text) return;
        interim.text = clean;
        el.hidden = !clean;
        if (clean) {
            els.empty.hidden = true;
            fillWords(el.querySelector(".en"), clean);
            setPt(el, clean, interim.translation && interim.requested && clean.startsWith(interim.requested.slice(0, 12)) ? interim.translation : "");
            scheduleInterimTranslation();
        } else {
            interim.translation = "";
            interim.requested = "";
        }
        markCurrent();
        scrollToLive();
    }

    function scheduleInterimTranslation() {
        if (mode === "en") return;
        clearTimeout(interim.timer);
        interim.timer = setTimeout(async () => {
            const text = interim.text;
            if (!text || text.split(" ").length < 3) return;
            interim.requested = text;
            const translation = await Translate.sentence(text);
            if (translation && interim.text.startsWith(text.slice(0, 12))) {
                interim.translation = translation;
                setPt(interim.el, interim.text, translation);
            }
        }, 900);
    }

    function markCurrent() {
        els.lines.querySelectorAll(".line.current").forEach(el => el.classList.remove("current"));
        const target = interim.text ? interim.el : lines[lines.length - 1]?.el;
        target?.classList.add("current");
    }

    function scrollToLive(force = false) {
        if (!followLive && !force) return;
        requestAnimationFrame(() => {
            els.captions.scrollTop = els.captions.scrollHeight;
        });
    }

    els.captions.addEventListener("scroll", () => {
        const distance = els.captions.scrollHeight - els.captions.scrollTop - els.captions.clientHeight;
        followLive = distance < 80;
        els.jumpLive.hidden = followLive || lines.length === 0;
    }, { passive: true });

    els.jumpLive.addEventListener("click", () => {
        followLive = true;
        els.jumpLive.hidden = true;
        scrollToLive(true);
    });

    els.lines.addEventListener("click", event => {
        const span = event.target.closest(".w");
        if (!span) return;
        const lineEl = span.closest(".line");
        let sentence;
        let translation;
        if (lineEl === interim.el) {
            sentence = interim.text;
            translation = interim.translation;
        } else {
            const line = lines.find(l => String(l.id) === lineEl.dataset.id);
            if (!line) return;
            sentence = line.text;
            translation = line.translation;
        }
        onWordTap(span, lineEl, sentence, translation);
    });

    function flash(spans) {
        spans.forEach(span => {
            span.classList.add("flash");
            setTimeout(() => span.classList.remove("flash"), 600);
        });
    }

    /** No translator answered: show ZWords' own (offline) definition meanwhile. */
    function showDictionaryFallback(bubble, target) {
        const senses = target.senses || [];
        const sense = senses.find(([pos]) => target.posHint && String(pos).toLowerCase() === target.posHint) || senses[0];
        Bubble.label(bubble, target.isPhrase ? target.headword : "");
        Bubble.fill(bubble, sense ? sense[1] : "salva ✓");
    }

    /** Tap → balloon with the meaning in context + saved to the library. Captions keep running. */
    async function onWordTap(span, lineEl, fullSentence, fullTranslation) {
        const tapped = Number(span.dataset.i);
        if (tokenize(fullSentence)[tapped]?.w !== span.dataset.w) return;
        const focus = focusSentence(fullSentence, tapped);
        const sentence = focus.sentence;
        const index = focus.index;
        const offset = tapped - index;
        const translation = sentence === fullSentence ? fullTranslation : null;
        const tokens = tokenize(sentence);
        if (navigator.vibrate) navigator.vibrate(12);
        flash([span]);
        const bubble = Bubble.show(span);

        const target = await resolveTarget(tokens, index);
        target.tap = index;
        if (sentence !== fullSentence) {
            target.full = fullSentence;
            target.fullTap = tapped;
            if (!target.isPhrase) Object.assign(target, hintFields(tokenize(fullSentence), tapped));
        }
        const spans = target.positions
            .map(position => lineEl.querySelector(`.w[data-i="${position + offset}"]`))
            .filter(Boolean);
        flash(spans);
        spans.forEach(el => el.classList.add("saved"));
        if (!target.isPhrase) markSaved(target.form);

        // Instant and offline: the 3 most used translations.
        const pick = pickTranslations(target, translation || Translate.cached(sentence));
        Bubble.label(bubble, target.isPhrase ? target.headword : "");
        if (pick.top.length) Bubble.fillWords(bubble, pick.top, Boolean(pick.contextual));
        else showDictionaryFallback(bubble, target);

        // In the background (once): the exact word used in this sentence.
        const translationPromise = translation
            ? Promise.resolve(translation)
            : Translate.sentence(sentence).catch(() => null);
        const meaningPromise = translationPromise.then(tr => explainTarget(target, tr));
        meaningPromise.then(meaning => {
            if (!meaning.viaNetwork || !meaning.gloss) return;
            const others = pick.top.filter(t => fold(t) !== fold(meaning.gloss)).slice(0, 2);
            Bubble.fillWords(bubble, [meaning.gloss, ...others], true);
        }).catch(() => {});

        saveTarget(target, sentence, translationPromise, meaningPromise);
    }


    // ============================================================
    // MEANING BALLOON (over the tapped word; never blocks the captions)
    // ============================================================

    const Bubble = (() => {
        let current = null;
        let timer = null;

        function place(state) {
            const { el, anchor } = state;
            if (!anchor.isConnected) return;
            const host = els.lines.getBoundingClientRect();
            const view = els.captions.getBoundingClientRect();
            const rect = anchor.getBoundingClientRect();
            const width = el.offsetWidth;
            const center = rect.left - host.left + rect.width / 2;
            const left = Math.max(0, Math.min(center - width / 2, host.width - width));
            let top = rect.top - host.top - el.offsetHeight - 10;
            const below = rect.top - el.offsetHeight - 10 < view.top;
            if (below) top = rect.bottom - host.top + 10;
            el.classList.toggle("below", below);
            el.style.left = `${left}px`;
            el.style.top = `${top}px`;
            el.style.setProperty("--arrow-x", `${Math.max(14, Math.min(center - left, width - 14))}px`);
        }

        function hide() {
            clearTimeout(timer);
            if (!current) return;
            const old = current.el;
            old.classList.add("out");
            setTimeout(() => old.remove(), 200);
            current = null;
        }

        function show(anchor) {
            hide();
            const el = document.createElement("div");
            el.className = "bubble";
            el.setAttribute("role", "status");
            el.innerHTML = `<span class="bubble-label" hidden></span><span class="bubble-text loading">…</span>`;
            els.lines.append(el);
            current = { el, anchor };
            place(current);
            timer = setTimeout(hide, 8000);
            return el;
        }

        function label(el, text) {
            if (current?.el !== el) return;
            const node = el.querySelector(".bubble-label");
            node.textContent = text;
            node.hidden = !text;
            place(current);
        }

        function fill(el, text) {
            if (current?.el !== el) return;
            const node = el.querySelector(".bubble-text");
            node.textContent = text;
            node.classList.remove("loading");
            place(current);
            clearTimeout(timer);
            timer = setTimeout(hide, 3800);
        }

        /** "prosperar · dar lucro · crescer" (the first in bold when it fits the sentence). */
        function fillWords(el, words, firstFits) {
            if (current?.el !== el) return;
            const node = el.querySelector(".bubble-text");
            node.innerHTML = words.map((word, i) => (i === 0 && firstFits
                ? `<strong>${escapeHtml(word)}</strong>`
                : escapeHtml(word))).join(" · ");
            node.classList.remove("loading");
            node.classList.add("words");
            place(current);
            clearTimeout(timer);
            timer = setTimeout(hide, 4000);
        }

        return { show, label, fill, fillWords, hide };
    })();

    function setMode(next) {
        mode = next;
        localStorage.setItem("zwl_mode", mode);
        els.app.classList.remove("mode-en", "mode-pt", "mode-both");
        els.app.classList.add("mode-" + mode);
        document.querySelectorAll(".mode").forEach(button => {
            button.setAttribute("aria-checked", String(button.dataset.mode === mode));
        });
        lines.forEach(line => {
            setPt(line.el, line.text, line.translation);
            if (!line.translation && mode !== "en") translateLine(line);
        });
        if (interim.el && interim.text) setPt(interim.el, interim.text, interim.translation);
    }

    document.querySelectorAll(".mode").forEach(button => {
        button.addEventListener("click", () => setMode(button.dataset.mode));
    });


    // ============================================================
    // SPEECH RECOGNITION
    // ============================================================

    const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    const isIOS = /iP(hone|ad|od)/.test(navigator.userAgent)
        || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    const isStandalone = window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;

    let listening = false;
    let recognizer = null;
    let lastFinal = "";
    let restartTimer = null;
    let quickRestarts = 0;
    let lastStart = 0;
    let wakeLock = null;

    function showNotice(message) {
        els.notice.textContent = message || "";
        els.notice.hidden = !message;
    }

    function commitFinal(transcript) {
        let text = transcript.trim();
        if (!text) return;
        // Chrome on Android repeats earlier final text in later results.
        const folded = text.toLowerCase();
        if (lastFinal) {
            if (folded === lastFinal) return;
            if (folded.startsWith(lastFinal)) text = text.slice(lastFinal.length).trim();
        }
        lastFinal = folded;
        addFinal(text);
    }

    function createRecognizer() {
        const r = new Recognition();
        r.lang = "en-US";
        r.continuous = true;
        r.interimResults = true;
        r.maxAlternatives = 1;

        r.onresult = event => {
            quickRestarts = 0;
            let pending = "";
            for (let i = event.resultIndex; i < event.results.length; i++) {
                const result = event.results[i];
                const transcript = result[0]?.transcript || "";
                if (result.isFinal) {
                    commitFinal(transcript);
                } else {
                    pending += transcript;
                }
            }
            let shown = pending.trim();
            if (lastFinal && shown.toLowerCase().startsWith(lastFinal)) shown = shown.slice(lastFinal.length).trim();
            setInterim(shown);
        };

        r.onerror = event => {
            const error = event.error;
            if (error === "not-allowed" || error === "service-not-allowed") {
                stopListening();
                showNotice(isIOS
                    ? "Permita o Microfone e o Reconhecimento de Fala para o Safari: Ajustes › Apps › Safari › Microfone (e Ajustes › Privacidade › Reconhecimento de Fala)."
                    : "Permita o microfone para este site (ícone de cadeado na barra de endereço) e tente de novo.");
            } else if (error === "audio-capture") {
                stopListening();
                showNotice("Nenhum microfone disponível. Verifique se outro app está usando o microfone.");
            } else if (error === "network") {
                showNotice("Sem conexão: o reconhecimento de fala do navegador precisa de internet.");
            } else if (error === "language-not-supported") {
                stopListening();
                showNotice("Este navegador não reconhece inglês (en-US).");
            }
        };

        r.onend = () => {
            if (interim.text) {
                // Keep what was heard even if the engine stopped mid-phrase.
                commitFinal(interim.text);
                setInterim("");
            }
            recognizer = null;
            if (!listening) return;
            const quick = Date.now() - lastStart < 1500;
            quickRestarts = quick ? quickRestarts + 1 : 0;
            const delay = quickRestarts > 4 ? 2000 : 250;
            clearTimeout(restartTimer);
            restartTimer = setTimeout(startRecognizer, delay);
        };

        return r;
    }

    function startRecognizer() {
        if (!listening || recognizer || document.hidden) return;
        try {
            recognizer = createRecognizer();
            lastFinal = "";
            lastStart = Date.now();
            recognizer.start();
        } catch (error) {
            recognizer = null;
            clearTimeout(restartTimer);
            restartTimer = setTimeout(startRecognizer, 1000);
        }
    }

    async function requestWakeLock() {
        try {
            if ("wakeLock" in navigator && !wakeLock) {
                wakeLock = await navigator.wakeLock.request("screen");
                wakeLock.addEventListener("release", () => { wakeLock = null; });
            }
        } catch (error) {
            wakeLock = null;
        }
    }

    function releaseWakeLock() {
        wakeLock?.release().catch(() => {});
        wakeLock = null;
    }

    function startListening() {
        if (!Recognition) return;
        listening = true;
        showNotice("");
        els.app.classList.add("listening");
        els.mic.setAttribute("aria-label", "Parar de ouvir");
        els.micLabel.textContent = "Ouvindo… toque para parar";
        Translate.prepareOnDevice();
        requestWakeLock();
        startRecognizer();
    }

    function stopListening() {
        listening = false;
        clearTimeout(restartTimer);
        els.app.classList.remove("listening");
        els.mic.setAttribute("aria-label", "Começar a ouvir");
        els.micLabel.textContent = "Toque para ouvir";
        releaseWakeLock();
        if (recognizer) {
            try { recognizer.stop(); } catch (error) { /* ignore */ }
        }
    }

    els.mic.addEventListener("click", () => {
        if (listening) stopListening(); else startListening();
    });

    document.addEventListener("visibilitychange", () => {
        if (document.hidden) return;
        if (listening) {
            requestWakeLock();
            startRecognizer();
        }
    });

    function checkSupport() {
        if (!window.isSecureContext) {
            showNotice("Abra esta página por https para usar o microfone.");
            els.mic.disabled = true;
            return;
        }
        if (Recognition) return;
        els.mic.disabled = true;
        els.mic.style.opacity = "0.4";
        if (isIOS && isStandalone) {
            showNotice("No app da tela de início o iPhone bloqueia o reconhecimento de fala. Abra esta página no Safari.");
        } else if (isIOS) {
            showNotice("Use o Safari para ouvir (navegadores dentro de outros apps, como Instagram, não têm reconhecimento de fala).");
        } else {
            showNotice("Este navegador não tem reconhecimento de fala. Use o Chrome (Android/computador) ou o Safari (iPhone).");
        }
    }


    // ============================================================
    // SPEECH SYNTHESIS
    // ============================================================

    function speak(text) {
        if (!("speechSynthesis" in window)) return;
        speechSynthesis.cancel();
        const utterance = new SpeechSynthesisUtterance(text);
        utterance.lang = "en-US";
        utterance.rate = 0.9;
        speechSynthesis.speak(utterance);
    }


    // ============================================================
    // LIBRARY
    // ============================================================

    function latestGloss(record) {
        const contexts = [...record.contexts].reverse();
        const withMeaning = contexts.find(c => c.gloss || c.definition);
        if (!withMeaning) return "…";
        return withMeaning.gloss || withMeaning.definition;
    }

    async function renderLibrary() {
        const all = await Store.all();
        all.sort((a, b) => (b.updatedAt || "").localeCompare(a.updatedAt || ""));
        updateLibraryBadge(all.length);
        const query = fold(els.librarySearch.value.trim());
        const filtered = query
            ? all.filter(record => fold([
                record.headword,
                ...record.contexts.flatMap(c => [c.form, c.sentence, c.translation, c.gloss, c.definition])
            ].join(" ")).includes(query))
            : all;

        els.libraryEmpty.hidden = all.length > 0;
        els.wordList.innerHTML = filtered.map(record => `
            <li>
                <button type="button" class="word-item" data-key="${escapeHtml(record.key)}">
                    <span class="word-main">
                        <span class="word-head">${escapeHtml(record.headword)}</span>
                        <span class="word-gloss">${escapeHtml(latestGloss(record))}</span>
                    </span>
                    ${record.contexts.length > 1 ? `<span class="word-count">${record.contexts.length}</span>` : ""}
                </button>
            </li>`).join("")
            || (all.length ? `<li class="library-empty">Nada encontrado para “${escapeHtml(els.librarySearch.value)}”.</li>` : "");
    }

    function openSheet(sheet) {
        sheet.hidden = false;
    }

    function closeSheet(sheet) {
        sheet.hidden = true;
    }

    $("openLibrary").addEventListener("click", async () => {
        await renderLibrary();
        openSheet(els.library);
        pendingCount().then(updatePendingNote);
        enrichPending().then(refreshOutdated);
    });

    $("closeLibrary").addEventListener("click", () => closeSheet(els.library));
    els.librarySearch.addEventListener("input", renderLibrary);

    els.wordList.addEventListener("click", event => {
        const item = event.target.closest(".word-item");
        if (item) openDetail(item.dataset.key);
    });

    async function openDetail(key) {
        const record = await Store.get(key);
        if (!record) {
            closeSheet(els.detail);
            return;
        }
        els.detail.dataset.key = key;
        els.detail.querySelector("h2").textContent = "";
        const contexts = [...record.contexts].reverse();
        const entry = record.phrase
            ? (record.senses?.length ? [record.headword, record.senses] : null)
            : await Dict.entry(record.key).catch(() => null);

        const extraSenses = record.extra?.senses || [];
        const allSenses = [...(entry ? entry[1] : []), ...extraSenses];
        if (!record.extra) ensureExtras(record.key);

        // Every translation from the fixed dictionary, grouped by part of speech.
        const own = record.phrase ? await Dict.entry(record.key).catch(() => null) : entry;
        const translations = own?.[2] || [];
        const groups = [];
        translations.forEach(([text, pos], i) => {
            let group = groups.find(g => g.pos === pos);
            if (!group) groups.push(group = { pos, items: [] });
            group.items.push(i < 3 ? `<strong>${escapeHtml(text)}</strong>` : escapeHtml(text));
        });

        els.detailBody.innerHTML = `
            <div class="detail-head">
                <h3>${escapeHtml(record.headword)}</h3>
                <button type="button" class="speak" data-speak="${escapeHtml(record.headword)}" aria-label="Ouvir pronúncia">🔊</button>
            </div>

            ${groups.length ? `
                <div class="translations">
                    ${groups.map(g => `<p>${g.pos ? `<em>${escapeHtml(posLabel(g.pos))}</em> ` : ""}${g.items.join(", ")}</p>`).join("")}
                </div>` : ""}

            <p class="section-label">${contexts.length === 1 ? "Onde você encontrou" : `${contexts.length} contextos reais`}</p>
            ${contexts.map(c => `
                <article class="context">
                    ${c.gloss
                        ? `<p class="context-gloss">${escapeHtml(c.gloss)}${c.pos ? ` <span class="word-count">${escapeHtml(posLabel(c.pos))}</span>` : ""}</p>`
                        : `<p class="context-definition">Buscando a tradução neste contexto…</p>`}
                    ${c.definition ? `<p class="context-definition">${escapeHtml(c.definition)}</p>` : ""}
                    <p class="context-sentence">${highlightForm(c.sentence, c.form)}</p>
                    <p class="context-translation">${escapeHtml(c.translation || "Traduzindo… (precisa de internet)")}</p>
                    <div class="context-meta">
                        <span>${escapeHtml(new Date(c.at).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" }))}</span>
                        <button type="button" data-remove="${escapeHtml(c.sentence)}">remover</button>
                    </div>
                </article>`).join("")}

            ${allSenses.length ? `
                <p class="section-label">Todos os sentidos</p>
                <ol class="senses">
                    ${allSenses.map(([pos, definition, source]) => `<li>${escapeHtml(definition)} <em>${escapeHtml(posLabel(pos))}${source === "wiktionary" ? " · Wiktionary" : ""}</em></li>`).join("")}
                </ol>
                ${extraSenses.length ? `<p class="source-note">Sentidos marcados com Wiktionary: dicionário aberto (CC BY-SA), traduzidos automaticamente.</p>` : ""}
                ${groups.length ? `<p class="source-note">Traduções: FreeDict (GPL), ordenadas pelas mais usadas no português.</p>` : ""}`
                : (record.extra ? "" : `<p class="source-note">Buscando todos os sentidos…</p>`)}
        `;
        openSheet(els.detail);
    }

    els.detailBody.addEventListener("click", async event => {
        const speakButton = event.target.closest("[data-speak]");
        if (speakButton) {
            speak(speakButton.dataset.speak);
            return;
        }
        const remove = event.target.closest("[data-remove]");
        if (remove) {
            const key = els.detail.dataset.key;
            const record = await Store.get(key);
            if (!record) return;
            record.contexts = record.contexts.filter(c => c.sentence !== remove.dataset.remove);
            if (record.contexts.length) {
                await Store.put(record);
                openDetail(key);
            } else {
                await Store.del(key);
                closeSheet(els.detail);
            }
            await loadSavedForms();
            renderLibrary();
        }
    });

    $("closeDetail").addEventListener("click", () => closeSheet(els.detail));

    $("deleteWord").addEventListener("click", async () => {
        const key = els.detail.dataset.key;
        const record = await Store.get(key);
        if (!record || !confirm(`Apagar “${record.headword}” e todos os contextos?`)) return;
        await Store.del(key);
        closeSheet(els.detail);
        await loadSavedForms();
        els.lines.querySelectorAll(".w.saved").forEach(el => {
            if (!savedForms.has(el.dataset.w)) el.classList.remove("saved");
        });
        renderLibrary();
    });

    $("exportLibrary").addEventListener("click", async () => {
        const all = await Store.all();
        const blob = new Blob([JSON.stringify({ app: "zwords-listen", version: 1, words: all }, null, 2)], { type: "application/json" });
        const link = document.createElement("a");
        link.href = URL.createObjectURL(blob);
        link.download = `zwords-palavras-${new Date().toISOString().slice(0, 10)}.json`;
        link.click();
        setTimeout(() => URL.revokeObjectURL(link.href), 2000);
    });

    $("importLibrary").addEventListener("change", async event => {
        const file = event.target.files?.[0];
        if (!file) return;
        try {
            const data = JSON.parse(await file.text());
            const words = Array.isArray(data) ? data : data.words;
            let count = 0;
            for (const incoming of words || []) {
                if (!incoming?.key || !Array.isArray(incoming.contexts)) continue;
                const existing = await Store.get(incoming.key);
                if (existing) {
                    incoming.contexts.forEach(c => {
                        if (!existing.contexts.some(e => e.sentence === c.sentence)) existing.contexts.push(c);
                    });
                    await Store.put(existing);
                } else {
                    await Store.put(incoming);
                }
                count++;
            }
            await loadSavedForms();
            renderLibrary();
            alert(`${count} palavra(s) importada(s).`);
        } catch (error) {
            alert("Arquivo inválido.");
        }
        event.target.value = "";
    });


    // ============================================================
    // REVIEW (spaced repetition with the real sentences)
    // ============================================================

    const INTERVAL_DAYS = [0, 1, 3, 7, 16, 35];
    let reviewQueue = [];
    let reviewDone = 0;
    let revealed = false;

    $("startReview").addEventListener("click", async () => {
        const all = await Store.all();
        reviewQueue = all.filter(r => (r.due || 0) <= Date.now()).sort((a, b) => (a.due || 0) - (b.due || 0));
        reviewDone = 0;
        revealed = false;
        renderReview(all.length);
        openSheet(els.review);
    });

    $("closeReview").addEventListener("click", () => {
        closeSheet(els.review);
        renderLibrary();
    });

    function renderReview(total = 0) {
        const record = reviewQueue[0];
        if (!record) {
            els.reviewTitle.textContent = "Revisão";
            els.reviewBody.innerHTML = `
                <div class="review-done">
                    <p><strong>${reviewDone ? "Revisão concluída 🎉" : "Tudo em dia"}</strong></p>
                    <p>${reviewDone ? `${reviewDone} palavra(s) revisada(s).` : "Nenhuma palavra para revisar agora."}</p>
                    ${total || reviewDone ? `<button type="button" class="text-button strong" id="reviewAll">Revisar todas mesmo assim</button>` : ""}
                </div>`;
            return;
        }
        els.reviewTitle.textContent = `${reviewQueue.length} restante(s)`;
        const context = record.contexts[Math.floor(Math.random() * record.contexts.length)];
        els.reviewBody.innerHTML = `
            <div class="card">
                <h3>${escapeHtml(record.headword)}
                    <button type="button" class="speak" data-speak="${escapeHtml(record.headword)}" aria-label="Ouvir pronúncia">🔊</button>
                </h3>
                <p class="context-sentence">${highlightForm(context.sentence, context.form)}</p>
                ${revealed ? `
                    <div class="card-answer">
                        ${context.gloss ? `<p class="context-gloss">${escapeHtml(context.gloss)}</p>` : ""}
                        ${context.definition ? `<p class="context-definition">${escapeHtml(context.definition)}</p>` : ""}
                        <p class="context-translation">${escapeHtml(context.translation || "")}</p>
                    </div>` : ""}
            </div>
            <div class="review-actions">
                ${revealed
                    ? `<button type="button" class="again" data-answer="again">Não lembrei</button>
                       <button type="button" class="good" data-answer="good">Lembrei</button>`
                    : `<button type="button" data-answer="reveal">Mostrar significado</button>`}
            </div>`;
    }

    els.reviewBody.addEventListener("click", async event => {
        const speakButton = event.target.closest("[data-speak]");
        if (speakButton) {
            speak(speakButton.dataset.speak);
            return;
        }
        if (event.target.id === "reviewAll") {
            reviewQueue = (await Store.all()).sort(() => Math.random() - 0.5);
            revealed = false;
            renderReview();
            return;
        }
        const answer = event.target.closest("[data-answer]")?.dataset.answer;
        if (!answer) return;
        if (answer === "reveal") {
            revealed = true;
            renderReview();
            return;
        }
        const record = reviewQueue.shift();
        const latest = await Store.get(record.key);
        if (latest) {
            if (answer === "good") {
                latest.box = Math.min((latest.box || 0) + 1, INTERVAL_DAYS.length - 1);
                latest.due = Date.now() + INTERVAL_DAYS[latest.box] * 86400000;
            } else {
                latest.box = 0;
                latest.due = Date.now() + 10 * 60000;
            }
            await Store.put(latest);
        }
        reviewDone++;
        revealed = false;
        renderReview();
    });


    // ============================================================
    // START
    // ============================================================

    setMode(mode);
    checkSupport();
    loadSavedForms().then(enrichPending).then(refreshOutdated);
    window.addEventListener("online", () => enrichPending().then(refreshOutdated));

    if ("serviceWorker" in navigator) {
        navigator.serviceWorker.register("./service-worker.js?v=20260913-3").catch(() => {});
    }

    // Exposed for automated tests only.
    window.__zwordsListen = { Wiki, ensureExtras, newSenses, markSentence, extractMarked, chunkSentence, focusSentence, refreshOutdated, MEANING_VERSION, addFinal, setInterim, explain, explainTarget, resolveTarget, Phrasal, Dict, Translate, Store, splitSentences, tokenize };

})();
