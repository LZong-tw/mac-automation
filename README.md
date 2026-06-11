# mac-automation

**English** | [繁體中文](README.zh-TW.md)

Personal macOS automation toolkit: shell + Swift utilities with their
LaunchAgents. On a new machine, `./install.sh` restores everything
(build → symlink → bootstrap agents).

## Tools

| Tool | LaunchAgent | Purpose |
|---|---|---|
| `memory-guardian` | ✓ every 120s | Memory pressure warning/critical alerts; auto-stops a deep-idle podman VM at critical level |
| `input-source-restorer` | ✓ daemon | Input source guard — stops macOS from hijacking your IME (Swift, see below) |
| `input-source-monitor.sh` | ✓ daemon | Logs input source switches with the frontmost app at that moment |
| `input-tap` | — | Input diagnostics: logs Caps Lock events and input source changes (Swift) |
| `capslock-monitor` | ✓ daemon | Logs Caps Lock state changes with the frontmost app (Swift) |
| `daily-work-report-reminder` | ✓ | 17:00 work report notification |
| `kubectl-eks-token` | — | kubectl exec credential plugin: AWS/Granted fallback chain (ambient → AWS_PROFILE → assume → assume --no-cache) |

## Install

```bash
./install.sh   # build.sh compiles the Swift tools, symlinks bin/* → ~/.local/bin, copies plists and bootstraps agents
```

## input-source-restorer: IME hijack guard (v11 policy)

macOS sometimes switches the input source to ABC — during secure input
(password fields) or for no visible reason at all. This daemon watches
TIS change notifications and restores the input source the user actually
wants:

- **Secure-input whitelist**: when loginwindow / SecurityAgent /
  CoreAuthentication.agent holds secure input, switching to ABC is
  expected — wait for `SECURE_OFF`, then restore
- **MYSTERY_DETECTED**: switched away with no secure-input context →
  capture the top-CPU processes at that instant; over time the log
  reveals which background process keeps messing with the input source
- **BACKOFF**: ≥3 consecutive restores pauses 5s, so we never get into
  an infinite fight with another program
- **TIS vs TIS_OWN**: event tags distinguish "externally-caused switch"
  from "switch caused by our own restore" — forensics stays clean
  instead of polluting itself

## Binary archaeology: how the Swift tools were resurrected

The original sources were lost; only arm64 binaries kept running in
`~/.local/bin` for months. When publishing this repo (2026-06), the
specs were reverse-engineered from three sources:

1. `strings` — log message templates, defaults keys, whitelisted bundle
   ids, an embedded `ps` command
2. `otool -L` — linked frameworks (Carbon/AppKit/CoreGraphics)
3. **Months of real logs** — the trigger conditions and exact output
   format of every event

The rewrites ran side-by-side with the old binaries until behavior
matched, then replaced them. Lesson learned: **a binary whose source you
deleted after compiling is a liability** — the archaeology took longer
than writing the tools did.

## memory-guardian: background and design decisions

Origin (2026-06-11): on a 16GB MacBook Pro under heavy load,
WindowServer died from memory pressure → loginwindow performed a
cleanup logout (`Logout triggered by windowserver exit`) → the entire
GUI session was torn down and rebuilt, three times in one day. The
guardian intervenes before pressure peaks.

- WARN (free<25% or swap>75%): notify, 30-min cooldown
- CRIT (free<15% or swap>90%): notify + auto-stop a *deep-idle* podman VM
- `SACRIFICE_APPS` defaults to empty (deliberately: never auto-quit the
  user's apps)

### Deep-idle determination (ALL must hold before stopping the VM)

1. No podman CLI process on the host (compared by binary name via
   `ps -axo comm=`)
2. `podman ps` succeeds **and** is empty, or —
3. Every running container: postgres → last client activity in
   `pg_stat_activity` > 2h; others → CPU < 1%
4. **Any query failure counts as not-idle** — prefer missing a stop
   over killing something in use

### Pitfalls encountered (read before touching this script)

- **launchd's PATH has no `/opt/podman/bin`** — the script must export
  PATH itself, or `command -v podman` fails silently and scheduled runs
  look like nothing happened
- **`pgrep -f 'podman exec'` false-positives** — any unrelated process
  whose argv happens to contain that string (e.g. your own test command)
  matches; compare real binary names via `ps -axo comm=` instead
- **`pg_stat_activity` must exclude itself** — `pid <> pg_backend_pid()`,
  otherwise the probe query itself is "recent activity" and the DB looks
  busy forever
- Log every silent path — errors swallowed by `2>/dev/null` cost an hour
  of debugging each

## kubectl-eks-token design

A kubectl exec plugin's stdout must be pure ExecCredential JSON — any
human-readable message leaking into stdout breaks kubectl. So every
fallback attempt writes to a temp file and validates the format before
emitting. Credential source priority: already-assumed ambient session →
AWS_PROFILE → Granted assume → assume --no-cache (handles Granted's
occasional stale cache).
