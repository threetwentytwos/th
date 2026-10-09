# Fixing "claude native binary not installed" on Termux (Android)

## Symptom

After installing Claude Code with npm on Termux, running `claude` fails:

```
Error: claude native binary not installed.

Either postinstall did not run (--ignore-scripts, some pnpm configs)
or the platform-native optional dependency was not downloaded
(--omit=optional).
```

Running the suggested `node node_modules/@anthropic-ai/claude-code/install.cjs`
does **not** fix it on Termux.

## Root cause

Starting with **v2.1.113**, Claude Code ships as a native Linux binary linked
against glibc instead of a JavaScript entry point. Two things break on Termux:

1. **npm never downloads the binary.** Termux's Node reports
   `process.platform === "android"`, so the platform-gated optional dependency
   (`@anthropic-ai/claude-code-linux-arm64`) is skipped — no platform matches.
2. **The binary can't run anyway.** Android uses Bionic libc, and its dynamic
   linker rejects the glibc executable (`unexpected e_type: 2`). Even
   force-installing the linux-arm64 package fails at exec time.

Tracked upstream in
[anthropics/claude-code#50270](https://github.com/anthropics/claude-code/issues/50270)
and [#20778](https://github.com/anthropics/claude-code/issues/20778).

## Fix

Run [`scripts/termux-fix-claude.sh`](scripts/termux-fix-claude.sh) inside Termux.
It supports two modes:

### Native mode (default — current Claude Code versions)

```bash
bash scripts/termux-fix-claude.sh
```

What it does:

1. Installs Termux's glibc compatibility packages (`glibc-runner`,
   `patchelf-glibc`).
2. Downloads the official `linux-arm64` binary from
   `https://downloads.claude.ai/claude-code-releases/<version>/linux-arm64/claude`
   and verifies its SHA256 against Anthropic's published `manifest.json`.
3. Rewrites the binary's ELF interpreter to Termux's glibc loader
   (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`) with `patchelf`, so Android can
   execute it.
4. Removes the broken npm install and places a wrapper at `$PREFIX/bin/claude`
   that unsets `LD_PRELOAD` (termux-exec breaks glibc binaries) and sets
   `DISABLE_AUTOUPDATER=1` (the built-in updater would overwrite the patched
   binary with an unpatched one).
5. Smoke-tests with `claude --version`.

To update Claude Code later, just re-run the script — it fetches and patches
the latest release. A specific version can be pinned with `--version X.Y.Z`.

### JS mode (fallback — old but zero-patching)

```bash
bash scripts/termux-fix-claude.sh --mode js
```

Pins `@anthropic-ai/claude-code@2.1.112`, the last release with a JavaScript
entry point, which runs on stock Termux Node with no binary patching. It also
adds `DISABLE_AUTOUPDATER=1` to `~/.bashrc` so the CLI doesn't upgrade itself
back into the broken native versions. Use this if the glibc-runner approach
fails on your device — the trade-off is being frozen on an old version.

## Alternatives considered

- **`linux-arm64-musl` build**: Anthropic publishes musl builds, but they are
  dynamically linked against `/lib/ld-musl-aarch64.so.1`, which doesn't exist
  on Android — so they don't run out of the box either.
- **proot-distro (Ubuntu in Termux)**: works and needs no patching, but adds
  syscall-emulation overhead that makes interactive use noticeably slower.

## Sources

- [anthropics/claude-code#50270 — v2.1.113+ broken on Termux/Android](https://github.com/anthropics/claude-code/issues/50270)
- [anthropics/claude-code#20778 — Native installer incompatible with Termux/Android](https://github.com/anthropics/claude-code/issues/20778)
- [ferrumclaudepilgrim/claude-code-android — glibc-runner approach](https://github.com/ferrumclaudepilgrim/claude-code-android)
- [Official bootstrap.sh — release CDN and manifest layout](https://downloads.claude.ai/claude-code-releases/bootstrap.sh)
