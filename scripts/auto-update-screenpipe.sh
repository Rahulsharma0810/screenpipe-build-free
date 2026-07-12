#!/usr/bin/env bash
# screenpipe — pull newest upstream release, push to your fork, trigger the
# `Build Free Screenpipe` workflow, wait for it, and on failure dump the
# failed step's log so you (or your IDE / agent) can fix and rerun.
#
# Result on success: a downloaded zip/dmg in ./out/<tag>/ that you can
# install on your M3 Mac (right-click -> Open the first time).
#
#   Requirements: git, gh (>=2.40), jq, curl
#   Auth:         `gh auth login` once. Token needs repo + workflow scopes.
#
#   Usage:
#       scripts/auto-update-screenpipe.sh                                  # check + build newest
#       scripts/auto-update-screenpipe.sh --force                          # rebuild even if up to date
#       scripts/auto-update-screenpipe.sh --tag v2.4.212                   # build a specific tag
#       scripts/auto-update-screenpipe.sh --pr 3929                        # build from a PR merge commit
#       scripts/auto-update-screenpipe.sh --tag app-v2.5.47 --apply-pr 4211 # build tag and apply PR 4211 patch
#       scripts/auto-update-screenpipe.sh --create-cert                    # generate and trust local code-signing cert
#       scripts/auto-update-screenpipe.sh --watch                          # loop forever (12h cadence)
#       scripts/auto-update-screenpipe.sh --update-packages                # only update npm/brew packages + restart services
#
# Conventions assumed about your repository:
#   * remote `upstream`      -> upstream  screenpipe/screenpipe (read only)
#   * remote `origin`        -> your fork (push target, runs Actions)
#   Adjust UPSTREAM_REMOTE / FORK_REMOTE below if yours differ.

set -Eeuo pipefail

# -------- config -------------------------------------------------------------
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
FORK_REMOTE="${FORK_REMOTE:-origin}"
WORKFLOW_FILE="${WORKFLOW_FILE:-build-free.yml}"
BUILD_BRANCH="${BUILD_BRANCH:-build-free/auto}"   # branch we push tags to on the fork
POLL_SECS="${POLL_SECS:-20}"
WATCH_INTERVAL_SECS="${WATCH_INTERVAL_SECS:-43200}" # 12h
REMOTE_HOST="${REMOTE_HOST:-rvs@192.168.0.51}"      # server where AI services run
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT_DIR/.cache/screenpipe-auto}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
mkdir -p "$STATE_DIR" "$OUT_DIR"
STATE_FILE="$STATE_DIR/last_built_tag"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"

# -------- pretty -------------------------------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

kill_screenpipe() {
    log "Stopping any running Screenpipe instances..."
    pkill -x screenpipe-app 2>/dev/null || true
    pkill -x screenpipe 2>/dev/null || true
    sleep 1
    if pgrep -x "screenpipe-app" >/dev/null || pgrep -x "screenpipe" >/dev/null; then
        log "Force killing stubborn Screenpipe processes..."
        pkill -9 -x screenpipe-app 2>/dev/null || true
        pkill -9 -x screenpipe 2>/dev/null || true
        sleep 1
    fi
}

restart_plist() {
    local plist="/Library/LaunchDaemons/$1"
    if [ ! -f "$plist" ]; then
        warn "  Plist not found, skipping restart: $plist"
        return
    fi
    log "  Restarting $1..."
    if sudo launchctl unload "$plist" 2>/dev/null && sudo launchctl load "$plist" 2>/dev/null; then
        ok "  Restarted: $1"
    else
        warn "  Failed to restart: $1"
    fi
}

