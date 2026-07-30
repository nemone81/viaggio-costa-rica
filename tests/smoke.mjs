/**
 * Smoke test: è il solo cancello prima che una modifica vada online.
 *
 * Carica index.html in un browser headless e verifica che la pagina funzioni
 * davvero, non solo che il file esista. Errori in console e promesse rifiutate
 * fanno fallire il test: un `ReferenceError` nel JS renderebbe la pagina vuota
 * senza che il file sembri rotto.
 *
 *   npm run smoke
 */

import { chromium } from "playwright";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";

const GIORNI_ATTESI = 18;
const TAPPE_ATTESE = 8;

/* La pagina va servita via HTTP, non da file://: sotto file:// il fetch verso
   /api/richieste è vietato dal browser e sporcherebbe la console di errori che
   in produzione non esistono. */
const server = createServer(async (req, res) => {
  if (req.url.startsWith("/api/richieste")) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end('{"richieste":[]}');
    return;
  }
  try {
    const html = await readFile(path.resolve("index.html"));
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    res.end(html);
  } catch (e) {
    res.writeHead(500);
    res.end(String(e));
  }
});
await new Promise((ok) => server.listen(0, "127.0.0.1", ok));
const BASE = `http://127.0.0.1:${server.address().port}/`;

let falliti = 0;

function check(nome, condizione, dettaglio = "") {
  if (condizione) {
    console.log(`  ok   ${nome}`);
  } else {
    falliti++;
    console.log(`  FAIL ${nome}${dettaglio ? " — " + dettaglio : ""}`);
  }
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 390, height: 844 } });

/* Gli errori che contano sono le eccezioni JavaScript. I fallimenti di rete verso
   servizi esterni (qui il meteo, deliberatamente spento) li logga il browser ma
   non sono un difetto della pagina: la pagina deve sopravvivere senza meteo. */
const RETE = /Failed to load resource|net::ERR|ERR_FAILED|503 \(Service Unavailable\)/;
const errori = [];
page.on("console", (m) => {
  if (m.type() === "error" && !RETE.test(m.text())) errori.push(m.text());
});
page.on("pageerror", (e) => errori.push(String(e)));

// Il meteo chiama Open-Meteo: il test non deve dipendere dalla rete, ma la pagina
// deve reggere la chiamata fallita senza lasciare errori a schermo.
await page.route("**/*open-meteo.com/**", (r) => r.fulfill({ status: 503, body: "{}" }));

console.log("Smoke test — pagina");
await page.goto(BASE, { waitUntil: "load" });

const giorni = await page.locator(".day").count();
check(`${GIORNI_ATTESI} giornate presenti`, giorni === GIORNI_ATTESI, `trovate ${giorni}`);

const tappe = await page.locator("#spine button").count();
check(`${TAPPE_ATTESE} tappe nel percorso`, tappe === TAPPE_ATTESE, `trovate ${tappe}`);

check("titolo compilato", (await page.title()).length > 5);
check("intestazione visibile", await page.locator("h1").first().isVisible());

// Un accordion chiuso si apre al tocco: verifica che il markup generato dal JS
// sia agganciato, non solo presente. Il giorno di oggi è già aperto da solo,
// quindi si parte da uno chiuso.
const idChiuso = await page.locator(".day:not([open])").first().getAttribute("id");
await page.locator(`#${idChiuso} summary`).click();
check("l'accordion si apre", await page.locator(`#${idChiuso} .body`).first().isVisible(), idChiuso);

console.log("Smoke test — viste");
for (const [vista, sel] of [["legs", "#legs .card"], ["stays", "#stays .card"], ["ask", "#askForm"]]) {
  await page.locator(`.tabs button[data-view="${vista}"]`).click();
  const n = await page.locator(sel).count();
  check(`vista ${vista} popolata`, n > 0, `${sel} → ${n}`);
}

console.log("Smoke test — alloggi e link");
await page.locator('.tabs button[data-view="stays"]').click();
const schede = await page.locator("#stays .card").count();
check("8 alloggi elencati", schede === TAPPE_ATTESE, `trovati ${schede}`);

const href = await page.locator("#stays .linkbtn").evaluateAll((as) =>
  as.filter((a) => a.tagName === "A").map((a) => a.href)
);
check("i link portano a Maps o Booking", href.length > 0 &&
  href.every((u) => /^https:\/\/(www\.google\.com\/maps|www\.booking\.com)\//.test(u)),
  href.find((u) => !/^https:\/\/(www\.google\.com\/maps|www\.booking\.com)\//.test(u)) || "");

const totale = await page.locator("#stays .total .big").textContent();
check("totale alloggi calcolato", /\d/.test(totale || ""), `"${totale}"`);

console.log("Smoke test — casella richieste");
await page.locator('.tabs button[data-view="ask"]').click();
await page.locator("#askText").fill("test");
await page.locator("#askSend").click();
check("rifiuta una richiesta troppo corta", (await page.locator("#askMsg").textContent()).length > 0);

console.log("Smoke test — console");
check("nessun errore JavaScript", errori.length === 0, errori.slice(0, 3).join(" | "));

await browser.close();
server.close();

console.log(falliti ? `\n${falliti} controlli falliti.` : "\nTutti i controlli passati.");
process.exit(falliti ? 1 : 0);
