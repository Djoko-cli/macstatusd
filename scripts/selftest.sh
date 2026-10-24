#!/bin/bash
# Suite de tests automatisée, hermétique et NON intrusive : rien n'est verrouillé,
# endormi ni éteint sur la session en cours, et rien ne sort de la machine.
#
# Principe :
#   - `swift test` joue d'abord les tests unitaires de MacStatusCore ;
#   - un faux binaire nommé ScreenSaverEngine simule l'économiseur d'écran, sur demande seulement
#     (SELFTEST_FAUX_ECONOMISEUR=1, daemon réel arrêté : sinon il le verrait aussi ; c'est
#     exactement ce que l'oracle « process » observe) ;
#   - un serveur HTTP local joue le rôle de Homebridge pour les webhooks ;
#   - chaque instance de test écoute sur 127.0.0.1, sur un port de 19000 à 19999,
#     avec des commandes inertes (/usr/bin/true) et sans escalade : un /on ou un
#     /off ne touche jamais l'écran du Mac.
#
# Si l'écran est éteint, la session verrouillée ou le Mac en veille au départ, les
# sections qui dépendent d'un écran allumé sont marquées SAUTÉ, sans compter en
# échec. Pour éprouver cette branche sans rien éteindre :
#
#   SELFTEST_FORCER_ECRAN_ETEINT=1 ./scripts/selftest.sh
#
# Une session verrouillée fait elle aussi SAUTER ces sections par défaut. Seul
# SELFTEST_IGNORER_VERROU=1 les rend jouables malgré le verrou (par exemple depuis
# une session distante) :
#
#   SELFTEST_IGNORER_VERROU=1 ./scripts/selftest.sh
#
# Le dossier de compilation de Swift est un dossier temporaire (supprimé à la
# sortie), ou SWIFT_SCRATCH s'il est défini (conservé). Il doit rester hors de
# ~/Documents : la signature du .xctest échoue sous iCloud.
#
#   ./scripts/selftest.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macstatusd-selftest.XXXXXX")"
if [[ -n "${SWIFT_SCRATCH:-}" ]]; then
  SCRATCH="$SWIFT_SCRATCH"
  SCRATCH_TEMPORAIRE=0
else
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/macstatusd-selftest-build.XXXXXX")"
  SCRATCH_TEMPORAIRE=1
fi

# Plage réservée aux instances de test : 19000-19999 (jamais 9090, l'instance réelle).
PORT_A=19090
PORT_B=19091
PORT_C=$((PORT_B + 5))
PORT_HB=19099
# Jeton de l'instance B, valeur d'essai inventée. Passé en en-tête : depuis la tâche 8,
# le jeton dans l'URL (?token=) est refusé par défaut.
JETON_B="jeton-essai-0123456789abcdef"
PASS=0
FAIL=0
SKIP=0

# Processus lancés par ce script. Ce sont des enfants du shell et on ne les
# attend qu'à l'arrêt : un PID ne peut donc pas être réattribué avant qu'on
# l'arrête (le zombie le retient). Jamais de pkill : seulement ces PID.
PIDS=()
FAKE_PID=""