# Local npm + brew updates (agent-browser is brew; no local service plists to restart)
update_npm_globals() {
    log "Updating local global npm packages..."
    local failed=()

    # brew packages
    local ab_before ab_after
    ab_before=$(brew list --versions agent-browser 2>/dev/null | awk '{print $2}')
    log "  brew upgrade agent-browser (current: ${ab_before:-none})"
    brew upgrade agent-browser >/dev/null 2>&1 || true
    ab_after=$(brew list --versions agent-browser 2>/dev/null | awk '{print $2}')
    if [ "$ab_before" != "$ab_after" ]; then
        ok "  Updated: agent-browser ($ab_before -> $ab_after)"
        log "  Restarting agent-browser daemon..."
        agent-browser stop 2>/dev/null || true
        sleep 1
        agent-browser dashboard start --background 2>/dev/null || true
        ok "  agent-browser restarted"
    else
        log "  Already up to date: agent-browser ($ab_after)"
    fi

    # npm packages
    for pkg in omniroute opencode-ai "@choplin/jira-cli-mcp" opencode-omniroute-auth "@openchamber/web"; do
        log "  npm install -g $pkg"
        /opt/homebrew/bin/npm install -g "$pkg" >/dev/null 2>&1; local npm_rc=$?
        if [ $npm_rc -eq 0 ] || /opt/homebrew/bin/npm list -g --depth=0 2>/dev/null | grep -q "^.*${pkg##*/}@"; then
            ok "  Updated: $pkg"
        else
            warn "  Failed to update: $pkg"
            failed+=("$pkg")
        fi
    done

    [ ${#failed[@]} -gt 0 ] && warn "Local packages failed: ${failed[*]}" || ok "All local packages updated."
}

# Remote npm updates + plist restarts on REMOTE_HOST
update_remote_services() {
    log "Updating npm packages on $REMOTE_HOST and restarting services..."
    ssh "$REMOTE_HOST" 'bash -s' << 'ENDSSH'
export PATH="/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:$PATH"
NPM=/opt/homebrew/opt/node@22/bin/npm
ok()   { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
log()  { printf "\033[1;34m[*]\033[0m %s\n" "$*"; }

plist_for() {
    case "$1" in
        openclaw)                              echo "ai.openclaw.gateway.plist" ;;
        "@openchamber/web")                    echo "com.rvs.openchamber.plist" ;;
        "@samanhappy/mcphub")                  echo "com.rvs.mcphub.plist" ;;
        "@srbhptl39/mcp-superassistant-proxy") echo "com.rvs.mcp-superassistant.plist" ;;
        *)                                     echo "" ;;
    esac
}

restart_svc() {
    local plist="/Library/LaunchDaemons/$1"
    [ -f "$plist" ] || { warn "  Plist missing: $plist"; return; }
    log "  Restarting $1..."
    sudo launchctl unload "$plist" 2>/dev/null
    sudo launchctl load  "$plist" 2>/dev/null && ok "  Restarted: $1" || warn "  Failed: $1"
}

pkg_ver() {
    $NPM list -g --depth=0 --json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dependencies',{}).get('$1',{}).get('version',''))" 2>/dev/null || echo ""
}

brew_update() {
    local pkg="$1" plist="$2"
    local ver_before ver_after
    ver_before=$(brew list --versions "$pkg" 2>/dev/null | awk '{print $2}')
    log "brew upgrade $pkg (current: ${ver_before:-none})"
    brew upgrade "$pkg" >/dev/null 2>&1 || true
    ver_after=$(brew list --versions "$pkg" 2>/dev/null | awk '{print $2}')
    if [ "$ver_before" != "$ver_after" ]; then
        ok "Updated: $pkg ($ver_before -> $ver_after)"
        [ -n "$plist" ] && restart_svc "$plist"
    else
        log "Already up to date: $pkg ($ver_after)"
    fi
}

failed=""

# omniroute: skip update if dev plist (com.rvs.omniroute.plist) is active;
# only update + repair + restart if global plist (com.rvs.omniroute.global.plist) is active.
OMNIROUTE_DEV_RUNNING=0
OMNIROUTE_GLOBAL_RUNNING=0
sudo launchctl list 2>/dev/null | grep -q "com.rvs.omniroute$"        && OMNIROUTE_DEV_RUNNING=1
sudo launchctl list 2>/dev/null | grep -q "com.rvs.omniroute.global"  && OMNIROUTE_GLOBAL_RUNNING=1

if [ "$OMNIROUTE_DEV_RUNNING" = "1" ]; then
    log "omniroute: dev plist is active — skipping global npm update."
