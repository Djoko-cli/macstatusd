#!/bin/bash
# Compile et installe macstatusd comme LaunchAgent de l'utilisateur courant.
#
#   ./scripts/install.sh          <-- SANS sudo
#
# Le script appelle sudo lui‑même uniquement pour /opt/macstatusd. Lancé
# entièrement en root, $UID vaudrait 0 et « launchctl bootstrap gui/0 »
# échouerait (erreur 125) : le LaunchAgent doit appartenir à la session
# graphique de l'utilisateur.
set -euo pipefail

# Relance sous l'identité réelle si on a été invoqué avec sudo.
if [[ $EUID -eq 0 ]]; then
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    echo "==> Lancé avec sudo : reprise en tant que $SUDO_USER (le LaunchAgent est par utilisateur)"
    exec sudo -u "$SUDO_USER" -H "$0" "$@"
  fi
  echo "!! Ne pas lancer ce script en root : le LaunchAgent doit être chargé dans" >&2
  echo "   la session graphique d'un utilisateur. Relance-le sans sudo." >&2
  exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="/opt/macstatusd"
LABEL="com.majid.macstatusd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/macstatusd"

cd "$REPO"

# Un passage antérieur en root laisse des artefacts root dans .build, qui font
# ensuite échouer la compilation avec « Operation not permitted ».
if [[ -d .build ]] && find .build -not -user "$(id -un)" -print -quit | grep -q .; then
  echo "==> Artefacts de build appartenant à root détectés → correction (sudo)"
  sudo chown -R "$(id -u):$(id -g)" .build
fi

echo "==> Compilation (release)"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/macstatusd"
test -x "$BINARY"

if [[ -f "$PREFIX/macstatusd" ]] && cmp -s "$BINARY" "$PREFIX/macstatusd"; then
  echo "==> $PREFIX/macstatusd déjà à jour (pas besoin de sudo)"
else
  echo "==> Installation dans $PREFIX (sudo requis)"
  sudo install -d -o root -g wheel -m 755 "$PREFIX"
  sudo install -m 755 -o root -g wheel "$BINARY" "$PREFIX/macstatusd"
fi

if [[ -f "$PREFIX/config.json" ]]; then
  echo "    config.json existant conservé"
else
  sudo install -m 644 -o root -g wheel "$REPO/config.example.json" "$PREFIX/config.json"
  echo "    config.json créé depuis config.example.json — à adapter (webhook_base_url)"
fi

echo "==> Journaux dans $LOGDIR"
mkdir -p "$LOGDIR" 2>/dev/null || true
if [[ ! -w "$LOGDIR" ]]; then
  echo "    répertoire non inscriptible → correction du propriétaire (sudo)"
  sudo chown -R "$(id -u):$(id -g)" "$LOGDIR"
fi

echo "==> LaunchAgent $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# Un plist laissé par un ancien passage en root n'est pas réinscriptible.
if [[ -e "$PLIST" && ! -w "$PLIST" ]]; then
  rm -f "$PLIST" 2>/dev/null || sudo rm -f "$PLIST"
fi
sed "s|__HOME__|$HOME|g" "$REPO/launchd/$LABEL.plist" > "$PLIST"
chmod 644 "$PLIST"

launchctl enable "gui/$UID/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
  echo "    bootstrap indisponible → repli sur launchctl load"
  launchctl load -w "$PLIST"
fi

PORT="$(python3 -c 'import json;print(json.load(open("/opt/macstatusd/config.json")).get("port",9090))')"
echo "==> Vérification (port $PORT)"
for _ in $(seq 20); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "    OK — état: $(curl -fsS "http://127.0.0.1:$PORT/state")"
    curl -fsS "http://127.0.0.1:$PORT/status"
    echo
    echo "==> Installé. Journal: $LOGDIR/macstatusd.log"
    exit 0
  fi
  sleep 0.5
done

echo "!! macstatusd ne répond pas sur le port $PORT" >&2
echo "   launchctl print gui/$UID/$LABEL | head -30" >&2
tail -20 "$LOGDIR/macstatusd.log" 2>/dev/null || true
exit 1
