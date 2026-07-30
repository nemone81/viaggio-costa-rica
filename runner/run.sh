#!/usr/bin/env bash
# Runner della casella richieste: una richiesta scritta sul sito diventa una
# modifica pubblicata, se lo smoke test passa.
#
# Gira come root da systemd timer (viaggi-runner.timer). Un run = al più UNA issue:
# prende la più vecchia con label auto-request, la dà a Claude Code (utente `runner`,
# nel clone di lavoro, senza alcun segreto), apre una PR e lascia che il cancello sia
# GitHub Actions. Verde → merge, e Vercel pubblica da sé. Ogni esito torna sulla
# issue come commento.
#
# Differenza dal runner di habit-tracker: qui i test NON girano sul VPS (niente
# npm, niente Chromium sui 4 GB della macchina), girano su Actions. Il runner
# aspetta il check e decide.
#
# Config in /root/runner-viaggi/env (vedi env.example).
set -euo pipefail

# Sotto systemd HOME non esiste: git --global e gh ne hanno bisogno.
export HOME=${HOME:-/root}

ENV_FILE=${ENV_FILE:-/root/runner-viaggi/env}
RUNNER_HOME=/home/runner
WORK=$RUNNER_HOME/work/viaggio-costa-rica
TEMPLATE=$(dirname "$0")/prompt-template.md
CLAUDE=${CLAUDE:-/usr/local/bin/claude}
CLAUDE_TIMEOUT=${CLAUDE_TIMEOUT:-1200}   # 20 min di tetto alla fase Claude
CHECKS_TIMEOUT=${CHECKS_TIMEOUT:-900}    # 15 min di attesa per GitHub Actions
DEPLOY_TIMEOUT=${DEPLOY_TIMEOUT:-240}    # 4 min perché Vercel pubblichi
SITE=${SITE:-https://viaggi.fabiocrestoni.it}

# File che il pipeline non può auto-mergiarsi: sé stesso, il cancello, le
# dipendenze e la funzione che valida il PIN. Il gate può essere verde: qui
# serve comunque un merge umano.
PROTECTED_RE='^(runner/|\.github/|tests/|api/|package(-lock)?\.json|vercel\.json|CLAUDE\.md)'

exec 9>/var/lock/viaggi-runner.lock
flock -n 9 || { echo "run già in corso, esco"; exit 0; }

# shellcheck source=/dev/null
source "$ENV_FILE"   # GITHUB_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, REPO, HEALTHCHECK_URL_RUNNER?
: "${GITHUB_TOKEN:?}" "${CLAUDE_CODE_OAUTH_TOKEN:?}" "${REPO:?}"
export GH_TOKEN=$GITHUB_TOKEN

hc() { [ -n "${HEALTHCHECK_URL_RUNNER:-}" ] && curl -fsS -m 10 "$HEALTHCHECK_URL_RUNNER$1" >/dev/null 2>&1 || true; }
log() { echo "$(date -Is) $*"; }

# Il clone appartiene a `runner` ma i git di orchestrazione li fa root.
git config --global --add safe.directory "$WORK" 2>/dev/null || true

# git autenticato senza scrivere il token nel clone: GIT_ASKPASS risponde ai
# prompt, la remote resta https pulita, così Claude non legge credenziali.
ASKPASS=$(mktemp)
chmod 700 "$ASKPASS"
cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  Username*) echo "x-access-token" ;;
  *)         echo "$GITHUB_TOKEN" ;;
esac
EOF
trap 'rm -f "$ASKPASS"' EXIT

gitauth() { GIT_ASKPASS="$ASKPASS" GITHUB_TOKEN="$GITHUB_TOKEN" git -C "$WORK" "$@"; }

chiudi_male() { # $1=numero issue, $2=motivo (markdown)
  gh issue comment "$1" --repo "$REPO" --body "$2" || true
  gh issue edit "$1" --repo "$REPO" --add-label auto-failed --remove-label in-progress || true
}

# ── 1. La coda: la issue aperta più vecchia con label auto-request ──────────────
# Le auto-failed restano fuori: un tentativo per richiesta, chi vuole ritentare
# riformula una richiesta nuova.
ISSUE_JSON=$(gh issue list --repo "$REPO" --label auto-request --state open \
  --json number,title,body,labels --limit 50 |
  jq -c '[.[] | select((.labels // []) | map(.name) | index("auto-failed") | not)] | sort_by(.number) | .[0] // empty')

if [ -z "$ISSUE_JSON" ]; then
  hc ""
  log "coda vuota"
  exit 0
fi

N=$(jq -r .number <<<"$ISSUE_JSON")
TITLE=$(jq -r .title <<<"$ISSUE_JSON")
BODY=$(jq -r .body <<<"$ISSUE_JSON")
BRANCH="auto/issue-$N"
log "lavoro la issue #$N: $TITLE"

# Una richiesta = un tentativo: se il branch esiste già, è stata tentata.
if gh api "repos/$REPO/branches/$BRANCH" >/dev/null 2>&1; then
  chiudi_male "$N" "Questa richiesta era già stata tentata (branch \`$BRANCH\` esistente). Scrivine una nuova riformulata."
  gh issue close "$N" --repo "$REPO" || true
  exit 0
fi

gh issue edit "$N" --repo "$REPO" --add-label in-progress || true