arreter_pid() { # arreter_pid <pid> : TERM, puis KILL si le processus s'obstine
  local pid="$1" essais=0
  kill "$pid" 2>/dev/null || return 0
  while kill -0 "$pid" 2>/dev/null && [[ $essais -lt 30 ]]; do
    sleep 0.1
    essais=$((essais + 1))
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

cleanup() {
  local pid
  [[ -n "$FAKE_PID" ]] && arreter_pid "$FAKE_PID"
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do arreter_pid "$pid"; done
  rm -rf "$WORK"
  [[ $SCRATCH_TEMPORAIRE -eq 1 ]] && rm -rf "$SCRATCH"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

ok()   { PASS=$((PASS+1)); printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
saute() { SKIP=$((SKIP+1)); printf '  \033[33mSAUTÉ\033[0m %s (%s)\n' "$1" "$2"; }
check() { # check <description> <attendu> <obtenu>
  if [[ "$2" == "$3" ]]; then ok "$1 (= $3)"; else bad "$1 — attendu '$2', obtenu '$3'"; fi
}

state()  { curl -fsS --max-time 2 "http://127.0.0.1:$1/state" 2>/dev/null; }
# Valeur d'une clé de /status (chemin à points : facts.hid_idle_seconds).
# Renvoie `__ERREUR__` si curl ou le JSON échoue, et une chaîne vide si la clé
# est absente : on distingue ainsi « pas de commande en attente » d'une panne.
field() { # field <port> <chemin>
  local json
  json="$(curl -fsS --max-time 2 "http://127.0.0.1:$1/status" 2>/dev/null)" || { echo "__ERREUR__"; return 0; }
  printf '%s' "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for cle in sys.argv[1].split('.'):
    if isinstance(d, dict) and cle in d:
        d = d[cle]
    else:
        d = None
        break
print('' if d is None else d)" "$2" 2>/dev/null || echo "__ERREUR__"
}
code()   { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$@"; }

# Attend un état plutôt qu'un délai fixe : la latence de détection dépend de la
# machine, ce que ces tests ne doivent pas transformer en faux échec.
await_state() { # await_state <port> <attendu> <secondes>
  local deadline=$((SECONDS + $3))
  while [[ $SECONDS -lt $deadline ]]; do
    [[ "$(state "$1")" == "$2" ]] && return 0
    sleep 0.25
  done
  return 1
}
await_field() { # await_field <port> <chemin> <attendu> <secondes>
  local deadline=$((SECONDS + $4))
  while [[ $SECONDS -lt $deadline ]]; do
    [[ "$(field "$1" "$2")" == "$3" ]] && return 0
    sleep 0.25
  done
  return 1
}
await_http() { # await_http <port> <secondes>
  local deadline=$((SECONDS + $2))
  while [[ $SECONDS -lt $deadline ]]; do
    curl -fsS --max-time 1 "http://127.0.0.1:$1/health" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
await_lignes() { # await_lignes <fichier> <minimum> <secondes>
  local deadline=$((SECONDS + $3))
  while [[ $SECONDS -lt $deadline ]]; do
    [[ "$(wc -l < "$1" | tr -d ' ')" -ge "$2" ]] && return 0
    sleep 0.5
  done
  return 1
}
port_libre() { # port_libre <port> : vrai si personne n'écoute dessus
  # SO_REUSEADDR, comme le daemon : les connexions en TIME_WAIT d'un lancement
  # précédent ne comptent pas.
  python3 -c "
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('127.0.0.1', int(sys.argv[1])))
except OSError:
    sys.exit(1)" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "==> Tests unitaires (swift test)"
cd "$REPO"
swift test --scratch-path "$SCRATCH" >"$WORK/swift-test.log" 2>&1
RC=$?
grep -E "Executed [0-9]+ tests" "$WORK/swift-test.log" | tail -1 | sed 's/^/  /'
if [[ $RC -ne 0 ]]; then
  tail -n 30 "$WORK/swift-test.log"
  echo "swift test a échoué"
  exit 1
fi

echo "==> Compilation du binaire"
swift build --scratch-path "$SCRATCH" >/dev/null 2>"$WORK/build.err" || { cat "$WORK/build.err"; echo "build échouée"; exit 1; }
BIN="$(swift build --scratch-path "$SCRATCH" --show-bin-path)/macstatusd"

for port in $PORT_A $PORT_B $PORT_C $PORT_HB; do
  port_libre "$port" || { echo "le port $port est déjà occupé : arrêt avant tout lancement"; exit 1; }
done

echo "==> Préparation de l'environnement de test dans $WORK"
cat > "$WORK/fake.c" <<'C'
#include <unistd.h>
#include <stdlib.h>
int main(int argc, char **argv) { sleep(argc > 1 ? atoi(argv[1]) : 5); return 0; }
C
# Le faux ScreenSaverEngine est visible de TOUT le Mac : un daemon réel en marche le voit aussi,
# passe à OFF et le pousse vers HomeKit et Home Assistant. Il n'est donc lancé que sur demande
# explicite (SELFTEST_FAUX_ECONOMISEUR=1) et seulement si aucune instance ne répond sur 9090.
HAVE_FAKE=0
RAISON_SANS_FAUX="faux économiseur désactivé (SELFTEST_FAUX_ECONOMISEUR=1 pour l'activer, daemon réel arrêté)"
if [[ "${SELFTEST_FAUX_ECONOMISEUR:-0}" == "1" ]]; then
  if curl -fsS --max-time 1 "http://127.0.0.1:9090/health" >/dev/null 2>&1; then
    RAISON_SANS_FAUX="un daemon réel répond sur 9090 : il verrait le faux économiseur et pousserait OFF"
  elif clang -o "$WORK/ScreenSaverEngine" "$WORK/fake.c" 2>/dev/null; then
    HAVE_FAKE=1
  else
    RAISON_SANS_FAUX="clang indisponible pour construire le faux économiseur"
  fi
fi

# Faux récepteur de webhook : note le chemin de chaque requête reçue.
cat > "$WORK/hbmock.py" <<'PY'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        print(self.path, flush=True)
        self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

# Champs communs à toutes les instances : écoute locale, faux récepteur de
# webhook, commandes inertes, aucune escalade.
commun() {
  cat <<JSON
  "bind_address": "127.0.0.1",
  "webhook_base_url": "http://127.0.0.1:$PORT_HB/hook",
  "off_command": ["/usr/bin/true"],
  "wake_command": ["/usr/bin/true"],
  "off_escalate_to_display_sleep": false,
  "stop_screensaver_on_wake": false,
JSON
}

{
  echo "{"
  commun
  cat <<JSON
  "enabled": true,
  "accessory_id": "selftest",
  "port": $PORT_A,
  "poll_interval_ms": 250,
  "settle_on_ms": 200,
  "settle_off_ms": 300,
  "heartbeat_seconds": 4,
  "command_confirm_timeout_ms": 3000,
  "saver_dismiss_on_input": false,
  "log_level": "debug",
  "log_file": "$WORK/a.log"
}
JSON
} > "$WORK/a.json"

{
  echo "{"
  commun
  cat <<JSON
  "enabled": false,
  "port": $PORT_B,
  "auth_token": "$JETON_B",
  "poll_interval_ms": 250,
  "settle_off_ms": 200,
  "command_confirm_timeout_ms": 2000,
  "log_level": "debug",
  "log_file": "$WORK/b.log"
}
JSON
} > "$WORK/b.json"

# Instance C : copie de B sur un autre port, pour la reprise après port occupé.
sed "s/\"port\": $PORT_B/\"port\": $PORT_C/; s|$WORK/b.log|$WORK/c.log|" "$WORK/b.json" > "$WORK/c.json"

# Garde : aucune instance ne démarre si sa configuration sort du cadre hermétique.
conformes=1
for nom in a b c; do
  python3 - "$WORK/$nom.json" <<'PY' || conformes=0
import json, sys
chemin = sys.argv[1]
c = json.load(open(chemin))
erreurs = []
if c.get("bind_address") != "127.0.0.1": erreurs.append("bind_address")
if not 19000 <= c.get("port", 0) <= 19999: erreurs.append("port")
if c.get("off_command") != ["/usr/bin/true"]: erreurs.append("off_command")
if c.get("wake_command") != ["/usr/bin/true"]: erreurs.append("wake_command")
if c.get("off_escalate_to_display_sleep") is not False: erreurs.append("off_escalate_to_display_sleep")
if c.get("stop_screensaver_on_wake") is not False: erreurs.append("stop_screensaver_on_wake")
if not c.get("webhook_base_url", "").startswith("http://127.0.0.1:"): erreurs.append("webhook_base_url")
if erreurs:
    print("  configuration non hermétique (%s) : %s" % (chemin, ", ".join(erreurs)))
    sys.exit(1)
PY
done
[[ $conformes -eq 1 ]] || { echo "configurations d'essai non conformes : arrêt"; exit 1; }

python3 "$WORK/hbmock.py" $PORT_HB > "$WORK/hook.log" 2>&1 &
PIDS+=($!)
"$BIN" --config "$WORK/a.json" > "$WORK/a.out" 2>&1 &
PIDS+=($!)
"$BIN" --config "$WORK/b.json" > "$WORK/b.out" 2>&1 &
PIDS+=($!)

# Lecture initiale (--once) : les sections qui exigent un écran allumé et une
# session déverrouillée n'ont de sens que si c'est le cas.
ECRAN_ETEINT=0
RAISON_SAUT=""
ONCE_JSON="$("$BIN" --config "$WORK/a.json" --once 2>/dev/null)"
ETAT_INITIAL="$(printf '%s' "$ONCE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
ignorer_verrou = sys.argv[1] == "1"
raisons = []
if d.get("system_asleep"): raisons.append("Mac en veille")
if d.get("display_asleep"): raisons.append("écran éteint")
if d.get("session_locked") and not ignorer_verrou: raisons.append("session verrouillée")
print(" + ".join(raisons))' "${SELFTEST_IGNORER_VERROU:-0}" 2>/dev/null)" || ETAT_INITIAL="__ERREUR__"
if [[ "$ETAT_INITIAL" == "__ERREUR__" ]]; then
  bad "lecture initiale (--once) illisible : sections dépendantes de l'écran sautées par prudence"
  ECRAN_ETEINT=1; RAISON_SAUT="lecture initiale illisible"
elif [[ -n "$ETAT_INITIAL" ]]; then
  ECRAN_ETEINT=1; RAISON_SAUT="écran éteint : $ETAT_INITIAL"
fi
if [[ "${SELFTEST_FORCER_ECRAN_ETEINT:-0}" == "1" ]]; then
  ECRAN_ETEINT=1; RAISON_SAUT="écran éteint : forcé par SELFTEST_FORCER_ECRAN_ETEINT"
fi
if [[ $ECRAN_ETEINT -eq 1 ]]; then
  echo "    Écran non disponible — $RAISON_SAUT : les sections qui en dépendent seront SAUTÉES."
fi

sleep 2

echo
echo "== 1. Disponibilité et cohérence"
check "/health répond" "OK" "$(curl -fsS --max-time 2 http://127.0.0.1:$PORT_A/health)"
ONCE="$(printf '%s' "$ONCE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])' 2>/dev/null)"
check "/state == état calculé par --once" "$ONCE" "$(state $PORT_A)"

echo
echo "== 2. Détection de l'économiseur d'écran (oracle process, machine réelle)"
if [[ $ECRAN_ETEINT -eq 1 ]]; then
  saute "détection de l'économiseur" "$RAISON_SAUT"
elif [[ $HAVE_FAKE -ne 1 ]]; then
  saute "détection de l'économiseur" "$RAISON_SANS_FAUX"
else
  "$WORK/ScreenSaverEngine" 8 &
  FAKE_PID=$!
  # Instance A : saver_dismiss_on_input=false, on teste l'oracle brut.
  if await_state $PORT_A 0 5; then ok "état OFF pendant l'économiseur"; else bad "état non passé à OFF pendant l'économiseur"; fi
  case "$(field $PORT_A facts.screensaver_evidence)" in
    *process*) ok "preuve = process" ;;
    *) bad "preuve attendue 'process', obtenue '$(field $PORT_A facts.screensaver_evidence)'" ;;
  esac
  check "économiseur signalé comme en cours" "True" "$(field $PORT_A facts.screensaver_running)"

  # Instance B : règle d'écartement active. L'issue dépend de l'activité réelle
  # de la machine, donc on vérifie l'invariant, pas une valeur figée.
  B_RUNNING="$(field $PORT_B facts.screensaver_running)"
  B_DISMISSED="$(field $PORT_B facts.screensaver_dismissed)"
  B_STATE="$(state $PORT_B)"
  if [[ "$B_RUNNING" == "True" ]]; then
    if [[ "$B_DISMISSED" == "True" ]]; then
      check "écarté par activité ⇒ état ON" "1" "$B_STATE"
    else
      check "économiseur seul à l'écran ⇒ état OFF" "0" "$B_STATE"
    fi
  else
    bad "instance B ne voit pas l'économiseur en cours"
  fi
  IDLE="$(field $PORT_B facts.hid_idle_seconds)"
  if [[ -n "$IDLE" && "$IDLE" != "__ERREUR__" ]]; then ok "inactivité HID exposée ($IDLE s)"; else bad "hid_idle_seconds absent de /status"; fi

  arreter_pid "$FAKE_PID"; FAKE_PID=""
  if await_state $PORT_A 1 5; then ok "retour à ON après l'économiseur"; else bad "état non revenu à ON après l'économiseur"; fi
