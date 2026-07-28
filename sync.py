#!/usr/bin/env python3
"""Scarica il foglio Google e mostra solo le celle cambiate dall'ultimo allineamento.

    ./sync.py          confronta il foglio con lo snapshot e stampa le differenze
    ./sync.py --save   salva lo stato attuale come nuovo riferimento

Lo snapshot in data/snapshot.csv è la fotografia del foglio al momento
dell'ultima rigenerazione di index.html. Serve a rispondere a una sola
domanda: cosa devo riportare nella pagina?
"""

import csv
import re
import subprocess
import sys
from pathlib import Path

SHEET_ID = "18fZee66ex_kRnWUK418kOjPAFTb_Md65Ld-G0UGV818"
GID = "1353912160"
CSV_URL = f"https://docs.google.com/spreadsheets/d/{SHEET_ID}/export?format=csv&gid={GID}"

ROOT = Path(__file__).parent
SNAPSHOT = ROOT / "data" / "snapshot.csv"


def fetch():
    out = subprocess.run(
        ["curl", "-sL", "--fail", CSV_URL], capture_output=True, text=True
    )
    if out.returncode != 0:
        sys.exit("Foglio non raggiungibile. Se la condivisione è tornata privata, l'export CSV risponde con una pagina di login.")
    if not out.stdout.lstrip().startswith("Data,"):
        sys.exit("Risposta inattesa: il foglio non sembra più pubblico o le colonne sono cambiate.")
    return out.stdout


def rows(text):
    return list(csv.reader(text.splitlines()))


def norm(s):
    return re.sub(r"\s+", " ", s or "").strip()


def main():
    text = fetch()
    now = rows(text)

    if "--save" in sys.argv or not SNAPSHOT.exists():
        SNAPSHOT.parent.mkdir(exist_ok=True)
        SNAPSHOT.write_text(text)
        print(f"Snapshot salvato: {SNAPSHOT} ({len(now) - 1} giorni)")
        return

    before = rows(SNAPSHOT.read_text())
    header = now[0]
    changes = 0

    for i in range(1, max(len(before), len(now))):
        a = before[i] if i < len(before) else []
        b = now[i] if i < len(now) else []
        if not b:
            print(f"— giorno {i}: riga rimossa dal foglio")
            changes += 1
            continue
        if not a:
            print(f"+ giorno {i}: riga nuova — {norm(b[2]) if len(b) > 2 else ''}")
            changes += 1
            continue
        for c, col in enumerate(header):
            va = norm(a[c]) if c < len(a) else ""
            vb = norm(b[c]) if c < len(b) else ""
            if va != vb:
                changes += 1
                print(f"\n=== giorno {i} · {col}")
                print(f"  prima: {va[:300] or '(vuoto)'}")
                print(f"   dopo: {vb[:300] or '(vuoto)'}")

    print(f"\n{changes} celle cambiate." if changes else "\nNessuna modifica: la pagina è allineata al foglio.")
    if changes:
        print("Riporta le modifiche in index.html, poi esegui ./sync.py --save")


if __name__ == "__main__":
    main()
