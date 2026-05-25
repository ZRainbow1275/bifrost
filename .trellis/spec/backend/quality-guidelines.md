# Quality Guidelines

> Code quality standards for backend development.

---

## Overview

<!--
Document your project's quality standards here.

Questions to answer:
- What patterns are forbidden?
- What linting rules do you enforce?
- What are your testing requirements?
- What code review standards apply?
-->

(To be filled by the team)

---

## Forbidden Patterns

<!-- Patterns that should never be used and why -->

(To be filled by the team)

---

## Required Patterns

<!-- Patterns that must always be used -->

### Scenario: GitHub hosts repair must be managed and repeatable

#### 1. Scope / Trigger
- Trigger: any change to GitHub clone/pull troubleshooting, `/etc/hosts` repair logic, install CLI recovery commands, or from-zero Server A/B runbooks.
- This is an infra contract because operators may run it on real cloud servers after GitHub TLS failures.

#### 2. Signatures
- Runtime entrypoints:
  - `install.sh --github-hosts-repair`
  - `scripts/github-hosts.sh::repair_github_hosts`
  - `ai-gateway-bridge/install.sh --github-hosts-repair`
  - `ai-gateway-bridge/scripts/github-hosts.sh::repair_github_hosts`
- Operator docs:
  - `FROM_ZERO_SERVER_A_RUNBOOK.md`
  - `FROM_ZERO_SERVER_B_RUNBOOK.md`

#### 3. Contracts
- Do not hard-code screenshot/example GitHub IP addresses as the only path.
- Runtime repair must resolve current public IPv4 records for `github.com` and `raw.githubusercontent.com`, preferring DNS-over-HTTPS and allowing explicit static env overrides for manual recovery.
- Runtime repair must try multiple resolved/static public IPv4 candidates when available and stop on the first pair that passes `git ls-remote`; do not pin operators to the first DNS answer.
- Git verification must have a bounded timeout and must continue to the next candidate on timeout; an unreachable GitHub IP must not hang the operator session indefinitely.
- Git verification must use HTTP/1.1 plus low-speed timeout guards, matching the real Tencent Cloud recovery path where `git ls-remote` may pass but `git pull` can still hit `SSL connection timeout` unless HTTP/1.1 and bounded low-speed settings are used.
- `/etc/hosts` edits must be backed up before writing.
- The script may only replace the `BIFROST-GITHUB-HOSTS` managed block; it must preserve unrelated hosts entries.
- The command must verify the written mappings and attempt repository access with `git ls-remote` unless explicitly skipped for tests.
- Root and `ai-gateway-bridge` copies must stay behaviorally aligned.

#### 4. Validation & Error Matrix
- Invalid/private/static IP -> fail before writing a new hosts block.
- DNS-over-HTTPS cannot resolve a public IPv4 -> fail with manual static-env instructions.
- Hosts file is not writable or `/etc/hosts` is edited without root -> fail before partial writes.
- GitHub verification still fails after the hosts update -> fail and direct the operator to the Windows upload fallback.

#### 5. Tests Required
- `bash ./tests/test-in-docker.sh github-hosts` must cover root and `ai-gateway-bridge` scripts.
- Regression tests must verify: one managed block, old managed mappings replaced, unrelated lines preserved, backup created, invalid/private IPv4 rejected, multi-candidate retry reaches a later working IP pair, hung Git verification times out and continues, Git verification includes HTTP/1.1 plus low-speed timeout guards, and CLI help exposes `--github-hosts-repair`.
- `bash ./tests/test-in-docker.sh syntax functions menu docs` should pass after changing the entrypoint or docs.

### Scenario: Reverse-proxy exposure profiles must include dependent assets

#### 1. Scope / Trigger
- Trigger: any change to Bifrost Caddy templates, generated Caddyfiles, or exposure-profile routing for `vpn-first`, `public-managed`, or `lab`.
- This is an infra contract because the shell scripts generate production reverse-proxy behavior.

#### 2. Signatures
- Runtime generators:
  - `scripts/server-a.sh::setup_caddy_a`
  - `scripts/server-b.sh::setup_caddy_b`
  - `ai-gateway-bridge/scripts/server-a.sh::setup_caddy_a`
  - `ai-gateway-bridge/scripts/server-b.sh::setup_caddy_b`
- Fixture templates:
  - `configs/caddy/Caddyfile-a.tpl`
  - `configs/caddy/Caddyfile-b.tpl`
  - `ai-gateway-bridge/configs/caddy/Caddyfile-a.tpl`
  - `ai-gateway-bridge/configs/caddy/Caddyfile-b.tpl`

