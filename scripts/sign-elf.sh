#!/usr/bin/env zsh
# sign-elf.sh — Sign a single ELF binary with binary-sign-tool-fix
# Usage: sign-elf.sh <path-to-elf>
set -eu

ELF="$1"
if [ ! -f "$ELF" ]; then
  echo "ERROR: $ELF not found" >&2
  exit 1
fi

# Verify it's actually an ELF file
if [ "$(head -c4 "$ELF" 2>/dev/null)" != "$(printf '\x7fELF')" ]; then
  echo "WARNING: $ELF is not an ELF file, skipping" >&2
  exit 0
fi

UNSIGNED="${ELF}.unsigned"
SIGNED="${ELF}.signed"

cp "$ELF" "$UNSIGNED"

# Strip existing .codesign section (may fail harmlessly)
llvm-objcopy --remove-section=.codesign "$ELF" "$UNSIGNED" 2>/dev/null || true
chmod 0755 "$UNSIGNED"

# Sign with self-sign key
OLD_LD_PATH="$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$(brew --prefix openssl@3)/lib:${OLD_LD_PATH}"
binary-sign-tool-fix sign \
  -inFile "$UNSIGNED" \
  -outFile "$SIGNED" \
  -selfSign 1
export LD_LIBRARY_PATH="$OLD_LD_PATH"

chmod 0755 "$SIGNED"
mv "$SIGNED" "$ELF"
rm -f "$UNSIGNED"

echo "Signed: $ELF"
