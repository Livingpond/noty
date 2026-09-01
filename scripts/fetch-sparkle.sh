#!/bin/bash
# Downloads the Sparkle binary framework into ./Sparkle (gitignored).
# Sparkle ships as a notarised binary release; there is nothing to compile.
set -euo pipefail

VERSION="${SPARKLE_VERSION:-2.9.6}"
# Only the pinned version has a checksum on file; overriding SPARKLE_VERSION
# skips the check, which is a local convenience and never what CI does.
EXPECTED_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sparkle"

if [ -d "$DEST/Sparkle.framework" ] && [ -z "${FORCE:-}" ]; then
    echo "✓ Sparkle $VERSION already present at $DEST"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz"
echo "→ downloading Sparkle ${VERSION}"
curl -fsSL -o "$TMP/sparkle.tar.xz" "$URL"

if [ "$VERSION" = "2.9.6" ]; then
    ACTUAL_SHA256="$(shasum -a 256 "$TMP/sparkle.tar.xz" | awk '{print $1}')"
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        echo "Sparkle checksum mismatch for ${VERSION}" >&2
        echo "  expected $EXPECTED_SHA256" >&2
        echo "  got      $ACTUAL_SHA256" >&2
        exit 1
    fi
    echo "✓ checksum verified"
fi

mkdir -p "$TMP/x"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP/x"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$TMP/x/Sparkle.framework" "$DEST/"
[ -d "$TMP/x/bin" ] && cp -R "$TMP/x/bin" "$DEST/"

echo "✓ Sparkle ${VERSION} → $DEST"
