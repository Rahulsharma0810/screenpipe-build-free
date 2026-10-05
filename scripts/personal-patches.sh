#!/usr/bin/env bash
# Opt-in personal-use source patches applied to an upstream screenpipe checkout.
# Run from the upstream repo root. Each patch fails loudly (exit 1) if its
# target pattern is missing, so upstream drift breaks the build instead of
# silently shipping an unpatched binary.
#
#   PATCH_UNLIMITED_HISTORY=true|false  (default true)
#     Removes the free-plan 24h history cap (recording.rs
#     history_access_restricted -> always false => HistoryAccessPolicy unrestricted).
#   PATCH_KEEP_WARM=true|false          (default true)
#     Unfocused monitors never drop to Cold; they stay Warm (periodic probe,
#     frame + OCR on visual change) instead of stopping capture.
#
# Last verified against screenpipe/screenpipe main @ 6e9f48b (2026-10-05).
set -euo pipefail

PATCH_UNLIMITED_HISTORY="${PATCH_UNLIMITED_HISTORY:-true}"
PATCH_KEEP_WARM="${PATCH_KEEP_WARM:-true}"

# replace_exact FILE FROM TO LABEL — literal (non-regex) single-occurrence replace.
replace_exact() {
  local file="$1" from="$2" to="$3" label="$4"
  [ -f "$file" ] || { echo "::error::[$label] file not found: $file"; exit 1; }
  FROM="$from" TO="$to" perl -0777 -i -pe '
    my $n = () = /\Q$ENV{FROM}\E/g;
    if ($n != 1) { print STDERR "MATCHES=$n\n"; exit 3 }
    s/\Q$ENV{FROM}\E/$ENV{TO}/;
  ' "$file" || {
    echo "::error::[$label] expected exactly 1 match of target pattern in $file — upstream changed, update scripts/personal-patches.sh"
    exit 1
  }
  echo "[$label] patched $file"
}

if [ "$PATCH_UNLIMITED_HISTORY" = "true" ]; then
  REC="apps/screenpipe-app-tauri/src-tauri/src/recording.rs"
  replace_exact "$REC" \
'fn history_access_restricted(is_enterprise_build: bool, free_or_unattributed: bool) -> bool {
    !is_enterprise_build && free_or_unattributed
}' \
'fn history_access_restricted(is_enterprise_build: bool, free_or_unattributed: bool) -> bool {
    // personal build: no free-plan history cap
    let _ = (is_enterprise_build, free_or_unattributed);
    false
}' "unlimited-history"
else
  echo "[unlimited-history] skipped (PATCH_UNLIMITED_HISTORY=$PATCH_UNLIMITED_HISTORY)"
fi

if [ "$PATCH_KEEP_WARM" = "true" ]; then
  FAC="crates/screenpipe-engine/src/focus_aware_controller.rs"
  # ~100 years: Warm never expires to Cold.
  replace_exact "$FAC" \
'const COLD_CUTOFF: Duration = Duration::from_millis(60_000);' \
'const COLD_CUTOFF: Duration = Duration::from_secs(100 * 365 * 24 * 60 * 60);' "keep-warm"
  # Monitors never focused since start are Cold by default; make them Warm too.
  replace_exact "$FAC" \
'            None => CaptureState::Cold,' \
'            None => CaptureState::Warm,' "keep-warm"
else
  echo "[keep-warm] skipped (PATCH_KEEP_WARM=$PATCH_KEEP_WARM)"
fi
