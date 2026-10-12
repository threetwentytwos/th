#!/usr/bin/env bash
set -euo pipefail

# claude-code-termux.sh — Install and run Claude Code on Termux (Android).
#
# Since 2.1.113 the npm package is only a launcher for per-platform native
# binaries, and no android build is published, so `npm i -g` on Termux leaves
# a stub behind. This script runs the official linux glibc build instead:
#
#   native  (default) linux-arm64/x64 binary, ELF interpreter patched to
#           Termux's glibc loader, plus a launcher that fixes DNS, /tmp and
#           the bionic/glibc LD_PRELOAD clash. See docs/claude-code-termux.md.
#   proot   official installer inside a proot-distro Debian/Ubuntu.
#   legacy  last pure-JS npm release (2.1.112) on Termux's Node.js.

PROG="$(basename "$0")"
DOWNLOAD_BASE="https://downloads.claude.ai/claude-code-releases"
LEGACY_VERSION="2.1.112"
MARKER="# managed-by: claude-code-termux"

usage() {
  cat <<EOF
Usage: ${PROG} <command> [args]

Commands:
  install [latest|stable|VERSION]  Install the native build (default: latest)
  update  [latest|stable]          Same as install; keeps the previous version
  use VERSION                      Switch to another installed version
  proot   [debian|ubuntu]          Install inside proot-distro instead
  legacy                           Install npm ${LEGACY_VERSION} on Termux Node.js
  doctor                           Show install state and test DNS from glibc
  uninstall                        Remove launcher and binaries (keeps ~/.claude)

Environment:
  CLAUDE_TERMUX_ROOT  Install root (default: \$PREFIX/opt/claude-code)
EOF
  exit "${1:-0}"
}

log() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

require_termux() {
  if [[ -z "${PREFIX:-}" ]] || ! command -v pkg >/dev/null 2>&1; then
    die "this script must run inside Termux (\$PREFIX and pkg not found)"
  fi
  ROOT="${CLAUDE_TERMUX_ROOT:-$PREFIX/opt/claude-code}"
  VERSIONS_DIR="${ROOT}/versions"
  LIBEXEC_DIR="${ROOT}/libexec"
  LAUNCHER="${PREFIX}/bin/claude"
  TMPDIR="${TMPDIR:-$PREFIX/tmp}"
}

detect_arch() {
  case "$(uname -m)" in
    aarch64)
      PLATFORM="linux-arm64"
      GLIBC_LD="${PREFIX}/glibc/lib/ld-linux-aarch64.so.1"
      ;;
    x86_64)
      PLATFORM="linux-x64"
      GLIBC_LD="${PREFIX}/glibc/lib/ld-linux-x86-64.so.2"
      ;;
    *)
      die "no native Claude Code build for $(uname -m); try: ${PROG} legacy"
      ;;
  esac
}

ensure_pkgs() {
  local missing=() p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  log "Installing Termux packages: ${missing[*]}"
  pkg install -y "${missing[@]}"
}

# Termux's glibc is built with prefix $PREFIX/glibc, so its resolver reads
# $PREFIX/glibc/etc/resolv.conf, which no package ships. Without it every
# getaddrinfo() falls back to 127.0.0.1:53 and fails with EAI_AGAIN. Bun's
# fetch, node:http, node:net and WebSocket all resolve through getaddrinfo.
# Point it at Termux's own resolv.conf so there is a single file to edit.
ensure_glibc_resolv() {
  local src="${PREFIX}/etc/resolv.conf" dst="${PREFIX}/glibc/etc/resolv.conf"
  [[ -s "$src" ]] || die "${src} is missing (pkg install resolv-conf)"
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" || ! -e "$dst" ]]; then
    ln -sfn "$src" "$dst"
  else
    log "Keeping existing ${dst}"
  fi
}

resolve_version() {
  local v="$1"
  case "$v" in
    latest|stable) v="$(curl -fsSL "${DOWNLOAD_BASE}/${v}" || true)" ;;
  esac
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "could not resolve a version (got '${v:0:40}'); is downloads.claude.ai reachable?"
  echo "$v"
}

