#!/bin/bash
# Validation guidée de l'instance macstatusd en cours d'exécution, en passant
# réellement par chaque état du Mac.
#
# Contrairement à selftest.sh, ce script demande des actions manuelles
# (verrouillage, économiseur, extinction d'écran, veille). Il enregistre en
# continu ce que macstatusd rapporte et vérifie automatiquement chaque étape.
#
#   ./scripts/validate-live.sh [port] [chemin/du/journal]
set -uo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "!! À lancer sans sudo : root ne voit ni ton journal ni ta session." >&2
  echo "   ./scripts/validate-live.sh" >&2
  exit 1
fi

PORT="${1:-9090}"
LOGFILE="${2:-$HOME/Library/Logs/macstatusd/macstatusd.log}"
BASE="http://127.0.0.1:$PORT"
REC="$(mktemp /tmp/macstatusd-live.XXXXXX)"
PASS=0
FAIL=0

cleanup() { [[ -n "${REC_PID:-}" ]] && kill "$REC_PID" 2>/dev/null; rm -f "$REC"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

curl -fsS --max-time 2 "$BASE/health" >/dev/null || {
  echo "macstatusd ne répond pas sur $BASE — vérifie qu'il tourne (launchctl list | grep macstatusd)"
  exit 1
}

# Enregistreur : une ligne JSON compacte toutes les 400 ms, tolérant aux pannes
# (la machine peut être endormie).
(
  while true; do
    curl -fsS --max-time 1 "$BASE/status" 2>/dev/null | python3 -c "
import json, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
f = d['facts']
print(json.dumps({
    't': time.time(), 'state': d['state'], 'reason': d['reason'],
    'locked': f['session_locked'], 'display_asleep': f['display_asleep'],
    'saver': f['screensaver_active'], 'saver_evidence': f['screensaver_evidence'],
    'saver_running': f.get('screensaver_running', False),
    'saver_dismissed': f.get('screensaver_dismissed', False),
    'hid_idle': f.get('hid_idle_seconds', -1),
    'secure_input': f['secure_input_active'], 'asleep': f['system_asleep'],
}), flush=True)
" >> "$REC"
    sleep 0.4
  done
) & REC_PID=$!

MARK=0
LOGMARK=0
# La fenêtre d'observation doit commencer AVANT l'action, sinon on ne mesure que
# le retour au bureau.
window_start() {
  MARK=$(wc -l < "$REC" | tr -d ' ')
  LOGMARK=$(wc -l < "$LOGFILE" 2>/dev/null | tr -d ' ')
  [[ -n "$LOGMARK" ]] || LOGMARK=0
}
# Ne cherche que dans ce que le daemon a journalisé pendant l'étape.
log_since_mark() { tail -n "+$((LOGMARK + 1))" "$LOGFILE" 2>/dev/null; }
# window_has <expression python sur la variable r> : vrai si un échantillon
# enregistré depuis window_start satisfait l'expression.
window_has() {
  python3 - "$REC" "$MARK" "$1" <<'PY'
import json, sys
path, mark, expr = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lines = open(path).read().splitlines()[mark:]
for line in lines:
    try:
        r = json.loads(line)
    except Exception:
        continue
    if eval(expr, {}, {'r': r}):
        print(json.dumps(r))
        sys.exit(0)
sys.exit(1)
PY
}
step() {
  echo
  echo "── $1"
  echo "   $2"
  window_start          # avant l'action, pas après
  echo -n "   Appuie sur [Entrée] une fois l'action terminée. "
  read -r _
  sleep 0.5             # laisse l'enregistreur écrire le dernier échantillon
}

echo "==> Validation en direct de macstatusd sur $BASE"
echo "    journal: $LOGFILE"
echo "    Chaque étape est vérifiée automatiquement à partir de ce que macstatusd rapporte."

# 1. Bureau
step "Étape 1/5 — bureau déverrouillé" "Reste sur ton bureau, session déverrouillée,"
if window_has >/dev/null "r['state']=='1' and not r['locked'] and not r['saver']"; then
  ok "bureau déverrouillé → ON"
else
  bad "bureau déverrouillé: ON attendu, obtenu $(curl -fsS "$BASE/state")"
fi

# 2. Écran de verrouillage
step "Étape 2/5 — écran de verrouillage avec champ mot de passe" \
     "Verrouille (Ctrl-Cmd-Q), laisse le champ mot de passe visible ~5 s, déverrouille, reviens ici,"
if RES=$(window_has "r['locked'] and not r['display_asleep'] and not r['saver'] and r['state']=='1'"); then
  ok "verrouillé + écran allumé → ON  ($(echo "$RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("reason="+d["reason"]+" secure_input="+str(d["secure_input"]))'))"
else
  bad "aucun échantillon « verrouillé, écran allumé, ON » — l'écran s'est peut-être éteint trop vite"
fi
if window_has >/dev/null "not r['locked'] and r['state']=='1'"; then
  ok "retour au bureau après déverrouillage → ON"
else
  bad "état ON non retrouvé après déverrouillage"
fi

# 3. Économiseur d'écran, puis panneau de mot de passe par-dessus
step "Étape 3/5 — économiseur, puis champ de mot de passe" \
     "Lance l'économiseur (coin actif, ou: open -a ScreenSaverEngine), NE TOUCHE À RIEN ~8 s,
   puis appuie UNE fois sur une touche pour faire apparaître le champ de mot de passe,
   attends ~8 s SANS déverrouiller, puis déverrouille et reviens ici,"
if RES=$(window_has "r['saver'] and r['state']=='0'"); then
  ok "économiseur seul à l'écran → OFF  (preuve: $(echo "$RES" | python3 -c 'import json,sys;print(json.load(sys.stdin)["saver_evidence"])'))"
else
  bad "économiseur non détecté (aucun échantillon économiseur actif avec état OFF)"
fi
# Le cœur du problème : le process de l'économiseur survit derrière le panneau
# d'authentification. L'état doit repasser à ON AVANT le déverrouillage.
if RES=$(window_has "r['saver_running'] and r['locked'] and not r['display_asleep'] and r['state']=='1'"); then
  ok "champ de mot de passe par-dessus l'économiseur → ON avant déverrouillage"
  echo "        $(echo "$RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("raison="+d["reason"]+", preuve="+d["saver_evidence"]+", idleHID="+str(d["hid_idle"])+"s")')"
else
  bad "état non repassé à ON à l'apparition du champ de mot de passe"
fi
if window_has >/dev/null "not r['locked'] and r['state']=='1'"; then
  ok "retour au bureau après déverrouillage → ON"
else
  bad "retour à ON non observé après déverrouillage"
fi

# 4. Écran éteint
step "Étape 4/5 — écran éteint" \
     "Éteins l'écran (Ctrl-Maj-Éject, ou: pmset displaysleepnow), attends ~6 s, réveille-le, reviens ici,"
if window_has >/dev/null "r['display_asleep'] and r['state']=='0'"; then
  ok "écran éteint → OFF"
else
  bad "extinction d'écran non détectée"
fi
if window_has >/dev/null "not r['display_asleep'] and r['state']=='1'"; then
  ok "réveil de l'écran → ON"
else
  bad "retour à ON non observé après réveil de l'écran"
fi

# 5. Veille système
step "Étape 5/5 — veille système" \
     "Mets le Mac en veille (menu Pomme > Suspendre), attends ~10 s, réveille-le, déverrouille, reviens ici,"
if log_since_mark | grep -q "veille imminente"; then
  ok "veille détectée par IOKit (OFF poussé avant le gel du daemon)"
else
  bad "aucune trace « veille imminente » dans $LOGFILE"
fi
if log_since_mark | grep -qE "réveil système|interruption de"; then
  ok "réveil détecté et resynchronisation effectuée"
else
  bad "aucune trace de réveil/resynchronisation dans le journal"
fi
if window_has >/dev/null "r['state']=='1'"; then
  ok "état ON retrouvé après le réveil"
else
  bad "état ON non retrouvé après le réveil"
fi

# 6. Commandes HomeKit
echo
echo "── Commandes HomeKit (déclenchées par ce script)"
window_start
curl -fsS --max-time 2 "$BASE/sleep" >/dev/null && echo "   /sleep envoyé"
sleep 4
if window_has >/dev/null "r['state']=='0'"; then ok "/sleep → OFF"; else bad "/sleep n'a pas produit OFF"; fi
window_start
curl -fsS --max-time 2 "$BASE/wake" >/dev/null && echo "   /wake envoyé"
sleep 4
if window_has >/dev/null "r['state']=='1'"; then ok "/wake → ON"; else bad "/wake n'a pas produit ON"; fi

echo
echo "==================================="
printf 'Résultat: %d OK, %d échec(s)\n' "$PASS" "$FAIL"
echo
echo "Transitions observées pendant la session:"
python3 - "$REC" <<'PY'
import json
prev = None
for line in open(__import__('sys').argv[1]):
    try:
        r = json.loads(line)
    except Exception:
        continue
    key = (r['state'], r['reason'])
    if key != prev:
        print(f"   {r['state']}  {r['reason']}")
        prev = key
PY
[[ $FAIL -eq 0 ]]
