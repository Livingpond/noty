#!/bin/bash
# Downloads the open-source CJK fonts bundled with the app into Resources/Fonts.
# All four families are SIL OFL 1.1, and each licence is fetched alongside the
# fonts so it travels inside the bundle with them, as the licence requires.
# The fonts are gitignored — run this once before building:
#   ./scripts/fetch-fonts.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Resources/Fonts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# raw.githubusercontent.com is unreachable on some networks and github.com can
# crawl, so release downloads go through public mirrors first, direct last.
# Licence text comes from api.github.com, which stays reachable and small.
GH_MIRRORS=("https://ghfast.top/" "https://gh-proxy.com/" "")
API="https://api.github.com/repos"
WENKAI_VER="1.522"
SANS_ZIP="https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/18_NotoSansSC.zip"
SERIF_ZIP="https://github.com/notofonts/noto-cjk/releases/download/Serif2.003/14_NotoSerifSC.zip"
SMILEY_ZIP="https://github.com/atelier-anchor/smiley-sans/releases/download/v2.0.1/smiley-sans-v2.0.1.zip"

mkdir -p "$DEST"

fetch() { # fetch <url> <output-path>
    local url="$1" out="$2"
    if [ -s "$out" ]; then echo "✓ $(basename "$out") already present"; return 0; fi
    echo "→ $(basename "$out")"
    local m
    for m in "${GH_MIRRORS[@]}"; do
        if curl -fsSL --retry 2 --connect-timeout 8 -o "$TMP/part" "$m$url"; then
            mv "$TMP/part" "$out"
            return 0
        fi
    done
    echo "✗ failed: $url" >&2
    return 1
}

licence() { # licence <repo> <output-name> <path-in-repo> [fallback paths...]
    local repo="$1" name="$2"; shift 2
    if [ -s "$DEST/$name" ]; then echo "✓ $name already present"; return 0; fi
    local p
    for p in "$@"; do
        if curl -fsSL --connect-timeout 8 "$API/$repo/contents/$p" -o "$TMP/lic.json"; then
            python3 -c "import json,base64,sys; print(base64.b64decode(json.load(open(sys.argv[1]))['content']).decode(), end='')" \
                "$TMP/lic.json" > "$DEST/$name"
            echo "✓ $name"
            return 0
        fi
    done
    echo "✗ could not fetch the licence for $repo" >&2
    return 1
}

# 霞鹜文楷 LXGW WenKai — a kai (brush) face; Medium stands in as the heavy cut.
fetch "https://github.com/lxgw/LxgwWenKai/releases/download/v$WENKAI_VER/LXGWWenKai-Regular.ttf" "$DEST/LXGWWenKai-Regular.ttf"
fetch "https://github.com/lxgw/LxgwWenKai/releases/download/v$WENKAI_VER/LXGWWenKai-Medium.ttf"  "$DEST/LXGWWenKai-Medium.ttf"

# 思源黑体 / 思源宋体 Noto Sans SC / Noto Serif SC — the language zips carry
# every weight; only Regular and Bold are kept.
if [ ! -s "$DEST/NotoSansSC-Bold.otf" ]; then
    echo "→ NotoSansSC zip"
    fetch "$SANS_ZIP" "$TMP/sans.zip"
    unzip -o -j "$TMP/sans.zip" "*NotoSansSC-Regular.otf" "*NotoSansSC-Bold.otf" -d "$DEST"
else
    echo "✓ NotoSansSC already present"
fi
if [ ! -s "$DEST/NotoSerifSC-Bold.otf" ]; then
    echo "→ NotoSerifSC zip"
    fetch "$SERIF_ZIP" "$TMP/serif.zip"
    unzip -o -j "$TMP/serif.zip" "*NotoSerifSC-Regular.otf" "*NotoSerifSC-Bold.otf" -d "$DEST"
else
    echo "✓ NotoSerifSC already present"
fi

# 得意黑 Smiley Sans — one oblique display face.
if [ ! -s "$DEST/SmileySans-Oblique.ttf" ]; then
    echo "→ SmileySans zip"
    fetch "$SMILEY_ZIP" "$TMP/smiley.zip"
    unzip -o -j "$TMP/smiley.zip" "SmileySans-Oblique.ttf" -d "$DEST" \
        || unzip -o -j "$TMP/smiley.zip" "SmileySans-Oblique.otf" -d "$DEST"
else
    echo "✓ SmileySans already present"
fi

# jsDelivr mirrors GitHub repos and npm; both stay reachable where the GitHub
# API rate-limits anonymous downloads.
licence_url() { # licence_url <url> <output-name>
    local url="$1" name="$2"
    if [ -s "$DEST/$name" ]; then echo "✓ $name already present"; return 0; fi
    if curl -fsSL --retry 3 --connect-timeout 8 -o "$DEST/$name" "$url"; then
        echo "✓ $name"
    else
        echo "✗ could not fetch $name" >&2
        return 1
    fi
}

licence_url "https://cdn.jsdelivr.net/gh/lxgw/LxgwWenKai@main/OFL.txt"            "LXGWWenKai-OFL.txt"
licence_url "https://cdn.jsdelivr.net/npm/@fontsource/noto-sans-sc/LICENSE"       "NotoSansSC-OFL.txt"
licence_url "https://cdn.jsdelivr.net/npm/@fontsource/noto-serif-sc/LICENSE"      "NotoSerifSC-OFL.txt"
licence_url "https://cdn.jsdelivr.net/gh/atelier-anchor/smiley-sans@main/LICENSE" "SmileySans-OFL.txt"

echo
ls -lh "$DEST" | awk 'NR>1 {printf "  %-28s %s\n", $9, $5}'
echo "✓ fonts in $DEST"
