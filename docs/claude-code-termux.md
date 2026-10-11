# Claude Code on Termux

`scripts/claude-code-termux.sh` installs Claude Code on Android/Termux. This
page explains why a plain `npm install -g @anthropic-ai/claude-code` no longer
works there, and what each piece of the script does about it. Everything below
was checked against Claude Code 2.1.287/2.1.296 and the Termux glibc and
termux-exec sources.

## Usage

```sh
bash scripts/claude-code-termux.sh install        # native glibc build (default)
bash scripts/claude-code-termux.sh update         # newer version, previous one kept
bash scripts/claude-code-termux.sh use 2.1.287    # roll back
bash scripts/claude-code-termux.sh doctor         # state + DNS test from inside the binary
bash scripts/claude-code-termux.sh proot          # fallback: proot-distro Debian
bash scripts/claude-code-termux.sh legacy         # fallback: npm 2.1.112 on Termux Node.js
```

`install` needs `aarch64` or `x86_64`. Devices that fail the smoke test, or
32-bit ARM devices, should use `proot` or `legacy`.

## Why npm fails

Up to 2.1.112 the npm package shipped `cli.js` and ran on any Node.js. Since
2.1.113 it is a launcher: `install.cjs` picks a native binary from
`optionalDependencies` and copies it over `bin/claude.exe`. Termux's Node.js
reports `process.platform === "android"`, so the launcher looks for
`@anthropic-ai/claude-code-linux-arm64-android`. That name is in its platform
table, but no such package is published and it is not in
`optionalDependencies`. The install "succeeds" and leaves a shell stub that
only prints an error.

## Native mode: what the script changes and why

### 1. ELF interpreter

The `linux-arm64` binary is a Bun standalone executable linked against glibc.
It asks for `/lib/ld-linux-aarch64.so.1`, which Android does not have, and its
newest symbol version is `GLIBC_2.26`. Termux's `glibc-repo` provides glibc under
`$PREFIX/glibc`, so the script runs:

```sh
patchelf --set-interpreter $PREFIX/glibc/lib/ld-linux-aarch64.so.1 claude
```

This is safe because Bun stores the bundled JavaScript in an ELF section
(`.bun`) inside a `PT_LOAD` segment, not as bytes appended after the ELF.
patchelf moves headers but keeps section contents and virtual addresses. Patching
the interpreter keeps `/proc/self/exe` pointing at the binary, unlike
`ld.so ./claude`. That matters because Claude Code re-executes its own binary
under other names (see section 3).

The download comes from the same place as the official `install.sh`
(`downloads.claude.ai/claude-code-releases/<version>/`). The script checks it
against the SHA-256 in that version's manifest. It uses the zstd variant
(~90 MB instead of ~250 MB) when `manifest.zst.json` lists one.

### 2. DNS

Termux's glibc is built with `--prefix=$PREFIX/glibc`, and its
`_PATH_RESCONF` is patched to `$PREFIX/glibc/etc/resolv.conf`. No package
ships that file. Without it, glibc falls back to `127.0.0.1:53`, and every
`getaddrinfo()` fails with `EAI_AGAIN`.

Inside the binary, `fetch`, `node:http`, `node:net`, `Bun.connect` and
`WebSocket` all resolve through `getaddrinfo()`. Only explicit
`dns.resolve*()` / `Bun.dns.lookup()` use c-ares, which reads the hardcoded
`/etc/resolv.conf`. That path does not exist on modern Android either.
`dns.setServers()` fixes c-ares only and has no effect on the connection path.
The script therefore symlinks `$PREFIX/glibc/etc/resolv.conf` to Termux's
`$PREFIX/etc/resolv.conf`, so there is one file to edit. `doctor` resolves
`api.anthropic.com` from inside the glibc process (a `BUN_OPTIONS=--preload`
probe calling `dns.lookup`) to check this end to end.

### 3. `LD_PRELOAD`: bionic vs glibc

Termux runs every process with a bionic `LD_PRELOAD` (termux-exec). It
rewrites `/usr/bin/env`, `/bin/sh` and similar shebang paths. When glibc's
`ld.so` loads that library, it tries to resolve its `DT_NEEDED` entries
(`libc.so`, `libdl.so`). It finds a linker script or nothing, and the error is
fatal for the whole process (`error while loading shared libraries`, exit 127).
termux-exec only strips `LD_*` when it executes a foreign-arch ELF or a
`/system` binary, so an aarch64 glibc binary keeps the preload.

The launcher therefore removes `LD_PRELOAD`/`LD_LIBRARY_PATH` before it
execs claude, and saves them as `CLAUDE_TERMUX_LD_PRELOAD` /
`CLAUDE_TERMUX_LD_LIBRARY_PATH`. Two documented hooks give them back to
claude's bionic children:

- **`CLAUDE_CODE_SHELL_PREFIX`** wraps Bash tool calls, hooks, the status line
  and stdio MCP server commands. The prefix script restores the variables and
  runs `exec bash -c "$1"`. Without this, `npx`-started MCP servers and any
  npm-installed CLI (`#!/usr/bin/env node`) fail with ENOENT.
- **`CLAUDE_ENV_FILE`**: Claude Code inlines this file into every Bash tool
  command, right after it sources its shell snapshot. The native build's
  snapshot defines `find` and `grep` (and `rg` when no system `rg` exists) as
  shell functions that run `exec -a bfs|ugrep|rg "$CLAUDE_CODE_EXECPATH"`,
  which re-executes the glibc binary. With the bionic preload restored, that
  exec hits the fatal `ld.so` error above. The env file runs
  `unset -f find grep rg`, so Termux's own GNU find/grep run instead. If you
  set your own `CLAUDE_ENV_FILE`, the launcher sources it from there via
  `CLAUDE_TERMUX_USER_ENV_FILE`.

`USE_BUILTIN_RIPGREP=0` makes the Grep/Glob tools use Termux's bionic `rg`.

### 4. Other environment

- `CLAUDE_CODE_TMPDIR=$TMPDIR`: some internal paths fall back to
  `/tmp/claude`, which an app cannot create on Android.
- `DISABLE_UPDATES=1`: `claude update` / `claude install` would fetch an
  unpatched binary. Update with `scripts/claude-code-termux.sh update`.
- `child_process` calls with `shell: true` hardcode `/bin/sh` because the
  process believes it runs on linux. AOSP links `/bin` to `/system/bin`, so
  those land on `/system/bin/sh`. `doctor` shows where `/bin/sh` points.
  `install` warns if it is missing.

### 5. Smoke test

Each new version runs `--version` and `--init-only` in a throwaway `HOME`
before `current` switches to it. A failing version is never activated. A death
by signal rejects the version:

- `SIGSYS`: Android's seccomp filter rejected a raw syscall such as `statx` or
  `pidfd_open`. This is typical on Android ≤ 10.
- `SIGSEGV`: glibc's syscall emulation shims crashed.

On such devices use `proot` (heavier, but the official installer and updater
work unchanged) or `legacy`. `legacy` pins the last pure-JS release
(2.1.112). It gets no fixes and stops working once the service raises its
minimum supported version.

## Layout

```
$PREFIX/bin/claude                       launcher (generated)
$PREFIX/opt/claude-code/current          -> versions/<version>
$PREFIX/opt/claude-code/versions/<v>/    patched binaries (current + previous)
$PREFIX/opt/claude-code/libexec/         shell-prefix, bash-env
$PREFIX/glibc/etc/resolv.conf            -> $PREFIX/etc/resolv.conf
```

`uninstall` removes all of the above. It leaves `~/.claude` and
`~/.claude.json` in place.