#### 3. Contracts
- `BIFROST_EXPOSURE_PROFILE=vpn-first` is production default.
- Public paths may expose business API/readiness endpoints and the decoy site.
- Management paths must be guarded by `remote_ip` allowlists.
- New API dashboard access is not just `/dashboard` and `/login`; it also includes frontend assets needed by the UI, currently `/static/*` and `/logo.png`.
- Root and `ai-gateway-bridge` copies must stay behaviorally identical.

#### 4. Validation & Error Matrix
- Missing dashboard asset route in allowlist -> allowlisted users can load HTML but fail JS/CSS/logo requests.
- Asset route falls through to decoy site -> false-success page with broken New API UI.
- Non-allowlisted origin reaches management asset -> management surface leak.
- Server start/firewall command fails but script continues -> deployment summary lies.

#### 5. Good/Base/Bad Cases
- Good: `vpn-first` allowlists `/api/* /static/* /logo.png /dashboard /dashboard/* /login /panel /token /user/* /admin/*` for New API management, and returns `403` for those paths outside the allowlist.
- Base: `public-managed` explicitly reverse-proxies dashboard assets and warns that management is public.
- Bad: only `/dashboard` is allowlisted while `/static/*` falls through to the decoy site.

#### 6. Tests Required
- Static parity tests must assert both generated scripts and Caddy templates contain the same profile routes.
- Generated Caddyfile tests must verify `vpn-first` and `public-managed` outputs separately.
- Path assertions containing `*` or `.` must use literal matching (`grep -Fq`) unless a regex is deliberately required.
- Regression tests must prove fail-fast behavior for Caddy start failures and firewall command failures.

#### 7. Wrong vs Correct
##### Wrong
```bash
grep -q "path /api/* /static/* /logo.png /dashboard" "$CADDY_CONFIG"
```

The `*` characters are regex quantifiers, so this can pass or fail for the wrong reason.

##### Correct
```bash
grep -Fq "path /api/* /static/* /logo.png /dashboard" "$CADDY_CONFIG"
```

Use fixed-string matching for generated Caddy path contracts.

### Scenario: Server A IP HTTPS mode must be explicit Certbot-managed TLS

#### 1. Scope / Trigger
- Trigger: any change to Server A endpoint collection, Caddy TLS generation, certificate renewal, deployment summaries, client URL output, or domain/ICP deployment docs.
- This is an infra contract because Tencent/domestic Server A can run without a bound ICP domain only through an explicit IP certificate path, not by silently downgrading to HTTP.

#### 2. Signatures
- Runtime generators:
  - `scripts/server-a.sh::setup_caddy_a`
  - `ai-gateway-bridge/scripts/server-a.sh::setup_caddy_a`
- Helper contracts:
  - `server_a_tls_mode`
  - `collect_server_a_public_ip`
  - `bootstrap_ip_certificate`
  - `server_a_caddy_tls_block`
  - `server_a_ip_http_challenge_block`
- Fixture templates:
  - `configs/caddy/Caddyfile-a.tpl`
  - `ai-gateway-bridge/configs/caddy/Caddyfile-a.tpl`

#### 3. Contracts
- `BIFROST_SERVER_A_TLS_MODE=domain` remains the default and continues to ask for an ICP-registered FQDN.
- `BIFROST_SERVER_A_TLS_MODE=ip` enables no-domain IP HTTPS mode.
- `BIFROST_SERVER_A_PUBLIC_IP` optionally supplies the public IPv4; otherwise the script may detect and then ask the operator to confirm.
- `BIFROST_ACME_EMAIL` optionally supplies the Let's Encrypt account contact.
- `BIFROST_CERTBOT_INSTALL_METHOD=snap|apt|none` controls Certbot installation; `snap` is the default because Ubuntu 22.04 apt can lag behind Certbot 5.4.
- IP mode must request Let's Encrypt with `--preferred-profile shortlived --ip-address <public-ip>`.
- IP mode must configure Caddy with explicit files: `tls /etc/letsencrypt/live/<ip>/fullchain.pem /etc/letsencrypt/live/<ip>/privkey.pem`.
- IP mode must keep HTTP-01 challenge handling under `/.well-known/acme-challenge/*` and configure frequent renewal plus Caddy reload.
- Saved Server A endpoint state must include `ENDPOINT_MODE`, `SERVER_A_ENDPOINT_HOST`, and `SERVER_A_BASE_URL`; `DOMAIN` alone is not enough.

