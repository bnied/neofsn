#!/bin/bash
#
# Generate compile_commands.json so sourcekit-lsp can resolve cross-file symbols.
#
# The app is built from a hand-written .xcodeproj (no SwiftPM manifest), so the
# editor's language server has no build graph and reports false "Cannot find type"
# errors for every cross-file reference. A compile database fixes that; the real
# build still goes through `xcodebuild`.
#
# Re-run this whenever you add/remove a Swift file or change the deployment target.
# The output contains machine-specific SDK paths, so it is git-ignored.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT/neofsn"
OUT="$ROOT/compile_commands.json"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
TARGET="arm64-apple-macos14.0"

# Collect all Swift files (absolute paths).
FILES=()
while IFS= read -r f; do
  FILES+=("$f")
done < <(find "$SRC_DIR" -name '*.swift' | sort)

# Build the shared argument list: swiftc, target, sdk, then every source file.
# Whole-module: each entry lists all files so opening any one sees the module.
files_json=""
for f in "${FILES[@]}"; do
  files_json+="$(printf '        ,"%s"\n' "$f")"
done

{
  printf '[\n'
  first=1
  for f in "${FILES[@]}"; do
    if [ $first -eq 0 ]; then printf ',\n'; fi
    first=0
    printf '  {\n'
    printf '    "directory": "%s",\n' "$ROOT"
    printf '    "file": "%s",\n' "$f"
    printf '    "arguments": [\n'
    printf '      "swiftc",\n'
    printf '      "-module-name", "neofsn",\n'
    printf '      "-sdk", "%s",\n' "$SDK"
    printf '      "-target", "%s",\n' "$TARGET"
    printf '      "-swift-version", "5"'
    for sf in "${FILES[@]}"; do
      printf ',\n      "%s"' "$sf"
    done
    printf '\n    ]\n'
    printf '  }'
  done
  printf '\n]\n'
} > "$OUT"

echo "Wrote $OUT (${#FILES[@]} files)"
