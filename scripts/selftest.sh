#!/bin/bash
# Suite de tests automatisée, hermétique et NON intrusive : rien n'est verrouillé,
# endormi ni éteint sur la session en cours, et rien ne sort de la machine.
#
# Principe :
#   - `swift test` joue d'abord les tests unitaires de MacStatusCore ;
#   - un faux binaire nommé ScreenSaverEngine simule l'économiseur d'écran, sur demande seulement
#     (SELFTEST_FAUX_ECONOMISEUR=1, daemon réel arrêté : sinon il le verrait aussi ; c'est
#     exactement ce que l'oracle « process » observe) ;
#   - un serveur HTTP local joue le rôle de Homebridge pour les webhooks (GET), un autre celui du
#     webhook de Home Assistant (POST JSON, réponse 200 sans corps) ; un troisième, lancé en retard,
#     joue un Home Assistant revenu après une panne (section 11) ;
#   - chaque instance de test écoute sur 127.0.0.1, sur un port de 19000 à 19999 passé aussi en
#     ligne de commande (--port) : en mode dégradé, le port du fichier est ignoré et le défaut 9090
#     serait pris, à côté du daemon réel ; commandes inertes (/usr/bin/true) et sans escalade : un
#     /on ou un /off ne touche jamais l'écran du Mac ;
#   - MACSTATUSD_SUPPORT_DIR pointe vers un dossier temporaire pour tous les processus lancés : aucun
#     ne lit ni ne consomme le vrai marqueur « restart-pending » de ~/Library/Application Support ;
#   - les cas « sigterm-off » et « sigterm-marqueur » (section 10) arrêtent leurs propres instances (H
#     et I, par leur PID) ; l'instance réelle (9090) n'est que lue (GET /status), avant et après ;
#   - les cas « journal-supprime », « journal-rotation » et « stdout-ferme » (section 9) n'écrivent
#     que dans le dossier temporaire du script : jamais dans ~/Library/Logs/macstatusd ;
#   - le cas « deux-instances » (section 12) lance deux instances sur le MÊME port d'essai, chacune avec
#     son faux Homebridge : la seconde ne tient pas le port et ne doit rien envoyer ; elle ne publie
#     qu'après l'arrêt de la première (par son PID) ; elles reçoivent --port en ligne de commande ;
#   - seule exception, l'instance D du cas « message-ecoute » écoute sur « :: »
#     (toutes interfaces) le temps de lire son message d'écoute, avec un jeton et les
#     mêmes commandes inertes ; le script ne lui parle que par la boucle locale.
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
PORT_D=19097
PORT_E=19098   # journal : sortie standard fermée
PORT_F=19092   # journal : fichier supprimé
PORT_G=19093   # journal : rotation
PORT_H=19094   # arrêt : SIGTERM, OFF publié
PORT_I=19095   # arrêt : SIGTERM, marqueur de redémarrage
PORT_HB=19099
PORT_HA=19100  # faux webhook Home Assistant (POST)
PORT_HA2=19101 # faux webhook Home Assistant lancé en retard (retour après panne)
PORT_J=19102   # webhook : cible revenue, resynchronisée par le réessai lent
PORT_K=19103   # webhook : transport borné (redirection, corps trop gros)
PORT_BORNE=19104 # faux récepteur qui redirige ou répond un corps trop gros
PORT_L=19106   # deux-instances : port PARTAGÉ par les deux instances (la seconde ne le tient pas)
PORT_HBL=19107 # deux-instances : faux Homebridge de la première instance
PORT_HBM=19108 # deux-instances : faux Homebridge de la seconde instance
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
# Dossier de support d'essai pour tous les processus lancés (jamais le vrai) ; le cas
# « sigterm-marqueur » en prend un autre, à lui.
export MACSTATUSD_SUPPORT_DIR="$WORK/support"
mkdir -p "$MACSTATUSD_SUPPORT_DIR"
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

for port in $PORT_A $PORT_B $PORT_C $PORT_D $PORT_E $PORT_F $PORT_G $PORT_H $PORT_I $PORT_HB $PORT_HA $PORT_HA2 $PORT_J $PORT_K $PORT_BORNE $PORT_L $PORT_HBL $PORT_HBM; do
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

# Faux webhook Home Assistant : accepte un POST, note le chemin, le Content-Type, l'en-tête d'essai et
# le corps, et répond 200 sans corps (comme HA). Valeurs d'essai seulement.
cat > "$WORK/hamock.py" <<'PY'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        corps = self.rfile.read(n).decode('utf-8', 'replace')
        print("POST %s %s %s %s" % (self.path, self.headers.get('Content-Type'),
                                    self.headers.get('X-Essai', '-'), corps), flush=True)
        self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
# Faux récepteur hostile : POST /redir répond 302 vers /suivi (qui ne doit jamais être demandé),
# GET /gros répond 200 avec un corps de 10 000 octets (au-delà du plafond de 4 Kio).
cat > "$WORK/bornemock.py" <<'PY'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def repondre(self):
        print(self.command, self.path, flush=True)
        if self.path.startswith("/redir"):
            self.send_response(302); self.send_header('Location', 'http://127.0.0.1:%s/suivi' % sys.argv[1])
            self.send_header('Content-Length', '0'); self.end_headers()
        elif self.path.startswith("/gros"):
            self.send_response(200); self.send_header('Content-Length', '10000'); self.end_headers()
            self.wfile.write(b'x' * 10000)
        else:
            self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()
    def do_GET(self): self.repondre()
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0)); self.repondre()
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
# Identifiant de webhook et en-tête d'essai : inventés, ils ne doivent jamais paraître au journal
# du daemon ni dans son /status.
HA_WEBHOOK_ID="selftest-webhook-essai-0123456789"
HA_ENTETE="valeur-essai-entete-abcdef"

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
# Instance D : copie de B liée à « :: », pour le seul cas « message-ecoute » (jeton exigé).
sed "s/\"port\": $PORT_B/\"port\": $PORT_D/; s|$WORK/b.log|$WORK/d.log|; s/\"bind_address\": \"127.0.0.1\"/\"bind_address\": \"::\"/" \
  "$WORK/b.json" > "$WORK/d.json"

