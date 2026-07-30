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