# ── 2. Clone di lavoro fresco su main ───────────────────────────────────────────
if [ ! -d "$WORK/.git" ]; then
  install -d -o runner -g runner "$(dirname "$WORK")"
  GIT_ASKPASS="$ASKPASS" GITHUB_TOKEN="$GITHUB_TOKEN" git clone "https://github.com/$REPO" "$WORK"
fi
gitauth fetch origin
git -C "$WORK" checkout -f main
git -C "$WORK" reset --hard origin/main
git -C "$WORK" clean -fd -e node_modules
git -C "$WORK" checkout -B "$BRANCH"
chown -R runner:runner "$WORK"

# ── 3. Claude Code, come utente runner, nel clone, con strumenti limitati ───────
PROMPT=$(sed -e "s/{{ISSUE_NUMBER}}/$N/" -e "s/{{ISSUE_TITLE}}/$(printf '%s' "$TITLE" | sed 's/[&/\]/\\&/g')/" "$TEMPLATE")
PROMPT="$PROMPT

--- RICHIESTA (issue #$N) ---
$BODY"

CLAUDE_LOG=/var/log/viaggi-runner-claude.log
set +e
timeout "$CLAUDE_TIMEOUT" sudo -u runner env -i \
  HOME="$RUNNER_HOME" PATH="/usr/local/bin:/usr/bin:/bin:$RUNNER_HOME/.local/bin" \
  CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
  bash -c "cd '$WORK' && '$CLAUDE' -p \"\$0\" --permission-mode acceptEdits \
    --allowedTools 'Edit,Write,Read,Glob,Grep,Bash(git diff:*),Bash(git status:*),Bash(git log:*)' \
    --max-turns 60 --output-format text" "$PROMPT" > "$CLAUDE_LOG" 2>&1
CLAUDE_RC=$?
set -e
if [ $CLAUDE_RC -ne 0 ]; then
  chiudi_male "$N" "Claude Code è uscito con errore (rc=$CLAUDE_RC, tetto ${CLAUDE_TIMEOUT}s). Log sul server: \`$CLAUDE_LOG\`."
  exit 0
fi

if git -C "$WORK" diff --quiet && [ -z "$(git -C "$WORK" ls-files --others --exclude-standard)" ]; then
  chiudi_male "$N" "Claude non ha prodotto alcuna modifica. Riformula la richiesta con più dettagli su cosa cambiare e dove."
  exit 0
fi

# ── 4. Commit, push, PR ─────────────────────────────────────────────────────────
git -C "$WORK" add -A
git -C "$WORK" -c user.name="viaggi-runner" -c user.email="runner@viaggi.fabiocrestoni.it" \
  commit -m "Auto: $TITLE (#$N)" -m "Richiesta dalla casella del sito. Issue #$N." >/dev/null
gitauth push -u origin "$BRANCH"

PR_URL=$(gh pr create --repo "$REPO" --head "$BRANCH" --base main \
  --title "Auto: $TITLE (#$N)" \
  --body "Closes #$N — generata dal runner della casella richieste." | tail -1)
log "PR aperta: $PR_URL"

# ── 5. Il cancello: lo smoke test su GitHub Actions ─────────────────────────────
set +e
timeout "$CHECKS_TIMEOUT" gh pr checks "$BRANCH" --repo "$REPO" --watch --fail-fast > /var/log/viaggi-runner-checks.log 2>&1
CHECKS_RC=$?
set -e

if [ $CHECKS_RC -ne 0 ]; then
  chiudi_male "$N" "**Smoke test rosso**: la modifica è pronta in $PR_URL ma i controlli non passano, quindi non va online.

\`\`\`
$(tail -12 /var/log/viaggi-runner-checks.log)
\`\`\`"
  exit 0
fi

# ── 6. File protetti → PR sì, merge no ──────────────────────────────────────────
if git -C "$WORK" diff --name-only origin/main..HEAD | grep -qE "$PROTECTED_RE"; then
  chiudi_male "$N" "La modifica tocca **file protetti** (runner, cancello, dipendenze o funzione del PIN): i controlli sono verdi ma serve il merge umano → $PR_URL"
  exit 0
fi

# ── 7. Merge: Vercel pubblica da sé ─────────────────────────────────────────────
gh pr merge "$BRANCH" --repo "$REPO" --squash --delete-branch
gitauth fetch origin
git -C "$WORK" checkout -f main
git -C "$WORK" reset --hard origin/main
COMMIT=$(git -C "$WORK" rev-parse --short origin/main)

# ── 8. Verifica che il sito sia davvero su ──────────────────────────────────────
ONLINE=no
for _ in $(seq 1 $((DEPLOY_TIMEOUT / 15))); do
  sleep 15
  CODE=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$SITE" || true)
  if [ "$CODE" = "200" ]; then ONLINE=yes; break; fi
done

gh issue edit "$N" --repo "$REPO" --remove-label in-progress || true

if [ "$ONLINE" = yes ]; then
  gh issue comment "$N" --repo "$REPO" --body "**Online** — $PR_URL (commit \`$COMMIT\`). Ricarica $SITE per vederla."
else
  gh issue comment "$N" --repo "$REPO" --body "Modifica mergiata (commit \`$COMMIT\`, $PR_URL) ma $SITE non ha risposto 200 entro ${DEPLOY_TIMEOUT}s: controlla il deploy su Vercel."
fi
gh issue close "$N" --repo "$REPO"
hc ""
log "issue #$N completata ($COMMIT, online=$ONLINE)"