# Instances E, F et G : copies de B (jeton d'essai, commandes inertes, webhook désactivé) pour les cas
# « stdout-ferme », « journal-supprime » et « journal-rotation ».
for suite in "e:$PORT_E" "f:$PORT_F" "g:$PORT_G"; do
  sed "s/\"port\": $PORT_B/\"port\": ${suite#*:}/; s|$WORK/b.log|$WORK/${suite%%:*}.log|" "$WORK/b.json" > "$WORK/${suite%%:*}.json"
done

# Instances H et I : copies de A (webhook vers le faux récepteur, pas de battement de cœur) pour les cas
# « sigterm-off » et « sigterm-marqueur ». Chacune a son accessoire, pour que le journal du faux
# Homebridge dise sans ambiguïté qui a poussé quoi (sans tiret : le client encode tout sauf les alphanumériques).
# H a deux cibles (webhook_targets) : le faux Homebridge en GET et le faux Home Assistant en POST.
python3 - "$WORK/a.json" "$WORK/h.json" "$PORT_H" "$WORK/h.log" "$PORT_HB" "$PORT_HA" "$HA_WEBHOOK_ID" "$HA_ENTETE" <<'PY'
import json, sys
source, cible, port, journal, hb, ha, ident, entete = sys.argv[1:]
c = json.load(open(source))
c.pop("webhook_base_url")
c.update({"port": int(port), "log_file": journal, "accessory_id": "selftestarret", "heartbeat_seconds": 0,
          "webhook_targets": [
              {"url": "http://127.0.0.1:%s/hook" % hb},
              {"url": "http://127.0.0.1:%s/api/webhook/%s" % (ha, ident), "method": "POST",
               "headers": {"X-Essai": entete}}]})
json.dump(c, open(cible, "w"), indent=2)
PY
sed "s/\"port\": $PORT_A/\"port\": $PORT_I/; s|$WORK/a.log|$WORK/i.log|; s/\"accessory_id\": \"selftest\"/\"accessory_id\": \"selftestmarqueur\"/; s/\"heartbeat_seconds\": 4/\"heartbeat_seconds\": 0/" \
  "$WORK/a.json" > "$WORK/i.json"
# Instance K : deux cibles vers le faux récepteur hostile, aucun réessai rapide, pas de battement de cœur.
python3 - "$WORK/a.json" "$WORK/k.json" "$PORT_K" "$WORK/k.log" "$PORT_BORNE" <<'PY'
import json, sys
source, cible, port, journal, borne = sys.argv[1:]
c = json.load(open(source))
c.pop("webhook_base_url")
c.update({"port": int(port), "log_file": journal, "accessory_id": "selftestborne", "heartbeat_seconds": 0,
          "webhook_retries": 0,
          "webhook_targets": [{"url": "http://127.0.0.1:%s/redir" % borne, "method": "POST"},
                              {"url": "http://127.0.0.1:%s/gros" % borne}]})
json.dump(c, open(cible, "w"), indent=2)
PY
# Instance J : une seule cible POST, vers un faux Home Assistant qui ne répond pas encore ; aucun
# réessai rapide (abandon au premier échec), pas de battement de cœur : seul le réessai lent la resynchronise.
python3 - "$WORK/a.json" "$WORK/j.json" "$PORT_J" "$WORK/j.log" "$PORT_HA2" <<'PY'
import json, sys
source, cible, port, journal, ha = sys.argv[1:]
c = json.load(open(source))
c.pop("webhook_base_url")
c.update({"port": int(port), "log_file": journal, "accessory_id": "selftestretour", "heartbeat_seconds": 0,
          "webhook_retries": 0,
          "webhook_targets": [{"url": "http://127.0.0.1:%s/api/webhook/selftest-retour-essai" % ha, "method": "POST"}]})
json.dump(c, open(cible, "w"), indent=2)
PY

# Instances L et M (cas « deux-instances ») : copies de A, même port PORT_L, chacune avec son faux
# Homebridge, son accessoire et son journal ; pas de battement de cœur (seules les publications
# d'état comptent).
for suite in "l:$PORT_HBL:selftestunique" "m:$PORT_HBM:selftestseconde"; do
  python3 - "$WORK/a.json" "$WORK/${suite%%:*}.json" "$PORT_L" "$WORK/${suite%%:*}.log" \
    "$(echo "$suite" | cut -d: -f2)" "$(echo "$suite" | cut -d: -f3)" <<'PY'
import json, sys
source, cible, port, journal, recepteur, accessoire = sys.argv[1:]
c = json.load(open(source))
c.update({"port": int(port), "log_file": journal, "accessory_id": accessoire, "heartbeat_seconds": 0,
          "webhook_base_url": "http://127.0.0.1:%s/hook" % recepteur})
