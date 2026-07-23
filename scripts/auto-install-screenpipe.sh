#!/usr/bin/env bash
# Checks if a newer build is available on GitHub, downloads and installs it.
# Designed to run via launchd every 3 hours.
#
# State: tracks the last installed release tag in ~/.cache/screenpipe-auto/last_installed_tag
# Usage: scripts/auto-install-screenpipe.sh [--force]

set -euo pipefail

REPO="Rahulsharma0810/screenpipe-build-free"
APP_PATH="/Applications/screenpipe.app"
STATE_DIR="$HOME/.cache/screenpipe-auto"
STATE_FILE="$STATE_DIR/last_installed_tag"
LOG_FILE="$STATE_DIR/auto-install.log"
mkdir -p "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }

add_spctl_exception() {
  local app_path="$1"
  if spctl --assess --type execute "$app_path" 2>/dev/null; then
    log "Gatekeeper already accepts $app_path"
    return 0
  fi
  # Method 1: spctl --add (works on macOS <15)
  if sudo spctl --add --label "screenpipe" "$app_path" 2>/dev/null; then
    log "Gatekeeper exception added via spctl"
    return 0
  fi
  # macOS 26+ removed both `spctl --add` and CLI `profiles install`.
  # A locally-signed app still launches via first-open provenance; there is no
  # supported CLI path to allowlist it. Skip the profile attempt on modern macOS.
  local osmajor
  osmajor=$(sw_vers -productVersion | cut -d. -f1)
  if [ "${osmajor:-0}" -ge 15 ]; then
    log "macOS ${osmajor}: no CLI Gatekeeper allowlist available; app relies on local signature + first-open trust. OK."
    return 0
  fi
  # Method 2: Configuration profile (macOS 15+)
  local profile_path
  profile_path=$(mktemp /tmp/screenpipe-gk.XXXXXX.mobileconfig)
  cat > "$profile_path" <<'PROFEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.systempolicy.application</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.rvs.screenpipe.gatekeeper</string>
            <key>PayloadUUID</key>
            <string>PLACEHOLDER_UUID</string>
            <key>Rules</key>
            <array>
                <dict>
                    <key>CodeRequirement</key>
                    <string>identifier "screenpi.pe" and anchor apple generic and certificate leaf[subject.CN] = "Screenpipe Local Dev"</string>
                    <key>RuleType</key>
                    <integer>0</integer>
                    <key>RuleValue</key>
                    <true/>
                </dict>
            </array>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>Screenpipe Gatekeeper Exception</string>
    <key>PayloadDescription</key>
    <string>Allows locally-signed screenpipe.app to pass Gatekeeper</string>
    <key>PayloadIdentifier</key>
    <string>com.rvs.screenpipe.gatekeeper</string>
    <key>PayloadUUID</key>
    <string>MAIN_UUID_PLACEHOLDER</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
PROFEOF
  local rule_uuid main_uuid
  rule_uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
  main_uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
  sed -i '' "s/PLACEHOLDER_UUID/$rule_uuid/; s/MAIN_UUID_PLACEHOLDER/$main_uuid/" "$profile_path"
  if sudo profiles install -i "$profile_path" 2>/dev/null; then
    log "Gatekeeper exception installed via configuration profile"
    rm -f "$profile_path"
    return 0
  else
    log "WARNING: Could not install Gatekeeper profile. App may need manual approval on first launch."
    rm -f "$profile_path"
    return 1
  fi
}

# --- Determine latest release ---
LATEST_RELEASE=$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name' 2>/dev/null || true)
if [ -z "$LATEST_RELEASE" ] || [ "$LATEST_RELEASE" = "null" ]; then
  log "ERROR: Could not fetch latest release from ${REPO}"
  exit 1
fi
log "Latest release: $LATEST_RELEASE"

# --- Check if already installed ---
LAST_INSTALLED=""
if [ -f "$STATE_FILE" ]; then
  LAST_INSTALLED=$(cat "$STATE_FILE")
fi

if [ "$LATEST_RELEASE" = "$LAST_INSTALLED" ] && [ "${1:-}" != "--force" ]; then
  log "Already up to date ($LATEST_RELEASE). Skipping."
  exit 0
fi

log "New release available: $LATEST_RELEASE (last installed: ${LAST_INSTALLED:-never})"

# --- Download DMG ---
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log "Downloading DMG..."
DMG_URL=$(gh release view "$LATEST_RELEASE" --repo "$REPO" --json assets --jq '.assets[] | select(.name | test("\\.dmg$")) | .url' 2>/dev/null)
if [ -z "$DMG_URL" ]; then
  log "ERROR: No DMG asset found in release $LATEST_RELEASE"
  exit 1
fi

gh release download "$LATEST_RELEASE" --repo "$REPO" --pattern "*.dmg" --dir "$TMP_DIR" 2>&1 | tee -a "$LOG_FILE"
DMG_FILE=$(find "$TMP_DIR" -name "*.dmg" | head -1)
if [ -z "$DMG_FILE" ] || [ ! -f "$DMG_FILE" ]; then
  log "ERROR: DMG download failed"
  exit 1
