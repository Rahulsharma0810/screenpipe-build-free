#!/usr/bin/env bash
# Opt-in personal-use source patches applied to an upstream screenpipe checkout.
# Run from the upstream repo root. Each patch fails loudly (exit 1) if its
# target pattern is missing, so upstream drift breaks the build instead of
# silently shipping an unpatched binary.
#
#   PATCH_UNLIMITED_HISTORY=true|false  (default true)
#     Removes the free-plan 24h history cap (recording.rs
#     history_access_restricted -> always false => HistoryAccessPolicy unrestricted).
#     Also lifts the activity-history restriction (activity_history.rs) and the
#     frontend timeline/ledger cap (isFreeOrUnattributedUser -> false).
#   PATCH_LOCAL_ACCESS=true|false       (default true)
#     Local server/recording start no longer requires sign-in or a verified
#     paid plan (consumer builds only; enterprise path untouched). Cloud
#     features still use their own server-side auth.
#   PATCH_UNLIMITED_PIPES=true|false    (default true)
#     Removes the free-plan cap of 2 non-template local pipes.
#   PATCH_NO_TRIAL_PAYWALL=true|false   (default true)
#     Disables the fresh-install trial-activation paywall that locks the app
#     and pauses recording after onboarding.
#   PATCH_KEEP_WARM=true|false          (default true)
#     Unfocused monitors never drop to Cold; they stay Warm (periodic probe,
#     frame + OCR on visual change) instead of stopping capture.
#   PATCH_SELF_UPDATER=true|false       (default true)
#     Native in-app updater checks SELF_UPDATER_ENDPOINT (this repo's latest
#     GitHub Release latest.json) instead of screenpipe.com, sends no cloud
#     token there, and is no longer disabled as a "source build". The
#     workflow sets plugins.updater endpoints/pubkey in tauri.conf.json.
#
# Last verified against screenpipe/screenpipe main @ 6e9f48b (2026-10-05).
set -euo pipefail

PATCH_UNLIMITED_HISTORY="${PATCH_UNLIMITED_HISTORY:-true}"
PATCH_KEEP_WARM="${PATCH_KEEP_WARM:-true}"
PATCH_LOCAL_ACCESS="${PATCH_LOCAL_ACCESS:-true}"
PATCH_UNLIMITED_PIPES="${PATCH_UNLIMITED_PIPES:-true}"
PATCH_NO_TRIAL_PAYWALL="${PATCH_NO_TRIAL_PAYWALL:-true}"
PATCH_SELF_UPDATER="${PATCH_SELF_UPDATER:-true}"
SELF_UPDATER_ENDPOINT="${SELF_UPDATER_ENDPOINT:-https://github.com/Rahulsharma0810/screenpipe-build-free/releases/latest/download/latest.json}"

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
  replace_exact "apps/screenpipe-app-tauri/src-tauri/src/activity_history.rs" \
'    !is_enterprise_build && settings.is_free_or_unattributed_user()
}' \
'    let _ = (settings, is_enterprise_build);
    false
}' "unlimited-history"
  replace_exact "apps/screenpipe-app-tauri/lib/app-entitlement.ts" \
