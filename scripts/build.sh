#!/bin/bash
# Compila l'app e la deposita in una cartella fissa, invece che dentro DerivedData.
#
#   ./scripts/build.sh                      → Debug  → ./dist/SSDCopier.app
#   ./scripts/build.sh Release              → Release → ./dist/SSDCopier.app
#   OUTPUT_DIR=~/Developer ./scripts/build.sh   → ~/Developer/SSDCopier.app
#
# La firma è ad-hoc: l'app gira su questo Mac e ottiene i suoi entitlements
# (quindi la sandbox è attiva come in produzione), ma non è distribuibile.
# Per una build firmata col tuo Team apri il progetto in Xcode.
set -euo pipefail

CONFIGURATION="${1:-Debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"
DERIVED_DATA="$ROOT/build"

cd "$ROOT"

echo "Compilo la configurazione $CONFIGURATION…"
xcodebuild \
    -project SSDCopier.xcodeproj \
    -scheme SSDCopier \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/SSDCopier.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "Compilazione riuscita ma il bundle non è dove me lo aspettavo:" >&2
    echo "    $BUILT_APP" >&2
    exit 1
fi

DESTINATION="$OUTPUT_DIR/SSDCopier.app"

# Guardia: rimuoviamo solo un bundle che si chiama davvero così.
if [ -e "$DESTINATION" ]; then
    if [ -d "$DESTINATION" ] && [ "$(basename "$DESTINATION")" = "SSDCopier.app" ]; then
        rm -rf "$DESTINATION"
    else
        echo "Mi rifiuto di sovrascrivere $DESTINATION: non è un bundle SSDCopier.app." >&2
        exit 1
    fi
fi

mkdir -p "$OUTPUT_DIR"
cp -R "$BUILT_APP" "$DESTINATION"

echo
echo "App pronta:"
echo "    $DESTINATION"
echo
echo "Aprila con:  open \"$DESTINATION\""

# Mostra il risultato nel Finder, se siamo in una sessione grafica.
if [ -z "${SSDCOPIER_NO_REVEAL:-}" ]; then
    open -R "$DESTINATION" 2>/dev/null || true
fi
