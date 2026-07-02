#!/usr/bin/env bash
set -euo pipefail

# termux-fix-claude.sh — Fix "claude native binary not installed" on Termux (Android).
#
# Background: Claude Code v2.1.113+ ships as a native glibc Linux binary instead
# of a JavaScript entry point. On Termux, Node reports process.platform="android",
# so npm never installs the linux-arm64 optional dependency — and even when the
# binary is downloaded manually, Android's Bionic linker rejects glibc executables
# ("unexpected e_type: 2"). Running the suggested install.cjs does not help.
#
# This script offers two working fixes:
#   native (default)  Download the official linux-arm64 binary, verify its SHA256
#                     against Anthropic's manifest, patch its ELF interpreter to
#                     Termux's glibc loader (glibc-runner), and install a wrapper
#                     at $PREFIX/bin/claude. Runs current Claude Code versions.
#   js                Pin the last JavaScript-based release (2.1.112) via npm.
#                     Simple and reliable, but frozen at an old version.
#
# Re-run the script any time to update the patched binary to the latest release.

RELEASE_BASE="https://downloads.claude.ai/claude-code-releases"
LAST_JS_VERSION="2.1.112"
INSTALL_ROOT="${CLAUDE_TERMUX_ROOT:-$HOME/.claude-termux}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Fix the Claude Code "native binary not installed" error on Termux/Android.

Options:
  -m, --mode MODE       "native" (patched official binary, default) or
                        "js" (pin npm package @${LAST_JS_VERSION})
  -v, --version X.Y.Z   Install a specific version (native mode only;
                        default: latest stable)
  -h, --help            Show this help message
EOF
  exit 0
}

MODE="native"
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--mode)
      MODE="$2"
      shift 2
      ;;
    -v|--version)
      VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_termux() {
  [[ "${PREFIX:-}" == *com.termux* ]] \
    || die "This script must run inside Termux (PREFIX not set to a com.termux path)."
}

remove_npm_package() {
  # A leftover npm install shadows/breaks the wrapper and its postinstall keeps
  # failing on Android, so clear it out first.
  if command -v npm >/dev/null 2>&1 \
     && npm ls -g @anthropic-ai/claude-code >/dev/null 2>&1; then
    echo "Removing npm-installed @anthropic-ai/claude-code (broken on Termux)..."
    npm uninstall -g @anthropic-ai/claude-code
  fi
}

install_js() {
  require_termux
  command -v npm >/dev/null 2>&1 || die "npm not found. Run: pkg install nodejs"

  remove_npm_package
  echo "Installing last JavaScript-based release: ${LAST_JS_VERSION}..."
  npm install -g "@anthropic-ai/claude-code@${LAST_JS_VERSION}"

  # The built-in auto-updater would upgrade past 2.1.112 and reintroduce the
  # unrunnable native binary.
  if ! grep -qs 'DISABLE_AUTOUPDATER' "$HOME/.bashrc"; then
    echo 'export DISABLE_AUTOUPDATER=1' >> "$HOME/.bashrc"
    echo "Added DISABLE_AUTOUPDATER=1 to ~/.bashrc (prevents auto-upgrade to broken versions)."
  fi

  echo ""
  echo "Done. Restart your shell (or run: export DISABLE_AUTOUPDATER=1), then run: claude"
  echo "Note: ${LAST_JS_VERSION} no longer receives updates. For current versions,"
  echo "re-run this script with: --mode native"
}

install_native() {
  require_termux
  [[ "$(uname -m)" == "aarch64" ]] \
    || die "Native mode needs an arm64 device (uname -m reported: $(uname -m))."

  echo "Installing Termux glibc packages (glibc-runner, patchelf-glibc)..."
  pkg install -y curl jq glibc-repo 2>/dev/null || true
  pkg install -y glibc-runner patchelf-glibc \
    || die "Could not install glibc-runner/patchelf-glibc. Update Termux (pkg update) and retry."

  local glibc_ld="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
  [[ -e "$glibc_ld" ]] || die "glibc loader not found at $glibc_ld after package install."

  local patchelf=""
  for candidate in "$PREFIX/glibc/bin/patchelf" "$(command -v patchelf.glibc || true)" "$(command -v patchelf || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { patchelf="$candidate"; break; }
  done
  [[ -n "$patchelf" ]] || die "patchelf not found after installing patchelf-glibc."

  if [[ -z "$VERSION" ]]; then
    echo "Resolving latest stable version..."
    VERSION="$(curl -fsSL "$RELEASE_BASE/latest")"
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Unexpected version string: $VERSION"
  fi
  echo "Installing Claude Code v${VERSION} (linux-arm64, ~240 MB download)..."

  command -v jq >/dev/null 2>&1 || die "jq not found. Run: pkg install jq"

  workdir="$(mktemp -d)"
  trap '[[ -n "${workdir:-}" ]] && rm -rf "$workdir"' EXIT

  curl -fSL --progress-bar "$RELEASE_BASE/$VERSION/manifest.json" -o "$workdir/manifest.json"
  curl -fSL --progress-bar "$RELEASE_BASE/$VERSION/linux-arm64/claude" -o "$workdir/claude"

  local expected actual
  expected="$(jq -r '.platforms["linux-arm64"].checksum' "$workdir/manifest.json")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "Could not read linux-arm64 checksum from manifest."
  actual="$(sha256sum "$workdir/claude" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] \
    || die "Checksum mismatch (expected $expected, got $actual). Download corrupted — retry."
  echo "Checksum verified."

  echo "Patching ELF interpreter to Termux glibc loader..."
  if ! LD_PRELOAD='' "$patchelf" --set-interpreter "$glibc_ld" "$workdir/claude"; then
    LD_PRELOAD='' grun "$patchelf" --set-interpreter "$glibc_ld" "$workdir/claude" \
      || die "patchelf failed to rewrite the interpreter."
  fi

  mkdir -p "$INSTALL_ROOT/versions"
  local target="$INSTALL_ROOT/versions/claude-$VERSION"
  install -m 755 "$workdir/claude" "$target"
  ln -sf "$target" "$INSTALL_ROOT/claude"

  remove_npm_package

  cat > "$PREFIX/bin/claude" <<WRAPEOF
#!$PREFIX/bin/sh
# Wrapper installed by termux-fix-claude.sh — runs the glibc-patched binary.
# LD_PRELOAD (termux-exec) breaks glibc binaries; the built-in auto-updater
# would replace this binary with an unpatched one, so both are disabled.
unset LD_PRELOAD
export DISABLE_AUTOUPDATER=1
exec "$INSTALL_ROOT/claude" "\$@"
WRAPEOF
  chmod 755 "$PREFIX/bin/claude"

  echo ""
  echo "Running smoke test: claude --version"
  if "$PREFIX/bin/claude" --version; then
    echo ""
    echo "Done. Claude Code v${VERSION} is installed."
    echo "Run \"hash -r\" (or restart Termux) so your shell forgets the old npm path, then run: claude"
    echo "To update later, re-run this script (auto-update is intentionally disabled)."
  else
    echo ""
    echo "Smoke test failed. The patched binary did not run on this device." >&2
    echo "Fall back to the JavaScript version with: $(basename "$0") --mode js" >&2
    exit 1
  fi
}

case "$MODE" in
  native) install_native ;;
  js)     install_js ;;
  *)      die "Invalid mode: $MODE (expected \"native\" or \"js\")" ;;
esac
