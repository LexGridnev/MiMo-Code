#!/data/data/com.termux/files/usr/bin/env bash
#
# MiMo-Code — fully automatic Termux/Android (aarch64) installer.
#
# One command:
#   curl -fsSL https://raw.githubusercontent.com/LexGridnev/MiMo-Code/HEAD/termux/setup.sh | bash
#
# Idempotent: safe to re-run. Runs MiMo-Code from source under Bun, because
# upstream release binaries are glibc-linked and do not run on Bionic libc.
#
set -euo pipefail

FORK="${MIMO_FORK:-https://github.com/LexGridnev/MiMo-Code}"
UPSTREAM="https://github.com/XiaomiMiMo/MiMo-Code"
REPO_DIR="${MIMO_SRC:-$HOME/MiMo-Code}"
ENTRY="packages/opencode/src/index.ts"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; NC='\033[0m'
say(){ echo -e "${GRN}==>${NC} $*"; }
warn(){ echo -e "${YLW}!! ${NC} $*" >&2; }
die(){ echo -e "${RED}xx ${NC} $*" >&2; exit 1; }

# --- preconditions ----------------------------------------------------------
[ -n "${PREFIX:-}" ] || die "Not inside Termux (\$PREFIX unset). Install Termux from F-Droid."
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "Only aarch64 is supported (got $(uname -m))." ;;
esac

# --- system packages --------------------------------------------------------
say "Updating Termux packages..."
yes | pkg update -y >/dev/null 2>&1 || true
say "Installing build deps..."
pkg install -y git python clang make pkg-config binutils libandroid-spawn \
                ca-certificates >/dev/null

# --- bun ---------------------------------------------------------------------
ensure_bun(){
  if command -v bun >/dev/null 2>&1; then return; fi
  say "Installing Bun..."
  if pkg install -y bun >/dev/null 2>&1 && command -v bun >/dev/null 2>&1; then
    say "Bun from pkg: $(bun --version)"; return
  fi
  warn "pkg bun unavailable; using official installer."
  curl -fsSL https://bun.sh/install | bash >/dev/null
  export PATH="$HOME/.bun/bin:$PATH"
  grep -q '.bun/bin' "$HOME/.bashrc" 2>/dev/null || \
    echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "$HOME/.bashrc"
}
ensure_bun
command -v bun >/dev/null || die "bun still not on PATH."
say "Bun: $(bun --version)"

# --- clone / update fork (auto-detect default branch) -----------------------
detect_default_branch(){
  # ask the remote which branch HEAD points at; fall back to main
  git ls-remote --symref "$FORK" HEAD 2>/dev/null \
    | sed -n 's#^ref: refs/heads/\([^\t ]*\).*#\1#p' | head -1
}

if [ -d "$REPO_DIR/.git" ]; then
  say "Repo exists at $REPO_DIR — pulling latest..."
  git -C "$REPO_DIR" pull --ff-only || warn "pull skipped (local changes?)."
else
  BRANCH="$(detect_default_branch || true)"
  BRANCH="${BRANCH:-main}"
  say "Cloning $FORK (branch: $BRANCH) ..."
  git clone --depth 1 --branch "$BRANCH" "$FORK" "$REPO_DIR" \
    || git clone --depth 1 "$FORK" "$REPO_DIR" \
    || die "Clone failed. Set MIMO_FORK to your fork URL and re-run."
fi
cd "$REPO_DIR"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM" || true
[ -f "$ENTRY" ] || die "Entrypoint $ENTRY missing — wrong repo?"

# --- JS deps + node-pty (shared with 'mimo upgrade') ------------------------
build_deps(){
  say "Installing JS dependencies..."
  bun install --ignore-scripts --backend=copyfile

  export LDFLAGS="-landroid-spawn ${LDFLAGS:-}"
  local PTY_DIR
  PTY_DIR="$(find node_modules -maxdepth 3 -type d -name node-pty 2>/dev/null | head -1 || true)"

  say "Fixing node-pty (LDFLAGS=$LDFLAGS)..."
  bun run --cwd packages/opencode fix-node-pty >/dev/null 2>&1 || true

  pty_works(){
    local h
    h="$(find "${PTY_DIR:-/nonexistent}" -name spawn-helper 2>/dev/null | head -1 || true)"
    [ -n "$h" ] && chmod +x "$h" 2>/dev/null && "$h" </dev/null >/dev/null 2>&1
  }

  if [ -n "$PTY_DIR" ] && ! pty_works; then
    warn "Prebuilt spawn-helper won't run on Bionic — building node-pty from source..."
    ( cd "$PTY_DIR" && {
        npm run install --build-from-source >/dev/null 2>&1 \
        || node-gyp rebuild >/dev/null 2>&1 \
        || bunx node-gyp rebuild >/dev/null 2>&1
      } ) && say "node-pty built from source." \
          || warn "node-pty source build failed; TUI may fall back to basic mode."
  fi
}
build_deps

# --- launcher: 'mimo' + 'mimo upgrade' --------------------------------------
BIN="$PREFIX/bin/mimo"
say "Installing launcher -> $BIN"
rm -f "$BIN"
cat > "$BIN" << WRAP
#!/data/data/com.termux/files/usr/bin/env bash
set -euo pipefail
REPO_DIR="$REPO_DIR"
ENTRY="$ENTRY"
export MIMOCODE_HOME="\${MIMOCODE_HOME:-\$HOME/.mimocode}"
export NODE_EXTRA_CA_CERTS="\${NODE_EXTRA_CA_CERTS:-$PREFIX/etc/tls/cert.pem}"

if [ "\${1:-}" = "upgrade" ]; then
  echo "==> Updating MiMo-Code..."
  git -C "\$REPO_DIR" pull --ff-only
  export LDFLAGS="-landroid-spawn \${LDFLAGS:-}"
  ( cd "\$REPO_DIR" && bun install --ignore-scripts --backend=copyfile \
    && bun run --cwd packages/opencode fix-node-pty >/dev/null 2>&1 || true )
  echo "==> Up to date."
  exit 0
fi

exec $PREFIX/bin/bun run --preload="@opentui/solid/preload" --conditions=browser "\$REPO_DIR/\$ENTRY" "\$@"
WRAP
chmod +x "$BIN"

say "Smoke test..."
"$BIN" --version >/dev/null 2>&1 && say "OK." || warn "Version check noisy; try 'mimo' directly."

echo
say "Done. Launch with:  ${GRN}mimo${NC}"
say "Update later with:  ${GRN}mimo upgrade${NC}"
