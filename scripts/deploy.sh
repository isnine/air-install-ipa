#!/usr/bin/env bash
set -euo pipefail

# ─── Air Install IPA — Deploy ──────────────────────────────────────────────
# Build/deploy an Ad Hoc signed .ipa for OTA installation.
# Three modes:
#   (default)  Serve from this Mac via HTTPS (mkcert certs) on local network
#   --tunnel   Serve from this Mac via cloudflared quick tunnel (no certs needed)
#   --cloud    Upload to Cloudflare R2 + Pages

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$HOME/.config/air-install-ipa/config"

# ─── Helpers ─────────────────────────────────────────────────────────────────
usage() {
  cat <<'USAGE'
Usage: deploy.sh [--tunnel | --cloud] [path/to/App.ipa]

Deploys an Ad Hoc signed .ipa for OTA installation.

Options:
  (default)  Serve IPA from this Mac over HTTPS on the local network.
             Uses mkcert certificates for LOCAL_HOSTNAME (set in config).
             Requires: mkcert certs + iPhone trusts the CA.
             Press Ctrl+C to stop the server when done.

  --tunnel   Serve IPA from this Mac via cloudflared quick tunnel.
             No certs needed — uses trycloudflare.com HTTPS.
             Press Ctrl+C to stop the tunnel when done.

  --cloud    Upload to Cloudflare R2 + deploy install page to Pages.

If no .ipa path is given, builds an Ad Hoc archive from the Xcode
project in the current directory and exports the .ipa automatically.

First-time (cloud mode)? Run setup first:
  bash ~/.claude/skills/air-install-ipa/scripts/setup.sh
USAGE
  exit 1
}

fail() { echo "Error: $1" >&2; exit 1; }
log()  { echo "▸ $*" >&2; }
ok()   { echo "✓ $*" >&2; }

# ─── Parse flags ──────────────────────────────────────────────────────────
LOCAL_MODE=false
TUNNEL_MODE=false
CLOUD_MODE=false
POSITIONAL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --local)   LOCAL_MODE=true ;;
    --tunnel)  TUNNEL_MODE=true ;;
    --cloud)   CLOUD_MODE=true ;;
    --help|-h) usage ;;
    *)         POSITIONAL_ARGS+=("$arg") ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

