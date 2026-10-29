#!/usr/bin/env bash
#MISE description="Extract iOS SwiftUI source strings for translation"
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
CATALOG="$ROOT/native/ios/Localizable.xcstrings"

# Lightweight parsing cannot infer interpolation types. Leave those strings for
# compiler-based extraction rather than generating incorrect format specifiers.
xcrun xcstringstool extract --SwiftUI --modern-localizable-strings \
  --avoid-arg-placeholder --output-directory "$TEMP_DIR" "$ROOT"/native/ios/Sources/*.swift
if [[ -f "$CATALOG" ]]; then
  cp "$CATALOG" "$TEMP_DIR/Localizable.xcstrings"
else
  printf '{"sourceLanguage":"en","strings":{},"version":"1.0"}\n' > "$TEMP_DIR/Localizable.xcstrings"
fi

# Apple's synchronizer preserves translations and handles removed source keys.
xcrun xcstringstool sync "$TEMP_DIR/Localizable.xcstrings" --stringsdata "$TEMP_DIR"/*.stringsdata
xcrun xcstringstool compile --output-directory "$TEMP_DIR/compiled" "$TEMP_DIR/Localizable.xcstrings"
cp "$TEMP_DIR/Localizable.xcstrings" "$CATALOG"
printf 'Updated %s source strings in %s\n' "$(jq '.strings | length' "$CATALOG")" "$CATALOG"