fi

echo
echo "== 3. Commandes HomeKit confirmées par les faits"
if [[ $ECRAN_ETEINT -eq 1 ]]; then
  saute "commandes /off puis /on confirmées" "$RAISON_SAUT"
elif [[ $HAVE_FAKE -ne 1 ]]; then
  saute "commandes /off puis /on confirmées" "$RAISON_SANS_FAUX"
else
  # Les commandes de l'instance sont inertes (/usr/bin/true) : c'est le script
  # qui joue l'effet, en lançant puis en arrêtant le faux économiseur.
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT_A/off" >/dev/null
  check "OFF immédiat (retour instantané à HomeKit)" "0" "$(state $PORT_A)"
  "$WORK/ScreenSaverEngine" 8 &
  FAKE_PID=$!
  if await_field $PORT_A pending_command.source "" 5; then
    ok "commande OFF confirmée (plus de commande en attente)"
  else
    bad "commande OFF non confirmée par les faits"
  fi
  check "état toujours OFF" "0" "$(state $PORT_A)"
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT_A/on" >/dev/null
  arreter_pid "$FAKE_PID"; FAKE_PID=""
  # /on rend l'état optimiste : /state passe à 1 aussitôt et ne prouve rien. La confirmation
  # vient des faits (verdict à 1) et de la fin de la commande en attente, attendues l'une et l'autre.
  if await_field $PORT_A facts_verdict 1 5; then ok "ON confirmé par les faits après /on"; else bad "ON non confirmé par les faits après /on"; fi
  if await_field $PORT_A pending_command.source "" 5; then
    ok "commande ON confirmée (plus de commande en attente)"
  else
    bad "commande ON non confirmée par les faits"
  fi
