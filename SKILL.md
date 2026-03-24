---
name: air-install-ipa
description: "Deploy an Ad Hoc signed .ipa for wireless OTA installation. Three modes: local HTTPS (default, mkcert), cloudflared tunnel, or cloud (R2 + Pages). Use when the user says /air-install-ipa, 'air install', 'deploy ipa', 'ota install', 'upload ipa', '安装到手机', '无线安装', '装到真机', '发布ipa', '部署ipa', or wants to distribute an iOS app for over-the-air installation to a device. Requires: macOS, python3 + mkcert (local), cloudflared (tunnel), or wrangler (cloud)."
---

# Air Install IPA

Build and deploy an Ad Hoc signed `.ipa` for OTA installation.

## Deploy (Local HTTPS — default)

Serves the IPA from this Mac over HTTPS on the local network using mkcert certificates. Fastest option — no upload, no external dependency.

```bash
# Auto-build from current Xcode project
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh

# Deploy a pre-built .ipa
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh path/to/App.ipa
```

The install page includes a CA certificate download button and trust guide for first-time iPhone setup. After the iPhone trusts the CA once, future installs are seamless.

Requires: `python3`, `mkcert` (certs at `~/.config/air-install-ipa/certs/`).

## Deploy (Tunnel — cloudflared)

IPA stays on this Mac. A cloudflared quick tunnel provides the HTTPS URL for OTA install. No certs needed on iPhone.

```bash
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh --tunnel
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh --tunnel path/to/App.ipa
```

Requires: `cloudflared`, `python3`. No Cloudflare account config needed.

## Deploy (Cloud — R2 + Pages)

Uploads to Cloudflare R2 and deploys install page to Cloudflare Pages.

```bash
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh --cloud
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh --cloud path/to/App.ipa
```

Requires: `wrangler` CLI + Cloudflare account. Run setup first if not configured.

## First-time setup

### Local mode (default)

```bash
brew install mkcert
mkcert -install
mkdir -p ~/.config/air-install-ipa/certs
cd ~/.config/air-install-ipa/certs && mkcert YOUR_HOSTNAME localhost 127.0.0.1
```

Set `LOCAL_HOSTNAME` in `~/.config/air-install-ipa/config` to match:

```
LOCAL_HOSTNAME=YOUR_HOSTNAME
```

On iPhone (once): open the install page in Safari, tap "Download CA Certificate", then trust it in Settings.

### Cloud mode

```bash
bash ~/.claude/skills/air-install-ipa/scripts/setup.sh
```

Setup walks through: Cloudflare login, R2 bucket creation, public URL, Pages project name. Config is saved to `~/.config/air-install-ipa/config`.

## What it does

### Local mode (default)
1. If no `.ipa` provided: archives and exports an Ad Hoc `.ipa`
2. Extracts metadata (bundle ID, version, title) from `Info.plist`
3. Collects git changelog (commits + modified files since last tag)
4. Starts an HTTPS server on the local network (mkcert certs)
5. Serves IPA + manifest + install page with cert guide, changelog, and release time
6. Outputs the install URL (`https://LOCAL_HOSTNAME:PORT`)
7. Keeps serving until Ctrl+C

### Tunnel mode (`--tunnel`)
1. If no `.ipa` provided: archives and exports an Ad Hoc `.ipa`
2. Extracts metadata from `Info.plist`
3. Collects git changelog (commits + modified files since last tag)
4. Starts a local HTTP server with IPA + manifest + install page
5. Opens a cloudflared quick tunnel (free, no config needed)
6. Outputs the HTTPS install URL
7. Keeps serving until Ctrl+C

### Cloud mode (`--cloud`)
1. If no `.ipa` provided: archives and exports an Ad Hoc `.ipa`
2. Extracts metadata from `Info.plist`
3. Collects git changelog (commits + modified files since last tag)
4. Uploads `.ipa` to Cloudflare R2 (fixed key `app.ipa` — overwrites previous)
5. Generates `manifest.plist` + install landing page with changelog and release time
6. Deploys to Cloudflare Pages (same URL every time)
7. Outputs the install URL

### Install page features
- App name, version, and build number
- Exact release timestamp
- Git commit log since last tag (or last 10 commits)
- Expandable list of modified files
- Cloud mode uses a **fixed URL** — each deploy overwrites the previous one

## Reconfigure

```bash
bash ~/.claude/skills/air-install-ipa/scripts/setup.sh
```

Or edit `~/.config/air-install-ipa/config` directly.
