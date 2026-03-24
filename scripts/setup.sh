#!/usr/bin/env bash
set -euo pipefail

# ─── Air Install IPA — First-run setup ──────────────────────────────────────
# Guides the user through Cloudflare authentication and R2/Pages configuration.
# Stores config in ~/.config/air-install-ipa/config for future deploys.
#
# Non-interactive mode (for CI/agent use):
#   setup.sh [--bucket NAME] [--pages NAME] [--url URL]
# All flags are optional; defaults are used when omitted.

CONFIG_DIR="$HOME/.config/air-install-ipa"
CONFIG_FILE="$CONFIG_DIR/config"

fail() { echo "Error: $1" >&2; exit 1; }
log()  { echo "▸ $*" >&2; }
ok()   { echo "✓ $*" >&2; }

# ─── Parse args ─────────────────────────────────────────────────────────────
ARG_BUCKET=""
ARG_PAGES=""
ARG_URL=""
ARG_HOSTNAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)   ARG_BUCKET="$2";   shift 2 ;;
    --pages)    ARG_PAGES="$2";    shift 2 ;;
    --url)      ARG_URL="$2";      shift 2 ;;
    --hostname) ARG_HOSTNAME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: setup.sh [--hostname NAME] [--bucket NAME] [--pages NAME] [--url URL]"
      echo "  --hostname  Local hostname for mkcert HTTPS (default: localhost)"
      echo "  --bucket    R2 bucket name (default: ipa-ota-install)"
      echo "  --pages     Cloudflare Pages project name (default: ipa-ota-install)"
      echo "  --url       R2 public URL (auto-detected if omitted)"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Detect if stdin is a terminal (interactive) or pipe/agent (non-interactive)
INTERACTIVE=false
[[ -t 0 ]] && INTERACTIVE=true

# ─── Preflight ──────────────────────────────────────────────────────────────
command -v wrangler >/dev/null 2>&1 || fail "wrangler not found. Install: npm i -g wrangler"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║        Air Install IPA — Setup               ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Local hostname ──────────────────────────────────────────────
echo "Step 1/5: Local hostname (for mkcert HTTPS in local mode)"
echo ""

DEFAULT_HOSTNAME="localhost"
if [[ -n "$ARG_HOSTNAME" ]]; then
  LOCAL_HOSTNAME="$ARG_HOSTNAME"
elif [[ "$INTERACTIVE" == "true" ]]; then
  read -r -p "  Local hostname [$DEFAULT_HOSTNAME]: " HOSTNAME_INPUT
  LOCAL_HOSTNAME="${HOSTNAME_INPUT:-$DEFAULT_HOSTNAME}"
else
  LOCAL_HOSTNAME="$DEFAULT_HOSTNAME"
fi
ok "Local hostname: $LOCAL_HOSTNAME"
echo ""

# ─── Step 2: Wrangler login ────────────────────────────────────────────────
echo "Step 2/5: Cloudflare authentication"
echo ""

WHOAMI_OUTPUT="$(wrangler whoami 2>&1 || true)"

if echo "$WHOAMI_OUTPUT" | grep -qE "You are logged in|Token Permissions"; then
  ACCOUNT_INFO="$(echo "$WHOAMI_OUTPUT" | grep -E '^\|' | head -2 | tail -1 || echo "")"
  ok "Already authenticated with Cloudflare. ${ACCOUNT_INFO}"