json.dump(c, open(cible, "w"), indent=2)
PY
done

# Garde : aucune instance ne démarre si sa configuration sort du cadre hermétique.
# Seule D peut écouter sur « :: », et seulement avec le jeton d'essai.
conformes=1
for nom in a b c d e f g h i j k l m; do
  attendu="127.0.0.1"
  [[ "$nom" == "d" ]] && attendu="::"
  python3 - "$WORK/$nom.json" "$attendu" "$JETON_B" <<'PY' || conformes=0
import json, sys
chemin, attendu, jeton = sys.argv[1], sys.argv[2], sys.argv[3]
c = json.load(open(chemin))
erreurs = []
if c.get("bind_address") != attendu: erreurs.append("bind_address")
if attendu != "127.0.0.1" and c.get("auth_token") != jeton: erreurs.append("auth_token")
if not 19000 <= c.get("port", 0) <= 19999: erreurs.append("port")
if c.get("off_command") != ["/usr/bin/true"]: erreurs.append("off_command")
if c.get("wake_command") != ["/usr/bin/true"]: erreurs.append("wake_command")
if c.get("off_escalate_to_display_sleep") is not False: erreurs.append("off_escalate_to_display_sleep")
if c.get("stop_screensaver_on_wake") is not False: erreurs.append("stop_screensaver_on_wake")
if "webhook_targets" in c:
    if not c["webhook_targets"] or any(not str(t.get("url", "")).startswith("http://127.0.0.1:") for t in c["webhook_targets"]):
        erreurs.append("webhook_targets")
elif not c.get("webhook_base_url", "").startswith("http://127.0.0.1:"): erreurs.append("webhook_base_url")
if erreurs:
    print("  configuration non hermétique (%s) : %s" % (chemin, ", ".join(erreurs)))
    sys.exit(1)
PY
done
[[ $conformes -eq 1 ]] || { echo "configurations d'essai non conformes : arrêt"; exit 1; }

# Instance réelle (9090) : lue seulement (GET /status), avant et après, pour prouver que ce script n'y
# touche pas (ni redémarrage, ni changement d'état).
reel_instantane() { # « état uptime », ou rien si personne ne répond
  curl -fsS --max-time 2 "http://127.0.0.1:9090/status" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["state"], d["uptime_seconds"])' 2>/dev/null
}
# L'état de l'instance réelle peut changer seul (activité réelle) ; seul un redémarrage remet sa durée de
# fonctionnement à zéro : c'est elle que le contrôle final compare.
REEL_AVANT="$(reel_instantane)"

python3 "$WORK/hbmock.py" $PORT_HB > "$WORK/hook.log" 2>&1 &
PIDS+=($!)
python3 "$WORK/hamock.py" $PORT_HA > "$WORK/ha.log" 2>&1 &
PIDS+=($!)
"$BIN" --config "$WORK/a.json" --port $PORT_A > "$WORK/a.out" 2>&1 &
PIDS+=($!)
"$BIN" --config "$WORK/b.json" --port $PORT_B > "$WORK/b.out" 2>&1 &
PIDS+=($!)

# Lecture initiale (--once) : les sections qui exigent un écran allumé et une
# session déverrouillée n'ont de sens que si c'est le cas.
ECRAN_ETEINT=0
RAISON_SAUT=""
ONCE_JSON="$("$BIN" --config "$WORK/a.json" --port $PORT_A --once 2>/dev/null)"
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
"$BIN" --config "$WORK/c.json" --port $PORT_C > "$WORK/c.out" 2>&1 &
PIDS+=($!)
sleep 2
if grep -q "Address already in use" "$WORK/c.log"; then ok "conflit de port détecté sans crash"; else bad "conflit de port non journalisé"; fi
if await_http $PORT_C 30; then ok "écoute reprise après libération du port"; else bad "écoute non reprise après libération du port"; fi

echo
echo "== 8. Adaptateur d'écoute : plafond, délai d'en-têtes, message d'écoute"
# Client brut : tient des sockets ouvertes, ce que curl ne sait pas faire.
cat > "$WORK/connexions.py" <<'PY'
import socket, sys, time
port, cas = int(sys.argv[1]), sys.argv[2]
REQUETE = b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

def ouvrir():
    return socket.create_connection(("127.0.0.1", port), timeout=5)

def lire_tout(s, delai):
    """Octets reçus jusqu'à la fermeture par le serveur ; None si toujours ouverte au délai."""
    s.settimeout(delai)
    morceaux = []
    try:
        while True:
            m = s.recv(4096)
            if not m:
                break
            morceaux.append(m)
    except (ConnectionResetError, BrokenPipeError):
        pass
    except socket.timeout:
        return None
    return b"".join(morceaux)

if cas == "pair":
    # 8 connexions muettes depuis 127.0.0.1, puis une 9e qui envoie une vraie requête.
    tenues = [ouvrir() for _ in range(8)]
    time.sleep(0.3)
    neuvieme = ouvrir()
    try:
        neuvieme.sendall(REQUETE)
    except OSError:
        pass
    reponse = lire_tout(neuvieme, 1.5)
    print("9e:" + ("fermee-sans-reponse" if reponse == b"" else "ouverte" if reponse is None else "repondu"))
    # La 1re des 8 est servie : elles avaient bien été acceptées.
    tenues[0].sendall(REQUETE)
    reponse = lire_tout(tenues[0], 1.5) or b""
    print("1re:" + ("200" if reponse.startswith(b"HTTP/1.1 200") else "autre"))
    for s in tenues + [neuvieme]:
        s.close()
