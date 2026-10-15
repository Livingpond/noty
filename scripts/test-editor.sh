#!/bin/bash
# Focused range, Markdown, task, selection, and IME-defer checks for the native editor.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# CommandLineTools 27's default macOS SDK ships no SwiftUIMacros plugin, so
# `@State` and friends cannot expand and the compile dies. Prefer an explicit
# SDKROOT, then the newest SDK that still carries the plugin, then xcrun's pick.
if [ -n "${SDKROOT:-}" ]; then
    SDK="$SDKROOT"
elif [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
    SDK="$(xcrun --show-sdk-path --sdk macosx)"
fi
OUT="$(mktemp -d "${TMPDIR:-/tmp}/noty-editor-tests.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

APP_SOURCES=()
for SOURCE_FILE in "$ROOT"/Sources/*.swift; do
    [ "$(basename "$SOURCE_FILE")" = "Main.swift" ] || APP_SOURCES+=("$SOURCE_FILE")
done

# Tests only ever run on the machine that built them, so one native slice is
# enough — a universal test binary doubles the compile for a slice nobody runs.
swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macosx15.0" \
    -sdk "$SDK" \
    "${APP_SOURCES[@]}" \
    "$ROOT"/Tests/*.swift \
    -o "$OUT/EditorStyleEngineTests"

"$OUT/EditorStyleEngineTests"
