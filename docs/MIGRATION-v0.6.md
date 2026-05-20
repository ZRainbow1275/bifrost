# Bifrost v0.6 Server A Migration

This guide covers the Server A hardening path introduced by `05-19-server-a-hardening-v2`.

## Summary

v0.6 keeps the existing public modes for compatibility, but recommends a private default for technical teams:

- `BIFROST_EXPOSURE_PROFILE=vpn-first`
- `BIFROST_SERVER_A_TLS_MODE=internal`
- WireGuard on a persisted high UDP port from `/etc/bifrost.env`
- Caddy bound to `10.8.0.1` instead of public `0.0.0.0`

The old `domain`, `cloudflare-origin`, and `ip` TLS modes still work. They now print a deprecation notice during Server A setup so operators do not mistake public 80/443 exposure for the hardened path.

## Mode Matrix

| Exposure profile | TLS mode | Public 80/443 | Caddy bind | Status |
|---|---|---:|---|---|
| `vpn-first` | `internal` | No | `10.8.0.1` | Recommended for technical employees |
| `public-managed` | `domain` | Yes | default | Compatibility |
| `public-managed` | `cloudflare-origin` | Yes | default | Compatibility |
| `public-managed` | `ip` | Yes | default | Legacy no-domain bootstrap |
| `lab` | any | Yes | default | Non-production only |

## Existing Public Domain Mode

Keep current behavior:

```bash
export BIFROST_EXPOSURE_PROFILE=public-managed
export BIFROST_SERVER_A_TLS_MODE=domain
bash ./install.sh --server-a
```

Migrate to vpn-first internal mode:

```bash
export BIFROST_EXPOSURE_PROFILE=vpn-first
export BIFROST_SERVER_A_TLS_MODE=internal
export BIFROST_ADMIN_ALLOWED_RANGES="10.8.0.0/24,127.0.0.1"
bash ./install.sh --server-a
```

Then distribute each employee's WireGuard bundle and, in `internal` mode, the Caddy local root CA.

## Cloudflare Origin Mode

`cloudflare-origin` remains valid when Cloudflare DNS is proxied and SSL/TLS mode is `Full (strict)`.

For vpn-first deployments, prefer `internal` because the service should not depend on a public Cloudflare edge path.

## IP HTTPS Mode

`ip` mode is retained for no-domain bootstrap and does not remove the Certbot IP certificate code path.

Use it only when you intentionally need public IP HTTPS:

```bash
export BIFROST_EXPOSURE_PROFILE=public-managed
export BIFROST_SERVER_A_TLS_MODE=ip
bash ./install.sh --server-a
```

## Trusting The Internal CA

After `internal` mode starts Caddy, the local root is usually available at:

```bash
/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
```

For each user, generate or refresh the bundle:

```bash
bash ./scripts/user-management.sh refresh-bundle <username>
```

The bundle includes `install-ca-linux.sh`, `install-ca-macos.sh`, and `install-ca-windows.ps1` when the Caddy root CA exists.

## Rollback

Return to the public legacy path:

```bash
export BIFROST_EXPOSURE_PROFILE=public-managed
export BIFROST_SERVER_A_TLS_MODE=ip
bash ./install.sh --server-a
```

If nftables strict mode was enabled, set a legacy firewall backend before rerunning:

```bash
export BIFROST_FIREWALL_BACKEND=ufw
```

## Operational Notes

- The WireGuard port is stored as `BIFROST_WG_PORT` in `/etc/bifrost.env`.
- Reality SNI rotations on Server B require syncing Server A with `scripts/sync-sni-to-a.sh`.
- Do not remove existing `domain`, `cloudflare-origin`, or `ip` code paths while legacy users still depend on them.
