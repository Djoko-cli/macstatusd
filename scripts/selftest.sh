#!/bin/bash
# Suite de tests automatisée et NON intrusive : rien n'est verrouillé, endormi
# ni éteint sur la session en cours.
#
# Principe : un faux binaire nommé ScreenSaverEngine simule l'économiseur
# d'écran (c'est exactement ce que l'oracle « process » observe), et un serveur
# HTTP local joue le rôle de Homebridge pour vérifier les webhooks.
#
#   ./scripts/selftest.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/macstatusd-selftest.XXXXXX)"
PORT_A=19090
PORT_B=19091
PORT_HB=19099
PASS=0
FAIL=0

cleanup() {
  pkill -f "macstatusd --config $WORK" 2>/dev/null
  pkill -f "$WORK/hbmock.py" 2>/dev/null
  pkill -f "$WORK/ScreenSaverEngine" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check() { # check <description> <attendu> <obtenu>
  if [[ "$2" == "$3" ]]; then ok "$1 (= $3)"; else bad "$1 — attendu '$2', obtenu '$3'"; fi
}
state()  { curl -fsS --max-time 2 "http://127.0.0.1:$1/state" 2>/dev/null; }
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
await_http() { # await_http <port> <secondes>
  local deadline=$((SECONDS + $2))
  while [[ $SECONDS -lt $deadline ]]; do
    curl -fsS --max-time 1 "http://127.0.0.1:$1/health" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
field()  { curl -fsS --max-time 2 "http://127.0.0.1:$1/status" 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
for key in '$2'.split('.'):
    d = d.get(key, {}) if isinstance(d, dict) else {}
print(d if d != {} else '')"; }
code()   { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$@"; }

echo "==> Compilation"
cd "$REPO"
swift build -c release >/dev/null || { echo "build échouée"; exit 1; }
BIN="$(swift build -c release --show-bin-path)/macstatusd"

echo "==> Préparation de l'environnement de test dans $WORK"
cat > "$WORK/fake.c" <<'C'
#include <unistd.h>
#include <stdlib.h>
int main(int argc, char **argv) { sleep(argc > 1 ? atoi(argv[1]) : 5); return 0; }
C
HAVE_FAKE=0
if clang -o "$WORK/ScreenSaverEngine" "$WORK/fake.c" 2>/dev/null; then HAVE_FAKE=1; fi

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

cat > "$WORK/a.json" <<JSON
{
  "enabled": true,
  "webhook_base_url": "http://127.0.0.1:$PORT_HB/hook",
  "accessory_id": "selftest",
  "port": $PORT_A,
  "bind_address": "127.0.0.1",
  "poll_interval_ms": 250,
  "settle_on_ms": 200,
  "settle_off_ms": 300,
  "heartbeat_seconds": 4,
  "command_confirm_timeout_ms": 3000,
  "saver_dismiss_on_input": false,
  "off_command": ["/bin/sh", "-c", "$WORK/ScreenSaverEngine 6 &"],
  "wake_command": ["/usr/bin/killall", "ScreenSaverEngine"],
  "log_level": "debug",
  "log_file": "$WORK/a.log"
}
JSON

cat > "$WORK/b.json" <<JSON
{
  "enabled": false,
  "port": $PORT_B,
  "bind_address": "127.0.0.1",
  "auth_token": "jeton-test",
  "poll_interval_ms": 250,
  "settle_off_ms": 200,
  "command_confirm_timeout_ms": 2000,
  "off_escalate_to_display_sleep": false,
  "off_command": ["/usr/bin/true"],
  "log_level": "debug",
  "log_file": "$WORK/b.log"
}
JSON

python3 "$WORK/hbmock.py" $PORT_HB > "$WORK/hook.log" 2>&1 & disown
"$BIN" --config "$WORK/a.json" > "$WORK/a.out" 2>&1 & disown
"$BIN" --config "$WORK/b.json" > "$WORK/b.out" 2>&1 & disown
sleep 2

echo
echo "== 1. Disponibilité et cohérence"
check "/health répond" "OK" "$(curl -fsS --max-time 2 http://127.0.0.1:$PORT_A/health)"
ONCE="$("$BIN" --config "$WORK/a.json" --once | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])')"
check "/state == état calculé par --once" "$ONCE" "$(state $PORT_A)"

echo
echo "== 2. Règle de décision de l'économiseur (logique pure, sources injectées)"
if "$BIN" --check-rules | sed 's/^/  /' | grep -q "toutes vérifiées"; then
  ok "les 17 vérifications de --check-rules passent"
else
  bad "--check-rules signale des échecs (le détail: $BIN --check-rules)"
fi

echo
echo "== 3. Détection de l'économiseur d'écran (oracle process, machine réelle)"
if [[ $HAVE_FAKE -eq 1 ]]; then
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
  if [[ -n "$IDLE" ]]; then ok "inactivité HID exposée ($IDLE s)"; else bad "hid_idle_seconds absent de /status"; fi

  kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null
  if await_state $PORT_A 1 5; then ok "retour à ON après l'économiseur"; else bad "état non revenu à ON après l'économiseur"; fi
else
  echo "  (ignoré : clang indisponible pour construire le faux économiseur)"
fi

echo
echo "== 4. Commandes HomeKit confirmées par les faits"
curl -fsS --max-time 2 "http://127.0.0.1:$PORT_A/off" >/dev/null
sleep 0.3
check "OFF immédiat (retour instantané à HomeKit)" "0" "$(state $PORT_A)"
sleep 1.5
check "commande OFF confirmée (plus de commande en attente)" "" "$(field $PORT_A pending_command.source)"
check "état toujours OFF" "0" "$(state $PORT_A)"
curl -fsS --max-time 2 "http://127.0.0.1:$PORT_A/on" >/dev/null
sleep 1.8
check "ON confirmé après /on" "1" "$(state $PORT_A)"
check "commande ON confirmée" "" "$(field $PORT_A pending_command.source)"

echo
echo "== 5. Commande sans effet : retour honnête aux faits"
curl -fsS --max-time 2 "http://127.0.0.1:$PORT_B/off?token=jeton-test" >/dev/null
sleep 0.4
check "OFF affiché pendant la commande" "0" "$(state $PORT_B)"
sleep 2.4
check "retour à l'état réel après expiration" "1" "$(state $PORT_B)"
if grep -q "non confirmée" "$WORK/b.log"; then ok "avertissement journalisé"; else bad "aucun avertissement 'non confirmée' dans le journal"; fi

echo
echo "== 6. Serveur HTTP"
check "route inconnue → 404" "404" "$(code http://127.0.0.1:$PORT_A/inconnu)"
check "POST → 405" "405" "$(code -X POST http://127.0.0.1:$PORT_A/state)"
check "requête surdimensionnée → 413" "413" "$(code "http://127.0.0.1:$PORT_A/state?x=$(python3 -c 'print("a"*65000)')")"
check "commande sans jeton → 401" "401" "$(code http://127.0.0.1:$PORT_B/off)"
check "commande avec jeton → 200" "200" "$(code "http://127.0.0.1:$PORT_B/off?token=jeton-test")"
check "/state reste public" "200" "$(code http://127.0.0.1:$PORT_B/state)"
PIDS=()
for _ in $(seq 10); do state $PORT_A > /dev/null & PIDS+=($!); done
for pid in "${PIDS[@]}"; do wait "$pid"; done
check "toujours vivant après 10 requêtes simultanées" "OK" "$(curl -fsS --max-time 2 http://127.0.0.1:$PORT_A/health)"

echo
echo "== 7. Webhooks Homebridge"
if grep -q "accessoryId=selftest&state=false" "$WORK/hook.log"; then ok "push OFF reçu"; else bad "aucun push state=false reçu"; fi
if grep -q "accessoryId=selftest&state=true" "$WORK/hook.log"; then ok "push ON reçu"; else bad "aucun push state=true reçu"; fi
HB="$(wc -l < "$WORK/hook.log" | tr -d ' ')"
if [[ "$HB" -ge 3 ]]; then ok "battement de cœur actif ($HB requêtes)"; else bad "battement de cœur absent ($HB requêtes)"; fi
check "webhook synchronisé (voulu == confirmé)" "$(field $PORT_A webhook.desired)" "$(field $PORT_A webhook.confirmed)"

echo
echo "== 8. Reprise du serveur si le port est occupé"
python3 - "$PORT_B" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]) + 5)); s.listen(1); time.sleep(5)
PY
sleep 0.5
sed "s/\"port\": $PORT_B/\"port\": $((PORT_B+5))/; s|$WORK/b.log|$WORK/c.log|" "$WORK/b.json" > "$WORK/c.json"
"$BIN" --config "$WORK/c.json" > "$WORK/c.out" 2>&1 & disown
sleep 2
if grep -q "Address already in use" "$WORK/c.log"; then ok "conflit de port détecté sans crash"; else bad "conflit de port non journalisé"; fi
if await_http $((PORT_B+5)) 30; then ok "écoute reprise après libération du port"; else bad "écoute non reprise après libération du port"; fi

echo
echo "==================================="
printf 'Résultat: %d OK, %d échec(s)\n' "$PASS" "$FAIL"
echo "Journaux: $WORK (supprimé à la sortie)"
[[ $FAIL -eq 0 ]]
