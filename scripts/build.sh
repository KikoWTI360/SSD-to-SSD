#!/bin/bash
# Compila l'app da riga di comando.
#   ./scripts/build.sh            → Debug
#   ./scripts/build.sh Release    → Release
set -euo pipefail

CONFIGURATION="${1:-Debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"

xcodebuild \
    -project SSDCopier.xcodeproj \
    -scheme SSDCopier \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    build

echo
echo "Build $CONFIGURATION completata."
echo "Per eseguire con la firma del tuo Team apri il progetto in Xcode:"
echo "    open SSDCopier.xcodeproj"