fi
log "Downloaded: $(basename "$DMG_FILE")"

# --- Stop running screenpipe ---
if pgrep -x "screenpipe-app" >/dev/null 2>&1 || pgrep -x "screenpipe" >/dev/null 2>&1; then
  log "Stopping running screenpipe..."
  pkill -x screenpipe-app 2>/dev/null || true
  pkill -x screenpipe 2>/dev/null || true
  sleep 3
  pkill -9 -x screenpipe-app 2>/dev/null || true
  pkill -9 -x screenpipe 2>/dev/null || true
  sleep 1
fi

# --- Mount DMG, copy app, unmount ---
log "Installing..."
MOUNT_DIR=$(mktemp -d)
hdiutil attach -nobrowse -mountpoint "$MOUNT_DIR" "$DMG_FILE" >/dev/null 2>&1

# Privileged file ops helper: use sudo only when the target isn't writable
# by the current user (e.g. the installed app is root-owned).
SUDO=""
if [ -e "$APP_PATH" ] && [ ! -w "$APP_PATH" ]; then
  SUDO="sudo"
  log "Existing app is not user-writable; using sudo for install."
  # Fail fast with a clear message if sudo needs an unavailable password.
  if ! sudo -n true 2>/dev/null; then
    log "NOTE: sudo will prompt for your password to replace the root-owned app."
  fi
fi

# Remove existing app
if [ -d "$APP_PATH" ]; then
  $SUDO rm -rf "$APP_PATH"
fi

# Copy new app
$SUDO cp -R "$MOUNT_DIR/screenpipe.app" "$APP_PATH"

# Take ownership so future updates don't require sudo
$SUDO chown -R "$(id -u):$(id -g)" "$APP_PATH" 2>/dev/null || true

# Remove quarantine attribute
xattr -cr "$APP_PATH" 2>/dev/null || $SUDO xattr -cr "$APP_PATH"

# Unmount
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1

# --- Re-sign with stable identity to preserve TCC permissions ---
# NOTE: `codesign --deep` is unreliable for RE-signing nested binaries — it can
# silently skip nested Mach-O helpers. We sign inside-out: every nested Mach-O
# binary/dylib individually first, then the outer bundle last.
IDENTITY="Screenpipe Local Dev"

sign_inside_out() {
  local app="$1"
  local rc=0
  # sign_one: sign a single non-empty Mach-O file.
  _sign_one() {
    local f="$1"
    [ -s "$f" ] || { log "  skip empty: ${f#$app/}"; return; }
    file "$f" 2>/dev/null | grep -q "Mach-O" || return
    if ! $SUDO codesign --force --timestamp=none --sign "$IDENTITY" "$f" 2>>"$LOG_FILE"; then
      log "  FAILED to sign: ${f#$app/}"
      rc=1
    fi
  }
  # Pass 1: libraries first (*.dylib, *.so). Executables that link these
  # libraries require them to already be signed, else codesign errors with
  # "code object is not signed at all".
  while IFS= read -r f; do _sign_one "$f"; done < <(find "$app/Contents" -type f \( -name "*.dylib" -o -name "*.so" \) 2>/dev/null)
  # Pass 2: remaining executables.
  while IFS= read -r f; do _sign_one "$f"; done < <(find "$app/Contents" -type f -perm -111 ! -name "*.dylib" ! -name "*.so" 2>/dev/null)
  # Sign the outer bundle last.
  if ! $SUDO codesign --force --timestamp=none --sign "$IDENTITY" "$app" 2>>"$LOG_FILE"; then
    log "  FAILED to sign bundle"
    rc=1
  fi
  return $rc
}

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  log "Re-signing (inside-out) with '$IDENTITY' to preserve TCC permissions..."
  if sign_inside_out "$APP_PATH"; then
    if $SUDO codesign --verify --deep --strict "$APP_PATH" 2>>"$LOG_FILE"; then
      log "Re-signed and verified successfully"
    else
      log "WARNING: signed but strict verification reported issues (see log)"
    fi
    add_spctl_exception "$APP_PATH"
  else
    log "WARNING: Re-sign failed, resetting TCC permissions..."
    tccutil reset ScreenCapture screenpi.pe 2>/dev/null || true
    tccutil reset Microphone screenpi.pe 2>/dev/null || true
    tccutil reset Accessibility screenpi.pe 2>/dev/null || true
  fi
else
  log "WARNING: '$IDENTITY' cert not found, resetting TCC permissions..."
  tccutil reset ScreenCapture screenpi.pe 2>/dev/null || true
  tccutil reset Microphone screenpi.pe 2>/dev/null || true
  tccutil reset Accessibility screenpi.pe 2>/dev/null || true
  add_spctl_exception "$APP_PATH"
fi

# --- Save state ---
echo "$LATEST_RELEASE" > "$STATE_FILE"
log "Installed $LATEST_RELEASE successfully"

# --- Launch ---
log "Launching screenpipe..."
open "$APP_PATH"
