#!/usr/bin/env bash
# Sostituisce il token di Claude Code usato dai runner sul VPS.
#
# Serve quando il token va ruotato: è condiviso dal runner di questo progetto e da
# quello di habit-tracker, quindi va aggiornato in due file.
#
# Prima, sul VPS, genera il token nuovo (è interattivo, apre un URL da aprire nel
# browser e chiede di incollare un codice):
#
#     ssh root@hetzi-fabio
#     su - runner -c 'claude setup-token'
#
# Poi, dal Mac, in questa cartella:
#
#     ./runner/aggiorna-token-claude.sh
#
# Il valore si digita a schermo, non viene mostrato e non passa come argomento di
# comando, quindi non finisce in `ps` né nella cronologia della shell.
set -euo pipefail

VPS=${VPS:-root@hetzi-fabio}

printf 'Incolla il nuovo token (sk-ant-oat...): ' >&2
read -rs TOKEN
printf '\n' >&2
[ -n "$TOKEN" ] || { echo "Valore vuoto, esco." >&2; exit 1; }
case "$TOKEN" in
  sk-ant-oat*) ;;
  *) echo "Non sembra un token di Claude Code (atteso sk-ant-oat...), esco." >&2; exit 1 ;;
esac

printf '%s\n' "$TOKEN" | ssh "$VPS" '
  read -r T
  for f in /root/runner/env /root/runner-viaggi/env; do
    [ -f "$f" ] || { echo "salto $f (non esiste)"; continue; }
    sed -i "/^CLAUDE_CODE_OAUTH_TOKEN=/d" "$f"
    printf "CLAUDE_CODE_OAUTH_TOKEN=%s\n" "$T" >> "$f"
    chmod 600 "$f"
    echo "aggiornato $f"
  done
'

echo
echo "Fatto. Il token vecchio non è più in uso, quindi le copie rimaste nel journal"
echo "di systemd non servono più a nessuno."
