#!/bin/bash

# Dossier de sortie
OUTDIR="$HOME/macstatusd_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"

echo "📡 Captures en cours..."
echo "📁 Dossier : $OUTDIR"
echo

# 1 — loginwindow
log stream --style compact --level info \
  --predicate 'subsystem == "com.apple.loginwindow"' \
  | tee "$OUTDIR/loginwindow.log" &

PID1=$!

# 2 — WindowServer (transitions utiles uniquement)
log stream --style compact --level info \
  --predicate 'process == "WindowServer" && (eventMessage CONTAINS "display" OR eventMessage CONTAINS "lock" OR eventMessage CONTAINS "surface" OR eventMessage CONTAINS "wake")' \
  | tee "$OUTDIR/windowserver.log" &

PID2=$!

# 3 — backboardd
log stream --style compact --level info \
  --predicate 'process == "backboardd"' \
  | tee "$OUTDIR/backboardd.log" &

PID3=$!

# 4 — powerd
log stream --style compact --level info \
  --predicate 'subsystem == "com.apple.powerd"' \
  | tee "$OUTDIR/powerd.log" &

PID4=$!

# 5 — ScreenSaverEngine
log stream --style compact --level info \
  --predicate 'process == "ScreenSaverEngine"' \
  | tee "$OUTDIR/screensaver.log" &

PID5=$!

echo "🟢 Toutes les captures sont actives."
echo "➡️  Fais maintenant la séquence complète."
echo
echo "Quand tu as terminé, appuie sur ENTER pour arrêter proprement."
read

echo "🛑 Arrêt des captures..."
kill $PID1 $PID2 $PID3 $PID4 $PID5 2>/dev/null

echo "✔️ Captures terminées."
echo "📁 Les logs sont dans : $OUTDIR"

