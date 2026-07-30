# Viaggio Costa Rica 2026

Web app mobile per consultare l'itinerario del viaggio di famiglia in Costa Rica
(31 luglio – 17 agosto 2026: Fabio, Eleonora, Irene, Viola).

## Come funziona

Un unico file, `index.html`, senza dipendenze: dati embedded in JS, CSS con token
per tema chiaro e scuro, accordion per giornata, quattro viste (Giorni, Tappe,
Alloggi, Migliora). In produzione su **https://viaggi.fabiocrestoni.it**, progetto
Vercel `viaggio-costa-rica` collegato a questo repo: ogni push su `main` pubblica.

Esiste anche un vecchio Artifact
(https://claude.ai/code/artifact/2a7620b8-ec7b-4fd2-97cf-fc3d0ab7875a) fermo alla
versione senza meteo: il meteo live chiama Open-Meteo e la CSP degli Artifact
blocca le richieste esterne. **La versione buona è quella su Vercel.**

## Pipeline della casella richieste

Dalla vista "Migliora" si scrive una modifica; se i controlli passano va online da
sola. Il modello è quello di `habit-tracker` (vedi lì `docs/auto-pipeline-spec.md`),
con una differenza: **il cancello gira su GitHub Actions, non sul VPS** — il repo è
pubblico, quindi i minuti sono gratis e i 4 GB del CX23 restano liberi.

```
casella sul sito → POST /api/richieste (verifica PIN)
      → issue GitHub con label auto-request        [token CASELLA: solo issues]
      → viaggi-runner.timer sul VPS, ogni 5 min, flock
      → claude -p nel clone /home/runner/work, senza rete né segreti
      → PR → smoke test su GitHub Actions          [token RUNNER: contents+PR+issues]
      → verde e nessun file protetto → merge squash → Vercel pubblica
      → commento con link e commit, issue chiusa
```

- Segreti: `REQUEST_PIN` e `GITHUB_TOKEN_ISSUES` su Vercel; `GITHUB_TOKEN` e
  `CLAUDE_CODE_OAUTH_TOKEN` in `/root/runner-viaggi/env` sul VPS (600). Il token
  Claude è lo stesso dell'abbonamento già usato dal runner di habit-tracker.
  Si (re)inseriscono con `./setup-segreti.sh`, che li legge da input.
- **File protetti**, mai auto-mergiati: `runner/`, `.github/`, `tests/`, `api/`,
  `package*.json`, `vercel.json`, `CLAUDE.md`. Il gate può essere verde: serve
  comunque il merge umano. `tests/` è protetto perché indebolire il cancello
  renderebbe l'auto-merge una firma in bianco.
- **Una richiesta = un tentativo**: se il branch `auto/issue-N` esiste già, la issue
  viene chiusa con l'invito a riformulare.
- Il testo della richiesta è un **requisito, non istruzioni all'agente**: il prompt
  in `runner/prompt-template.md` lo dice esplicitamente, perché la casella è un
  ingresso di testo non fidato verso un agente che scrive codice.
- Comandi utili sul VPS: `systemctl list-timers viaggi-runner.timer`,
  `journalctl -u viaggi-runner -n 50`, log in `/var/log/viaggi-runner-*.log`.

## Storage condiviso — predisposto, non ancora usato

Serve a tenere delle spunte visibili da **tutti** i dispositivi (cose da prenotare,
valigia, attività fatte). Backend pronto e collaudato il 30/7, nessuna UI: la
sezione con le checkbox si aggancia quando serve.

- **Upstash Redis** dal Marketplace Vercel, risorsa `viaggio-spunte`, collegata a
  production e preview. Variabili iniettate: `KV_REST_API_URL`, `KV_REST_API_TOKEN`,
  `KV_REST_API_READ_ONLY_TOKEN`, `KV_URL`, `REDIS_URL`. Attenzione: si chiamano
  `KV_*`, quindi `Redis.fromEnv()` di `@upstash/redis` **non** le troverebbe (cerca
  `UPSTASH_*`). `api/stato.js` parla con l'API REST via `fetch`, così il progetto
  resta senza dipendenze a runtime.
- Un solo hash Redis, `viaggio:spunte`: campo = chiave della spunta, valore =
  `{"v":true,"t":"<ISO>"}`. Tetto di 300 chiavi, 50 per richiesta, chiavi
  `^[a-z0-9][a-z0-9:_-]{0,63}$`.

```
GET  /api/stato   → {"spunte":{"prenota:manuel-antonio":true},"aggiornato":"…"}
                    lettura libera, senza PIN: le spunte non sono un segreto e
                    così le vede anche chi non ha il PIN
POST /api/stato   → {"pin":"…","patch":{"prenota:manuel-antonio":true,"vecchia":null}}
                    null cancella la chiave; risponde con lo stato aggiornato
```

**Per agganciare la UI** servono tre cose: leggere lo stato al montaggio della
vista e riflettere le spunte; su `change` di una checkbox mandare la patch della
sola chiave toccata (non tutto lo stato, altrimenti due telefoni si sovrascrivono);
scrivere subito anche in `localStorage` e partire da lì, perché in viaggio la rete
manca spesso e la spunta deve essere istantanea. Con la rete assente la POST
fallisce: va accodata e ritentata, oppure si accetta che il condiviso sia
"migliore sforzo" e il locale resti la verità sul dispositivo.

Chiavi suggerite: `prenota:<slug>` per le prenotazioni, `valigia:<slug>` per la
valigia, `fatto:g<N>:<slug>` per le attività di una giornata.

## Controlli

`npm run smoke` (Playwright, Chromium headless) serve la pagina su un server locale
e verifica ciò che si romperebbe davvero: 18 giornate, 8 tappe, le quattro viste
popolate, l'accordion che si apre, i link solo verso Maps e Booking, il totale
alloggi, e **nessuna eccezione JavaScript**. I fallimenti di rete verso Open-Meteo
sono filtrati di proposito: la pagina deve restare usabile senza meteo.

## Fonte dei dati

Il foglio Google, tab `gid=1353912160`, condiviso in lettura pubblica:
https://docs.google.com/spreadsheets/d/18fZee66ex_kRnWUK418kOjPAFTb_Md65Ld-G0UGV818/edit?gid=1353912160

Colonne: `Data | N° | Località | Attività | Spostamenti e Durata | Note | Hotel | € hotel`

L'artifact **non** legge il foglio da solo: la CSP di claude.ai blocca le richieste
verso host esterni, e le uniche capability concedibili sono `downloads` e `mcp`.
Scelta di Fabio (28 lug 2026): rigenerazione manuale via Claude, così i contenuti
vengono interpretati e non solo importati. L'alternativa scartata era una pagina su
Vercel con fetch del CSV: fattibile (CORS aperto), ma applica regole fisse.

## Flusso di aggiornamento

Quando Fabio modifica il foglio:

```bash
./sync.py          # mostra solo le celle cambiate rispetto a data/snapshot.csv
                   # riportare le modifiche in index.html
./sync.py --save   # aggiorna lo snapshot dopo aver allineato la pagina
```

Poi ripubblicare l'artifact **sullo stesso path** per conservare l'URL, e aggiornare
la data di allineamento nel footer di `index.html`.

## Interventi editoriali sui dati

Il foglio è testo libero: la pagina non lo rispecchia alla lettera, lo normalizza.
Quando si rigenera, mantenere queste scelte:

- Refusi corretti: "psicina" → piscina, "Marino Balenas" → Marino Ballena · Uvita,
  "Bogarian Trail" → Bogarín Trail, "puerto viejco" → Puerto Viejo.
- Giorno 18: la colonna Località dice "Aereo", in pagina è "Rientro a Roma".
- Le attività lunghe sono spezzate in fasce orarie (Mattina, Pranzo, Pomeriggio,
  Sera, Tramonto) e in box secondari per consigli, alternative ed extra.
- Gli hotel sono normalizzati nell'array `STAYS`: nome, zona, prezzo, data di
  cancellazione, chi ha prenotato. Sul foglio sono una cella di testo unica.
- Notte del 14/08: sul foglio la colonna Hotel è vuota, in pagina è assegnata a
  Well Melody con badge "notte non indicata sul foglio". Non darla per confermata.
- Giorni 17-18: le colonne Spostamenti (Sierpe, Golfo Dulce, Corcovado) non sono
  coerenti col resto e sono etichettate "variante sul foglio".
- Ogni struttura ha due pulsanti, Mappa e Booking, nei campi `maps` e `booking`
  di `STAYS`. Il link Maps è una **ricerca per nome** (`maps/search/?api=1&query=`),
  non coordinate: resta valido anche se cambia l'indirizzo. Gli URL Booking sono
  verificati uno per uno; "Villa pratz" del foglio corrisponde a Hotel Villa Prats
  (camera quadrupla economy con colazione e piscina). Well Melody non risulta su
  Booking: mostra un pulsante disattivato, non inventare un URL.

## Nota sulle date

La colonna Data del foglio ha un formato personalizzato che nell'export CSV perde
mese e anno (`Friday,  31,`). Le date in pagina sono scritte per esteso nei dati
embedded. Se un giorno si passasse al parsing automatico, vanno ricostruite dalla
progressione a partire dal 31/07/2026 e verificate contro il giorno della settimana.