elif [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  if wrangler r2 bucket list >/dev/null 2>&1; then
    ok "Authenticated via CLOUDFLARE_API_TOKEN environment variable."
  else
    fail "CLOUDFLARE_API_TOKEN is set but appears invalid. Check the token and try again."
  fi
else
  if [[ "$INTERACTIVE" == "true" ]]; then
    log "Opening browser for Cloudflare login..."
    wrangler login
    if ! wrangler whoami 2>&1 | grep -qE "You are logged in|Token Permissions"; then
      fail "Login failed. Run 'wrangler login' manually and try again."
    fi
    ok "Logged in to Cloudflare."
  else
    fail "Not authenticated. Set CLOUDFLARE_API_TOKEN or run 'wrangler login' first."
  fi
fi
echo ""

# ─── Step 2: R2 bucket ────────────────────────────────────────────────────
echo "Step 3/5: R2 bucket"
echo ""

DEFAULT_BUCKET="ipa-ota-install"
if [[ -n "$ARG_BUCKET" ]]; then
  R2_BUCKET="$ARG_BUCKET"
elif [[ "$INTERACTIVE" == "true" ]]; then
  read -r -p "  R2 bucket name [$DEFAULT_BUCKET]: " BUCKET_INPUT
  R2_BUCKET="${BUCKET_INPUT:-$DEFAULT_BUCKET}"
else
  R2_BUCKET="$DEFAULT_BUCKET"
fi
log "Using bucket: $R2_BUCKET"

BUCKET_LIST="$(wrangler r2 bucket list 2>&1)"
if echo "$BUCKET_LIST" | grep -q "$R2_BUCKET"; then
  ok "Bucket '$R2_BUCKET' already exists."
else
  log "Creating R2 bucket '$R2_BUCKET'..."
  wrangler r2 bucket create "$R2_BUCKET"
  ok "Bucket '$R2_BUCKET' created."
fi
echo ""

# ─── Step 3: Enable public URL for R2 bucket ─────────────────────────────
echo "Step 4/5: R2 public access"
echo ""

if [[ -n "$ARG_URL" ]]; then
  R2_PUBLIC_URL="$ARG_URL"
else
  log "Enabling dev URL for bucket '$R2_BUCKET'..."
  wrangler r2 bucket dev-url enable "$R2_BUCKET" 2>/dev/null || true

  R2_PUBLIC_URL="$(wrangler r2 bucket dev-url get "$R2_BUCKET" 2>&1 | grep -oE 'https://[a-zA-Z0-9._-]+\.r2\.dev' | head -1 || echo "")"

  if [[ -z "$R2_PUBLIC_URL" ]]; then
    if [[ "$INTERACTIVE" == "true" ]]; then
      echo "  Could not auto-detect the R2 public URL."
      echo "  Run: wrangler r2 bucket dev-url get $R2_BUCKET"
      read -r -p "  Paste the public URL here: " R2_PUBLIC_URL
      [[ -n "$R2_PUBLIC_URL" ]] || fail "R2 public URL is required."
    else
      fail "Could not auto-detect R2 public URL. Pass --url or run: wrangler r2 bucket dev-url get $R2_BUCKET"
    fi
  fi
fi
ok "R2 public URL: $R2_PUBLIC_URL"
echo ""

# ─── Step 4: Pages project name ──────────────────────────────────────────
echo "Step 5/5: Cloudflare Pages project"
echo ""

DEFAULT_PAGES="ipa-ota-install"
if [[ -n "$ARG_PAGES" ]]; then
  PAGES_PROJECT="$ARG_PAGES"
elif [[ "$INTERACTIVE" == "true" ]]; then
  read -r -p "  Pages project name [$DEFAULT_PAGES]: " PAGES_INPUT
  PAGES_PROJECT="${PAGES_INPUT:-$DEFAULT_PAGES}"
else
  PAGES_PROJECT="$DEFAULT_PAGES"
fi

ok "Pages project: $PAGES_PROJECT"
echo ""

# ─── Save config ─────────────────────────────────────────────────────────
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
# Air Install IPA — config
# Generated by setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
LOCAL_HOSTNAME=$LOCAL_HOSTNAME
R2_BUCKET=$R2_BUCKET
R2_PUBLIC_URL=$R2_PUBLIC_URL
PAGES_PROJECT=$PAGES_PROJECT
EOF

chmod 600 "$CONFIG_FILE"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Setup complete! Config saved to: $CONFIG_FILE"
echo ""
echo "  You can now deploy with:"
echo "    /air-install-ipa"
echo "    /air-install-ipa path/to/App.ipa"
echo ""
echo "  To reconfigure, run this setup again."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