#### 4. Validation & Error Matrix
- Invalid `BIFROST_SERVER_A_TLS_MODE` -> fail before writing final Caddy config.
- Invalid public IPv4 -> re-prompt or fail if supplied by env.
- Certbot missing or below 5.4 -> install/upgrade or fail; do not attempt an IP cert with unsupported Certbot.
- Certbot order rejected or certificate files missing -> fail setup; do not print a usable HTTPS endpoint.
- Caddy validation/restart failure -> fail setup; deployment summary must not claim complete.
- Renewal timer/hook cannot be installed -> fail setup because IP certificates are short-lived.

#### 5. Good/Base/Bad Cases
- Good: Tencent Server A with no domain sets `BIFROST_SERVER_A_TLS_MODE=ip`, obtains a short-lived IP cert, Caddy serves `https://<ip>/v1`, and `bifrost-certbot-renew.timer` reloads Caddy after renewal.
- Base: Server A has a备案 domain and uses default domain mode with Caddy-managed ACME.
- Bad: no domain mode falls back to plain HTTP, self-signed TLS, Caddy internal CA, or a public endpoint summary using `https://<ip>` without a publicly trusted IP certificate.

#### 6. Tests Required
- Generated Caddyfile tests must cover both domain/profile behavior and IP HTTPS behavior.
- Static parity tests must assert root and `ai-gateway-bridge` scripts/templates contain the IP certificate contract.
- Assertions must check `--preferred-profile shortlived`, `--ip-address`, explicit Caddy `tls <fullchain> <privkey>`, HTTP-01 webroot, saved `SERVER_A_BASE_URL`, and renewal timer service content.
- Full project test should include `syntax`, `deploy`, `dd`, and the Bifrost API contract when backend compatibility code changes.

#### 7. Wrong vs Correct
##### Wrong
```bash
https://203.0.113.10 {
    tls internal
    reverse_proxy localhost:3000
}
```

This creates a locally trusted certificate and will not satisfy real browsers or API clients on another machine.

##### Correct
```bash
certbot certonly --preferred-profile shortlived --webroot --webroot-path /var/www/bifrost-acme --ip-address 203.0.113.10

https://203.0.113.10 {
    tls /etc/letsencrypt/live/203.0.113.10/fullchain.pem /etc/letsencrypt/live/203.0.113.10/privkey.pem
    reverse_proxy localhost:3000
}
```

Use the public Let's Encrypt IP certificate and keep renewal automated.

### Scenario: Starlette TemplateResponse signature must be runtime-compatible

#### 1. Scope / Trigger
- Trigger: any change to Bifrost API HTML page rendering, FastAPI/Starlette versions, or `Jinja2Templates.TemplateResponse` calls.

#### 2. Signatures
- `bifrost-api/app/routers/register.py::_template_response(request, name, context)`
- `bifrost-api/app/routers/register.py::register_page`

#### 3. Contracts
- The template context must always include `request`.
- The renderer must support Starlette variants where `TemplateResponse` accepts `request=` and variants where the signature is `TemplateResponse(name, context, ...)`.

#### 4. Validation & Error Matrix
- Local Starlette rejects `request=` keyword -> route must still render through the legacy positional signature.
- Newer Starlette accepts `request=` -> keep the newer call form to avoid deprecation drift.

#### 5. Good/Base/Bad Cases
- Good: inspect the runtime signature once and dispatch to the matching call style.
- Base: direct legacy call works on Starlette 0.27.
- Bad: hardcode only `request=` and break the local API contract test on older Starlette.

#### 6. Tests Required
- `bash ./tests/test-in-docker.sh bifrost` must cover the `/register` page.
- `python -m py_compile bifrost-api/app/routers/register.py` must pass after router edits.

#### 7. Wrong vs Correct
##### Wrong
```python
return templates.TemplateResponse(request=request, name="register.html", context={"request": request})
```

This fails on Starlette releases whose `TemplateResponse` method does not accept `request` as a keyword.

##### Correct
```python
template_context = {"request": request, **context}
if _TEMPLATE_RESPONSE_ACCEPTS_REQUEST_KW:
    return templates.TemplateResponse(request=request, name=name, context=template_context)
return templates.TemplateResponse(name, template_context)
```

Branch on the installed runtime signature instead of assuming one framework version.

