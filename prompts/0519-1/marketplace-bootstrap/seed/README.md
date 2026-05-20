# bifrost-internal Marketplace - Team Onboarding & Offline Seed

This directory ships two things:

1. The **onboarding walkthrough** (this README) -- a 10-minute path from
   a clean laptop to a running `/plugin install hello-world-skill`.
2. A **build script** (`scripts/build-marketplace-seed.sh`) that produces
   an offline tarball for laptops without VPN / LAN access to Server A.

If you are picking up a workstation for the first time, start at
**[1. Quick start (network mode)](#1-quick-start-network-mode)** below.
If your VPN is broken or you are on an isolated network, jump to
**[2. Offline mode](#2-offline-mode-via-seed-tarball)**.

---

## 1. Quick start (network mode)

**Pre-requisites**

- WireGuard tunnel up. `dig +short files.uuhfn.cloud` MUST return the
  Server A public IP, and `curl -I https://files.uuhfn.cloud/` MUST
  return HTTP 2xx.
- Claude Code CLI installed (`claude --version` works).

**Steps**

```bash
# 1. Place the team settings template
mkdir -p ~/.claude
cp prompts/0519-1/team-config/.claude/settings.json.template \
   ~/.claude/settings.json
# Open the file and tweak ANTHROPIC_BASE_URL / enabledPlugins / permissions
# to match what your team agreed on.

# 2. (Optional) Copy the team CLAUDE.md.template to your project root
cp prompts/0519-1/team-config/CLAUDE.md.template <your-project>/CLAUDE.md
# Replace <PROJECT_NAME> inside.

# 3. Start Claude Code
claude

# 4. Inside the TUI
/plugin browse
# You should see the bifrost-internal marketplace and hello-world-skill.

/plugin install hello-world-skill@bifrost-internal
# Files land under ~/.claude/plugins/cache/bifrost-internal/hello-world-skill/<version>/
```

**Success check**: `~/.claude/plugins/cache/bifrost-internal/hello-world-skill/v0.1.0/`
exists and contains `skills/hello/SKILL.md`.

---

## 2. Offline mode (via seed tarball)

Use this path when:

- Travelling, or VPN is down.
- A fresh laptop has not yet been enrolled in WireGuard.
- CI / sandbox environments without outbound access to `files.uuhfn.cloud`.

**Build the tarball** (run inside the repo, anywhere with a working bash):

```bash
bash scripts/build-marketplace-seed.sh --output dist/marketplace-seed.tar.gz
# Output:
#   dist/marketplace-seed.tar.gz
#   dist/marketplace-seed.tar.gz.sha256
```

**Distribute** the two files via any side channel (USB stick, S3 bucket,
internal Verdaccio file-store).

**Consume the tarball on the target machine**:

```bash
# 1. Verify integrity
sha256sum -c marketplace-seed.tar.gz.sha256

# 2. Extract to a stable location
mkdir -p ~/marketplace-seed
tar xzf marketplace-seed.tar.gz -C ~/marketplace-seed

# 3. Point Claude Code at the seed and skip network discovery
export CLAUDE_CODE_PLUGIN_SEED_DIR="$HOME/marketplace-seed/bifrost-internal-plugins"
echo "export CLAUDE_CODE_PLUGIN_SEED_DIR=$HOME/marketplace-seed/bifrost-internal-plugins" \
    >> ~/.bashrc   # persist

# 4. Drop the settings template (if not done yet)
mkdir -p ~/.claude
cp ~/marketplace-seed/settings.json.template ~/.claude/settings.json

# 5. Launch
claude
# /plugin browse should still show bifrost-internal even with WG down.
```

**Reproducibility note**: the build script pins tar `--mtime / --owner /
--group / --sort` so the sha256 is byte-stable across machines for the
same source tree. If two builds disagree, the source repository drifted.

---

## 3. Updating to the latest plugin version

Once your laptop is back on the management VPN:

```bash
# Inside Claude Code:
/plugin marketplace update bifrost-internal
/plugin install hello-world-skill@bifrost-internal           # latest
/plugin install hello-world-skill@bifrost-internal --version v0.1.0  # pinned
```

`/plugin marketplace update` clones `https://files.uuhfn.cloud/git/bifrost-internal-plugins.git`
under the hood; it requires LAN reachability. If that fails, you fall back
to the offline seed (section 2) until VPN is fixed.

---

## 4. Troubleshooting

| Symptom | First check | Fix |
|---|---|---|
| `/plugin browse` does not show `bifrost-internal` | `jq '.extraKnownMarketplaces' ~/.claude/settings.json` | Re-copy the template, ensure `source.source == "url"` and `source.url` ends in `bifrost-internal-plugins.git` (no `git+` prefix). |
| `/plugin install` fails with SSL / connection refused | `curl -I https://files.uuhfn.cloud/` | Bring the WG tunnel up; check `wg show wg0`. If still failing, fall back to offline seed. |
| `permission denied` on a Bash tool | `permissions.deny` is doing its job | If legitimate, talk to the security reviewer about adding a narrow allow rule -- do NOT delete entries from `deny`. |
| Offline seed sha256 mismatch | Source tree drifted, or download corrupted | Re-run `bash scripts/build-marketplace-seed.sh` against a clean checkout, or re-download. |
| Plugin version not appearing after upload | Server B `marketplace-render.path` not triggered | Ask an admin to inspect `journalctl -u marketplace-render.service` on B (PR-4 surfaces this in `/marketplace/status`). |

---

## 5. Uploading a new plugin (admin workflow)

End-to-end SOP lives in `spec.md` section 6.3. Short version:

1. Add `plugins/<name>/` to a local clone of the bare repo.
2. Tarball + manifest: `tar czf <name>-vX.Y.Z.tar.gz -C plugins/<name> .`
3. Browse to `https://panel.uuhfn.cloud/marketplace/upload` (admin token
   gated, VPN-only).
4. Submit the tarball + manifest. The admin pipeline creates the
   `plugins/<name>/vX.Y.Z` annotated tag and triggers
   `marketplace-render.service`.
5. Notify the team to run `/plugin marketplace update bifrost-internal`.

Direct `git push` is intentionally blocked (Caddy returns 403 on
`git-receive-pack`); the panel route is the only sanctioned write path.

---

## 6. Security boundary (RK-2 mitigation)

- **Internal-only distribution** -- ADR-4 in `spec.md` section 5.2 mandates
  ALL-RIGHTS-RESERVED licensing and bans mirroring upstream. Do not
  redistribute this marketplace outside the team.
- **`permissions.deny` is the last line of defence** against a malicious
  plugin trying to `curl` from public GitHub or `npm install` from the
  public registry. The template ships 12 deny entries; treat any
  diminution as a security-reviewable change.
- **Plugin upload audit log** lives at
  `/var/log/marketplace/admin-audit.log` on Server B. The bifrost-readonly
  router exposes a tail of it through `/marketplace/logs?service=marketplace-render`.
- **No tokens in the template** -- `X-Admin-Key`, Anthropic API keys, and
  Verdaccio bootstrap passwords MUST come from the developer's credential
  manager, never from a committed file.

---

## File map

```
prompts/0519-1/team-config/
  .claude/settings.json.template   # extraKnownMarketplaces + permissions.deny
  CLAUDE.md.template               # team conventions for AI assistants

prompts/0519-1/marketplace-bootstrap/
  bifrost-internal-plugins/        # the seed marketplace (PR-1)
  seed/README.md                   # this file

scripts/
  build-marketplace-seed.sh        # offline tarball builder
```