elif cas == "lent":
    # En-têtes jamais finis : durée jusqu'à la fermeture par le serveur.
    s = ouvrir()
    debut = time.monotonic()
    s.sendall(b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n")
    reponse = lire_tout(s, 6)
    duree = time.monotonic() - debut
    s.close()
    print("ouverte" if reponse is None else "%.2f" % duree)
PY

RES_PAIR="$(python3 "$WORK/connexions.py" $PORT_A pair 2>&1)"
check "connexions-pair : 9e connexion de 127.0.0.1 refusée" "9e:fermee-sans-reponse" "$(printf '%s\n' "$RES_PAIR" | grep '^9e:')"
check "connexions-pair : les 8 premières acceptées" "1re:200" "$(printf '%s\n' "$RES_PAIR" | grep '^1re:')"
if grep -q "HTTP connexion refusée depuis 127.0.0.1 : plafond atteint" "$WORK/a.log"; then
  ok "connexions-pair : refus journalisé"
else
  bad "connexions-pair : aucun refus 'plafond atteint' dans le journal de A"
fi
check "connexions-pair : places rendues après fermeture" "OK" "$(curl -fsS --max-time 2 http://127.0.0.1:$PORT_A/health)"

DUREE="$(python3 "$WORK/connexions.py" $PORT_A lent 2>&1)"
if python3 -c 'import sys; d = float(sys.argv[1]); sys.exit(0 if 1.8 <= d <= 3.0 else 1)' "$DUREE" 2>/dev/null; then
  ok "en-tetes-lents : connexion sans en-têtes fermée en $DUREE s"
else
  bad "en-tetes-lents : fermeture attendue en 2 à 3 s, obtenu '$DUREE'"
fi

# Instance D liée à « :: » : lancée ici, arrêtée dès son message d'écoute lu.
"$BIN" --config "$WORK/d.json" --port $PORT_D > "$WORK/d.out" 2>&1 &
PID_D=$!
PIDS+=($PID_D)
if await_http $PORT_D 10; then ok "message-ecoute : instance « :: » joignable par 127.0.0.1"; else bad "message-ecoute : instance « :: » injoignable par 127.0.0.1"; fi
for _ in $(seq 10); do grep -qF "IPv4+IPv6" "$WORK/d.log" 2>/dev/null && break; sleep 0.3; done
if grep -qF "serveur HTTP à l'écoute sur [::]:$PORT_D (IPv4+IPv6, toutes interfaces)" "$WORK/d.log"; then
  ok "message-ecoute : le journal contient « [::]:$PORT_D (IPv4+IPv6, toutes interfaces) »"
else
  bad "message-ecoute : message IPv4+IPv6 absent du journal de D ($(grep -F "à l'écoute" "$WORK/d.log" | tail -1))"
fi
arreter_pid "$PID_D"
if grep -qF "serveur HTTP à l'écoute sur 127.0.0.1:$PORT_A" "$WORK/a.log"; then
  ok "message-ecoute : adresse liée exacte pour A (127.0.0.1:$PORT_A)"
else
  bad "message-ecoute : message d'écoute de A inexact"
fi

echo
echo "== 9. Journal : fichier supprimé, rotation, sortie standard fermée"
# Aucun journal réel : f.log, g.log et e.log vivent dans $WORK. Chaque instance est arrêtée par son PID.
mode_octal() { stat -f '%Lp' "$1" 2>/dev/null || echo "absent"; }

# journal-supprime : le fichier disparaît pendant que l'instance tourne ; l'inode est comparé toutes
# les 100 écritures, puis le fichier est recréé (mode 600).
"$BIN" --config "$WORK/f.json" --port $PORT_F > "$WORK/f.out" 2>&1 &
PID_F=$!
PIDS+=($PID_F)
if await_http $PORT_F 10; then ok "journal-supprime : instance démarrée"; else bad "journal-supprime : instance injoignable"; fi
rm -f "$WORK/f.log"
for _ in $(seq 160); do state $PORT_F >/dev/null; done
for _ in $(seq 20); do [[ -s "$WORK/f.log" ]] && break; sleep 0.25; done
if [[ -s "$WORK/f.log" ]]; then ok "journal-supprime : journal recréé après suppression"; else bad "journal-supprime : journal non recréé"; fi
check "journal-supprime : droits du nouveau journal" "600" "$(mode_octal "$WORK/f.log")"
check "journal-supprime : instance toujours vivante" "OK" "$(curl -fsS --max-time 2 http://127.0.0.1:$PORT_F/health)"
arreter_pid "$PID_F"

# journal-rotation : taille de rotation réduite (variable d'essai) ; au plus 5 générations.
MAX_ROTATION=20000
MACSTATUSD_LOG_MAX_BYTES=$MAX_ROTATION "$BIN" --config "$WORK/g.json" --port $PORT_G > "$WORK/g.out" 2>&1 &
PID_G=$!
PIDS+=($PID_G)
if await_http $PORT_G 10; then ok "journal-rotation : instance démarrée"; else bad "journal-rotation : instance injoignable"; fi
python3 - "$PORT_G" <<'PY'
import http.client, sys
for _ in range(3000):
    c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=3)
    c.request("GET", "/state"); c.getresponse().read(); c.close()