elif [ "$OMNIROUTE_GLOBAL_RUNNING" = "1" ]; then
    log "omniroute: global plist is active — updating..."
    ver_before=$(pkg_ver "omniroute")
    if $NPM install -g omniroute >/dev/null 2>&1; then
        ver_after=$(pkg_ver "omniroute")
        if [ "$ver_before" != "$ver_after" ]; then
            ok "Updated: omniroute ($ver_before -> $ver_after)"
            log "  Running omniroute repair to rebuild native bindings..."
            omniroute repair 2>&1 && ok "  Native bindings repaired." || warn "  omniroute repair failed."
            restart_svc "com.rvs.omniroute.global.plist"
        else
            log "Already up to date: omniroute ($ver_after)"
        fi
    else
        warn "Failed: omniroute"
        failed="$failed omniroute"
    fi
else
    log "omniroute: neither plist is active — skipping."
fi

# npm packages
for pkg in openclaw opencode-ai \
           "@openchamber/web" "@samanhappy/mcphub" "@srbhptl39/mcp-superassistant-proxy" \
           opencode-omniroute-auth "@choplin/jira-cli-mcp" modelrelay \
           "@anthropic-ai/claude-code" clawdbot; do
    ver_before=$(pkg_ver "$pkg")
    log "npm install -g $pkg (current: ${ver_before:-none})"
    if $NPM install -g "$pkg" >/dev/null 2>&1; then
        ver_after=$(pkg_ver "$pkg")
        if [ "$ver_before" != "$ver_after" ]; then
            ok "Updated: $pkg ($ver_before -> $ver_after)"
            plist=$(plist_for "$pkg")
            [ -n "$plist" ] && restart_svc "$plist"
        else
            log "Already up to date: $pkg ($ver_after)"
        fi
    else
        warn "Failed: $pkg"
        failed="$failed $pkg"
    fi
done

# brew packages
brew_update agent-browser "com.rvs.agent-browser-dashboard.plist"

[ -n "$failed" ] && warn "Failed packages:$failed" || ok "All remote packages up to date."
ENDSSH
    local rc=$?
    [ $rc -eq 0 ] && ok "Remote services updated." || warn "Remote update finished with errors (exit $rc)."
}

resign_app() {
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Screenpipe Local Dev"; then
        log "Re-signing locally with stable 'Screenpipe Local Dev' certificate to preserve TCC permissions..."
        if codesign --force --deep --sign "Screenpipe Local Dev" "/Applications/screenpipe.app"; then
            ok "Successfully re-signed screenpipe.app!"
            return 0
        else
            warn "Failed to re-sign screenpipe.app (keychain may be locked or permission denied)."
            return 1
        fi
    else
        log "No 'Screenpipe Local Dev' codesigning identity found. App remains ad-hoc signed."
        return 1
    fi
}

create_cert() {
    log "Creating self-signed code signing certificate 'Screenpipe Local Dev'..."
    local tmpdir
    tmpdir=$(mktemp -d)
    cat << 'EOF' > "$tmpdir/cert.cnf"
[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
prompt              = no
x509_extensions     = v3_ca

[ req_distinguished_name ]
CN                  = Screenpipe Local Dev

[ v3_ca ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

    openssl genrsa -out "$tmpdir/cert.key" 2048
    openssl req -new -x509 -key "$tmpdir/cert.key" -out "$tmpdir/cert.crt" -days 3650 -config "$tmpdir/cert.cnf"
    
    if ! openssl pkcs12 -export -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -out "$tmpdir/cert.p12" -inkey "$tmpdir/cert.key" -in "$tmpdir/cert.crt" -passout pass:password 2>/dev/null; then
        openssl pkcs12 -export -out "$tmpdir/cert.p12" -inkey "$tmpdir/cert.key" -in "$tmpdir/cert.crt" -passout pass:password
    fi
    
    log "Importing certificate into your login keychain..."
    log "NOTE: If prompted by macOS, enter your login keychain password to authorize the import."
    security import "$tmpdir/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P password
    
    log "Adding certificate to System Trust as a trusted Code Signing root..."
    log "NOTE: This requires administrator privileges to write to the System keychain. Please enter your Mac's sudo password."
    sudo security add-trusted-cert -d -r trustRoot -p codeSigning -k "/Library/Keychains/System.keychain" "$tmpdir/cert.crt"
    
    rm -rf "$tmpdir"
    ok "Certificate 'Screenpipe Local Dev' created, imported, and trusted successfully!"
}

# -------- args ---------------------------------------------------------------
FORCE=0
EXPLICIT_TAG=""
PR_NUM=""
APPLY_PR_NUM=""
LOCAL_ZIP=""
WATCH=0
CREATE_CERT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --force)        FORCE=1 ;;
        --tag)          EXPLICIT_TAG="${2:?missing tag}"; shift ;;
        --pr)           PR_NUM="${2:?missing PR number}"; shift ;;
        --apply-pr)     APPLY_PR_NUM="${2:?missing PR number}"; shift ;;
        --local-zip)    LOCAL_ZIP="${2:?missing ZIP path}"; shift ;;
        --create-cert)       CREATE_CERT=1 ;;
        --watch)             WATCH=1 ;;
        --update-packages)   update_npm_globals; update_remote_services; exit 0 ;;
        -h|--help)           sed -n '2,30p' "$0"; exit 0 ;;
        *)              die "unknown arg: $1" ;;
    esac
    shift
