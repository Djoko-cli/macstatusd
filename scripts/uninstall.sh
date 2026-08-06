#!/bin/bash
# Désinstalle macstatusd. La configuration et les journaux sont conservés
# sauf si --purge est passé.
set -euo pipefail

LABEL="com.majid.macstatusd"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PREFIX="/opt/macstatusd"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
sudo rm -f "$PREFIX/macstatusd"
echo "==> LaunchAgent retiré, binaire supprimé"

if [[ "${1:-}" == "--purge" ]]; then
  sudo rm -rf "$PREFIX"
  rm -rf "$HOME/Library/Logs/macstatusd"
  echo "==> Configuration et journaux supprimés"
else
  echo "    conservés: $PREFIX/config.json, ~/Library/Logs/macstatusd"
fi
