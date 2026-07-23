#!/usr/bin/env bash
# Poll a GitHub Actions run to completion, then (on success) download the
# release DMG and verify: (a) Info.plist version, (b) real onnx dylib (not dSYM),
# (c) codesign --verify --deep --strict.
#
# Usage: bash scripts/poll-and-verify.sh <run_id> [expected_version]
#   run_id           GitHub Actions run databaseId to poll
#   expected_version optional X.Y.Z the bundle should embed (e.g. 2.5.132)
#
# Avoids the zsh read-only `status` var pitfall by never using that name.
set -uo pipefail

REPO="Rahulsharma0810/screenpipe-build-free"
RUN_ID="${1:?usage: poll-and-verify.sh <run_id> [expected_version]}"
EXPECT_VER="${2:-}"
RELEASE_TAG="app-v2.5.132-pr-4333-4344"
ASSET="screenpipe-macos-arm64.dmg"
INTERVAL="${POLL_INTERVAL:-120}"
MAX_POLLS="${MAX_POLLS:-90}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# --- Poll ---
run_state=""; run_concl=""
for i in $(seq 1 "$MAX_POLLS"); do
  js=$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion 2>/dev/null) || { log "poll $i: gh error, retrying"; sleep "$INTERVAL"; continue; }
  run_state=$(printf '%s' "$js" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status") or "")')
  run_concl=$(printf '%s' "$js" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("conclusion") or "")')
  # current step for visibility
  cur=$(gh run view "$RUN_ID" --repo "$REPO" --json jobs 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
for j in d.get("jobs",[]):
    if j["name"]=="build-macos-arm64":
        for s in j["steps"]:
            if s["status"]=="in_progress": print(s["name"]); break
' 2>/dev/null)
  log "poll $i: status=$run_state conclusion=$run_concl ${cur:+step=\"$cur\"}"
  [ "$run_state" = "completed" ] && break
  sleep "$INTERVAL"
done

if [ "$run_state" != "completed" ]; then
  log "TIMEOUT: run did not complete after $MAX_POLLS polls"
  exit 2
fi
if [ "$run_concl" != "success" ]; then
  log "RUN FAILED: conclusion=$run_concl"
  gh run view "$RUN_ID" --repo "$REPO" --log-failed 2>/dev/null | tail -40
  exit 1
fi
log "RUN SUCCEEDED"

# --- Download DMG ---
tmp=$(mktemp -d)
trap 'hdiutil detach "$tmp/mnt" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
log "Downloading $ASSET from release $RELEASE_TAG..."
gh release download "$RELEASE_TAG" --repo "$REPO" -p "$ASSET" -D "$tmp" --clobber || { log "download failed"; exit 1; }
dmg="$tmp/$ASSET"
log "DMG size: $(stat -f%z "$dmg" 2>/dev/null || stat -c%s "$dmg") bytes"

# --- Mount & verify ---
mkdir -p "$tmp/mnt"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$tmp/mnt" >/dev/null || { log "mount failed"; exit 1; }
app=$(find "$tmp/mnt" -maxdepth 1 -name '*.app' | head -1)
[ -n "$app" ] || { log "no .app in DMG"; exit 1; }

ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)
log "CFBundleShortVersionString: $ver"

dylib="$app/Contents/MacOS/libonnxruntime.dylib"
if [ -e "$dylib" ]; then
  dsz=$(stat -f%z "$dylib" 2>/dev/null || stat -c%s "$dylib")
  dkind=$(file -b "$dylib")
  log "libonnxruntime.dylib: ${dsz} bytes | $dkind"
else
  log "libonnxruntime.dylib: MISSING"
fi

if codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | tail -2; then
  log "codesign --verify --deep --strict: PASS"
  sign_ok=1
else
  log "codesign --verify --deep --strict: FAIL"
  sign_ok=0
fi

# --- Verdict ---
ok=1
if [ -n "$EXPECT_VER" ] && [ "$ver" != "$EXPECT_VER" ]; then log "FAIL: version $ver != expected $EXPECT_VER"; ok=0; fi
case "$dkind" in
  *"dynamically linked shared library"*) : ;;
  *) log "FAIL: onnx dylib is not a real shared library ($dkind)"; ok=0 ;;
esac
[ "${sign_ok:-0}" = "1" ] || ok=0

if [ "$ok" = "1" ]; then log "ALL CHECKS PASSED (version=$ver, onnx=real, signature=valid)"; exit 0; fi
log "VERIFICATION FAILED"; exit 1