done

if [ "$CREATE_CERT" -eq 1 ]; then
    create_cert
    exit 0
fi

IS_EXPLICIT=0
if [ -n "$EXPLICIT_TAG" ] || [ -n "$PR_NUM" ] || [ -n "$APPLY_PR_NUM" ]; then
    IS_EXPLICIT=1
fi

# -------- preflight ----------------------------------------------------------
if [ -z "$LOCAL_ZIP" ]; then
    for bin in git gh jq curl; do
        command -v "$bin" >/dev/null || die "missing required tool: $bin"
    done
    gh auth status >/dev/null 2>&1 || die "run 'gh auth login' first"

    cd "$ROOT_DIR"
    git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 \
        || die "no remote '$UPSTREAM_REMOTE' (set UPSTREAM_REMOTE=...)"
    git remote get-url "$FORK_REMOTE" >/dev/null 2>&1 \
        || die "no remote '$FORK_REMOTE' (set FORK_REMOTE=...)"

    FORK_URL="$(git remote get-url "$FORK_REMOTE")"
    # extract owner/repo from any git URL form
    FORK_SLUG="$(echo "$FORK_URL" \
        | sed -E 's#(git@|https?://)[^/:]+[/:]##; s#\.git$##')"
    [ -n "$FORK_SLUG" ] || die "could not parse fork slug from $FORK_URL"
    log "Fork repo for Actions: $FORK_SLUG"
fi

# -------- find target tag ----------------------------------------------------
if [ -n "$LOCAL_ZIP" ]; then
    [ -f "$LOCAL_ZIP" ] || die "local ZIP file not found: $LOCAL_ZIP"
    TARGET_TAG="local-zip"
else
    log "Fetching upstream tags from $UPSTREAM_REMOTE..."
    git fetch --quiet --tags --force "$UPSTREAM_REMOTE"

    if [ -n "$PR_NUM" ]; then
        TARGET_TAG="pr-$PR_NUM"
        log "Building PR #$PR_NUM (tag=$TARGET_TAG)"
    elif [ -n "$EXPLICIT_TAG" ]; then
        TARGET_TAG="$EXPLICIT_TAG"
    else
        # newest semver-ish tag by creation date
        TARGET_TAG="$(git for-each-ref --sort=-creatordate --format '%(refname:short)' \
            'refs/tags/v*' 'refs/tags/app-v*' | head -n1)"
    fi
    [ -n "$TARGET_TAG" ] || die "no tag found"

    if [ "$TARGET_TAG" = "main" ] || [ "$TARGET_TAG" = "master" ]; then
        log "Resolving latest commit SHA for upstream branch $TARGET_TAG..."
        SHA=$(curl -s "https://api.github.com/repos/screenpipe/screenpipe/commits/${TARGET_TAG}" | jq -r '.sha')
        if [ -n "$SHA" ] && [ "$SHA" != "null" ]; then
            SHORT_SHA="${SHA:0:7}"
            TARGET_TAG="${TARGET_TAG}-${SHORT_SHA}"
        fi
    fi

    if [ -n "$APPLY_PR_NUM" ]; then
        # Replace commas with dashes for a safe tag name
        SAFE_PR_SUFFIX=$(echo "$APPLY_PR_NUM" | tr ',' '-')
        TARGET_TAG="${TARGET_TAG}-pr-${SAFE_PR_SUFFIX}"
        log "Applying PRs #$APPLY_PR_NUM on top of tag: Target output tag is $TARGET_TAG"
    fi
