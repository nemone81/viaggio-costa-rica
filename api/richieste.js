/**
 * Casella richieste: POST accoda una modifica, GET restituisce lo storico.
 *
 * Una richiesta diventa una issue GitHub con label `auto-request`. Il runner sul
 * VPS pesca da quella coda, fa fare la modifica a Claude Code, e pubblica se lo
 * smoke test passa. Qui dentro non c'è niente che scriva codice: il token di
 * questa funzione può solo aprire e leggere issue.
 */

import { timingSafeEqual } from "node:crypto";

const REPO = "nemone81/viaggio-costa-rica";
const LABEL = "auto-request";
const API = "https://api.github.com";

const MIN_LEN = 10;
const MAX_LEN = 2000;

function pinOk(given) {
  const expected = process.env.REQUEST_PIN || "";
  if (!expected || typeof given !== "string" || given.length === 0) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  // timingSafeEqual pretende lunghezze uguali: confronta prima quelle, poi i byte.
  return a.length === b.length && timingSafeEqual(a, b);
}

async function gh(path, init = {}) {
  const res = await fetch(API + path, {
    ...init,
    headers: {
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      authorization: `Bearer ${process.env.GITHUB_TOKEN_ISSUES}`,
      "content-type": "application/json",
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  let body = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { raw: text.slice(0, 400) };
  }
  return { ok: res.ok, status: res.status, body };
}

/** Titolo leggibile per la issue: prima frase o primi 70 caratteri. */
function titleFrom(text) {
  const flat = text.replace(/\s+/g, " ").trim();
  const stop = flat.search(/[.!?](\s|$)/);
  const base = stop > 15 ? flat.slice(0, stop) : flat;
  return base.length > 70 ? base.slice(0, 67) + "…" : base;
}

/**
 * Lo stato mostrato in pagina si deduce da issue state + label che mette il runner.
 * Nessuna: in coda. `in-progress`: Claude ci sta lavorando. Chiusa: pubblicata.
 */
function statoOf(issue) {
  const labels = (issue.labels || []).map((l) => (typeof l === "string" ? l : l.name));
  if (issue.state === "closed") return labels.includes("auto-failed") ? "annullata" : "pubblicata";
  if (labels.includes("auto-failed")) return "fallita";
  if (labels.includes("in-progress")) return "in corso";
  return "in coda";
}

export default async function handler(req, res) {
  if (!process.env.GITHUB_TOKEN_ISSUES) {
    return res.status(503).json({ errore: "La casella non è ancora configurata: manca il token GitHub." });
  }

  if (req.method === "GET") {
    const q = `/repos/${REPO}/issues?labels=${LABEL}&state=all&per_page=20&sort=created&direction=desc`;
    const { ok, status, body } = await gh(q);
    if (!ok) {
      return res.status(502).json({ errore: `GitHub ha risposto ${status} leggendo la coda.` });
    }
    const richieste = (Array.isArray(body) ? body : [])
      .filter((i) => !i.pull_request)
      .map((i) => ({
        numero: i.number,
        titolo: i.title,
        stato: statoOf(i),
        creata: i.created_at,
        url: i.html_url,
      }));
    res.setHeader("cache-control", "no-store");
    return res.status(200).json({ richieste });
  }

  if (req.method !== "POST") {
    res.setHeader("allow", "GET, POST");
    return res.status(405).json({ errore: "Metodo non ammesso." });
  }

  const payload = typeof req.body === "string" ? safeParse(req.body) : req.body || {};
  const testo = typeof payload.testo === "string" ? payload.testo.trim() : "";

  if (!pinOk(payload.pin)) {
    return res.status(401).json({ errore: "PIN non valido." });
  }
  if (testo.length < MIN_LEN) {
    return res.status(400).json({ errore: `Scrivi almeno ${MIN_LEN} caratteri: serve capire cosa cambiare.` });
  }
  if (testo.length > MAX_LEN) {
    return res.status(400).json({ errore: `Massimo ${MAX_LEN} caratteri, ne hai scritti ${testo.length}.` });
  }

  const corpo = [
    "**Richiesta inviata dalla casella del sito.**",
    "",
    "```text",
    testo.replace(/```/g, "'''"),
    "```",
    "",
    `_Ricevuta il ${new Date().toISOString()}._`,
  ].join("\n");

  const { ok, status, body } = await gh(`/repos/${REPO}/issues`, {
    method: "POST",
    body: JSON.stringify({ title: titleFrom(testo), body: corpo, labels: [LABEL] }),
  });

  if (!ok) {
    return res.status(502).json({ errore: `Non ho potuto accodare la richiesta (GitHub ${status}).` });
  }

  return res.status(201).json({
    numero: body.number,
    url: body.html_url,
    messaggio: "Richiesta accodata. Viene lavorata entro pochi minuti.",
  });
}

function safeParse(s) {
  try {
    return JSON.parse(s);
  } catch {
    return {};
  }
}
