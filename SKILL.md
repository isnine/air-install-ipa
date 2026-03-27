---
name: air-install-ipa
description: "Deploy an Ad Hoc signed .ipa for wireless OTA installation. Two modes: local HTTPS (mkcert) or cloud (Cloudflare R2 + Pages). Use when the user says /air-install-ipa, 'air install', 'deploy ipa', 'ota install', 'upload ipa', '安装到手机', '无线安装', '装到真机', '发布ipa', '部署ipa', or wants to distribute an iOS app for over-the-air installation to a device. Requires: macOS, python3 + mkcert (local), or wrangler (cloud)."
---

# Air Install IPA

Build and deploy an Ad Hoc signed `.ipa` for OTA installation.

## First-time setup

If no config exists (`~/.config/air-install-ipa/config`), **ask the user which mode they prefer** before running setup:

> **Local HTTPS** — Serves IPA from this Mac over the local network. Fastest option (no upload). Requires the iPhone to be on the same Wi-Fi and to trust a CA certificate once. Needs `mkcert` + `python3`.
>
> **Cloud (Cloudflare)** — Uploads IPA to Cloudflare R2 and deploys an install page to Cloudflare Pages. Works from anywhere, no cert trust needed. Needs `wrangler` CLI + free Cloudflare account.

Then run setup with the chosen mode:

```bash
# Local mode
bash ~/.claude/skills/air-install-ipa/scripts/setup.sh --mode local --hostname YOUR_HOSTNAME

# Cloud mode
bash ~/.claude/skills/air-install-ipa/scripts/setup.sh --mode cloud
```

Setup saves `DEPLOY_MODE` to config. All future deploys use this mode automatically.

## Deploy

```bash
# Auto-build from current Xcode project (uses configured mode)
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh

# Deploy a pre-built .ipa
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh path/to/App.ipa

# Override mode for this run
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh --local
bash ~/.claude/skills/air-install-ipa/scripts/deploy.sh --cloud
```

## Behavior

### Singleton
Each deploy kills any previous running server. Only one deploy is active at a time.

### Auto-shutdown (local mode)
- Server auto-stops after **30 minutes**
- If the IPA is downloaded, server stops **3 minutes** after download
- Override via env: `AIR_INSTALL_TIMEOUT=3600` (seconds), `AIR_INSTALL_DOWNLOAD_GRACE=300`

### Non-blocking (local mode)
- In a **terminal** (interactive): script waits for Ctrl+C
- In **Claude Code** (non-interactive): script exits immediately, server runs in background

### Install page features
- App name, version, and build number
- Exact release timestamp
- Git commit log (last 3 commits + uncommitted files)
- Local mode: CA certificate download button + trust guide for first-time iPhone setup
- Cloud mode: fixed URL — each deploy overwrites the previous one

## Reconfigure

```bash
bash ~/.claude/skills/air-install-ipa/scripts/setup.sh
```

Or edit `~/.config/air-install-ipa/config` directly.