fi

log "Target tag: $TARGET_TAG"

CURRENT_TAG=""
[ -f "$STATE_FILE" ] && CURRENT_TAG="$(cat "$STATE_FILE")"

# PR/Local ZIP builds always run (no skip)
if [ -z "$PR_NUM" ] && [ -z "$LOCAL_ZIP" ]; then
    if [ "$FORCE" -eq 0 ] && [ "$TARGET_TAG" = "$CURRENT_TAG" ]; then
        ok "Already built $TARGET_TAG (use --force to rebuild)"
        [ "$WATCH" -eq 1 ] || exit 0
    fi
fi

# -------- push only the workflow file to the fork (orphan branch) -----------
# We do NOT push the upstream source - that triggers Git LFS uploads of
# hundreds of MB and routinely fails on missing local objects. Instead we
# create an orphan branch on the fork containing only .github/workflows/,
# and the workflow checks out screenpipe/screenpipe directly via
# actions/checkout's `repository:` field. Result: ~5 KB push instead of ~1 GB.
push_to_fork() {
    log "Pushing workflow-only orphan branch '$BUILD_BRANCH' to $FORK_SLUG..."
    local tmpdir="$STATE_DIR/orphan-$$"
    rm -rf "$tmpdir"
    mkdir -p "$tmpdir/.github/workflows" "$tmpdir/scripts"
    cp "$ROOT_DIR/.github/workflows/$WORKFLOW_FILE" "$tmpdir/.github/workflows/"
    cp "$ROOT_DIR/scripts/auto-update-screenpipe.sh" "$tmpdir/scripts/"
    cat > "$tmpdir/README.md" <<EOF
# screenpipe-build-free

Auto-generated by \`scripts/auto-update-screenpipe.sh\`.
Branch \`$BUILD_BRANCH\` carries only the workflow file - the build itself
checks out upstream screenpipe/screenpipe directly.
EOF
    (
        cd "$tmpdir"
        git init --quiet --initial-branch="$BUILD_BRANCH"
        git config user.name  "auto-update"
        git config user.email "auto@local"
        git add .
        git commit --quiet -m "ci: build-free workflow"
        git remote add fork "$(git -C "$ROOT_DIR" remote get-url "$FORK_REMOTE")"
        git push --force fork "$BUILD_BRANCH:$BUILD_BRANCH"
    )
    rm -rf "$tmpdir"
    ok "Workflow pushed to $FORK_SLUG:$BUILD_BRANCH"
}

# -------- trigger workflow + wait + on-failure debug ------------------------
trigger_and_wait() {
    local tag="$1"
    local run_id pre_max post_max status conclusion fail_step api_args

    pre_max="$(gh run list --repo "$FORK_SLUG" --workflow "$WORKFLOW_FILE" \
        --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null || echo 0)"
    pre_max="${pre_max:-0}"

    log "Dispatching workflow $WORKFLOW_FILE on $FORK_SLUG (branch=$BUILD_BRANCH, upstream tag=$tag)..."
    # New workflows need ~5-30s to be indexed by GitHub before `gh workflow run`
    # can resolve them by filename. Retry until it accepts the dispatch (or
    # we give up). Use the REST API directly to avoid `gh workflow run`'s
    # default-branch lookup quirk on brand-new repos.
    local dispatch_ok=0
    for attempt in $(seq 1 20); do
        api_args=(
            -X POST
            "/repos/$FORK_SLUG/actions/workflows/$WORKFLOW_FILE/dispatches"
            -f "ref=$BUILD_BRANCH"
        )
        if [ -n "$PR_NUM" ]; then
            api_args+=(-f "inputs[pr]=$PR_NUM")
        else
            local git_tag="${tag%%-pr-*}"
            # Strip commit SHA suffix if this is a branch run (e.g. main-20b6a54)
            if [[ "$git_tag" =~ ^(main|master)-[0-9a-f]{7}$ ]]; then
                git_tag="${git_tag%-*}"
            fi
            api_args+=(-f "inputs[ref]=$git_tag")
        fi
        if [ -n "$APPLY_PR_NUM" ]; then
            api_args+=(-f "inputs[apply_pr]=$APPLY_PR_NUM")
        fi
        api_args+=(-f "inputs[upstream]=${UPSTREAM_REPO:-screenpipe/screenpipe}")
        if gh api "${api_args[@]}" >/dev/null 2>&1; then
            dispatch_ok=1
            ok "Dispatched (attempt $attempt)"
            break
        fi
        log "  workflow not indexed yet (attempt $attempt/20), sleeping 5s..."
        sleep 5
    done
    [ "$dispatch_ok" = "1" ] || die "could not dispatch after 20 attempts; check that $WORKFLOW_FILE is committed and Actions enabled on $FORK_SLUG"

    log "Waiting for new run to appear..."
    for _ in $(seq 1 30); do
        post_max="$(gh run list --repo "$FORK_SLUG" --workflow "$WORKFLOW_FILE" \
            --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null || echo 0)"
        post_max="${post_max:-0}"
        if [ "$post_max" -gt "$pre_max" ]; then
            run_id="$post_max"; break
        fi
        sleep 2
    done
    [ -n "${run_id:-}" ] || die "workflow run never appeared"
    TRIGGERED_RUN_ID="$run_id"
    ok "Run id: $run_id   https://github.com/$FORK_SLUG/actions/runs/$run_id"

    # Stream-watch (gh handles backoff). Returns non-zero on failure.
    if gh run watch "$run_id" --repo "$FORK_SLUG" --exit-status --interval "$POLL_SECS"; then
        ok "Build succeeded"
        return 0
    fi

    # ---- failure path: capture logs of the failed job/step ----------------
    warn "Build failed - dumping failed step log to $LOG_DIR/$tag-$run_id.log"
    gh run view "$run_id" --repo "$FORK_SLUG" --log-failed \
        > "$LOG_DIR/$tag-$run_id.log" 2>&1 || true
    fail_step="$(gh run view "$run_id" --repo "$FORK_SLUG" --json jobs \
        --jq '.jobs[] | select(.conclusion=="failure") |
              {job:.name, step:(.steps[] | select(.conclusion=="failure") | .name)}')"
    warn "Failed steps:"
    printf '%s\n' "$fail_step" >&2

    # Tail of the log on stdout for IDE / agent to read.
    echo "================= FAILED STEP LOG (tail) ================="
    tail -n 200 "$LOG_DIR/$tag-$run_id.log" || true
    echo "=========================================================="
    echo "Full log: $LOG_DIR/$tag-$run_id.log"
    echo "Run URL : https://github.com/$FORK_SLUG/actions/runs/$run_id"
    return 1
}

download_artifact() {
    local tag="$1" dest
    dest="$OUT_DIR/$tag"
    rm -rf "$dest" && mkdir -p "$dest"
    log "Downloading artifacts to $dest..."
    
    # Start a background loop to show download progress
    (
        local size prev_size=0
        sleep 2
        while kill -0 "$$" 2>/dev/null; do
            size=$(du -sk "$dest" 2>/dev/null | awk '{print $1}' || echo 0)
            if [ "$size" -gt 0 ] && [ "$size" -ne "$prev_size" ]; then
                local size_mb=$(expr $size / 1024 2>/dev/null || echo 0)
                log "  Downloaded: ${size_mb} MB..."
                prev_size="$size"
            fi
            sleep 4
        done
    ) &
    local progress_pid=$!

    if [ -n "${TRIGGERED_RUN_ID:-}" ]; then
        gh run download "$TRIGGERED_RUN_ID" --repo "$FORK_SLUG" --dir "$dest"
    else
        gh run download --repo "$FORK_SLUG" \
            --name "$(gh run list --repo "$FORK_SLUG" --workflow "$WORKFLOW_FILE" \
                      --limit 1 --json name,databaseId \
                      --jq '.[0] | (.name)')" \
            --dir "$dest" 2>/dev/null || \
            gh run download --repo "$FORK_SLUG" --dir "$dest"
    fi
    
    # Kill the background progress loop
    kill "$progress_pid" 2>/dev/null || true
    wait "$progress_pid" 2>/dev/null || true

    ok "Artifacts in $dest:"
    ls -lh "$dest"
}

# -------- main one-shot ------------------------------------------------------
build_once() {
    local tag="$1"
    
    if [ -n "${LOCAL_ZIP:-}" ]; then
        local dest="$OUT_DIR/$tag"
        rm -rf "$dest" && mkdir -p "$dest"
        if [[ "$LOCAL_ZIP" == *.dmg ]]; then
            log "Using local DMG file directly: $LOCAL_ZIP"
            cp "$LOCAL_ZIP" "$dest/screenpipe-macos-arm64.dmg"
        else
            log "Using local ZIP file: $LOCAL_ZIP"
            log "Extracting local ZIP to $dest..."
            unzip -q "$LOCAL_ZIP" -d "$dest"
        fi
    else
        local matched_run=""
        if [ "$FORCE" -eq 0 ]; then
            # Search for an existing run (in_progress, queued, or recently completed success)
            log "Checking if a build is already running or completed for $tag..."
            local run_info
            run_info=$(gh run list --repo "$FORK_SLUG" --workflow "$WORKFLOW_FILE" --limit 15 --json databaseId,status,conclusion,name 2>/dev/null || echo "[]")
            
            matched_run=$(echo "$run_info" | python3 -c '
import sys, json
def norm(s):
    return s.lower().replace(" ", "").replace("-", "").replace("#", "").replace("_", "")

try:
    runs = json.load(sys.stdin)
    target = sys.argv[1]
    is_explicit = sys.argv[2] == "1"
    target_clean = target.replace("Build Free ", "").replace("app-", "").strip()
    
    if not is_explicit:
        # If not explicit (default run), use the latest run that is in_progress/queued or completed success
        for r in runs:
            status = r.get("status", "")
            conclusion = r.get("conclusion", "")
            run_id = r.get("databaseId")
            if status in ["in_progress", "queued"]:
                print(f"{run_id}|{status}|{conclusion}")
                sys.exit(0)
            elif status == "completed" and conclusion == "success":
                print(f"{run_id}|{status}|{conclusion}")
                sys.exit(0)
    else:
        # 1. First look for in_progress or queued runs matching target
        for r in runs:
            name = r.get("name", "")
            status = r.get("status", "")
            run_id = r.get("databaseId")
            conclusion = r.get("conclusion", "")
            if status in ["in_progress", "queued"]:
                if norm(target_clean) in norm(name) or norm(name) in norm(target_clean):
                    print(f"{run_id}|{status}|{conclusion}")
                    sys.exit(0)
                    
        # 2. Look for completed success runs matching target
        for r in runs:
            name = r.get("name", "")
            status = r.get("status", "")
            conclusion = r.get("conclusion", "")
            run_id = r.get("databaseId")
            if status == "completed" and conclusion == "success":
                if norm(target_clean) in norm(name) or norm(name) in norm(target_clean):
                    print(f"{run_id}|{status}|{conclusion}")
                    sys.exit(0)
except Exception as e:
    pass
print("")
' "$tag" "$IS_EXPLICIT")
        fi

        if [ -n "$matched_run" ]; then
            IFS='|' read -r GHA_RUN_ID GHA_STATUS GHA_CONCLUSION <<< "$matched_run"
            log "Found existing build run $GHA_RUN_ID (status: $GHA_STATUS, conclusion: $GHA_CONCLUSION)"
            
            if [ "$GHA_STATUS" = "in_progress" ] || [ "$GHA_STATUS" = "queued" ]; then
                log "Attaching to in-progress run $GHA_RUN_ID..."
                if gh run watch "$GHA_RUN_ID" --repo "$FORK_SLUG" --exit-status --interval "$POLL_SECS"; then
                    ok "Attached build succeeded"
                    TRIGGERED_RUN_ID="$GHA_RUN_ID"
                else
                    die "Attached build failed."
                fi
            elif [ "$GHA_STATUS" = "completed" ] && [ "$GHA_CONCLUSION" = "success" ]; then
                log "Using already completed successful run $GHA_RUN_ID."
                TRIGGERED_RUN_ID="$GHA_RUN_ID"
            fi
        else
            log "No existing build run found for $tag. Triggering a new build..."
            push_to_fork
            if ! trigger_and_wait "$tag"; then
                return 1
            fi
        fi
        
        download_artifact "$tag"
        echo "$tag" > "$STATE_FILE"
    fi
    
    # Automatic local installation/updating logic
    local dest="$OUT_DIR/$tag"
    local dmg_file
    dmg_file="$(find "$dest" -name "*.dmg" | head -n1 || true)"
        if [ -n "$dmg_file" ]; then
            log "Found DMG: $dmg_file. Mounting..."
            local mount_point
            mount_point="$(hdiutil mount "$dmg_file" | grep -E "/Volumes/" | awk -F'\t' '{print $NF}' || true)"
            if [ -n "$mount_point" ]; then
                log "Mounted at: $mount_point"
                kill_screenpipe
                
                log "Copying screenpipe.app to /Applications..."
                rm -rf "/Applications/screenpipe.app"
                cp -R "$mount_point/screenpipe.app" "/Applications/"
                
                log "Unmounting DMG..."
                hdiutil unmount "$mount_point"
                
                log "Bypassing Gatekeeper / quarantine..."
                xattr -cr "/Applications/screenpipe.app"
                
                log "Reindexing Spotlight for screenpipe.app..."
                mdimport /Applications/screenpipe.app 2>/dev/null || true
                
                if resign_app; then
                    log "Local signature matches. Preserving existing TCC permissions..."
                else
                    log "Resetting Screen Recording, Microphone, and Accessibility permissions to clear cached signatures..."
                    tccutil reset ScreenCapture screenpi.pe 2>/dev/null || true
                    tccutil reset Microphone screenpi.pe 2>/dev/null || true
                    tccutil reset Accessibility screenpi.pe 2>/dev/null || true
                fi
                
                ok "Successfully updated /Applications/screenpipe.app to $tag!"
                log "Launching Screenpipe..."
                open -a "/Applications/screenpipe.app"
            else
                warn "Failed to mount DMG automatically."
            fi
        else
            # Try fallback zip if DMG not found
            local zip_file
            zip_file="$(find "$dest" -name "*.zip" | head -n1 || true)"
            if [ -n "$zip_file" ]; then
                log "Found ZIP: $zip_file. Extracting..."
                kill_screenpipe
                rm -rf "/Applications/screenpipe.app"
                unzip -q "$zip_file" -d "/Applications/"
                xattr -cr "/Applications/screenpipe.app"
                
                log "Reindexing Spotlight for screenpipe.app..."
                mdimport /Applications/screenpipe.app 2>/dev/null || true
                
                if resign_app; then
                    log "Local signature matches. Preserving existing TCC permissions..."
                else
                    log "Resetting Screen Recording, Microphone, and Accessibility permissions to clear cached signatures..."
                    tccutil reset ScreenCapture screenpi.pe 2>/dev/null || true
                    tccutil reset Microphone screenpi.pe 2>/dev/null || true
                    tccutil reset Accessibility screenpi.pe 2>/dev/null || true
                fi
                
                ok "Successfully updated /Applications/screenpipe.app to $tag from ZIP!"
                open -a "/Applications/screenpipe.app"
            else
                warn "No DMG or ZIP found in artifacts. Skipping automatic installation."
            fi
        fi

        update_npm_globals
        update_remote_services
        ok "DONE: $tag built and installed!"
        return 0
}

if [ "$WATCH" -eq 1 ]; then
    while true; do
        build_once "$TARGET_TAG" || warn "build failed, will retry next cycle"
        log "Sleeping ${WATCH_INTERVAL_SECS}s before next upstream check..."
        sleep "$WATCH_INTERVAL_SECS"
        git fetch --quiet --tags --force "$UPSTREAM_REMOTE"
        TARGET_TAG="$(git for-each-ref --sort=-creatordate \
            --format '%(refname:short)' 'refs/tags/v*' 'refs/tags/app-v*' | head -n1)"
    done
else
    build_once "$TARGET_TAG"
fi