PY
sleep 1
GENERATIONS=0
for n in 1 2 3 4 5 6 7; do [[ -e "$WORK/g.log.$n" ]] && GENERATIONS=$n; done
check "journal-rotation : 5 générations au plus (.1 à .5, pas de .6)" "5" "$GENERATIONS"
TROP_GROS=0
for fichier in "$WORK"/g.log "$WORK"/g.log.[1-5]; do
  [[ "$(stat -f '%z' "$fichier" 2>/dev/null || echo 0)" -le $((MAX_ROTATION + 1024)) ]] || TROP_GROS=1
done
check "journal-rotation : chaque fichier reste près de la taille de rotation" "0" "$TROP_GROS"
DROITS_LARGES=0
for fichier in "$WORK"/g.log "$WORK"/g.log.[1-5]; do
  [[ "$(mode_octal "$fichier")" == "600" ]] || DROITS_LARGES=1
done
check "journal-rotation : toutes les générations en mode 600" "0" "$DROITS_LARGES"
check "journal-rotation : instance toujours vivante" "OK" "$(curl -fsS --max-time 2 http://127.0.0.1:$PORT_G/health)"
arreter_pid "$PID_G"

# stdout-ferme : premier plan (-f) dont la sortie est un tube que `head -1` ferme aussitôt. Un tube
# nommé donne le PID du daemon (dans `daemon | head`, $! serait celui de head).
mkfifo "$WORK/e.fifo"
head -1 < "$WORK/e.fifo" > "$WORK/e.head" &
PID_HEAD=$!
PIDS+=($PID_HEAD)
"$BIN" --config "$WORK/e.json" --port $PORT_E -f > "$WORK/e.fifo" 2>&1 &
PID_E=$!
PIDS+=($PID_E)
sleep 3
if kill -0 "$PID_E" 2>/dev/null; then ok "stdout-ferme : daemon vivant 3 s après la fermeture du tube"; else bad "stdout-ferme : daemon mort après la fermeture du tube"; fi
check "stdout-ferme : head a lu une ligne" "1" "$(wc -l < "$WORK/e.head" | tr -d ' ')"
check "stdout-ferme : /health répond" "OK" "$(curl -fsS --max-time 2 http://127.0.0.1:$PORT_E/health)"
AVANT="$(wc -l < "$WORK/e.log" | tr -d ' ')"
for _ in $(seq 5); do state $PORT_E >/dev/null; done
sleep 0.5
APRES="$(wc -l < "$WORK/e.log" | tr -d ' ')"
if [[ "$APRES" -gt "$AVANT" ]]; then ok "stdout-ferme : le journal fichier continue ($AVANT → $APRES lignes)"; else bad "stdout-ferme : le journal fichier n'avance plus ($AVANT → $APRES lignes)"; fi
arreter_pid "$PID_E"

echo
echo "== 10. Arrêt propre : OFF publié au SIGTERM, sauf redémarrage prévu"
nb_pushs() { # nb_pushs <accessoire> <état> : lignes du faux Homebridge pour cet accessoire et cet état
  grep -c "accessoryId=$1&state=$2" "$WORK/hook.log" 2>/dev/null || true
}
await_push() { # await_push <accessoire> <secondes> : attend la publication initiale de l'instance
  local deadline=$((SECONDS + $2))
  while [[ $SECONDS -lt $deadline ]]; do
    grep -q "accessoryId=$1&state=" "$WORK/hook.log" 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}