# Default to local mode if no mode flag given
if ! $LOCAL_MODE && ! $TUNNEL_MODE && ! $CLOUD_MODE; then
  LOCAL_MODE=true
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────
if $LOCAL_MODE || $TUNNEL_MODE; then
  # In local/tunnel mode, keep serving dir alive; clean up on exit
  TMPDIR_WORK="$(mktemp -d)"
  cleanup() {
    [[ -n "${TUNNEL_PID:-}" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
    [[ -n "${TMPDIR_WORK:-}" ]] && rm -rf "$TMPDIR_WORK"
  }
  trap cleanup EXIT INT TERM
elif $CLOUD_MODE; then
  TMPDIR_WORK="$(mktemp -d)"
  cleanup() { [[ -n "${TMPDIR_WORK:-}" ]] && rm -rf "$TMPDIR_WORK"; }
  trap cleanup EXIT
fi

# ─── Load config ──────────────────────────────────────────────────────────
# Config is always loaded (LOCAL_HOSTNAME used by local mode, R2/Pages by cloud)
# Must be loaded before preflight so LOCAL_HOSTNAME is available for cert checks.
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Default LOCAL_HOSTNAME if not configured
LOCAL_HOSTNAME="${LOCAL_HOSTNAME:-localhost}"

# ─── Preflight ──────────────────────────────────────────────────────────────
[[ -x /usr/libexec/PlistBuddy ]] || fail "PlistBuddy not found — this script requires macOS"

if $LOCAL_MODE; then
  command -v python3 >/dev/null 2>&1 || fail "python3 not found"
  # Check mkcert certs exist — find cert files matching LOCAL_HOSTNAME
  CERT_DIR="$HOME/.config/air-install-ipa/certs"
  CERT_FILE="$(find "$CERT_DIR" -name "${LOCAL_HOSTNAME}*.pem" ! -name "*-key.pem" 2>/dev/null | head -1)"
  KEY_FILE="$(find "$CERT_DIR" -name "${LOCAL_HOSTNAME}*-key.pem" 2>/dev/null | head -1)"
  if [[ -z "$CERT_FILE" || -z "$KEY_FILE" || ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
    fail "mkcert certs for '${LOCAL_HOSTNAME}' not found in $CERT_DIR. Run: mkdir -p $CERT_DIR && cd $CERT_DIR && mkcert ${LOCAL_HOSTNAME} localhost 127.0.0.1"
  fi
elif $TUNNEL_MODE; then
  command -v cloudflared >/dev/null 2>&1 || fail "cloudflared not found. Install: brew install cloudflared"
  command -v python3 >/dev/null 2>&1 || fail "python3 not found"
else
  command -v wrangler >/dev/null 2>&1 || fail "wrangler not found. Install: npm i -g wrangler"
fi

if $CLOUD_MODE; then
  if [[ -z "${R2_BUCKET:-}" || -z "${R2_PUBLIC_URL:-}" || -z "${PAGES_PROJECT:-}" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
      echo ""
      echo "No config found. Running first-time setup..."
      echo ""
      bash "$SKILL_DIR/scripts/setup.sh"
      [[ -f "$CONFIG_FILE" ]] || fail "Setup did not create config. Aborting."
      # shellcheck source=/dev/null
      source "$CONFIG_FILE"
    fi
  fi

  [[ -n "${R2_BUCKET:-}" ]]     || fail "R2_BUCKET not set in config. Run: bash $SKILL_DIR/scripts/setup.sh"
  [[ -n "${R2_PUBLIC_URL:-}" ]] || fail "R2_PUBLIC_URL not set in config. Run: bash $SKILL_DIR/scripts/setup.sh"
  [[ -n "${PAGES_PROJECT:-}" ]] || fail "PAGES_PROJECT not set in config. Run: bash $SKILL_DIR/scripts/setup.sh"
fi

# ─── Step 1: Resolve IPA path (build if not provided) ────────────────────
if [[ $# -ge 1 ]]; then
  IPA_PATH="$1"
  [[ -f "$IPA_PATH" ]] || fail "File not found: $IPA_PATH"
  [[ "$IPA_PATH" == *.ipa ]] || fail "Not an .ipa file: $IPA_PATH"
else
  log "No .ipa provided — building from current project..."

  # Find .xcworkspace or .xcodeproj
  WORKSPACE=""
  PROJECT=""
  if ls *.xcworkspace 1>/dev/null 2>&1; then
    WORKSPACE="$(ls -d *.xcworkspace | head -1)"
    log "Found workspace: $WORKSPACE"
  elif ls *.xcodeproj 1>/dev/null 2>&1; then
    PROJECT="$(ls -d *.xcodeproj | head -1)"
    log "Found project: $PROJECT"
  else
    fail "No .xcworkspace or .xcodeproj found in $(pwd)"
  fi

  # Determine scheme
  if [[ -n "$WORKSPACE" ]]; then
    SCHEME="$(xcodebuild -workspace "$WORKSPACE" -list 2>/dev/null | awk '/Schemes:/{found=1; next} found && NF{print $1; exit}')"
    BUILD_TARGET="-workspace $WORKSPACE"
  else
    SCHEME="$(xcodebuild -project "$PROJECT" -list 2>/dev/null | awk '/Schemes:/{found=1; next} found && NF{print $1; exit}')"
    BUILD_TARGET="-project $PROJECT"
  fi
  [[ -n "$SCHEME" ]] || fail "Could not determine scheme"
  log "Using scheme: $SCHEME"

  ARCHIVE_PATH="$TMPDIR_WORK/$SCHEME.xcarchive"
  EXPORT_DIR="$TMPDIR_WORK/export"

  # Build archive
  log "Archiving (Ad Hoc)..."
  # shellcheck disable=SC2086
  xcodebuild archive \
    $BUILD_TARGET \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    2>&1 | tail -5 >&2
  [[ -d "$ARCHIVE_PATH" ]] || fail "Archive failed — $ARCHIVE_PATH not created"
  ok "Archive created"

  # Generate export options plist
  EXPORT_PLIST="$TMPDIR_WORK/ExportOptions.plist"
  ARCHIVE_PLIST="$ARCHIVE_PATH/Info.plist"
  TEAM_ID="$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:Team" "$ARCHIVE_PLIST" 2>/dev/null || echo "")"

  cat > "$EXPORT_PLIST" <<EXPORTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>compileBitcode</key>
    <false/>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>thinning</key>
    <string>&lt;none&gt;</string>
EXPORTEOF

  if [[ -n "$TEAM_ID" ]]; then
    cat >> "$EXPORT_PLIST" <<TEAMEOF
    <key>teamID</key>
    <string>${TEAM_ID}</string>
TEAMEOF
  fi

  cat >> "$EXPORT_PLIST" <<ENDEOF
</dict>
</plist>
ENDEOF

  # Export IPA
  log "Exporting IPA..."
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    2>&1 | tail -5 >&2

  IPA_PATH="$(find "$EXPORT_DIR" -name "*.ipa" -print -quit)"
  [[ -n "$IPA_PATH" && -f "$IPA_PATH" ]] || fail "IPA export failed — no .ipa found in $EXPORT_DIR"
  ok "IPA exported: $(basename "$IPA_PATH")"
fi

# ─── Step 2: Extract IPA metadata ──────────────────────────────────────────
log "Extracting metadata..."

unzip -q -o "$IPA_PATH" "Payload/*.app/Info.plist" -d "$TMPDIR_WORK"

INFO_PLIST="$(find "$TMPDIR_WORK/Payload" -maxdepth 2 -name "Info.plist" -print -quit)"
[[ -n "$INFO_PLIST" ]] || fail "Could not find Info.plist in IPA"

plist_val() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || echo ""; }

BUNDLE_ID="$(plist_val CFBundleIdentifier)"
VERSION="$(plist_val CFBundleShortVersionString)"
BUILD="$(plist_val CFBundleVersion)"
APP_TITLE="$(plist_val CFBundleDisplayName)"
[[ -z "$APP_TITLE" ]] && APP_TITLE="$(plist_val CFBundleName)"
[[ -z "$APP_TITLE" ]] && APP_TITLE="App"

[[ -n "$BUNDLE_ID" ]] || fail "Could not read CFBundleIdentifier from Info.plist"
[[ -n "$VERSION" ]]   || fail "Could not read CFBundleShortVersionString from Info.plist"

echo "  App:     $APP_TITLE"
echo "  Bundle:  $BUNDLE_ID"
echo "  Version: $VERSION ($BUILD)"

# ─── Step 2.5: Collect git changelog + release timestamp ──────────────────
RELEASE_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

# Collect uncommitted files + last 3 git commits
CHANGED_FILES_HTML=""
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "Collecting git changelog..."

  # Uncommitted files (staged + unstaged + untracked)
  UNCOMMITTED="$(git status --short 2>/dev/null || echo "")"

  # Last 3 commits
  COMMIT_LOG="$(git log --oneline -3 2>/dev/null || echo "")"

  CHANGED_FILES_HTML="<div class=\"changelog\"><h2>Changes in This Update</h2>"

  # Uncommitted files section (shown above commits)
  if [[ -n "$UNCOMMITTED" ]]; then
    UNCOMMITTED_ITEMS=""
    while IFS= read -r line; do
      [[ -n "$line" ]] && UNCOMMITTED_ITEMS="${UNCOMMITTED_ITEMS}<li>${line}</li>"
    done <<< "$UNCOMMITTED"
    UNCOMMITTED_COUNT="$(echo "$UNCOMMITTED" | grep -c '.' || echo 0)"
    CHANGED_FILES_HTML="${CHANGED_FILES_HTML}<h3>Uncommitted (${UNCOMMITTED_COUNT})</h3><ul class=\"files\">${UNCOMMITTED_ITEMS}</ul>"
    ok "Found ${UNCOMMITTED_COUNT} uncommitted files"
  fi

  # Commits section
  if [[ -n "$COMMIT_LOG" ]]; then
    COMMIT_ITEMS=""
    while IFS= read -r line; do
      [[ -n "$line" ]] && COMMIT_ITEMS="${COMMIT_ITEMS}<li>${line}</li>"
    done <<< "$COMMIT_LOG"
    CHANGED_FILES_HTML="${CHANGED_FILES_HTML}<h3>Recent Commits</h3><ul class=\"commits\">${COMMIT_ITEMS}</ul>"
  fi

  CHANGED_FILES_HTML="${CHANGED_FILES_HTML}</div>"
fi

# ─── HTML generator function ───────────────────────────────────────────────
# Generates the install page HTML. Called by each mode with the appropriate
# manifest URL and optional extras (cert button, note text).
# Args: $1=manifest_url  $2=extra_buttons_html  $3=extra_sections_html
generate_install_html() {
  local MANIFEST_URL="$1"
  local EXTRA_BUTTONS="${2:-}"
  local EXTRA_SECTIONS="${3:-}"

  cat <<HTMLEOF
<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Install ${APP_TITLE}</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    min-height: 100vh; background: #f5f5f7; color: #1d1d1f;
    padding: 40px 16px;
  }
  .container { max-width: 400px; margin: 0 auto; }
  .card {
    background: #fff; border-radius: 16px; padding: 32px 24px;
    text-align: center;
    box-shadow: 0 2px 12px rgba(0,0,0,0.08);
    margin-bottom: 16px;
  }
  h1 { font-size: 22px; margin-bottom: 4px; }
  .version { font-size: 14px; color: #86868b; margin-bottom: 4px; }
  .release-time { font-size: 12px; color: #aeaeb2; margin-bottom: 24px; }
  .btn {
    display: block; width: 100%; text-align: center;
    text-decoration: none; padding: 14px 0; border-radius: 12px;
    font-size: 17px; font-weight: 600; transition: all 0.2s;
    margin-bottom: 10px;
  }
  .btn:last-child { margin-bottom: 0; }
  .btn-install { background: #007aff; color: #fff; }
  .btn-install:active { background: #0056b3; }
  .btn-install.disabled {
    background: #c7c7cc; pointer-events: none;
  }
  .btn-cert { background: #f2f2f7; color: #007aff; border: 1px solid #e5e5ea; }
  .btn-cert:active { background: #e5e5ea; }
  .note { font-size: 12px; color: #86868b; margin-top: 16px; }
  .changelog {
    background: #fff; border-radius: 16px; padding: 24px;
    box-shadow: 0 2px 12px rgba(0,0,0,0.08);
    text-align: left; margin-bottom: 16px;
  }
  .changelog h2 {
    font-size: 17px; margin-bottom: 16px; text-align: center;
    color: #1d1d1f;
  }
  .changelog h3 {
    font-size: 14px; color: #636366; margin-bottom: 8px;
    font-weight: 600;
  }
  .changelog ul {
    list-style: none; padding: 0; margin: 0 0 12px 0;
  }
  .changelog ul.commits li {
    font-size: 14px; line-height: 1.6; padding: 4px 0;
    border-bottom: 1px solid #f2f2f7;
  }
  .changelog ul.commits li:last-child { border-bottom: none; }
  .changelog details { margin-top: 8px; }
  .changelog summary {
    font-size: 14px; color: #007aff; cursor: pointer;
    font-weight: 500; padding: 8px 0;
  }
  .changelog ul.files li {
    font-size: 12px; line-height: 1.5; padding: 2px 0;
    font-family: ui-monospace, SFMono-Regular, monospace;
    color: #636366; word-break: break-all;
  }
  .guide {
    background: #fff; border-radius: 16px; padding: 24px;
    box-shadow: 0 2px 12px rgba(0,0,0,0.08);
    text-align: left;
  }
  .guide h2 {
    font-size: 17px; margin-bottom: 16px; text-align: center;
    color: #1d1d1f;
  }
  .step {
    display: flex; gap: 12px; margin-bottom: 16px;
    align-items: flex-start;
  }
  .step:last-child { margin-bottom: 0; }
  .step-num {
    flex-shrink: 0; width: 28px; height: 28px;
    background: #007aff; color: #fff; border-radius: 50%;
    display: flex; align-items: center; justify-content: center;
    font-size: 14px; font-weight: 700;
  }
  .step-num.done { background: #34c759; }
  .step-text { font-size: 15px; line-height: 1.5; padding-top: 3px; }
  .step-text small { color: #86868b; display: block; margin-top: 2px; font-size: 13px; }
  .path { font-family: ui-monospace, monospace; font-size: 13px; color: #636366; }
  .divider { height: 1px; background: #e5e5ea; margin: 20px 0; }
  .status {
    text-align: center; font-size: 14px; padding: 10px;
    border-radius: 8px; margin-bottom: 12px;
  }
  .status-ok { background: #e8f8ef; color: #1b7a3d; }
  .status-warn { background: #fff8e6; color: #946800; }
</style>
</head>
<body>
<div class="container">
  <div class="card">
    <h1>${APP_TITLE}</h1>
    <p class="version">${VERSION} (${BUILD})</p>
    <p class="release-time">${RELEASE_TIME}</p>
    <div id="cert-status"></div>
    <a id="installBtn" class="btn btn-install" href="itms-services://?action=download-manifest&url=${MANIFEST_URL}">Install App</a>
${EXTRA_BUTTONS}
  </div>

${CHANGED_FILES_HTML}

${EXTRA_SECTIONS}

  <p class="note" style="text-align:center;">Open this page in Safari on your iPhone.</p>
</div>
</body>
</html>
HTMLEOF
}

# ─── Step 3+: Deploy (cloud or local) ─────────────────────────────────────

if $LOCAL_MODE; then
  # ─── LOCAL MODE: serve via HTTPS on local network (mkcert) ───────────
  SERVE_DIR="$TMPDIR_WORK/serve"
  mkdir -p "$SERVE_DIR"

  # Copy IPA into serve dir
  cp "$IPA_PATH" "$SERVE_DIR/"
  IPA_FILENAME="$(basename "$IPA_PATH")"

  # Pick a local port (auto-increment if busy)
  LOCAL_PORT=8443
  while lsof -i :"$LOCAL_PORT" >/dev/null 2>&1; do
    LOCAL_PORT=$((LOCAL_PORT + 1))
  done

  BASE_URL="https://${LOCAL_HOSTNAME}:${LOCAL_PORT}"
  IPA_URL="${BASE_URL}/${IPA_FILENAME}"

  # Generate manifest.plist
  cat > "$SERVE_DIR/manifest.plist" <<MANIFEST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${IPA_URL}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${BUNDLE_ID}</string>
        <key>bundle-version</key>
        <string>${VERSION}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${APP_TITLE}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
MANIFEST

  # Copy CA root cert into serve dir for download
  CA_ROOT="$(mkcert -CAROOT)/rootCA.pem"
  if [[ -f "$CA_ROOT" ]]; then
    cp "$CA_ROOT" "$SERVE_DIR/ca.pem"
  fi

  # Generate install page
  MANIFEST_URL="${BASE_URL}/manifest.plist"
  CERT_BTN="    <a class=\"btn btn-cert\" href=\"${BASE_URL}/ca.pem\">Download CA Certificate</a>"
  GUIDE_HTML='
  <div class="guide" id="guide">
    <h2>First-Time Setup</h2>
    <p style="font-size:14px; color:#86868b; text-align:center; margin-bottom:16px;">
      Only needed once. After trusting the certificate,<br>you can install apps directly next time.
    </p>
    <div class="step">
      <div class="step-num">1</div>
      <div class="step-text">
        Tap <strong>"Download CA Certificate"</strong> above
        <small>Safari will prompt you to download a profile</small>
      </div>
    </div>
    <div class="step">
      <div class="step-num">2</div>
      <div class="step-text">
        Install the profile
        <small class="path">Settings → General → VPN &amp; Device Management → Install the downloaded profile</small>
      </div>
    </div>
    <div class="step">
      <div class="step-num">3</div>
      <div class="step-text">
        Enable full trust
        <small class="path">Settings → General → About → Certificate Trust Settings → Turn on the toggle for mkcert</small>
      </div>
    </div>
    <div class="divider"></div>
    <div class="step">
      <div class="step-num" style="background:#34c759">4</div>
      <div class="step-text">
        Come back and tap <strong>"Install App"</strong>
      </div>
    </div>
  </div>'

  # Add cert detection script to guide section
  GUIDE_HTML="${GUIDE_HTML}
<script>
(function() {
  var status = document.getElementById('cert-status');
  var btn = document.getElementById('installBtn');
  var guide = document.getElementById('guide');
  fetch('${BASE_URL}/manifest.plist', { mode: 'no-cors' })
    .then(function() {
      if (status) status.style.display = 'none';
      if (guide) guide.style.display = 'none';
    })
    .catch(function() {
      if (status) {
        status.className = 'status status-warn';
        status.textContent = 'Certificate not yet trusted — follow the guide below';
      }
      btn.classList.add('disabled');
      btn.textContent = 'Install App (trust certificate first)';
    });
})();
</script>"

  generate_install_html "$MANIFEST_URL" "$CERT_BTN" "$GUIDE_HTML" > "$SERVE_DIR/index.html"

  # Start HTTPS server with mkcert certs
  log "Starting HTTPS server on ${LOCAL_HOSTNAME}:${LOCAL_PORT}..."
  python3 -c "
import http.server, ssl, os, sys
os.chdir('$SERVE_DIR')
handler = http.server.SimpleHTTPRequestHandler
handler.extensions_map['.plist'] = 'application/xml'
handler.extensions_map['.ipa'] = 'application/octet-stream'
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('$CERT_FILE', '$KEY_FILE')
try:
    server = http.server.HTTPServer(('0.0.0.0', $LOCAL_PORT), handler)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
except OSError as e:
    print(f'Server error: {e}', file=sys.stderr)
    sys.exit(1)
" &
  SERVER_PID=$!
  sleep 1

  # Verify server started
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "HTTPS server failed to start on port $LOCAL_PORT"
  fi

  # ─── Done (local) ───────────────────────────────────────────────────────
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  ok "Local HTTPS server ready! Install URL:"
  echo "  $BASE_URL"
  echo ""
  echo "  Open this URL on your iPhone in Safari to install."
  echo "  Make sure your iPhone trusts the mkcert CA:"
  echo "    Settings → General → VPN & Device Mgmt → Install CA"
  echo "    Settings → General → About → Certificate Trust Settings → Enable"
  echo ""
  echo "  CA cert: $(mkcert -CAROOT)/rootCA.pem"
  echo "  Press Ctrl+C to stop the server."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Keep script alive until Ctrl+C
  wait "$SERVER_PID" 2>/dev/null || true

elif $TUNNEL_MODE; then
  # ─── TUNNEL MODE: serve via cloudflared quick tunnel ─────────────────
  SERVE_DIR="$TMPDIR_WORK/serve"
  mkdir -p "$SERVE_DIR"

  # Copy IPA into serve dir
  cp "$IPA_PATH" "$SERVE_DIR/"
  IPA_FILENAME="$(basename "$IPA_PATH")"

  # Pick a local port (auto-increment if busy)
  LOCAL_PORT=8723
  while lsof -i :"$LOCAL_PORT" >/dev/null 2>&1; do
    LOCAL_PORT=$((LOCAL_PORT + 1))
  done

  # Start local HTTP server in background
  log "Starting local HTTP server on port $LOCAL_PORT..."
  python3 -c "
import http.server, socketserver, os, sys
os.chdir('$SERVE_DIR')
handler = http.server.SimpleHTTPRequestHandler
handler.extensions_map['.plist'] = 'application/xml'
handler.extensions_map['.ipa'] = 'application/octet-stream'
try:
    with socketserver.TCPServer(('127.0.0.1', $LOCAL_PORT), handler) as s:
        s.serve_forever()
except OSError as e:
    print(f'Server error: {e}', file=sys.stderr)
    sys.exit(1)
" &
  SERVER_PID=$!
  sleep 1

  # Verify server started
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "Local HTTP server failed to start on port $LOCAL_PORT"
  fi

  # Start cloudflared quick tunnel in background, capture the URL
  log "Starting cloudflared tunnel..."
  TUNNEL_LOG="$TMPDIR_WORK/tunnel.log"
  cloudflared tunnel --url "http://127.0.0.1:$LOCAL_PORT" \
    --no-autoupdate --config /dev/null 2>"$TUNNEL_LOG" &
  TUNNEL_PID=$!

  # Wait for cloudflared to print the public URL
  TUNNEL_URL=""
  for i in $(seq 1 30); do
    TUNNEL_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)"
    if [[ -n "$TUNNEL_URL" ]]; then
      break
    fi
    sleep 1
  done

  if [[ -z "$TUNNEL_URL" ]]; then
    cat "$TUNNEL_LOG" >&2
    fail "cloudflared failed to create tunnel within 30s"
  fi

  ok "Tunnel active: $TUNNEL_URL"

  IPA_URL="${TUNNEL_URL}/${IPA_FILENAME}"

  # Generate manifest.plist (IPA URL points to tunnel)
  cat > "$SERVE_DIR/manifest.plist" <<MANIFEST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${IPA_URL}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${BUNDLE_ID}</string>
        <key>bundle-version</key>
        <string>${VERSION}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${APP_TITLE}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
MANIFEST

  # Generate install page
  generate_install_html "${TUNNEL_URL}/manifest.plist" "" "" > "$SERVE_DIR/index.html"

  # ─── Done (tunnel) ──────────────────────────────────────────────────────
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  ok "Tunnel server ready! Install URL:"
  echo "  $TUNNEL_URL"
  echo ""
  echo "  Open this URL on your iPhone in Safari to install."
  echo "  Press Ctrl+C to stop the tunnel."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Keep script alive until Ctrl+C
  wait "$TUNNEL_PID" 2>/dev/null || true

elif $CLOUD_MODE; then
  # ─── CLOUD MODE: Upload to R2 + Pages (fixed URL, overwrites previous) ─
  IPA_FILENAME="$(basename "$IPA_PATH")"
  # Use fixed key — each deploy overwrites the previous one
  R2_KEY="app.ipa"
  IPA_URL="${R2_PUBLIC_URL}/${R2_KEY}"

  log "Uploading IPA to R2 (overwriting previous)..."
  wrangler r2 object put "${R2_BUCKET}/${R2_KEY}" \
    --file "$IPA_PATH" \
    --content-type "application/octet-stream" \
    --remote

  ok "Uploaded: $IPA_URL"

  # ─── Step 4: Generate manifest.plist ─────────────────────────────────────
  OUTPUT_DIR="$TMPDIR_WORK/output"
  mkdir -p "$OUTPUT_DIR"

  cat > "$OUTPUT_DIR/manifest.plist" <<MANIFEST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${IPA_URL}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${BUNDLE_ID}</string>
        <key>bundle-version</key>
        <string>${VERSION}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${APP_TITLE}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
MANIFEST

  # ─── Step 5: Generate install page ──────────────────────────────────────
  # Cloud mode uses JS to resolve manifest URL from current origin
  cat > "$OUTPUT_DIR/index.html" <<'HTMLEOF_CLOUD_PRE'
<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Install APP_TITLE_PLACEHOLDER</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    min-height: 100vh; background: #f5f5f7; color: #1d1d1f;
    padding: 40px 16px;
  }
  .container { max-width: 400px; margin: 0 auto; }
  .card {
    background: #fff; border-radius: 16px; padding: 32px 24px;
    text-align: center;
    box-shadow: 0 2px 12px rgba(0,0,0,0.08);
    margin-bottom: 16px;
  }
  h1 { font-size: 22px; margin-bottom: 4px; }
  .version { font-size: 14px; color: #86868b; margin-bottom: 4px; }
  .release-time { font-size: 12px; color: #aeaeb2; margin-bottom: 24px; }
  .btn {
    display: block; width: 100%; text-align: center;
    text-decoration: none; padding: 14px 0; border-radius: 12px;
    font-size: 17px; font-weight: 600; transition: all 0.2s;
    margin-bottom: 10px;
  }
  .btn:last-child { margin-bottom: 0; }
  .btn-install { background: #007aff; color: #fff; }
  .btn-install:active { background: #0056b3; }
  .note { font-size: 12px; color: #86868b; margin-top: 16px; }
  .changelog {
    background: #fff; border-radius: 16px; padding: 24px;
    box-shadow: 0 2px 12px rgba(0,0,0,0.08);
    text-align: left; margin-bottom: 16px;
  }
  .changelog h2 {
    font-size: 17px; margin-bottom: 16px; text-align: center;
    color: #1d1d1f;
  }
  .changelog h3 {
    font-size: 14px; color: #636366; margin-bottom: 8px;
    font-weight: 600;
  }
  .changelog ul {
    list-style: none; padding: 0; margin: 0 0 12px 0;
  }
  .changelog ul.commits li {
    font-size: 14px; line-height: 1.6; padding: 4px 0;
    border-bottom: 1px solid #f2f2f7;
  }
  .changelog ul.commits li:last-child { border-bottom: none; }
  .changelog details { margin-top: 8px; }
  .changelog summary {
    font-size: 14px; color: #007aff; cursor: pointer;
    font-weight: 500; padding: 8px 0;
  }
  .changelog ul.files li {
    font-size: 12px; line-height: 1.5; padding: 2px 0;
    font-family: ui-monospace, SFMono-Regular, monospace;
    color: #636366; word-break: break-all;
  }
</style>
</head>
<body>
<div class="container">
  <div class="card">
    <h1>APP_TITLE_PLACEHOLDER</h1>
    <p class="version">VERSION_PLACEHOLDER (BUILD_PLACEHOLDER)</p>
    <p class="release-time">RELEASE_TIME_PLACEHOLDER</p>
    <a id="installLink" class="btn btn-install" href="#">Install App</a>
  </div>

CHANGELOG_PLACEHOLDER

  <p class="note" style="text-align:center;">Open this page in Safari on your iPhone.</p>
</div>
<script>
  var manifestUrl = window.location.origin + '/manifest.plist';
  var link = 'itms-services://?action=download-manifest&url=' + encodeURIComponent(manifestUrl);
  document.getElementById('installLink').href = link;
</script>
</body>
</html>
HTMLEOF_CLOUD_PRE

  # Replace placeholders
  sed -i '' "s/APP_TITLE_PLACEHOLDER/${APP_TITLE}/g" "$OUTPUT_DIR/index.html"
  sed -i '' "s/VERSION_PLACEHOLDER/${VERSION}/g" "$OUTPUT_DIR/index.html"
  sed -i '' "s/BUILD_PLACEHOLDER/${BUILD}/g" "$OUTPUT_DIR/index.html"
  sed -i '' "s|RELEASE_TIME_PLACEHOLDER|${RELEASE_TIME}|g" "$OUTPUT_DIR/index.html"

  # Replace changelog placeholder with actual HTML (use a temp file for multiline)
  if [[ -n "$CHANGED_FILES_HTML" ]]; then
    # Write changelog HTML to a temp file and use it for replacement
    CHANGELOG_FILE="$TMPDIR_WORK/changelog_fragment.html"
    echo "$CHANGED_FILES_HTML" > "$CHANGELOG_FILE"
    # Use python for reliable multiline replacement
    python3 -c "
import sys
with open('$OUTPUT_DIR/index.html', 'r') as f:
    content = f.read()
with open('$CHANGELOG_FILE', 'r') as f:
    changelog = f.read().strip()
content = content.replace('CHANGELOG_PLACEHOLDER', changelog)
with open('$OUTPUT_DIR/index.html', 'w') as f:
    f.write(content)
"
  else
    sed -i '' 's/CHANGELOG_PLACEHOLDER//g' "$OUTPUT_DIR/index.html"
  fi

  # ─── Step 6: Deploy to Cloudflare Pages ─────────────────────────────────
  log "Deploying to Cloudflare Pages..."

  if ! wrangler pages project list 2>&1 | grep -q "$PAGES_PROJECT"; then
    wrangler pages project create "$PAGES_PROJECT" --production-branch production >/dev/null 2>&1 || true
  fi

  DEPLOY_OUTPUT="$(wrangler pages deploy "$OUTPUT_DIR" \
    --project-name "$PAGES_PROJECT" \
    --branch production \
    --commit-dirty=true 2>&1)"

  DEPLOY_URL="$(echo "$DEPLOY_OUTPUT" | grep -oE 'https://[a-z0-9-]+\.'"$PAGES_PROJECT"'\.pages\.dev' | head -1)"
  [[ -z "$DEPLOY_URL" ]] && DEPLOY_URL="$(echo "$DEPLOY_OUTPUT" | grep -oE 'https://[^ ]+\.pages\.dev' | head -1)"

  # ─── Done ────────────────────────────────────────────────────────────────
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ -n "$DEPLOY_URL" ]]; then
    ok "Deployed! Install URL:"
    echo "  $DEPLOY_URL"
  else
    ok "Deployed! Check Cloudflare Pages dashboard for the URL."
  fi
  echo ""
  echo "  Open this URL on your iPhone in Safari to install."
  echo "  Same URL for every deploy — always points to the latest version."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

fi
