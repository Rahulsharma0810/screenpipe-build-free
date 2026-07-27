# screenpipe-build-free

Free-tier build of [screenpipe](https://github.com/screenpipe/screenpipe) for macOS arm64. Builds pristine upstream at a tag, applies free-tier gate patches, signs ad-hoc, publishes a GitHub release with a DMG.

- **Repo:** `Rahulsharma0810/screenpipe-build-free`
- **Branch:** `build-free/auto` (default)
- **Workflow:** `.github/workflows/build-free.yml` (`Build Free Screenpipe (macOS arm64, unsigned)`)
- **Release format:** `app-vX.Y.Z-pr-4333-4344` with asset `screenpipe-macos-arm64.dmg`

## Autonomous pipeline

`scripts/autonomous-pipe.sh` runs the full CI → install loop:

```
1. FETCH     Latest CI run on Rahulsharma0810/screenpipe-build-free
             in_progress → poll every 3 min until completed
             completed   → proceed directly
2. EVALUATE  conclusion:
             success  → step 4
             failure  → step 3
3. DIAGNOSE  Read failed log (gh run view <id> --log-failed),
             apply source patch or workflow fix, re-dispatch. → step 1
4. DOWNLOAD  .dmg from the successful release
5. INSTALL   Mount DMG, copy to /Applications, inside-out re-sign
             with 'Screenpipe Local Dev' identity (preserves TCC)
6. VERIFY    codesign --verify --deep --strict + embedded version check
7. LOG       Timestamp, run ID, outcome → scripts/ci-cycle.log
8. SLEEP     Until next interval, repeat from 1
```

### Usage

```bash
# Single cycle (poll → install → done)
scripts/autonomous-pipe.sh

# Continuous loop (default 3h interval)
scripts/autonomous-pipe.sh --loop

# Custom interval (e.g. 30 min)
scripts/autonomous-pipe.sh --loop 1800
```

### Manual dispatch

```bash
gh workflow run "Build Free Screenpipe (macOS arm64, unsigned)" \
  --repo Rahulsharma0810/screenpipe-build-free \
  -f ref=app-vX.Y.Z \
  -f apply_pr=4333,4344
```

## Scheduled task (launchd)

Set up a macOS launchd job to run the pipeline every 6 hours:

```bash
# 1. Create directories
mkdir -p ~/Library/LaunchAgents ~/.cache/screenpipe-auto

# 2. Create the plist
cat > ~/Library/LaunchAgents/com.rvs.screenpipe-autopipe.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rvs.screenpipe-autopipe</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/rvs/Repositories/SVNs/Github-Rahulsharma0810/screenpipe-build-free/scripts/autonomous-pipe.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>StandardOutPath</key>
    <string>/Users/rvs/.cache/screenpipe-auto/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/rvs/.cache/screenpipe-auto/launchd-stderr.log</string>
</dict>
</plist>
PLIST

# 3. Load it
launchctl load ~/Library/LaunchAgents/com.rvs.screenpipe-autopipe.plist

# 4. Verify
launchctl list | grep screenpipe-autopipe
```

| Interval | Seconds |
|---|---|
| 1 hour | 3600 |
| 3 hours | 10800 |
| 6 hours | 21600 (default) |
| 12 hours | 43200 |
| 24 hours | 86400 |

### Manage

| Action | Command |
|---|---|
| Stop | `launchctl unload ~/Library/LaunchAgents/com.rvs.screenpipe-autopipe.plist` |
| Start | `launchctl load ~/Library/LaunchAgents/com.rvs.screenpipe-autopipe.plist` |
| Restart | `launchctl unload ... && launchctl load ...` |

## Scripts

| Script | Purpose |
|---|---|
| `scripts/autonomous-pipe.sh` | Full autonomous loop (CI poll → install → verify) |
| `scripts/auto-install-screenpipe.sh` | Download latest release, install, re-sign |
| `scripts/poll-and-verify.sh` | Poll a specific run, download & verify DMG |
| `scripts/ci-cycle.log` | Append-only audit trail of all pipeline cycles |

## Logs

| Log | Path | Contents |
|---|---|---|
| Pipeline | `scripts/ci-cycle.log` | High-level cycle outcomes |
| Install | `~/.cache/screenpipe-auto/auto-install.log` | Detailed install/sign steps |
| Stdout | `~/.cache/screenpipe-auto/launchd-stdout.log` | Script stdout |
| Stderr | `~/.cache/screenpipe-auto/launchd-stderr.log` | Script stderr |

```bash
tail -10 scripts/ci-cycle.log          # recent cycles
tail -50 ~/.cache/screenpipe-auto/auto-install.log  # install details
```

## State

- `~/.cache/screenpipe-auto/last_installed_tag` — prevents re-installing the same release
- `~/.cache/screenpipe-auto/auto-install.log` — detailed install log
- `scripts/ci-cycle.log` — pipeline-level audit trail

## Troubleshooting

```bash
# Reset state (force reinstall)
rm ~/.cache/screenpipe-auto/last_installed_tag

# App becomes root-owned (needs sudo once)
sudo chown -R $(id -u):$(id -g) /Applications/screenpipe.app

# Uninstall scheduled task
launchctl unload ~/Library/LaunchAgents/com.rvs.screenpipe-autopipe.plist
rm ~/Library/LaunchAgents/com.rvs.screenpipe-autopipe.plist
```

## Build notes

- CI signs ad-hoc (`-`); local install re-signs with `Screenpipe Local Dev` identity
- Signing is inside-out: dylibs/.so/.metallib first, then executables, then outer bundle
- Post-sign quarantine cleared via `xattr -dr com.apple.quarantine` (never `xattr -cr` — preserves cs.* xattrs for metallib)
- TCC usage keys (Mic, Screen, Camera, Accessibility, AppleEvents) injected by install script
- Build guard prevents shipping stale DMGs (verifies embedded binary version matches release tag)
- Unclean PR patches are skipped (Tier-4 whole-file overwrite removed) — builds pristine upstream