verify_sha256() {
  local file="$1" want="$2" got
  got="$(sha256sum "$file" | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] || die "checksum mismatch for ${file##*/}: ${got} != ${want}"
}

manifest_checksum() {
  jq -r --arg p "$PLATFORM" '.platforms[$p].checksum // empty' 2>/dev/null || true
}

# Same source and checks as the official install.sh: the per-version manifest
# carries the SHA-256 of the raw binary and, in manifest.zst.json, of the
# zstd-compressed one (~90 MB instead of ~250 MB).
fetch_binary() {
  local version="$1" dest="$2" sum zsum
  sum="$(curl -fsSL "${DOWNLOAD_BASE}/${version}/manifest.json" | manifest_checksum || true)"
  [[ "$sum" =~ ^[a-f0-9]{64}$ ]] || die "no ${PLATFORM} build in the ${version} manifest"
  zsum="$(curl -fsSL "${DOWNLOAD_BASE}/${version}/manifest.zst.json" 2>/dev/null | manifest_checksum || true)"

  if [[ "$zsum" =~ ^[a-f0-9]{64}$ ]]; then
    log "Downloading ${version}/${PLATFORM}/claude.zst"
    curl -fL --retry 3 --progress-bar -o "${dest}.zst" \
      "${DOWNLOAD_BASE}/${version}/${PLATFORM}/claude.zst"
    verify_sha256 "${dest}.zst" "$zsum"
    zstd -dqf "${dest}.zst" -o "$dest"
    rm -f "${dest}.zst"
  else
    log "Downloading ${version}/${PLATFORM}/claude"
    curl -fL --retry 3 --progress-bar -o "$dest" \
      "${DOWNLOAD_BASE}/${version}/${PLATFORM}/claude"
  fi
  verify_sha256 "$dest" "$sum"
}

describe_exit() {
  local rc="$1"
  if (( rc > 128 )); then
    echo "killed by SIG$(kill -l $((rc - 128)) 2>/dev/null || echo "?") (exit ${rc})"
  else
    echo "exit ${rc}"
  fi
}

# Run the patched binary in a throwaway HOME. Death by signal is what a bad
# build looks like here: SIGSYS when Android's seccomp filter rejects a raw
# syscall (statx, pidfd_open on Android <= 10), SIGSEGV in glibc's syscall
# shims. --init-only exercises more of startup than --version; a plain
# non-zero exit from it (offline, flag removed) is not treated as a crash.
smoke_test() {
  local bin="$1" home rc=0
  home="$(mktemp -d "${TMPDIR}/claude-smoke.XXXXXX")"
  env -u LD_PRELOAD -u LD_LIBRARY_PATH HOME="$home" CLAUDE_CODE_TMPDIR="$TMPDIR" \
    "$bin" --version >/dev/null 2>"${home}/err" || rc=$?
  if (( rc == 0 )); then
    env -u LD_PRELOAD -u LD_LIBRARY_PATH HOME="$home" CLAUDE_CODE_TMPDIR="$TMPDIR" \
      timeout 60 "$bin" --init-only </dev/null >/dev/null 2>>"${home}/err" || rc=$?
    (( rc > 128 )) || rc=0
  fi
  if (( rc != 0 )); then
    echo "smoke test failed: $(describe_exit "$rc")" >&2
    sed 's/^/  | /' "${home}/err" | tail -n 15 >&2
  fi
  rm -rf "$home"
  return "$rc"
}

current_version() {
  local target
  target="$(readlink "${ROOT}/current" 2>/dev/null)" || return 0
  basename "$target"
}

installed_versions() {
  local d out=""
  for d in "${VERSIONS_DIR}"/*/; do
    if [[ -x "${d}claude" ]]; then out+="$(basename "$d") "; fi
  done
  echo "${out:-none}"
}

render() {
  sed -e "s|@PREFIX@|${PREFIX}|g" -e "s|@ROOT@|${ROOT}|g" -e "s|@MARKER@|${MARKER}|g" \
    -e "s|@DISTRO@|${DISTRO:-}|g" -e "s|@NPM_ROOT@|${NPM_ROOT:-}|g"
}

# Never write through an existing file: after `npm i -g` the launcher path is
# a symlink into node_modules.
install_launcher() {
  local tmp
  tmp="$(mktemp "${PREFIX}/bin/.claude.XXXXXX")"
  render >"$tmp"
  chmod 755 "$tmp"
  rm -f "$LAUNCHER"
  mv "$tmp" "$LAUNCHER"
}

launcher_is_ours() {
  [[ -f "$LAUNCHER" && ! -L "$LAUNCHER" ]] && grep -q "$MARKER" "$LAUNCHER" 2>/dev/null
}

# Ours, or the symlink `npm i -g @anthropic-ai/claude-code` leaves behind.
check_launcher_owner() {
  [[ -e "$LAUNCHER" || -L "$LAUNCHER" ]] || return 0
  launcher_is_ours && return 0
  [[ -L "$LAUNCHER" && "$(readlink "$LAUNCHER")" == *@anthropic-ai/claude-code/* ]] && return 0
  die "${LAUNCHER} exists and was not written by ${PROG}; move it away first"
}

write_native_helpers() {
  mkdir -p "$LIBEXEC_DIR"

  # CLAUDE_CODE_SHELL_PREFIX: wraps Bash tool calls, hooks, status line and
  # stdio MCP server commands. Gives those bionic children back the
  # termux-exec LD_PRELOAD the launcher kept away from the glibc process,
  # so `#!/usr/bin/env` shebangs (npx, npm-installed CLIs) resolve again.
  render >"${LIBEXEC_DIR}/shell-prefix" <<'EOF'
#!@PREFIX@/bin/sh
@MARKER@
if [ -n "${CLAUDE_TERMUX_LD_PRELOAD:-}" ]; then export LD_PRELOAD="$CLAUDE_TERMUX_LD_PRELOAD"; fi
if [ -n "${CLAUDE_TERMUX_LD_LIBRARY_PATH:-}" ]; then export LD_LIBRARY_PATH="$CLAUDE_TERMUX_LD_LIBRARY_PATH"; fi
exec @PREFIX@/bin/bash -c "$1"
EOF
  chmod 755 "${LIBEXEC_DIR}/shell-prefix"

  # CLAUDE_ENV_FILE: Claude Code inlines this into every Bash tool command
  # right after sourcing its shell snapshot. The snapshot defines find and
  # grep (and rg when no system rg exists) as functions that re-exec the
  # glibc claude binary as bfs/ugrep/rg. With the bionic LD_PRELOAD back in
  # place that exec dies in glibc's ld.so, so drop them for Termux's tools.
  render >"${LIBEXEC_DIR}/bash-env" <<'EOF'
unset -f find grep rg 2>/dev/null; true
@MARKER@
if [ -n "${CLAUDE_TERMUX_LD_PRELOAD:-}" ]; then export LD_PRELOAD="$CLAUDE_TERMUX_LD_PRELOAD"; fi
if [ -n "${CLAUDE_TERMUX_USER_ENV_FILE:-}" ] && [ -r "$CLAUDE_TERMUX_USER_ENV_FILE" ]; then . "$CLAUDE_TERMUX_USER_ENV_FILE"; fi
EOF
}

write_native_launcher() {
  install_launcher <<'EOF'
#!@PREFIX@/bin/sh
@MARKER@ (native)
# Termux preloads a bionic library (termux-exec) into every process. Loaded by
# glibc's ld.so it fails fatally, so claude itself runs without it and the
# shell-prefix hands it back to the commands claude spawns.
if [ -n "${LD_PRELOAD:-}" ]; then export CLAUDE_TERMUX_LD_PRELOAD="$LD_PRELOAD"; fi
if [ -n "${LD_LIBRARY_PATH:-}" ]; then export CLAUDE_TERMUX_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"; fi
unset LD_PRELOAD LD_LIBRARY_PATH

case "${CLAUDE_ENV_FILE:-}" in
  ""|@ROOT@/libexec/bash-env) ;;
  *) export CLAUDE_TERMUX_USER_ENV_FILE="$CLAUDE_ENV_FILE" ;;
esac
export CLAUDE_ENV_FILE=@ROOT@/libexec/bash-env
export CLAUDE_CODE_SHELL_PREFIX="${CLAUDE_CODE_SHELL_PREFIX:-@ROOT@/libexec/shell-prefix}"

# Internal temp files would otherwise go to /tmp, which Android does not give us.
export CLAUDE_CODE_TMPDIR="${CLAUDE_CODE_TMPDIR:-${TMPDIR:-@PREFIX@/tmp}}"
# Termux's bionic rg works without any preload games.
export USE_BUILTIN_RIPGREP=0
# `claude update` would fetch an unpatched binary; run the installer instead.
export DISABLE_UPDATES=1

exec @ROOT@/current/claude "$@"
EOF
}

switch_to() {
  local version="$1"
  ln -sfn "versions/${version}" "${ROOT}/current"
}

prune_versions() {
  local keep_a="$1" keep_b="${2:-}" d name
  rm -rf "${VERSIONS_DIR}"/.stage-*
  for d in "${VERSIONS_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    [[ "$name" == "$keep_a" || "$name" == "$keep_b" ]] && continue
    rm -rf "$d"
  done
}

STAGE=""
cleanup_stage() { [[ -z "$STAGE" ]] || rm -rf "$STAGE"; }

cmd_install() {
  local want="${1:-latest}" version prev
  require_termux
  detect_arch
  check_launcher_owner

  if ! dpkg -s glibc-repo >/dev/null 2>&1; then
    ensure_pkgs glibc-repo
    apt-get update -q
  fi
  ensure_pkgs glibc patchelf curl jq zstd ripgrep resolv-conf
  [[ -x "$GLIBC_LD" ]] || die "glibc loader not found at ${GLIBC_LD}"
  ensure_glibc_resolv
  # The glibc process believes it is on linux, so child_process `shell: true`
  # spawns hardcode /bin/sh. AOSP links /bin to /system/bin; without it those
  # spawns fail with ENOENT.
  [[ -x /bin/sh ]] || warn "/bin/sh does not exist on this device; some features will fail (consider: ${PROG} proot)"

  version="$(resolve_version "$want")"
  prev="$(current_version)"
  mkdir -p "$VERSIONS_DIR"

  if [[ "$prev" == "$version" && -x "${VERSIONS_DIR}/${version}/claude" ]]; then
    log "Claude Code ${version} is already current"
  else
    STAGE="$(mktemp -d "${VERSIONS_DIR}/.stage-${version}.XXXXXX")"
    trap cleanup_stage EXIT
    fetch_binary "$version" "${STAGE}/claude"

    # The binary asks for /lib/ld-linux-*.so.*, which Android does not have.
    # Bun keeps the bundled JS in an ELF section (.bun) inside a PT_LOAD
    # segment, so rewriting PT_INTERP leaves the payload intact.
    patchelf --set-interpreter "$GLIBC_LD" "${STAGE}/claude"
    chmod 755 "${STAGE}/claude"

    log "Smoke-testing ${version}"
    if ! smoke_test "${STAGE}/claude"; then
      echo >&2
      echo "Claude Code ${version} does not run on this device; nothing was changed." >&2
      echo "Alternatives: '${PROG} proot' (proot-distro) or '${PROG} legacy' (npm ${LEGACY_VERSION})." >&2
      exit 1
    fi

    rm -rf "${VERSIONS_DIR:?}/${version}"
    mv "$STAGE" "${VERSIONS_DIR}/${version}"
    STAGE=""
    switch_to "$version"
    prune_versions "$version" "$prev"
  fi

  write_native_helpers
  write_native_launcher
  log "Claude Code ${version} installed (${PLATFORM}, glibc)"
  if [[ -n "$prev" && "$prev" != "$version" ]]; then
    log "Previous version kept: ${prev} (${PROG} use ${prev})"
  fi
  log "Run: claude"
}

cmd_use() {
  local version="${1:-}"
  require_termux
  [[ -n "$version" ]] || usage 1
  [[ -x "${VERSIONS_DIR}/${version}/claude" ]] \
    || die "version ${version} is not installed (have: $(installed_versions))"
  switch_to "$version"
  log "Now using Claude Code ${version}"
}

cmd_proot() {
  DISTRO="${1:-debian}"
  require_termux
  case "$DISTRO" in
    debian|ubuntu) ;;
    *) die "only debian and ubuntu are supported (apt-based)" ;;
  esac
  check_launcher_owner
  ensure_pkgs proot-distro

  if ! proot-distro login "$DISTRO" -- true >/dev/null 2>&1; then
    log "Installing proot-distro ${DISTRO}"
    proot-distro install "$DISTRO"
  fi

  # Inside the guest process.platform is linux, /etc/resolv.conf and /tmp
  # exist and the official installer and updater work unmodified.
  log "Running the official installer inside ${DISTRO}"
  proot-distro login "$DISTRO" -- /bin/sh -c '
    set -e
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl ca-certificates git ripgrep
    curl -fsSL https://claude.ai/install.sh | bash'

  # proot-distro binds Termux's $HOME at the same path, so --work-dir "$PWD"
  # keeps you in the directory you started from.
  install_launcher <<'EOF'
#!@PREFIX@/bin/sh
@MARKER@ (proot @DISTRO@)
exec proot-distro login @DISTRO@ --shared-tmp --work-dir "$PWD" -- /root/.local/bin/claude "$@"
EOF
  log "Installed in proot-distro ${DISTRO}. Run: claude"
}

cmd_legacy() {
  require_termux
  check_launcher_owner
  command -v node >/dev/null 2>&1 || ensure_pkgs nodejs-lts
  ensure_pkgs ripgrep
  warn "${LEGACY_VERSION} is the last pure-JS release (April 2026); it gets no fixes and"
  warn "may be refused once the service raises its minimum supported version."
  # npm refuses to replace a bin path it does not own.
  if launcher_is_ours; then rm -f "$LAUNCHER"; fi
  npm install -g "@anthropic-ai/claude-code@${LEGACY_VERSION}"
  NPM_ROOT="$(npm root -g)"
  [[ -f "${NPM_ROOT}/@anthropic-ai/claude-code/cli.js" ]] || die "cli.js not found under ${NPM_ROOT}"

  # The bundled ripgrep has no android build, and the autoupdater would move
  # to a native-only release that cannot run here.
  install_launcher <<'EOF'
#!@PREFIX@/bin/sh
@MARKER@ (legacy npm)
export CLAUDE_CODE_TMPDIR="${CLAUDE_CODE_TMPDIR:-${TMPDIR:-@PREFIX@/tmp}}"
export USE_BUILTIN_RIPGREP=0
export DISABLE_AUTOUPDATER=1
exec node @NPM_ROOT@/@anthropic-ai/claude-code/cli.js "$@"
EOF
  log "Claude Code ${LEGACY_VERSION} (npm) installed. Run: claude"
}

# Resolve a hostname from inside the glibc claude process: preload a script
# via BUN_OPTIONS and call dns.lookup, which Bun routes to getaddrinfo().
dns_probe() {
  local bin="$1" probe out
  probe="$(mktemp "${TMPDIR}/claude-dns.XXXXXX.js")"
  cat >"$probe" <<'EOF'
require("dns").lookup("api.anthropic.com", (e, a) => {
  console.error(e ? "FAIL " + e.code : "OK " + a);
  process.exit(0);
});
setTimeout(() => { console.error("FAIL timeout"); process.exit(0); }, 10000);
EOF
  out="$(env -u LD_PRELOAD -u LD_LIBRARY_PATH BUN_OPTIONS="--preload ${probe}" \
    "$bin" --version 2>&1 >/dev/null | grep -E '^(OK|FAIL) ' | head -n 1 || true)"
  rm -f "$probe"
  echo "${out:-inconclusive (preload not honoured)}"
}

cmd_doctor() {
  local mode bin
  require_termux
  echo "device:    $(uname -m), Android $(getprop ro.build.version.release 2>/dev/null || echo '?'), kernel $(uname -r)"
  mode="$(grep -o "${MARKER} ([a-z0-9 ]*)" "$LAUNCHER" 2>/dev/null | sed 's/.*(\(.*\))/\1/' || true)"
  echo "launcher:  ${LAUNCHER} -> ${mode:-not managed by ${PROG}}"
  echo "LD_PRELOAD in this shell: ${LD_PRELOAD:-<unset>}"
  [[ "$mode" == "native" ]] || return 0

  detect_arch
  bin="${ROOT}/current/claude"
  echo "version:   $(current_version) (installed: $(installed_versions))"
  echo "interp:    $(patchelf --print-interpreter "$bin" 2>/dev/null || echo '?')"
  if [[ -x "$GLIBC_LD" ]]; then echo "glibc ld:  ok"; else echo "glibc ld:  MISSING (${GLIBC_LD})"; fi
  echo "/bin/sh:   $(readlink -f /bin/sh 2>/dev/null || echo MISSING)"
  echo "resolv:    ${PREFIX}/glibc/etc/resolv.conf -> $(readlink -f "${PREFIX}/glibc/etc/resolv.conf" 2>/dev/null || echo MISSING)"
  echo "           nameservers: $(awk '/^nameserver/ {printf "%s ", $2}' "${PREFIX}/glibc/etc/resolv.conf" 2>/dev/null)"
  echo "dns:       $(dns_probe "$bin")"
}

cmd_uninstall() {
  require_termux
  if grep -q "$MARKER (legacy npm)" "$LAUNCHER" 2>/dev/null; then
    npm uninstall -g @anthropic-ai/claude-code || true
  fi
  if launcher_is_ours; then
    rm -f "$LAUNCHER"
  fi
  rm -rf "$VERSIONS_DIR" "$LIBEXEC_DIR" "${ROOT}/current"
  rmdir "$ROOT" 2>/dev/null || true
  local resolv="${PREFIX}/glibc/etc/resolv.conf"
  if [[ -L "$resolv" && "$(readlink "$resolv")" == "${PREFIX}/etc/resolv.conf" ]]; then
    rm -f "$resolv"
  fi
  log "Removed. Settings in ~/.claude and ~/.claude.json were left in place."
  log "A proot-distro guest is not removed; use: proot-distro remove <distro>"
}

case "${1:-}" in
  install)   shift; cmd_install "$@" ;;
  update)    shift; cmd_install "${1:-latest}" ;;
  use)       shift; cmd_use "$@" ;;
  proot)     shift; cmd_proot "$@" ;;
  legacy)    shift; cmd_legacy ;;
  doctor)    cmd_doctor ;;
  uninstall) cmd_uninstall ;;
  -h|--help|help) usage 0 ;;
  *) usage 1 ;;
esac
