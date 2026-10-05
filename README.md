# screenpipe-build-free

GitHub Actions builds of upstream [screenpipe](https://github.com/screenpipe/screenpipe) for macOS (arm64), with a few personal patches and a self-hosted updater.

**Personal use and testing only.** The Screenpipe founder permitted personal builds; work use needs a paid licence.

## Overview

`.github/workflows/build-free.yml` checks out upstream at a tag (latest `app-v*` by default, every 12 h or on manual dispatch), applies `scripts/personal-patches.sh`, builds, signs with a stable self-signed identity, and publishes a GitHub release with a DMG plus updater artifacts. Each successful non-PR build becomes an update for installed apps.

## Install & updates

1. Download the DMG from the [latest release](https://github.com/Rahulsharma0810/screenpipe-build-free/releases/latest) and drag `screenpipe.app` to `/Applications` (once).
2. Gatekeeper: right-click the app → **Open**, or run
   ```bash
   xattr -dr com.apple.quarantine /Applications/screenpipe.app
   ```
3. Grant Screen Recording, Microphone and Accessibility once.

After that, the built-in updater prompts on each new successful build. Grants carry over because every build uses the same signing certificate.

## Personal patches

Applied by `scripts/personal-patches.sh`; each is a workflow input.

| Flag | Effect | Default |
|------|--------|---------|
| `PATCH_UNLIMITED_HISTORY` | No 24 h cap (backend, activity history, timeline UI) | on |
| `PATCH_KEEP_WARM` | Unfocused monitors never go Cold | on |
| `PATCH_LOCAL_ACCESS` | Local server/recording without a paid sign-in | on |
| `PATCH_UNLIMITED_PIPES` | More than 2 custom pipes | on |
| `PATCH_NO_TRIAL_PAYWALL` | No fresh-install trial paywall | on |
| `PATCH_SELF_UPDATER` | Updater points at this repo's `latest.json`, own pubkey, `is_source_build=false` | on |

Other inputs: `build_engine` (default off; also ships a standalone `screenpipe` CLI artifact), `apply_pr` (optional upstream PR diff applied on top of the ref), `ref`.

## Manual builds

```bash
gh workflow run build-free.yml -R Rahulsharma0810/screenpipe-build-free \
  --ref build-free/auto -f ref=app-vX.Y.Z
```

With an empty `ref`, the run builds the latest upstream tag and skips if that release already exists.

## Secrets & keys

| Secret | Purpose |
|--------|---------|
| `TAURI_SIGNING_PRIVATE_KEY` / `_PASSWORD` | Signs the updater tarball (`.sig`) |
| `UPDATER_PUBKEY` | Public key embedded in the app to verify updates |
| `MACOS_CODESIGN_P12_BASE64` / `_PASSWORD` | Self-signed code-signing identity `screenpipe-build-free` |

Local copies live in `~/.config/screenpipe-build-free/`. **Back them up.** If you lose the updater key, installed apps can't accept updates and must be reinstalled by hand. If you lose the codesign cert, permissions must be granted again.

## Troubleshooting

- **Official update prompt on an old build:** decline it. Builds from before `PATCH_SELF_UPDATER` still check upstream; reinstall from this repo's DMG once.
- **Permissions stop working:** the signing certificate changed. Remove the app in System Settings → Privacy & Security and grant it again.
- **"App is damaged / can't be opened":** clear quarantine with the `xattr` command above, or right-click → Open.

## Build notes

- CI signs with the stable self-signed identity `screenpipe-build-free` (secret `MACOS_CODESIGN_P12_BASE64`, temp keychain, deleted after the run). The designated requirement pins the certificate leaf hash, so TCC grants survive updates.
- Self-updater (`PATCH_SELF_UPDATER`, default on): the native Screenpipe updater checks `https://github.com/Rahulsharma0810/screenpipe-build-free/releases/latest/download/latest.json`. Each release carries `screenpipe-macos-arm64.app.tar.gz` (the final re-signed .app), its minisign `.sig` (`TAURI_SIGNING_PRIVATE_KEY`) and `latest.json`; the release is marked Latest.
- App version is `X.Y.(Z*1000 + run_number%1000)` from upstream `app-vX.Y.Z` (e.g. 2.7.84 built in run 353 -> `2.7.84353`). Tauri compares plain semver (`>`), and a prerelease suffix would sort *below* the release, so a numeric patch is used: rebuilds of the same tag are newer, and the next upstream patch always beats any rebuild. Only wraps after 1000 runs on a single upstream patch.
- Signing is inside-out: dylibs/.so/.metallib first, then executables, then outer bundle
- Post-sign quarantine cleared via `xattr -dr com.apple.quarantine` (never `xattr -cr` — preserves cs.* xattrs for metallib)
- TCC usage keys (Mic, Screen, Camera, Accessibility, AppleEvents) injected into Info.plist by CI
- Build guard prevents shipping stale DMGs (verifies embedded binary version matches release tag)
- Unclean PR patches are skipped (Tier-4 whole-file overwrite removed) — builds pristine upstream
