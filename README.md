# Air Install IPA

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agent skill for deploying Ad Hoc signed iOS `.ipa` files via OTA (Over-The-Air) installation.

Say `/air-install-ipa` in Claude Code, or just say "deploy ipa" / "安装到手机" — the agent handles the rest.

## Install

```bash
npx skills add isnine/air-install-ipa
```

## Three Deployment Modes

| Mode | Command | How it works | Requires |
|------|---------|-------------|----------|
| **Local** (default) | `/air-install-ipa` | Serves IPA over HTTPS on your local network | `python3`, `mkcert` |
| **Tunnel** | `/air-install-ipa --tunnel` | Serves via cloudflared quick tunnel — no certs on iPhone | `python3`, `cloudflared` |
| **Cloud** | `/air-install-ipa --cloud` | Uploads to Cloudflare R2 + Pages — fixed URL, always overwrites | `wrangler` + Cloudflare account |

If no `.ipa` file is provided, the skill automatically builds one from your current Xcode project.

## Install Page

The generated install page includes:

- **App version & build number**
- **Exact release timestamp**
- **Git changelog** — commit log since last tag (or last 10 commits)
- **Modified files list** — expandable, shows every changed file
- **One-tap install** via `itms-services://` protocol
- **CA certificate guide** (local mode) for first-time iPhone setup

<p align="center">
  <em>Open the install URL on your iPhone in Safari → tap Install.</em>
</p>

## Setup

### Local mode (default)

```bash
brew install mkcert
mkcert -install
mkdir -p ~/.config/air-install-ipa/certs
cd ~/.config/air-install-ipa/certs && mkcert YOUR_HOSTNAME localhost 127.0.0.1
```

Add to `~/.config/air-install-ipa/config`:

```
LOCAL_HOSTNAME=YOUR_HOSTNAME
```

On iPhone (once): open the install page → tap "Download CA Certificate" → trust it in Settings.

### Tunnel mode

No setup needed. Just install `cloudflared`:

```bash
brew install cloudflared
```

### Cloud mode

```bash
bash ~/.claude/skills/air-install-ipa/scripts/setup.sh
```

Walks you through: Cloudflare login → R2 bucket → public URL → Pages project. Config is saved to `~/.config/air-install-ipa/config`.

## Trigger Keywords

The skill activates when you say:

`/air-install-ipa` · `air install` · `deploy ipa` · `ota install` · `upload ipa` · `安装到手机` · `无线安装` · `装到真机` · `发布ipa` · `部署ipa`

## Requirements

- macOS (uses `PlistBuddy` for IPA metadata extraction)
- Xcode (if auto-building from project)
- One of: `mkcert` (local) / `cloudflared` (tunnel) / `wrangler` (cloud)

## License

MIT
