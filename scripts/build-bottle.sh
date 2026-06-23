#!/usr/bin/env zsh
# build-bottle.sh — Generic bottle build script for Harmonybrew Cask
# Runs inside DockerHarmony container.
#
# Required env vars:
#   FORMULA          — formula name (e.g. binary-sign-tool)
# Optional env vars:
#   SOFTWARE         — artifact directory name (default: same as FORMULA)
#   SCRIPT_DIR  — already set by wrapper
#   EXTRA_PACKAGES   — space-separated list of extra formula to pre-install
#   RUN_FORMULA_TESTS — 1 = run brew test after install (default: 1)
set -eu

TAP_NAME="${TAP_NAME:-nknkol/cask}"
FORMULA="${FORMULA:?FORMULA is required}"
SOFTWARE="${SOFTWARE:-$FORMULA}"
WORKSPACE="${WORKSPACE:-/workspace}"
OUTPUT_DIR="${OUTPUT_DIR:-$WORKSPACE/artifacts/$SOFTWARE}"
LOG_DIR="$OUTPUT_DIR/logs"
RUN_FORMULA_TESTS="${RUN_FORMULA_TESTS:-1}"

QUALIFIED_FORMULA="$TAP_NAME/$FORMULA"

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_FROM_API=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

if ! command -v brew >/dev/null 2>&1 && [ -x /storage/Users/currentUser/.harmonybrew/bin/brew ]; then
  export PATH="/storage/Users/currentUser/.harmonybrew/bin:/storage/Users/currentUser/.harmonybrew/sbin:$PATH"
fi

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

log_step() { printf '\n==> %s\n' "$*"; }

run_with_log() {
  name="$1"; shift
  log_file="$LOG_DIR/$name.log"
  status_file="$LOG_DIR/$name.status"
  rm -f "$status_file"
  log_step "$*"
  set +e
  ("$@" 2>&1; printf '%s' "$?" > "$status_file") | tee "$log_file"
  set -e
  if [ -f "$status_file" ]; then
    command_status="$(cat "$status_file")"
    rm -f "$status_file"
    return "$command_status"
  fi
}

if ! command -v brew >/dev/null 2>&1; then
  echo "brew is not available in PATH" >&2
  exit 1
fi

# ── Tap from local workspace (changes persist to host) ─────────────
if [ -d "$WORKSPACE/Formula" ]; then
  log_step "Tap $TAP_NAME from local workspace"
  brew tap --force "$TAP_NAME" "$WORKSPACE"
else
  echo "ERROR: WORKSPACE/Formula not found — mount your repo to $WORKSPACE" >&2
  exit 1
fi
brew tap

# ── Pre-install extra packages ──────────────────────────────────────
if [ -n "${EXTRA_PACKAGES:-}" ]; then
  for pkg in $EXTRA_PACKAGES; do
    run_with_log "extra-$pkg" brew install --verbose "$TAP_NAME/$pkg"
  done
fi

# ── Formula info ────────────────────────────────────────────────────
log_step "Formula information"
brew info "$QUALIFIED_FORMULA" || true
brew info --json=v2 "$QUALIFIED_FORMULA" > "$OUTPUT_DIR/formula-info.json"

# ── Clean up stale install ──────────────────────────────────────────
log_step "Remove stale installation if present"
brew uninstall --ignore-dependencies --force "$QUALIFIED_FORMULA" >/dev/null 2>&1 || true

# ── Install from source ─────────────────────────────────────────────
run_with_log install \
  brew install --verbose --build-bottle "$QUALIFIED_FORMULA"

# ── Generate bottle ─────────────────────────────────────────────────
run_with_log bottle \
  brew bottle --verbose --skip-relocation --json "$QUALIFIED_FORMULA"

# ── Tests ───────────────────────────────────────────────────────────
if [ "$RUN_FORMULA_TESTS" = "1" ]; then
  run_with_log postinstall brew postinstall "$QUALIFIED_FORMULA"
  run_with_log test brew test --verbose "$QUALIFIED_FORMULA"
fi

# ── Merge bottle block into formula ─────────────────────────────────
log_step "Merge bottle block into formula"
git config --global user.email "bottle@harmonybrew.local"
git config --global user.name "Harmonybrew Bottle"
JSON_FILE=$(ls ./"$FORMULA"-*.json 2>/dev/null | head -1)
if [ -n "$JSON_FILE" ] && [ -f "$JSON_FILE" ]; then
  brew bottle --merge --write "$JSON_FILE"
  log_step "Formula updated with bottle block"
else
  echo "ERROR: No bottle JSON found for merge" >&2
  exit 1
fi

# ── Collect artifacts ───────────────────────────────────────────────
log_step "Collect bottle artifacts"
found_artifact=0
for path in ./"$FORMULA"-*.tar.gz ./"$FORMULA"-*.json; do
  if [ -f "$path" ]; then
    cp "$path" "$OUTPUT_DIR/"
    found_artifact=1
  fi
done
if [ "$found_artifact" -ne 1 ]; then
  echo "No bottle artifacts found for $FORMULA" >&2
  exit 1
fi

chmod -R a+rX "$OUTPUT_DIR"

log_step "Generated files"
find "$OUTPUT_DIR" -maxdepth 2 -type f | sort
