# bifrost-internal-plugins

Internal Claude Code plugin marketplace for the Bifrost team. **Team-only**;
not intended for public consumption and not a mirror of any upstream
(see ADR-4 in `spec.md` section 5.2 for the LICENSE-compliance rationale).

## Layout

```
.
├── .claude-plugin/
│   └── marketplace.json     # protocol file consumed by Claude Code clients
├── plugins/
│   └── hello-world-skill/   # sample plugin
│       ├── .claude-plugin/plugin.json
│       ├── manifest.yaml    # Bifrost-internal additional fields
│       ├── skills/hello/SKILL.md
│       ├── LICENSE
│       └── README.md
├── LICENSE
├── NOTICE
└── README.md
```

`.claude-plugin/marketplace.json` is **not authored by hand** in production —
it is rendered by `scripts/render-marketplace-json.sh` (executed as a oneshot
service `marketplace-render.service` on Server B, triggered by
`marketplace-render.path` watching the bare repo's refs). The seed copy
checked in here is the byte-stable shape used for schema-validation tests.

## Consuming from Claude Code clients

Team members on the management VPN run, once:

```bash
/plugin marketplace add https://files.uuhfn.cloud/git/bifrost-internal-plugins.git
/plugin install hello-world-skill@bifrost-internal
```

(No `git+` prefix — `spec.md` section 4.1 / C3.)

## Plugin authoring workflow

See `spec.md` section 6.3 — short version: never push directly to this bare
repo (Caddy returns 403 on receive-pack). Upload via the panel admin
endpoint at `panel.uuhfn.cloud/marketplace/upload`.

## LICENSE

ALL-RIGHTS-RESERVED. See `LICENSE` and `NOTICE`.