attendre_sortie() { # attendre_sortie <pid> <secondes> : vrai si le processus s'arrête à temps
  local deadline=$((SECONDS + $2))
  while [[ $SECONDS -lt $deadline ]]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

# sigterm-off : SIGTERM, le faux Homebridge reçoit state=false (même si l'état était déjà OFF : l'arrêt
# publie en force), et le daemon sort de lui-même, bien avant l'ExitTimeOut de 5 s.
"$BIN" --config "$WORK/h.json" --port $PORT_H > "$WORK/h.out" 2>&1 &
PID_H=$!
PIDS+=($PID_H)
if await_http $PORT_H 10 && await_push selftestarret 10; then ok "sigterm-off : instance démarrée, état initial publié"; else bad "sigterm-off : instance injoignable ou sans publication initiale"; fi
nb_posts_ha() { # nb_posts_ha <accessoire> <true|false> : POST JSON reçus par le faux Home Assistant
  grep -c "\"accessoryId\":\"$1\",\"state\":$2}" "$WORK/ha.log" 2>/dev/null || true
}
# /status de H : deux cibles, URL masquée, ni identifiant de webhook ni en-tête.
STATUT_H="$(curl -fsS --max-time 2 "http://127.0.0.1:$PORT_H/status" 2>/dev/null)"
VERDICT_H="$(printf '%s' "$STATUT_H" | python3 -c '
import json, sys
ident, entete = sys.argv[1], sys.argv[2]
brut = sys.stdin.read()
d = json.loads(brut)
cibles = d["webhook"]["targets"]
ok = (len(cibles) == 2 and cibles[1]["method"] == "POST"
      and cibles[1]["url"].endswith("/api/webhook/<masqué>")
      and ident not in brut and entete not in brut and "X-Essai" not in brut)
print("ok" if ok else "ko")' "$HA_WEBHOOK_ID" "$HA_ENTETE" 2>/dev/null)"
check "deux-cibles : /status, une entrée par cible, URL masquée, sans en-tête" "ok" "$VERDICT_H"
if await_lignes "$WORK/ha.log" 1 5 && grep -qF "POST /api/webhook/$HA_WEBHOOK_ID application/json $HA_ENTETE {\"accessoryId\":\"selftestarret\",\"state\":" "$WORK/ha.log"; then
  ok "deux-cibles : faux Home Assistant servi en POST JSON, avec l'en-tête de la cible"
else
  bad "deux-cibles : aucun POST JSON conforme reçu par le faux Home Assistant"
fi
AVANT_H="$(nb_pushs selftestarret false)"
AVANT_HA="$(nb_posts_ha selftestarret false)"
DEBUT_H=$SECONDS
kill -TERM "$PID_H"
if attendre_sortie "$PID_H" 5; then ok "sigterm-off : le daemon sort de lui-même ($((SECONDS - DEBUT_H)) s, ExitTimeOut 5 s)"; else bad "sigterm-off : le daemon n'est pas sorti en 5 s"; fi
wait "$PID_H" 2>/dev/null; check "sigterm-off : code de sortie" "0" "$?"
APRES_H="$(nb_pushs selftestarret false)"
if [[ "$APRES_H" -gt "$AVANT_H" ]]; then ok "sigterm-off : state=false reçu par le faux Homebridge ($AVANT_H → $APRES_H)"; else bad "sigterm-off : aucun state=false reçu après le SIGTERM ($AVANT_H → $APRES_H)"; fi
APRES_HA="$(nb_posts_ha selftestarret false)"
if [[ "$APRES_HA" -gt "$AVANT_HA" ]]; then ok "sigterm-off : state=false reçu par le faux Home Assistant ($AVANT_HA → $APRES_HA)"; else bad "sigterm-off : aucun state=false reçu par le faux Home Assistant ($AVANT_HA → $APRES_HA)"; fi
if grep -q "arrêt : OFF confirmé par 2/2 cibles" "$WORK/h.log"; then ok "sigterm-off : « arrêt : OFF confirmé par 2/2 cibles » au journal (livré aux deux cibles avant la sortie)"; else bad "sigterm-off : « arrêt : OFF confirmé par 2/2 cibles » absent du journal"; fi
if grep -q "arrêt terminé" "$WORK/h.log"; then ok "sigterm-off : « arrêt terminé » au journal"; else bad "sigterm-off : « arrêt terminé » absent du journal"; fi
if grep -qF -e "$HA_WEBHOOK_ID" -e "$HA_ENTETE" "$WORK/h.log" "$WORK/h.out"; then
  bad "deux-cibles : identifiant de webhook ou en-tête au journal de H"
else
  ok "deux-cibles : ni identifiant de webhook ni en-tête au journal de H"
fi

# sigterm-marqueur : un marqueur restart-pending récent (dossier d'essai, jamais le vrai) : rien n'est
# publié, et le marqueur est supprimé.
SUPPORT_I="$WORK/support-i"
mkdir -p "$SUPPORT_I"
: > "$SUPPORT_I/restart-pending"
MACSTATUSD_SUPPORT_DIR="$SUPPORT_I" "$BIN" --config "$WORK/i.json" --port $PORT_I > "$WORK/i.out" 2>&1 &
PID_I=$!
PIDS+=($PID_I)
if await_http $PORT_I 10 && await_push selftestmarqueur 10; then ok "sigterm-marqueur : instance démarrée, état initial publié"; else bad "sigterm-marqueur : instance injoignable ou sans publication initiale"; fi
sleep 1
AVANT_I="$(nb_pushs selftestmarqueur false)"
TOTAL_I="$(grep -c "accessoryId=selftestmarqueur" "$WORK/hook.log" 2>/dev/null || true)"
kill -TERM "$PID_I"
if attendre_sortie "$PID_I" 5; then ok "sigterm-marqueur : le daemon sort de lui-même"; else bad "sigterm-marqueur : le daemon n'est pas sorti en 5 s"; fi
wait "$PID_I" 2>/dev/null; check "sigterm-marqueur : code de sortie" "0" "$?"
check "sigterm-marqueur : rien reçu par le faux Homebridge" "$TOTAL_I" "$(grep -c "accessoryId=selftestmarqueur" "$WORK/hook.log" 2>/dev/null || true)"
check "sigterm-marqueur : aucun state=false de plus" "$AVANT_I" "$(nb_pushs selftestmarqueur false)"
if [[ -e "$SUPPORT_I/restart-pending" ]]; then bad "sigterm-marqueur : le marqueur n'a pas été supprimé"; else ok "sigterm-marqueur : marqueur supprimé"; fi
if grep -q "redémarrage prévu" "$WORK/i.log"; then ok "sigterm-marqueur : « redémarrage prévu » au journal"; else bad "sigterm-marqueur : « redémarrage prévu » absent du journal"; fi

echo
echo "== 11. Webhook résilient : Home Assistant absent, puis de retour"
# J publie vers un faux Home Assistant qui n'écoute pas encore : connexion refusée (-1004), abandon
# immédiat (webhook_retries 0), sonde du chemin vers 127.0.0.1 seulement. Le faux revient ensuite :
# le réessai lent (15 s après l'abandon) doit lui livrer l'état, sans battement de cœur.
cible_j() { # cible_j <clé> : valeur de la première cible dans /status de J
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT_J/status" 2>/dev/null | python3 -c '
import json, sys
c = json.load(sys.stdin)["webhook"]["targets"][0]
v = c.get(sys.argv[1])
print("" if v is None else v)' "$1" 2>/dev/null || echo "__ERREUR__"
}
"$BIN" --config "$WORK/j.json" --port $PORT_J > "$WORK/j.out" 2>&1 &
PID_J=$!
PIDS+=($PID_J)
if await_http $PORT_J 10; then ok "ha-retour : instance démarrée"; else bad "ha-retour : instance injoignable"; fi
for _ in $(seq 40); do grep -q "abandonné" "$WORK/j.log" 2>/dev/null && break; sleep 0.25; done
if grep -q "abandonné après 1 essai " "$WORK/j.log"; then ok "ha-retour : cible injoignable, série rapide abandonnée"; else bad "ha-retour : aucun abandon au journal de J"; fi
check "ha-retour : phase de la cible" "réessai lent" "$(cible_j phase)"
DEBUT_J=$SECONDS
python3 "$WORK/hamock.py" $PORT_HA2 > "$WORK/ha2.log" 2>&1 &
PID_HA2=$!
PIDS+=($PID_HA2)
RECU_J=0
while [[ $SECONDS -lt $((DEBUT_J + 25)) ]]; do
  grep -q "selftestretour" "$WORK/ha2.log" 2>/dev/null && { RECU_J=1; break; }
  sleep 0.25
done
if [[ $RECU_J -eq 1 ]]; then ok "ha-retour : état livré par le réessai lent ($((SECONDS - DEBUT_J)) s après le retour, 60 s au plus)"; else bad "ha-retour : rien reçu 25 s après le retour du faux Home Assistant"; fi
DESIRE_J="$(field $PORT_J webhook.desired)"
if [[ -n "$DESIRE_J" && "$DESIRE_J" != "__ERREUR__" ]] && await_field $PORT_J webhook.confirmed "$DESIRE_J" 5; then
  ok "ha-retour : état voulu confirmé dans /status (= $DESIRE_J)"
else
  bad "ha-retour : état voulu non confirmé dans /status ($DESIRE_J / $(field $PORT_J webhook.confirmed))"
fi
for _ in $(seq 20); do grep -q "de retour après" "$WORK/j.log" 2>/dev/null && break; sleep 0.25; done
if grep -q "de retour après" "$WORK/j.log"; then ok "ha-retour : retour journalisé avec la durée de la panne"; else bad "ha-retour : « de retour après » absent du journal de J"; fi
if grep -q "NSURLErrorDomain -1004" "$WORK/j.log"; then ok "ha-retour : domaine et code de l'erreur au journal"; else bad "ha-retour : domaine et code de l'erreur absents du journal"; fi
if grep -q "accès au réseau local refusé" "$WORK/j.log"; then bad "ha-retour : refus d'accès au réseau local annoncé pour 127.0.0.1"; else ok "ha-retour : aucun refus d'accès au réseau local pour 127.0.0.1"; fi
if grep -q "selftest-retour-essai" "$WORK/j.log"; then bad "ha-retour : identifiant de webhook au journal de J"; else ok "ha-retour : identifiant de webhook absent du journal de J"; fi
arreter_pid "$PID_J"
arreter_pid "$PID_HA2"

# transport-borne : une redirection n'est pas suivie, un corps de plus de 4 Kio annule la requête.
python3 "$WORK/bornemock.py" $PORT_BORNE > "$WORK/borne.log" 2>&1 &
PID_BORNE=$!
PIDS+=($PID_BORNE)
sleep 0.5
"$BIN" --config "$WORK/k.json" --port $PORT_K > "$WORK/k.out" 2>&1 &
PID_K=$!
PIDS+=($PID_K)
if await_http $PORT_K 10; then ok "transport-borne : instance démarrée"; else bad "transport-borne : instance injoignable"; fi
detail_k() { # detail_k <index> : détail de la cible dans /status de K
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT_K/status" 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin)["webhook"]["targets"][int(sys.argv[1])]["detail"])' "$1" 2>/dev/null || echo "__ERREUR__"
}
for _ in $(seq 20); do [[ "$(detail_k 1)" == erreur* && "$(detail_k 0)" == HTTP* ]] && break; sleep 0.25; done
check "transport-borne : redirection refusée" "HTTP 302 : redirection refusée" "$(detail_k 0)"
check "transport-borne : corps au-delà de 4 Kio" "erreur corps de réponse au-delà de 4 Kio, requête annulée" "$(detail_k 1)"
if grep -q "/suivi" "$WORK/borne.log"; then bad "transport-borne : la redirection a été suivie"; else ok "transport-borne : la redirection n'a pas été suivie"; fi
arreter_pid "$PID_K"
arreter_pid "$PID_BORNE"

echo
echo "== 12. Une seule instance publie : le détenteur du port"
# deux-instances : L tient le port PORT_L, M (même port, autre faux Homebridge) ne le peut pas.
# M ne doit RIEN envoyer tant qu'elle ne tient pas le port ; quand L s'arrête, M reprend le port et
# publie alors l'état courant en force. Reprise du listener : en `.waiting`, nouvelle écoute après 5 s
# si l'état n'a pas changé ; en `.failed` (ou `.cancelled`), nouvelle écoute après 1 s, délai doublé
# à chaque échec jusqu'à 30 s. La reprise de M prend donc de 1 à 30 s selon l'état où le port occupé
# l'a mise (d'où l'attente de 30 s plus bas).
# Les deux instances reçoivent --port en ligne de commande, en plus du port de leur configuration.
SESSION_A_LA_CONSOLE="$(printf '%s' "$ONCE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("on_console", False))' 2>/dev/null)"
if [[ "$SESSION_A_LA_CONSOLE" != "True" ]]; then
  saute "deux-instances" "la session n'est pas à la console : aucune instance ne publierait (on_console = $SESSION_A_LA_CONSOLE)"
