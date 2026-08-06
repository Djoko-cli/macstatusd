#!/bin/bash

RAW_LOG="/tmp/loginwindow_raw.log"
OUT_LOG="/tmp/loginwindow_events.log"

if [ ! -f "$RAW_LOG" ]; then
    echo "❌ Raw log not found: $RAW_LOG"
    exit 1
fi

echo "🔍 Extracting loginwindow events..."
echo "Input : $RAW_LOG"
echo "Output: $OUT_LOG"
echo ""

# Header
{
    echo "==============================================="
    echo " LOGINWINDOW EVENT EXTRACTION"
    echo " Generated: $(date)"
    echo " Source: $RAW_LOG"
    echo "==============================================="
    echo ""
} > "$OUT_LOG"

# Extract interesting lines
grep -E \
    "screensaver|Shield|Auth|UI|Controller|Window|loginwindow|locked=|screensaverActive=|displaySleep=" \
    "$RAW_LOG" \
    | sed 's/\r$//' \
    | awk '!seen[$0]++' \
    >> "$OUT_LOG"

echo "✅ Extraction complete."
echo "You can now inspect:"
echo "   $OUT_LOG"
