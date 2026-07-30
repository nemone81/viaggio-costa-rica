#!/usr/bin/env python3
"""Genera le icone del sito da un'illustrazione quadrata.

    python3 tools/genera-icone.py <immagine.png>

L'originale è il bradipo con gli occhiali a bandiera appeso al ramo, con il
vulcano e il lago sullo sfondo. Serve un'immagine **quadrata e piena fino ai
bordi**: iOS e Android applicano la loro maschera, quindi angoli arrotondati o
margini bianchi già disegnati diventerebbero aloni chiari sugli spigoli.

L'icona maskable è l'immagine intera, non una versione rimpicciolita con
margine: Android ritaglia al massimo il 20% del lato e qui il muso del bradipo
sta comodamente al centro, quindi si perde solo un po' di fogliame.

Dipende da Pillow, che al sito non serve: si esegue a mano quando l'icona cambia.
"""

import sys
from pathlib import Path

from PIL import Image

DEST = Path(__file__).resolve().parent.parent / "icons"

MISURE = [
    ("apple-touch-icon.png", 180),   # iOS, aggiunta alla schermata Home
    ("icon-192.png", 192),           # Android, icona dell'app installata
    ("icon-512.png", 512),           # splash e store dell'app installata
    ("icon-maskable-512.png", 512),  # Android, con la sua maschera sopra
    ("favicon-32.png", 32),          # scheda del browser
]


def quadra(im: Image.Image) -> Image.Image:
    """Ritaglia al quadrato centrale, se l'originale non lo è già."""
    w, h = im.size
    if w == h:
        return im
    lato = min(w, h)
    sx, sy = (w - lato) // 2, (h - lato) // 2
    print(f"immagine {w}x{h} non quadrata: ritaglio centrale {lato}x{lato}")
    return im.crop((sx, sy, sx + lato, sy + lato))


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("Uso: python3 tools/genera-icone.py <immagine.png>")

    originale = quadra(Image.open(sys.argv[1]).convert("RGB"))
    print(f"sorgente: {originale.size[0]}x{originale.size[1]}")

    DEST.mkdir(exist_ok=True)
    for nome, lato in MISURE:
        originale.resize((lato, lato), Image.LANCZOS).save(DEST / nome, optimize=True)
        peso = (DEST / nome).stat().st_size // 1024
        print(f"  {nome:24} {lato:>4}x{lato:<4} {peso:>4} KB")


if __name__ == "__main__":
    main()