else
  mkdir -p "$WORK/home-deux"
  python3 "$WORK/hbmock.py" $PORT_HBL > "$WORK/hook-l.log" 2>&1 &
  PIDS+=($!)
  python3 "$WORK/hbmock.py" $PORT_HBM > "$WORK/hook-m.log" 2>&1 &
  PIDS+=($!)
  sleep 0.5
  CFFIXED_USER_HOME="$WORK/home-deux" "$BIN" --config "$WORK/l.json" --port $PORT_L > "$WORK/l.out" 2>&1 &
  PID_L=$!
  PIDS+=($PID_L)
  if await_http $PORT_L 10 && await_lignes "$WORK/hook-l.log" 1 10; then
    ok "deux-instances : la première instance tient le port et publie son état initial"
  else
    bad "deux-instances : la première instance n'a pas publié (port $PORT_L)"
  fi
  check "deux-instances : la première est autorisée à publier (/status)" "True" "$(field $PORT_L publishing_allowed)"

  CFFIXED_USER_HOME="$WORK/home-deux" "$BIN" --config "$WORK/m.json" --port $PORT_L > "$WORK/m.out" 2>&1 &
  PID_M=$!
  PIDS+=($PID_M)
  # La reprise du listener se fait toutes les 5 s : on laisse passer deux cycles.
  for _ in $(seq 40); do grep -q "publication bloquée : port occupé" "$WORK/m.log" 2>/dev/null && break; sleep 0.25; done
  if grep -q "publication bloquée : port occupé" "$WORK/m.log"; then ok "deux-instances : la seconde journalise « publication bloquée : port occupé »"; else bad "deux-instances : « publication bloquée : port occupé » absent du journal de la seconde"; fi
  sleep 12
  check "deux-instances : la seconde n'a rien envoyé à son faux Homebridge" "0" "$(wc -l < "$WORK/hook-m.log" | tr -d ' ')"
  if kill -0 "$PID_M" 2>/dev/null; then ok "deux-instances : la seconde tourne toujours (en attente du port)"; else bad "deux-instances : la seconde s'est arrêtée"; fi
  check "deux-instances : le port répond toujours pour la première" "True" "$(field $PORT_L publishing_allowed)"
  if grep -q "publication autorisée" "$WORK/m.log"; then bad "deux-instances : la seconde s'est crue autorisée"; else ok "deux-instances : la seconde ne s'est jamais crue autorisée"; fi

  # Arrêt de la première, par son PID : la seconde reprend le port et publie en force.
  kill -TERM "$PID_L"
  if attendre_sortie "$PID_L" 5; then ok "deux-instances : la première s'arrête"; else bad "deux-instances : la première ne s'arrête pas"; fi
  wait "$PID_L" 2>/dev/null
  DEBUT_M=$SECONDS
  if await_lignes "$WORK/hook-m.log" 1 30; then
    ok "deux-instances : la seconde reprend le port et publie ($((SECONDS - DEBUT_M)) s après l'arrêt de la première)"
  else
    bad "deux-instances : la seconde n'a rien publié 30 s après l'arrêt de la première"
  fi
  if grep -q "publication autorisée : prêt" "$WORK/m.log"; then ok "deux-instances : « publication autorisée : prêt » au journal de la seconde"; else bad "deux-instances : « publication autorisée : prêt » absent du journal de la seconde"; fi
  if grep -q "retour de l'autorisation" "$WORK/m.log"; then ok "deux-instances : l'état courant est publié en force au retour de l'autorisation"; else bad "deux-instances : aucune publication forcée au retour de l'autorisation"; fi
  check "deux-instances : une seule publication au retour" "1" "$(grep -c 'accessoryId=selftestseconde&state=' "$WORK/hook-m.log" 2>/dev/null || true)"
  check "deux-instances : la seconde est autorisée (/status)" "True" "$(field $PORT_L publishing_allowed)"
  if grep -q "accessoryId=selftestseconde" "$WORK/hook-l.log"; then bad "deux-instances : le faux Homebridge de la première a reçu la seconde"; else ok "deux-instances : les deux récepteurs sont restés distincts"; fi
  arreter_pid "$PID_M"
fi

# Instance réelle : inchangée (lue seulement).
REEL_APRES="$(reel_instantane)"
if [[ -z "$REEL_AVANT" ]]; then
  saute "instance réelle non redémarrée" "aucune instance réelle ne répondait sur 9090 au départ"
elif [[ -z "$REEL_APRES" ]]; then
  bad "instance réelle : ne répond plus sur 9090 après le script (avant : $REEL_AVANT)"
else
  python3 -c '
import sys
(e1, u1), (e2, u2) = (x.split() for x in sys.argv[1:3])
sys.exit(0 if int(u2) >= int(u1) else 1)' "$REEL_AVANT" "$REEL_APRES" \
    && ok "instance réelle non redémarrée (état et durée de fonctionnement : $REEL_AVANT → $REEL_APRES)" \
    || bad "instance réelle redémarrée ($REEL_AVANT → $REEL_APRES)"
fi

echo
echo "==================================="
printf 'Résultat: %d OK, %d échec(s), %d sauté(s)\n' "$PASS" "$FAIL" "$SKIP"
echo "Journaux: $WORK (supprimé à la sortie)"
[[ $FAIL -eq 0 ]]
