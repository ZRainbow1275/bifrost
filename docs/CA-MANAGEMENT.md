# Bifrost Internal CA Management

This document applies when Server A uses:

```bash
BIFROST_SERVER_A_TLS_MODE=internal
```

In this mode Caddy issues certificates from its local authority. Employee devices must trust the exported root certificate before browser and CLI clients accept internal HTTPS endpoints.

## CA Location

Default Caddy local authority path:

```bash
/var/lib/caddy/.local/share/caddy/pki/authorities/local/
```

Protect the directory:

```bash
chmod 700 /var/lib/caddy/.local/share/caddy/pki/authorities/local
chmod 600 /var/lib/caddy/.local/share/caddy/pki/authorities/local/*.key
```

## Employee Bundle

Generate or refresh a user bundle:

```bash
bash ./scripts/user-management.sh refresh-bundle <username>
```

When the root CA exists, the bundle contains:

- `wg0.conf`
- `README-onboarding.md`
- `bifrost-root.crt`
- `install-ca-linux.sh`
- `install-ca-macos.sh`
- `install-ca-windows.ps1`

## Offboarding

Removing a WireGuard peer does not remove the CA from the user's device. Ask the user to run the matching uninstall command:

```bash
sudo bash install-ca-linux.sh --uninstall
sudo bash install-ca-macos.sh --uninstall
./install-ca-windows.ps1 --uninstall
```

If the user is hostile or the device cannot be reached, rotate the local root CA.

## Rotation Cadence

Rotate every six months, or immediately after suspected CA private key exposure:

```bash
bash ./scripts/user-management.sh rotate-ca
```

After rotation:

1. Restart Caddy and verify a new `root.crt`.
2. Refresh all employee bundles.
3. Distribute the new CA and WireGuard config.
4. Remove the archived old CA after verification.

## Emergency Rotation

For urgent compromise:

```bash
BIFROST_NONINTERACTIVE=1 bash ./scripts/user-management.sh rotate-ca
systemctl restart caddy
```

Then force bundle refresh for all users and notify employees that old CA trust must be removed.

## FAQ

If an employee cannot install a private CA, keep that employee on a public TLS mode such as `cloudflare-origin` and document the exception.
