#!/usr/bin/env bash
# Inserisce i tre segreti della pipeline e accende il runner.
#
# Da lanciare una volta sola, dal Mac, dentro questa cartella:
#
#     ./setup-segreti.sh
#
# I valori si digitano a schermo (non vengono mostrati) e non passano mai come
# argomenti di comando, quindi non finiscono in `ps` né nella cronologia shell.
#
# Prima di lanciarlo servono due token fine-grained su
# github.com/settings/personal-access-tokens/new, entrambi limitati al solo
# repository nemone81/viaggio-costa-rica:
#
#   token CASELLA  → permesso: Issues (read and write)
#                    lo usa la funzione /api/richieste per accodare le richieste
#   token RUNNER   → permessi: Contents (rw), Pull requests (rw), Issues (rw)
#                    lo usa il runner sul VPS per aprire PR e mergiare
#
# Sono separati di proposito: così il sito in produzione non ha modo di scrivere
# codice, può solo aprire issue.
set -euo pipefail

VPS=${VPS:-root@hetzi-fabio}
SCOPE=nemone81s-projects

chiedi() { # $1=prompt
  local v
  printf '%s: ' "$1" >&2
  read -rs v
  printf '\n' >&2
  [ -n "$v" ] || { echo "Valore vuoto, esco." >&2; exit 1; }
  printf '%s' "$v"
}

echo "== 1/4  PIN della casella =="
PIN=$(chiedi "Scegli il PIN (quello che digiterai sul sito)")
for env in production preview; do
  printf '%s' "$PIN" | vercel env add REQUEST_PIN "$env" --force --yes --scope "$SCOPE" >/dev/null
done
echo "PIN impostato su Vercel (production e preview)."

echo "== 2/4  Token GitHub della casella =="
TOK_ISSUES=$(chiedi "Incolla il token CASELLA (Issues rw)")
for env in production preview; do
  printf '%s' "$TOK_ISSUES" | vercel env add GITHUB_TOKEN_ISSUES "$env" --force --yes --scope "$SCOPE" >/dev/null
done
echo "Token della casella impostato."

echo "== 3/4  Token GitHub del runner (va sul VPS) =="
TOK_RUNNER=$(chiedi "Incolla il token RUNNER (Contents + PR + Issues rw)")
printf '%s\n' "$TOK_RUNNER" | ssh "$VPS" '
  read -r T
  install -d -m 700 /root/runner-viaggi
  sed -i "/^GITHUB_TOKEN=/d" /root/runner-viaggi/env
  printf "GITHUB_TOKEN=%s\n" "$T" >> /root/runner-viaggi/env
  chmod 600 /root/runner-viaggi/env
  echo "env aggiornato sul VPS"
'

echo "== 4/4  Accendo il runner e ripubblico =="
if [ -n "$(git status --porcelain)" ]; then
  echo "Attenzione: hai modifiche locali non committate. Il deploy pubblicherebbe queste,"
  echo "non quelle su main. Committa e ripeti, oppure conferma per procedere comunque."
  read -rp "Procedo? [s/N] " ok
  [ "$ok" = s ] || exit 1
fi
ssh "$VPS" 'systemctl enable --now viaggi-runner.timer && systemctl list-timers viaggi-runner.timer --no-pager | sed -n 2p'
vercel deploy --prod --scope "$SCOPE" >/dev/null
echo
echo "Fatto. Prova dal telefono: apri https://viaggi.fabiocrestoni.it, vista Migliora,"
echo "scrivi una richiesta banale e guarda la coda su"
echo "https://github.com/nemone81/viaggio-costa-rica/issues"