### Scenario: New API one-click deployment must be preflighted and repeatable

#### 1. Scope / Trigger
- Trigger: any change to Server A New API deployment, generated `docker-compose.yml`, Caddy TLS mode handling, or New API troubleshooting docs.
- This is an infra contract because deployment scripts run on real VPS hosts and must fail before printing a usable endpoint when configuration is invalid.

#### 2. Signatures
- Runtime generators:
  - `scripts/server-a.sh::install_new_api`
  - `scripts/server-a.sh::prepare_new_api_env`
  - `scripts/server-a.sh::setup_caddy_a`
  - `ai-gateway-bridge/scripts/server-a.sh::install_new_api`
  - `ai-gateway-bridge/scripts/server-a.sh::prepare_new_api_env`
  - `ai-gateway-bridge/scripts/server-a.sh::setup_caddy_a`
- Fixture templates:
  - `configs/caddy/Caddyfile-a.tpl`
  - `ai-gateway-bridge/configs/caddy/Caddyfile-a.tpl`

#### 3. Contracts
- Server A one-click deployment is `install.sh --server-a`; do not create an unrelated New API deployment entrypoint unless the main chain calls it.
- Generated New API compose files must bind `3000` to `127.0.0.1` only.
- Deployment must run `docker compose config --quiet` before `docker compose pull` or `docker compose up -d`.
- Runtime secrets and database credentials must persist in `/opt/new-api/.env`; reruns must reuse existing values instead of silently regenerating them.
- PostgreSQL mode must be explicit via `BIFROST_NEW_API_DB=postgres`; the generated internal Docker-network DSN must include `sslmode=disable`.
- Existing PostgreSQL data without the original `.env` is a hard stop unless the operator provides the existing password or performs an explicit migration/reset.
- Cloudflare Origin CA mode must be explicit via `BIFROST_SERVER_A_TLS_MODE=cloudflare-origin` and must validate both `BIFROST_CLOUDFLARE_ORIGIN_CERT` and `BIFROST_CLOUDFLARE_ORIGIN_KEY` before writing the final Caddyfile.
- `BIFROST_SERVER_A_DOMAIN` must allow non-interactive domain mode.

#### 4. Validation & Error Matrix
- Compose syntax/interpolation failure -> fail before pulling images.
- New API readiness timeout -> fail and print recent compose logs.
- Public `0.0.0.0:3000` or `:::3000` binding -> fail because Caddy is the only public ingress.

### Scenario: Server B private distribution must stay wg-only and read-only observable

#### 1. Scope / Trigger
- Trigger: any change to Server B distribution templates, `scripts/server-b.sh --enable-distribution`, Server A `api/npm/files` reverse-proxy routing, bifrost-api `/mirrors/*`, or distribution diagnostics.
- This is an infra and API contract because it binds Docker, nftables, Caddy, systemd, WireGuard, SSH forced commands, FastAPI responses, and public DNS behavior.

#### 2. Signatures
- Commands:
  - `scripts/server-b.sh --enable-distribution`
  - `scripts/server-b.sh --disable-distribution`
  - `scripts/server-b.sh --rotate-bootstrap-pwd`
  - `scripts/diagnostics.sh --check distribution`
  - `scripts/e2e-distribution-rehearsal.sh [--execute]`
- FastAPI routes:
  - `GET /mirrors/status`
  - `GET /mirrors/logs?service={verdaccio|new-api|newapi|git-sync|git-mirror}&tail=1..1000`
  - `GET /mirrors/disk`
- Environment keys:
  - `BIFROST_SERVER_A_NEWAPI_MODE=distribution|legacy`
  - `BIFROST_SERVER_B_WG_IP`
  - `BIFROST_READONLY_SSH_KEY`
  - `BIFROST_READONLY_USER`
  - `BIFROST_READONLY_SSH_PUBLIC_KEY`

