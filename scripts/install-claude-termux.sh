#!/usr/bin/env bash
set -euo pipefail

# install-claude-termux.sh — Install Claude Code on Termux (Android).
#
# Claude Code is not officially supported on Termux, but it runs via Node.js.
# This script installs the prerequisites, sets up a user-writable npm prefix
# to avoid permission errors, and installs the Claude Code CLI.
#
# Usage:
#   bash install-claude-termux.sh          # full install
#   bash install-claude-termux.sh --help   # show this help

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Install Claude Code on Termux (Android).

Options:
  -h, --help   Show this help message

After installation, restart Termux (or run 'source ~/.bashrc') and start
Claude Code with:

  claude
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Sanity check: are we actually on Termux?
if [[ -z "${PREFIX:-}" || "${PREFIX}" != *com.termux* ]]; then
  warn "This does not look like a Termux environment (\$PREFIX is not set to Termux)."
  warn "The script is intended to be run inside the Termux app on Android."
fi

command -v pkg >/dev/null 2>&1 || die "'pkg' not found. This script must run inside Termux."

# 2. Update package lists and install Node.js LTS + git.
log "Updating Termux packages..."
pkg update -y && pkg upgrade -y

log "Installing Node.js LTS, git and build tools..."
pkg install -y nodejs-lts git python clang make

# 3. Verify Node version (Claude Code needs Node 18+).
NODE_VERSION="$(node --version 2>/dev/null || echo "none")"
log "Node.js version: ${NODE_VERSION}"
NODE_MAJOR="$(printf '%s' "${NODE_VERSION}" | sed -E 's/^v([0-9]+).*/\1/')"
if [[ "${NODE_MAJOR}" =~ ^[0-9]+$ ]] && (( NODE_MAJOR < 18 )); then
  die "Node.js 18+ is required, found ${NODE_VERSION}."
fi

# 4. Configure a user-writable npm global prefix to avoid permission errors.
NPM_GLOBAL="${HOME}/.npm-global"
log "Configuring npm global prefix at ${NPM_GLOBAL}..."
mkdir -p "${NPM_GLOBAL}"
npm config set prefix "${NPM_GLOBAL}"

# Ensure the prefix bin dir is on PATH (persist in ~/.bashrc).
BASHRC="${HOME}/.bashrc"
PATH_LINE='export PATH="$HOME/.npm-global/bin:$PATH"'
if ! grep -qsF "${PATH_LINE}" "${BASHRC}" 2>/dev/null; then
  printf '\n# Added by install-claude-termux.sh\n%s\n' "${PATH_LINE}" >> "${BASHRC}"
  log "Added npm-global bin to PATH in ${BASHRC}"
fi
export PATH="${NPM_GLOBAL}/bin:${PATH}"

# 5. Install Claude Code.
log "Installing @anthropic-ai/claude-code..."
npm install -g @anthropic-ai/claude-code

# 6. Verify.
if command -v claude >/dev/null 2>&1; then
  log "Claude Code installed: $(claude --version 2>/dev/null || echo 'installed')"
  log "Done! Restart Termux (or run 'source ~/.bashrc'), then run: claude"
else
  warn "Installation finished but 'claude' is not on PATH yet."
  warn "Restart Termux or run: source ~/.bashrc"
fi