fi

echo
echo "== 4. Commande sans effet : retour honnête aux faits"
if [[ $ECRAN_ETEINT -eq 1 ]]; then
  saute "retour à l'état réel après une commande sans effet" "$RAISON_SAUT"
else
  curl -fsS --max-time 2 -H "X-Auth-Token: $JETON_B" "http://127.0.0.1:$PORT_B/off" >/dev/null
  sleep 0.4
  check "OFF affiché pendant la commande" "0" "$(state $PORT_B)"
  if await_state $PORT_B 1 6; then ok "retour à l'état réel après expiration"; else bad "état non revenu à ON après expiration"; fi
  if grep -q "non confirmée" "$WORK/b.log"; then ok "avertissement journalisé"; else bad "aucun avertissement 'non confirmée' dans le journal"; fi
fi

echo
echo "== 5. Serveur HTTP"
check "route inconnue → 404" "404" "$(code http://127.0.0.1:$PORT_A/inconnu)"
check "POST → 405" "405" "$(code -X POST http://127.0.0.1:$PORT_A/state)"
check "requête surdimensionnée → 413" "413" "$(code "http://127.0.0.1:$PORT_A/state?x=$(python3 -c 'print("a"*65000)')")"
check "commande sans jeton → 401" "401" "$(code http://127.0.0.1:$PORT_B/off)"
check "commande avec jeton en en-tête → 200" "200" "$(code -H "X-Auth-Token: $JETON_B" "http://127.0.0.1:$PORT_B/off")"
check "commande avec Authorization: Bearer → 200" "200" "$(code -H "Authorization: Bearer $JETON_B" "http://127.0.0.1:$PORT_B/off")"
check "jeton dans l'URL refusé par défaut → 401" "401" "$(code "http://127.0.0.1:$PORT_B/off?token=$JETON_B")"
check "commande avec Origin → 403" "403" "$(code -H "X-Auth-Token: $JETON_B" -H "Origin: http://evil.example" "http://127.0.0.1:$PORT_B/off")"
check "commande avec Sec-Fetch-Site: cross-site → 403" "403" "$(code -H "X-Auth-Token: $JETON_B" -H "Sec-Fetch-Site: cross-site" "http://127.0.0.1:$PORT_B/off")"
check "Host rebindé → 403" "403" "$(code -H "X-Auth-Token: $JETON_B" -H "Host: evil.example:$PORT_B" "http://127.0.0.1:$PORT_B/off")"
check "commande en HEAD → 405" "405" "$(code -I -H "X-Auth-Token: $JETON_B" "http://127.0.0.1:$PORT_B/off")"
check "lecture en boucle locale sans jeton → 200" "200" "$(code http://127.0.0.1:$PORT_B/state)"
check "instance sans jeton, boucle locale → 200" "200" "$(code http://127.0.0.1:$PORT_A/state)"
if grep -q "HTTP refusée 401 (token)" "$WORK/b.log"; then ok "refus journalisé (WARN)"; else bad "aucun refus 'HTTP refusée 401 (token)' dans le journal de B"; fi
if grep -q "$JETON_B" "$WORK/b.log"; then bad "le jeton apparaît dans le journal de B"; else ok "jeton absent du journal"; fi
REQ_PIDS=()
for _ in $(seq 10); do state $PORT_A > /dev/null & REQ_PIDS+=($!); done
for pid in "${REQ_PIDS[@]}"; do wait "$pid"; done
check "toujours vivant après 10 requêtes simultanées" "OK" "$(curl -fsS --max-time 2 http://127.0.0.1:$PORT_A/health)"

