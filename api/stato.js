/**
 * Stato condiviso della pagina: spunte che si vedono da tutti i dispositivi.
 *
 * Predisposto, non ancora usato dalla UI. Serve a tenere delle caselle spuntate
 * (cose da prenotare, valigia, attività fatte) su un Redis di Upstash, così una
 * spunta messa da un telefono si vede anche dall'altro.
 *
 *   GET  /api/stato            → { spunte: { chiave: true, … }, aggiornato }
 *   POST /api/stato            → { pin, patch: { chiave: true|false|null } }
 *                                null cancella la chiave. Risponde con lo stato.
 *
 * Lettura libera (le spunte non sono un segreto), scrittura col PIN della casella.
 *
 * Parla con l'API REST di Upstash via fetch invece di usare `@upstash/redis`:
 * il progetto non ha dipendenze a runtime e non c'è motivo di introdurne una per
 * due comandi. Le variabili KV_REST_API_URL e KV_REST_API_TOKEN le inietta
 * l'integrazione Marketplace (nomi KV_*, non UPSTASH_*: `Redis.fromEnv()` non
 * le troverebbe).
 */

import { timingSafeEqual } from "node:crypto";

const HASH = "viaggio:spunte";
const MAX_CHIAVI = 300;
const CHIAVE_OK = /^[a-z0-9][a-z0-9:_-]{0,63}$/;

function pinOk(given) {
  const expected = process.env.REQUEST_PIN || "";
  if (!expected || typeof given !== "string" || given.length === 0) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Un comando Redis sull'API REST di Upstash. Il body è l'array del comando. */
async function redis(cmd) {
  const url = process.env.KV_REST_API_URL;
  const token = process.env.KV_REST_API_TOKEN;
  const res = await fetch(url, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(cmd),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok || (body && body.error)) {
    throw new Error(`Redis ${res.status}: ${(body && body.error) || "risposta illeggibile"}`);
  }
  return body ? body.result : null;
}

/** HGETALL torna un array piatto [campo, valore, campo, valore, …]. */
function coppie(piatto) {
  const out = {};
  if (!Array.isArray(piatto)) return out;
  for (let i = 0; i < piatto.length - 1; i += 2) {
    out[piatto[i]] = piatto[i + 1];
  }
  return out;
}

async function leggi() {
  const grezzo = coppie(await redis(["HGETALL", HASH]));
  const spunte = {};
  let aggiornato = null;
  for (const [k, v] of Object.entries(grezzo)) {
    try {
      const { v: val, t } = JSON.parse(v);
      spunte[k] = val;
      if (t && (!aggiornato || t > aggiornato)) aggiornato = t;
    } catch {
      // valore scritto a mano o corrotto: lo si mostra come spuntato
      spunte[k] = true;
    }
  }
  return { spunte, aggiornato };
}

export default async function handler(req, res) {
  if (!process.env.KV_REST_API_URL || !process.env.KV_REST_API_TOKEN) {
    return res.status(503).json({ errore: "Lo storage non è collegato a questo ambiente." });
  }

  try {
    if (req.method === "GET") {
      res.setHeader("cache-control", "no-store");
      return res.status(200).json(await leggi());
    }

    if (req.method !== "POST") {
      res.setHeader("allow", "GET, POST");
      return res.status(405).json({ errore: "Metodo non ammesso." });
    }

    const payload = typeof req.body === "string" ? JSON.parse(req.body || "{}") : req.body || {};
    if (!pinOk(payload.pin)) {
      return res.status(401).json({ errore: "PIN non valido." });
    }

    const patch = payload.patch;
    if (!patch || typeof patch !== "object" || Array.isArray(patch)) {
      return res.status(400).json({ errore: "Serve un oggetto patch, per esempio { patch: { \"prenota:manuel-antonio\": true } }." });
    }

    const voci = Object.entries(patch);
    if (!voci.length) return res.status(400).json({ errore: "La patch è vuota." });
    if (voci.length > 50) return res.status(400).json({ errore: "Massimo 50 chiavi per volta." });

    for (const [k, v] of voci) {
      if (!CHIAVE_OK.test(k)) {
        return res.status(400).json({ errore: `Chiave non valida: "${k}". Ammesse minuscole, cifre, : _ -` });
      }
      if (v !== null && typeof v !== "boolean") {
        return res.status(400).json({ errore: `Il valore di "${k}" deve essere true, false o null.` });
      }
    }

    // Un tetto al numero di chiavi: senza, una UI con un bug potrebbe riempire
    // il database una spunta per volta senza che nessuno se ne accorga.
    const nuove = voci.filter(([, v]) => v !== null).map(([k]) => k);
    if (nuove.length) {
      const presenti = await redis(["HLEN", HASH]);
      if (Number(presenti) + nuove.length > MAX_CHIAVI) {
        return res.status(409).json({ errore: `Troppe chiavi salvate (tetto ${MAX_CHIAVI}).` });
      }
    }

    const t = new Date().toISOString();
    const daScrivere = [];
    const daCancellare = [];
    for (const [k, v] of voci) {
      if (v === null) daCancellare.push(k);
      else daScrivere.push(k, JSON.stringify({ v, t }));
    }

    if (daScrivere.length) await redis(["HSET", HASH, ...daScrivere]);
    if (daCancellare.length) await redis(["HDEL", HASH, ...daCancellare]);

    return res.status(200).json(await leggi());
  } catch (e) {
    return res.status(502).json({ errore: "Lo storage non ha risposto.", dettaglio: String(e.message || e).slice(0, 200) });
  }
}