#### 3. Contracts
- Server B distribution services bind to `10.8.0.2` only: NewAPI `3000`, Verdaccio `4873`, files `8081`, git smart HTTP `8082`.
- Server A is the public TLS endpoint and reverse-proxies `api.<domain>`, `npm.<domain>`, and `files.<domain>` to Server B over wg0.
- `BIFROST_SERVER_A_NEWAPI_MODE=distribution` is the default; local Server A NewAPI install is legacy and must be explicitly selected.
- `BIFROST_DISTRIBUTION_DOMAIN` may explicitly set the root distribution domain. If it is absent and the Server A domain is already `api.*`, `npm.*`, `files.*`, or `legacy.*`, the root domain must be derived by stripping the first label so the generated sites do not become `api.api.<domain>`.
- The generic Server A `server_b_proxy` snippet must not hard-code a shared `health_uri /-/ping`; that path is Verdaccio-specific and would mark NewAPI or files upstreams unhealthy.
- Docker bypass must be closed with `DOCKER-USER` DROP rules for `3000/4873/8081/8082` on public `eth0`.
- Verdaccio bootstrap password must not be written to deploy state, API responses, or logs. It may be written once to `/root/.verdaccio-bootstrap-pwd.txt` with `0400`.
- bifrost-api mirror logs and disk usage must use `bifrost-readonly` forced-command SSH, not root SSH.
- `/mirrors/status` may degrade to `up=false`; `/mirrors/logs` and `/mirrors/disk` must fail closed with 503/502/504 and must not leak private key paths or stack traces.

#### 4. Validation & Error Matrix
- `wg0` missing on Server B -> `--enable-distribution` fails before services start.
- Caddy lacks `Requires=wg-quick@wg0.service` -> diagnostics fails.
- Server A is configured with `BIFROST_SERVER_A_DOMAIN=api.uuhfn.cloud` but no `BIFROST_DISTRIBUTION_DOMAIN` -> generated distribution sites must be `api.uuhfn.cloud`, `npm.uuhfn.cloud`, and `files.uuhfn.cloud`, not `api.api.uuhfn.cloud`.
- Server A `server_b_proxy` uses `health_uri /-/ping` for every upstream -> NewAPI and files can be falsely ejected from the upstream pool.
- NewAPI compose lacks `sslmode=disable` -> diagnostics and tests fail.
- Caddy git endpoint allows `git-receive-pack` -> tests fail because mirror must be read-only.
- `BIFROST_READONLY_SSH_KEY` missing -> `/mirrors/logs` and `/mirrors/disk` return 503, while `/mirrors/status` reports `ssh_configured=false`.
- Unsupported `/mirrors/logs service` -> 422.
- Re-running `--enable-distribution` after completed steps -> skip completed step-state entries and keep generated secrets stable.

#### 5. Good/Base/Bad Cases
- Good: Server B only exposes distribution ports on wg0, Server A publishes `api/npm/files`, diagnostics passes, `/mirrors/status` shows per-service state, and git push returns 403.
- Base: readonly SSH key has not been installed yet; status still works with `ssh_configured=false`, but logs/disk fail closed.
- Bad: Docker publishes `0.0.0.0:4873`, bifrost-api reads logs with root SSH, or Verdaccio bootstrap password appears in `distribution.env`.

#### 6. Tests Required
- `bash tests/test-in-docker.sh distribution` must assert templates, DOCKER-USER rules, forced-command SSH, diagnostics, Server A reverse-proxy routes, and mocked `enable_distribution` idempotency.
- Distribution tests must assert Server A root-domain derivation for prefixed domains and must reject a shared `health_uri /-/ping` in the generic Server B proxy snippet.
- `bash tests/test-in-docker.sh bifrost` must assert `/mirrors/*` admin auth and missing-key error semantics.
- `bash tests/test-in-docker.sh deploy` must assert Server A distribution mode does not silently reinstall local NewAPI by default.
- `bash -n` must cover all new shell scripts and templates with shell content.
- `python -m compileall -q bifrost-api/app` must pass after router changes.

#### 7. Wrong vs Correct
##### Wrong
```bash
docker run -p 0.0.0.0:4873:4873 verdaccio/verdaccio:6.7.1
echo "VERDACCIO_BOOTSTRAP_PASSWORD=$password" >> /var/lib/bifrost/distribution.env
```

This exposes Verdaccio publicly and stores the bootstrap secret in deploy state.

##### Correct
```bash
docker run -p 10.8.0.2:4873:4873 -e VERDACCIO_PUBLIC_URL=https://npm.uuhfn.cloud verdaccio/verdaccio:6.7.1
iptables -C DOCKER-USER -i eth0 -p tcp --dport 4873 -j DROP 2>/dev/null \
  || iptables -I DOCKER-USER -i eth0 -p tcp --dport 4873 -j DROP
```

Bind the service to wg0 and block Docker's public ingress path separately from nftables.
- PostgreSQL `password authentication failed` / `SQLSTATE 28P01` -> explain password-volume drift; do not suggest blind `up -d`.
- PostgreSQL TLS noise -> require `sslmode=disable` for internal container traffic.
- Cloudflare Origin cert/key missing or empty -> fail before Caddy restart.