echo
echo "== 6. Webhooks (faux récepteur local)"
if [[ $ECRAN_ETEINT -eq 1 ]]; then
  saute "pushs OFF puis ON reçus" "$RAISON_SAUT"
else
  # Le push OFF vient de la section 2 (faux économiseur) : sans lui, rien ne passe à OFF.
  if [[ $HAVE_FAKE -ne 1 ]]; then
    saute "push OFF reçu" "$RAISON_SANS_FAUX"
  elif grep -q "accessoryId=selftest&state=false" "$WORK/hook.log"; then ok "push OFF reçu"; else bad "aucun push state=false reçu"; fi
  if grep -q "accessoryId=selftest&state=true" "$WORK/hook.log"; then ok "push ON reçu"; else bad "aucun push state=true reçu"; fi
fi
# Le battement de cœur est de 4 s : on lui laisse le temps de se manifester.
await_lignes "$WORK/hook.log" 3 15
HB="$(wc -l < "$WORK/hook.log" | tr -d ' ')"
if [[ "$HB" -ge 3 ]]; then ok "battement de cœur actif ($HB requêtes)"; else bad "battement de cœur absent ($HB requêtes)"; fi
DESIRE="$(field $PORT_A webhook.desired)"
CONFIRME="$(field $PORT_A webhook.confirmed)"
if [[ "$DESIRE" == "__ERREUR__" || "$CONFIRME" == "__ERREUR__" ]]; then
  bad "webhook synchronisé : /status illisible"
elif [[ -z "$DESIRE" ]]; then
  # Une clé absente rendrait deux chaînes vides égales : ce ne serait pas une synchronisation.
  bad "webhook synchronisé : état voulu (webhook.desired) absent de /status"
else
  check "webhook synchronisé (voulu == confirmé)" "$DESIRE" "$CONFIRME"
fi

echo
echo "== 7. Reprise du serveur si le port est occupé"
python3 - "$PORT_C" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(5)
PY
PIDS+=($!)
sleep 0.5
"$BIN" --config "$WORK/c.json" > "$WORK/c.out" 2>&1 &
PIDS+=($!)
sleep 2
if grep -q "Address already in use" "$WORK/c.log"; then ok "conflit de port détecté sans crash"; else bad "conflit de port non journalisé"; fi
if await_http $PORT_C 30; then ok "écoute reprise après libération du port"; else bad "écoute non reprise après libération du port"; fi

echo
echo "==================================="
printf 'Résultat: %d OK, %d échec(s), %d sauté(s)\n' "$PASS" "$FAIL" "$SKIP"
echo "Journaux: $WORK (supprimé à la sortie)"
[[ $FAIL -eq 0 ]]