'): boolean {
  return getLocalPlanPolicy(user) !== "verified-paid";
}' \
'): boolean {
  void user;
  return false;
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

if [ "$PATCH_LOCAL_ACCESS" = "true" ]; then
  REC="apps/screenpipe-app-tauri/src-tauri/src/recording.rs"
  replace_exact "$REC" \
'pub(crate) fn server_access_allowed(app: &tauri::AppHandle, store: &SettingsStore) -> bool {
' \
'pub(crate) fn server_access_allowed(app: &tauri::AppHandle, store: &SettingsStore) -> bool {
    if !cfg!(feature = "enterprise-build") {
        return true;
    }
' "local-access"
  replace_exact "$REC" \
'pub(crate) fn recording_access_allowed(app: &tauri::AppHandle, store: &SettingsStore) -> bool {
' \
'pub(crate) fn recording_access_allowed(app: &tauri::AppHandle, store: &SettingsStore) -> bool {
    if !cfg!(feature = "enterprise-build") {
        return true;
    }
' "local-access"
else
  echo "[local-access] skipped (PATCH_LOCAL_ACCESS=$PATCH_LOCAL_ACCESS)"
fi

if [ "$PATCH_UNLIMITED_PIPES" = "true" ]; then
  replace_exact "apps/screenpipe-app-tauri/src-tauri/src/store.rs" \
'            LocalPlanPolicy::VerifiedFree => {
                config.max_non_template_pipes = Some(2);
            }
            LocalPlanPolicy::Unknown => {
                // Unknown must never inherit paid/unlimited behavior.
                config.max_non_template_pipes = Some(2);
            }
            LocalPlanPolicy::VerifiedPaid => {}' \
'            // personal build: no local pipe cap
            LocalPlanPolicy::VerifiedFree
            | LocalPlanPolicy::Unknown
            | LocalPlanPolicy::VerifiedPaid => {}' "unlimited-pipes"
  # Runtime plan refresh re-applies Some(2) to the live pipe manager.
  replace_exact "apps/screenpipe-app-tauri/src-tauri/src/commands.rs" \
'pipe_manager.set_max_non_template_pipes(restrict_paid_features.then_some(2))' \
'pipe_manager.set_max_non_template_pipes(None)' "unlimited-pipes-runtime"
  # Core backstop: ignore any limit passed in from any caller.
  replace_exact "crates/screenpipe-core/src/pipes/mod.rs" \
'    pub fn set_max_non_template_pipes(&mut self, limit: Option<usize>) -> bool {
        if self.max_non_template_pipes == limit {' \
'    pub fn set_max_non_template_pipes(&mut self, limit: Option<usize>) -> bool {
        // personal build: no local pipe cap
        let _ = limit;
        let limit: Option<usize> = None;
        if self.max_non_template_pipes == limit {' "unlimited-pipes-core"
else
  echo "[unlimited-pipes] skipped (PATCH_UNLIMITED_PIPES=$PATCH_UNLIMITED_PIPES)"
fi

if [ "$PATCH_NO_TRIAL_PAYWALL" = "true" ]; then
  STORE="apps/screenpipe-app-tauri/src-tauri/src/store.rs"
  replace_exact "$STORE" \
'    pub fn blocks_trial_activation_app(&self) -> bool {
' \
'    pub fn blocks_trial_activation_app(&self) -> bool {
        #[allow(unreachable_code)]
        return false;
' "no-trial-paywall"
  replace_exact "$STORE" \
'    pub fn blocks_trial_activation_recording(&self) -> bool {
' \
'    pub fn blocks_trial_activation_recording(&self) -> bool {
        #[allow(unreachable_code)]
        return false;
' "no-trial-paywall"
  TA="apps/screenpipe-app-tauri/lib/first-run/trial-activation.ts"
  replace_exact "$TA" \
'  devForce = TRIAL_ACTIVATION_DEV_FORCE,
): boolean {
  return (' \
'  devForce = TRIAL_ACTIVATION_DEV_FORCE,
): boolean {
  return false && (' "no-trial-paywall"
  replace_exact "$TA" \
'  return state === "summary" || state === "paywall";' \
'  return false && (state === "summary" || state === "paywall");' "no-trial-paywall"
else
  echo "[no-trial-paywall] skipped (PATCH_NO_TRIAL_PAYWALL=$PATCH_NO_TRIAL_PAYWALL)"
fi

if [ "$PATCH_SELF_UPDATER" = "true" ]; then
  UPD="apps/screenpipe-app-tauri/src-tauri/src/updates.rs"
  # Consumer endpoint (stable / pre-release channel) -> this repo's latest release.
  replace_exact "$UPD" \
'        "https://screenpipe.com/api/app-update/{channel}/{{{{target}}}}-{{{{arch}}}}/{{{{current_version}}}}"
    )' \
'        "{}",
        { let _ = channel; "'"$SELF_UPDATER_ENDPOINT"'" }
    )' "self-updater"
  # Don't send the screenpipe cloud token to GitHub (consumer builds only).
  replace_exact "$UPD" \
'    } else if let Some(settings) = settings {' \
'    } else if let Some(settings) = settings.filter(|_| false) {' "self-updater"
  # Updates are disabled for "source builds" (no official-build feature).
  replace_exact "$UPD" \
'    !cfg!(feature = "official-build") && !cfg!(feature = "enterprise-build")' \
'    false' "self-updater"
else
  echo "[self-updater] skipped (PATCH_SELF_UPDATER=$PATCH_SELF_UPDATER)"
fi
