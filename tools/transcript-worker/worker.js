// ============================================================
// zwords-transcript — Cloudflare Worker (free plan)
//
// GET /transcript?v=<YouTube id>&lang=en
//   -> { id, lang, auto, title, cues: [{ start, dur, text }] }
//
// A website cannot read YouTube's captions directly (YouTube blocks
// cross-site requests). This worker fetches them server-side, the same
// way open-source tools like youtube-transcript-api do, and returns
// plain JSON to the ZWords "Ouvir" page. Results are cached for a day.
// ============================================================

const ALLOWED_ORIGINS = [
    "https://andrezaferreira.github.io",
    "http://localhost:8765"
];

const USER_AGENT =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36";

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);
        const origin = request.headers.get("Origin") || "";
        const cors = {
            "Access-Control-Allow-Origin": ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
            "Access-Control-Allow-Methods": "GET, OPTIONS",
            "Vary": "Origin"
        };

        if (request.method === "OPTIONS") return new Response(null, { headers: cors });
        if (url.pathname !== "/transcript") return json({ error: "not found" }, 404, cors);

        const id = url.searchParams.get("v") || "";
        if (!/^[\w-]{11}$/.test(id)) return json({ error: "invalid video id" }, 400, cors);
        const lang = (url.searchParams.get("lang") || "en").replace(/[^a-zA-Z-]/g, "").slice(0, 8) || "en";

        const cache = caches.default;
        const cacheKey = new Request(`https://transcript-cache.zwords/${id}/${lang}`);
        const hit = await cache.match(cacheKey);
        if (hit) {
            return new Response(await hit.text(), {
                headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "X-Cache": "HIT" }
            });
        }

        try {
            const body = JSON.stringify(await transcript(id, lang));
            ctx.waitUntil(cache.put(cacheKey, new Response(body, {
                headers: { "Cache-Control": "public, max-age=86400" }
            })));
            return new Response(body, { headers: { ...cors, "Content-Type": "application/json; charset=utf-8" } });
        } catch (error) {
            return json({ error: String(error?.message || error) }, 502, cors);
        }
    }
};

function json(data, status, headers) {
    return new Response(JSON.stringify(data), {
        status,
        headers: { ...headers, "Content-Type": "application/json; charset=utf-8" }
    });
}

async function transcript(id, lang) {
    // 1. The watch page gives the public API key of YouTube's own web app.
    const page = await fetch(`https://www.youtube.com/watch?v=${id}&hl=en`, {
        headers: { "User-Agent": USER_AGENT, "Accept-Language": "en-US,en;q=0.9", "Cookie": "CONSENT=YES+1" }
    }).then(r => r.text());
    const key = page.match(/"INNERTUBE_API_KEY":"([^"]+)"/)?.[1];
    if (!key) throw new Error("youtube page unavailable");

    // 2. The player data lists the caption tracks (the Android client's
    //    caption URLs work without browser-only tokens).
    const player = await fetch(`https://www.youtube.com/youtubei/v1/player?key=${key}&prettyPrint=false`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "User-Agent": USER_AGENT },
        body: JSON.stringify({
            context: { client: { clientName: "ANDROID", clientVersion: "20.10.38", hl: "en" } },
            videoId: id
        })
    }).then(r => r.json());

    const tracks = player?.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
    if (!tracks.length) {
        const status = player?.playabilityStatus?.status;
        throw new Error(status && status !== "OK" ? `video ${status.toLowerCase()}` : "no captions");
    }
    const track =
        tracks.find(t => t.languageCode?.startsWith(lang) && t.kind !== "asr") ||   // human captions first
        tracks.find(t => t.languageCode?.startsWith(lang));                         // then automatic ones
    if (!track) throw new Error(`no ${lang} captions`);

    // 3. The caption file itself.
    const xml = await fetch(track.baseUrl.replace(/&fmt=[^&]*/, ""), {
        headers: { "User-Agent": USER_AGENT }
    }).then(r => r.text());
    const cues = parseCaptions(xml);
    if (!cues.length) throw new Error("empty captions");

    return {
        id,
        lang: track.languageCode,
        auto: track.kind === "asr",
        title: player?.videoDetails?.title || "",
        cues
    };
}

function parseCaptions(xml) {
    const cues = [];
    // Classic format: <text start="1.2" dur="3.4">Hello</text>
    for (const m of xml.matchAll(/<text start="([\d.]+)"(?: dur="([\d.]+)")?[^>]*>([\s\S]*?)<\/text>/g)) {
        cues.push({ start: Number(m[1]), dur: Number(m[2] || 0), text: decode(m[3]) });
    }
    // Format 3: <p t="1200" d="3400">Hello <s>world</s></p>
    if (!cues.length) {
        for (const m of xml.matchAll(/<p t="(\d+)"(?: d="(\d+)")?[^>]*>([\s\S]*?)<\/p>/g)) {
            cues.push({ start: Number(m[1]) / 1000, dur: Number(m[2] || 0) / 1000, text: decode(m[3]) });
        }
    }
    return cues.filter(cue => cue.text);
}

function decode(text) {
    return text
        .replace(/<[^>]+>/g, "")
        .replace(/&amp;/g, "&")
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'")
        .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
        .replace(/<[^>]+>/g, "")                 // tags that were escaped inside the text
        .replace(/\s+/g, " ")
        .trim();
}

// Exported for local tests only.
export { parseCaptions, decode };