#### 5. Good/Base/Bad Cases
- Good: `BIFROST_SERVER_A_TLS_MODE=cloudflare-origin` with `BIFROST_SERVER_A_DOMAIN`, readable Origin cert/key files, `BIFROST_EXPOSURE_PROFILE=vpn-first`, pinned `BIFROST_NEW_API_IMAGE`, and a generated compose file that passes `docker compose config --quiet`.
- Base: default domain mode with Caddy-managed ACME and SQLite storage; still preflights compose and binds New API to `127.0.0.1:3000`.
- Bad: editing `/opt/new-api/docker-compose.yml` to introduce PostgreSQL and a new password while reusing an old `postgres-data` volume, then running `docker compose up -d` directly.

#### 6. Tests Required
- Static tests must assert root and bridge scripts contain env persistence, compose quiet validation, loopback port validation, PostgreSQL `sslmode=disable`, and Cloudflare Origin CA file checks.
- Generated Caddyfile tests must cover domain/profile, IP HTTPS, and Cloudflare Origin CA TLS mode.
- Documentation must include copyable one-click commands and the PostgreSQL volume/password drift recovery path.

#### 7. Wrong vs Correct
##### Wrong
```bash
cd /opt/new-api
docker compose up -d
```

This bypasses compose validation, does not check loopback-only port binding, and can hide PostgreSQL password-volume drift until runtime.

##### Correct
```bash
export BIFROST_SERVER_A_TLS_MODE=cloudflare-origin
export BIFROST_SERVER_A_DOMAIN=api.example.com
export BIFROST_CLOUDFLARE_ORIGIN_CERT=/etc/caddy/certs/api.example.com-origin.pem
export BIFROST_CLOUDFLARE_ORIGIN_KEY=/etc/caddy/certs/api.example.com-origin.key
export BIFROST_NEW_API_IMAGE="calciumion/new-api:<fixed-version-or-digest>"
sudo ./install.sh --server-a
```

Keep the generated `/opt/new-api/.env` with the data directory; reruns must reuse its database password and `SESSION_SECRET`.

### Scenario: Deployment scripts must not dirty the checked-out repository

#### 1. Scope / Trigger
- Trigger: any change to deployment scripts, security hardening, generated runtime config, or from-zero Server A/B runbooks.
- This is an infra contract because operators run these commands from `/opt/bifrost` on real servers and then rely on `git pull --ff-only` for updates.

#### 2. Signatures
- Runtime scripts:
  - `scripts/security.sh::harden_kernel`
  - `ai-gateway-bridge/scripts/security.sh::harden_kernel`
- Operator docs:
  - `FROM_ZERO_SERVER_A_RUNBOOK.md`
  - `FROM_ZERO_SERVER_B_RUNBOOK.md`
  - `README.md`
  - `docs/USAGE.md`

#### 3. Contracts
- Deployment commands may write runtime state under `/etc`, `/var`, `/root`, or explicit operator-selected paths.
- Deployment commands must not copy runtime-generated files back into repository-tracked paths such as `configs/**`.
- Runbooks must not ask operators to run broad `chmod +x install.sh scripts/*.sh`; executable bits must be tracked in Git.
- If an operator already dirtied the working tree with old commands, runbooks must first save `git diff`, then restore only the affected repository files before `git pull --ff-only`.
- Root and `ai-gateway-bridge` copies must stay behaviorally aligned.

#### 4. Validation & Error Matrix
- `git status` shows many mode-only `M scripts/*.sh` after a runbook `chmod` -> document it as file-mode drift and remove the chmod instruction.
- `M configs/sysctl/hardening.conf` appears after `--security` -> treat as a script bug; runtime sysctl output must remain under `/etc/sysctl.d/`.
- Local restore guidance must not touch system files such as `/etc/hosts`, `/etc/ssh/sshd_config`, or `/etc/sysctl.d/`.

#### 5. Tests Required
- Security tests must prove `harden_kernel` writes the runtime sysctl file and preserves repo `configs/sysctl/hardening.conf`.
- Syntax checks must cover root and `ai-gateway-bridge` security scripts.
- Documentation checks must reject reintroducing broad `chmod +x install.sh scripts/*.sh` bootstrap steps.

---

## Testing Requirements

<!-- What level of testing is expected -->

(To be filled by the team)

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)
