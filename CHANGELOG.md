# Changelog

## Unreleased

### Added

- Added Server A v0.6 hardening local contracts: Mihomo/Xray localhost-only proxy surfaces, Reality SNI sync helper, AI/dev whitelist expansion, persisted `BIFROST_WG_PORT`, nftables strict template, exposure-aware firewall behavior, `tls internal`, vpn-first Caddy bind, onboarding bundle, and CA management docs.
- Added `panel.uuhfn.cloud` local Caddy contract and Vue 3 marketplace panel deployment hooks for `prompts/0519-2`.
- Added live acceptance runbook under the active Trellis task for deferred production validation.

### Changed

- Updated WireGuard user/operator docs to describe `BIFROST_WG_PORT` as the current deployment source of truth, while retaining `51820` only as a legacy fallback.
- Kept legacy Server A TLS modes (`domain`, `cloudflare-origin`, `ip`) compatible with deprecation guidance rather than removing the existing IP HTTPS path.

### Security

- Hardened marketplace admin SSH command handling and audit logging locally.
- Added tarball path traversal validation before marketplace upload extraction.
- Kept production/live acceptance deferred until explicit user authorization; local tests do not replace DNS, allowlist, real Claude client, or live upload/tag evidence.
